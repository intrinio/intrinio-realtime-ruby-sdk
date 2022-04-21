require 'logger'
require 'uri'
#require 'http'
require 'net/http'
require 'eventmachine'
require 'websocket-client-simple'

module Intrinio
  module Realtime
    HEARTBEAT_TIME = 3
    SELF_HEAL_BACKOFFS = [0, 100, 500, 1000, 2000, 5000].freeze
    REALTIME = "REALTIME".freeze
    MANUAL = "MANUAL".freeze
    PROVIDERS = [REALTIME, MANUAL].freeze
    ASK = "Ask".freeze
    BID = "Bid".freeze

    def self.connect(options, on_trade, on_quote)
      EM.run do
        client = ::Intrinio::Realtime::Client.new(options, on_trade, on_quote)
        client.connect()
      end
    end

    class Trade
      def initialize(symbol, price, size, timestamp, total_volume)
        @symbol = symbol
        @price = price
        @size = size
        @timestamp = timestamp
        @total_volume = total_volume
      end

      def symbol
        @symbol
      end

      def price
        @price
      end

      def size
        @size
      end

      def timestamp
        @timestamp
      end

      def total_volume
        @total_volume
      end

      def to_s
        [@symbol, @price, @size, @timestamp, @total_volume].join(",")
      end
    end

    class Quote
      def initialize(type, symbol, price, size, timestamp)
        @type = type
        @symbol = symbol
        @price = price
        @size = size
        @timestamp = timestamp
      end

      def type
        @type
      end

      def symbol
        @symbol
      end

      def price
        @price
      end

      def size
        @size
      end

      def timestamp
        @timestamp
      end

      def to_s
        [@symbol, @type, @price, @size, @timestamp].join(",")
      end
    end

    class Client

      def initialize(options, on_trade, on_quote)
        raise "Options parameter is required" if options.nil? || !options.is_a?(Hash)
        @stop = false
        @messages = Queue.new
        raise "Unable to create queue." if @messages.nil?
        @on_trade = on_trade
        @on_quote = on_quote

        @api_key = options[:api_key]
        raise "API Key was formatted invalidly." if @api_key && !valid_api_key?(@api_key)
		
        unless @api_key
          @username = options[:username]
          @password = options[:password]
          raise "API Key or Username and password are required" if @username.nil? || @username.empty? || @password.nil? || @password.empty?
        end

        @provider = options[:provider]
        unless @provider
          @provider = REALTIME
        end
        raise "Provider must be 'REALTIME' or 'MANUAL'" unless PROVIDERS.include?(@provider)

        @ip_address = options[:ip_address]
        raise "Missing option ip_address while in MANUAL mode." if @provider == MANUAL and (@ip_address.nil? || @ip_address.empty?)

        @trades_only = options[:trades_only]
        if @trades_only.nil?
          @trades_only = false
        end

        @thread_quantity = options[:threads]
        unless @thread_quantity
          @thread_quantity = 4
        end

        @threads = []

        @channels = []
        @channels = parse_channels(options[:channels]) if options[:channels]
        bad_channels = @channels.select{|x| !x.is_a?(String)}
        raise "Invalid channels to join: #{bad_channels}" unless bad_channels.empty?

        if options[:logger] == false
          @logger = nil 
        elsif !options[:logger].nil?
          @logger = options[:logger]
        else
          @logger = Logger.new($stdout)
          @logger.level = Logger::INFO
        end

        @ready = false
        @joined_channels = []
        @heartbeat_timer = nil
        @selfheal_timer = nil
        @selfheal_backoffs = Array.new(SELF_HEAL_BACKOFFS)
        @ws = nil
      end

      def provider
        @provider
      end
      
      def join(*channels)
        channels = parse_channels(channels)
        nonconforming = channels.select{|x| !x.is_a?(String)}
        return error("Invalid channels to join: #{nonconforming}") unless nonconforming.empty?
        
        @channels.concat(channels)
        @channels.uniq!
        debug "Joining channels #{channels}"
        
        refresh_channels()
      end
      
      def leave(*channels)
        channels = parse_channels(channels)
        nonconforming = channels.find{|x| !x.is_a?(String)}
        return error("Invalid channels to leave: #{nonconforming}") unless nonconforming.empty?
        
        channels.each{|c| @channels.delete(c)}
        debug "Leaving channels #{channels}"
        
        refresh_channels()
      end
      
      def leave_all
        @channels = []
        debug "Leaving all channels"
        refresh_channels()
      end

      def connect
        raise "Must be run from within an EventMachine run loop" unless EM.reactor_running?
        return warn("Already connected!") if @ready
        debug "Connecting..."
        
        catch :fatal do
          begin
            @closing = false
            @ready = false
            refresh_token()
            refresh_websocket()
          rescue StandardError => e
            error("Connection error: #{e} \n#{e.backtrace.join("\n")}")
            try_self_heal()
          end
        end
      end
      
      def disconnect
        EM.cancel_timer(@heartbeat_timer) if @heartbeat_timer
        EM.cancel_timer(@selfheal_timer) if @selfheal_timer
        @ready = false
        @closing = true
        @channels = []
        @joined_channels = []
        @ws.close() if @ws
        @stop = true
        sleep(2)
        @threads.each { |thread|
          if !thread.nil? && (!thread.pending_interrupt? || thread.status == "run" || thread.status == "Sleeping")
          then thread.join(7)
          elsif !thread.nil?
          then thread.kill
          end
        }
        @threads = []
        @stop = false
        info "Connection closed"
      end

      def on_trade(on_trade)
        @on_trade = on_trade
      end

      def on_quote(on_quote)
        @on_quote = on_quote
      end
      
      private

      def queue_message(message)
        @messages.enq(message)
      end

      def parse_uint64(data)
        data.map { |i| [sprintf('%02x',i)].pack('H2') }.join.unpack('Q<').first
      end

      def parse_int32(data)
        data.map { |i| [sprintf('%02x',i)].pack('H2') }.join.unpack('l<').first
      end

      def parse_uint32(data)
        data.map { |i| [sprintf('%02x',i)].pack('H2') }.join.unpack('V').first
      end

      def parse_float32(data)
        data.map { |i| [sprintf('%02x',i)].pack('H2') }.join.unpack('e').first
      end

      def parse_trade(data, start_index, symbol_length)
        symbol = data[start_index + 2, symbol_length].map!{|c| c.chr}.join
        price = parse_float32(data[start_index + 2 + symbol_length, 4])
        size = parse_uint32(data[start_index + 6 + symbol_length, 4])
        timestamp = parse_uint64(data[start_index + 10 + symbol_length, 8])
        total_volume = parse_uint32(data[start_index + 18 + symbol_length, 4])
        return Trade.new(symbol, price, size, timestamp, total_volume)
      end

      def parse_quote(data, start_index, symbol_length, msg_type)
        type = case when msg_type == 1 then ASK when msg_type == 2 then BID end
        symbol = data[start_index + 2, symbol_length].map!{|c| c.chr}.join
        price = parse_float32(data[start_index + 2 + symbol_length, 4])
        size = parse_uint32(data[start_index + 6 + symbol_length, 4])
        timestamp = parse_uint64(data[start_index + 10 + symbol_length, 8])
        return Quote.new(type, symbol, price, size, timestamp)
      end

      def handle_message(data, start_index)
        msg_type = data[start_index]
        symbol_length = data[start_index + 1]
        case msg_type
        when 0 then
          trade = parse_trade(data, start_index, symbol_length)
          @on_trade.call(trade)
          return start_index + 22 + symbol_length
        when 1 || 2 then
          quote = parse_quote(data, start_index, symbol_length, msg_type)
          @on_quote.call(quote)
          return start_index + 18 + symbol_length
        end
        return start_index
      end

      def handle_data
        Thread.current.priority -= 1
        me = self
        pop = nil
        until @stop do
          begin
            pop = nil
            data = nil
            pop = @messages.deq
            unless pop.nil?
              begin
                data = pop.unpack('C*')
              rescue StandardError => ex
                me.send :error, "Error unpacking data from queue: #{ex} #{pop}"
                next
              end
              if !data then me.send :error, "Cannot process data.  Data is nil. #{pop}" end
              start_index = 1
              count = data[0]
              # These are grouped (many) messages.
              # The first byte tells us how many there are.
              # From there, check the type and symbol length at index 0 of each chunk to know how many bytes each message has.
              count.times {start_index = handle_message(data, start_index)}
            end
            if pop.nil? then sleep(0.1) end
          rescue StandardError => e
            me.send :error, "Error handling message from queue: #{e} #{pop} : #{data} ; count: #{count} ; start index: #{start_index}"
          rescue Exception => e
            #me.send :error, "General error handling message from queue: #{e} #{pop} : #{data} ; count: #{count} ; start index: #{start_index}"
          end
        end
      end

      def refresh_token
        @token = nil

        uri = URI.parse(auth_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true if (auth_url.include?("https"))
        http.start
        request = Net::HTTP::Get.new(uri.request_uri)
        request.add_field("Client-Information", "IntrinioRealtimeRubySDKv4.0")

        unless @api_key
          request.basic_auth(@username, @password)
        end

        response = http.request(request)

        return fatal("Unable to authorize") if response.code == "401"
        return fatal("Could not get auth token") if response.code != "200"

        @token = response.body
        debug "Token refreshed"
      end
      
      def auth_url 
        url = ""

        case @provider 
        when REALTIME then url = "https://realtime-mx.intrinio.com/auth"
		    when MANUAL then url = "http://" + @ip_address + "/auth"
        end

        url = api_auth_url(url) if @api_key

        url
      end

      def api_auth_url(url)
        if url.include? "?"
          url = "#{url}&"
        else
          url = "#{url}?"
        end

        "#{url}api_key=#{@api_key}"
      end

      def socket_url 
        case @provider
		    when REALTIME then "wss://realtime-mx.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}"
		    when MANUAL then "ws://" + @ip_address + "/socket/websocket?vsn=1.0.0&token=#{@token}"
        end
      end

      def refresh_websocket
        me = self

        @ws.close() unless @ws.nil?
        @ready = false
        @joined_channels = []

        @stop = true
        sleep(2)
        @threads.each { |thread|
          if !thread.nil? && (!thread.pending_interrupt? || thread.status == "run" || thread.status == "Sleeping")
          then thread.join(7)
          elsif !thread.nil?
          then thread.kill
          end
        }
        @threads = []
        @stop = false
        @thread_quantity.times {@threads << Thread.new{handle_data}}
        
        @ws = ws = WebSocket::Client::Simple.connect(socket_url)
        me.send :info, "Connection opening"

        ws.on :open do
          me.send :info, "Connection established"
          me.send :ready, true
          if [REALTIME, MANUAL].include?(me.send(:provider))
            me.send :refresh_channels
          end
          me.send :start_heartbeat
          me.send :stop_self_heal
        end

        ws.on :message do |frame|
          data_message = frame.data
          #me.send :debug, "Message: #{data_message}"
          begin
            unless data_message.nil?
            then me.send :queue_message, data_message
            end
          rescue StandardError => e
            me.send :error, "Error adding message to queue: #{data_message} #{e}"
          end
        end
        
        ws.on :close do |e|
          me.send :ready, false
          me.send :info, "Connection closing...: #{e}"
          me.send :try_self_heal
        end

        ws.on :error do |e|
          me.send :ready, false
          me.send :error, "Connection error: #{e}"
          me.send :try_self_heal
        end
      end
      
      def refresh_channels
        return unless @ready
        debug "Refreshing channels"
        
        # Join new channels
        new_channels = @channels - @joined_channels
        new_channels.each do |channel|
          #msg = join_message(channel)
          #@ws.send(msg.to_json)
          msg = join_binary_message(channel)
          @ws.send(msg)
          info "Joined #{channel}"
        end
        
        # Leave old channels
        old_channels = @joined_channels - @channels
        old_channels.each do |channel|
          #msg = leave__message(channel)
          #@ws.send(msg.to_json)
          msg = leave_binary_message(channel)
          @ws.send(msg)
          info "Left #{channel}"
        end
        
        @channels.uniq!
        @joined_channels = Array.new(@channels)
        debug "Current channels: #{@channels}"
      end
      
      def start_heartbeat
        EM.cancel_timer(@heartbeat_timer) if @heartbeat_timer
        @heartbeat_timer = EM.add_periodic_timer(HEARTBEAT_TIME) do
          if msg = heartbeat_msg()
            @ws.send(msg)
            debug "Heartbeat #{msg}"
          end
        end
      end
      
      def heartbeat_msg
        ""
      end
      
      def stop_heartbeat
        EM.cancel_timer(@heartbeat_timer) if @heartbeat_timer
      end
      
      def try_self_heal
        return if @closing
        debug "Attempting to self-heal"
        
        time = @selfheal_backoffs.first
        @selfheal_backoffs.delete_at(0) if @selfheal_backoffs.count > 1
        
        EM.cancel_timer(@heartbeat_timer) if @heartbeat_timer
        EM.cancel_timer(@selfheal_timer) if @selfheal_timer
        
        @selfheal_timer = EM.add_timer(time/1000) do
          connect()
        end
      end
      
      def stop_self_heal
        EM.cancel_timer(@selfheal_timer) if @selfheal_timer
        @selfheal_backoffs = Array.new(SELF_HEAL_BACKOFFS)
      end
      
      def ready(val)
        @ready = val
      end

      def debug(message)
        message = "IntrinioRealtime | #{message}"
        @logger.debug(message) rescue
        nil
      end
      
      def info(message)
        message = "IntrinioRealtime | #{message}"
        @logger.info(message) rescue
        nil
      end
      
      def error(message)
        message = "IntrinioRealtime | #{message}"
        @logger.error(message) rescue
        nil
      end
      
      def fatal(message)
        message = "IntrinioRealtime | #{message}"
        @logger.fatal(message) rescue
        EM.stop_event_loop
        throw :fatal
        nil
      end
      
      def parse_channels(channels)
        channels.flatten!
        channels.uniq!
        channels.compact!
        channels
      end
      
      def join_binary_message(channel)
        if (channel == "lobby") && (@trades_only == false)
          return [74, 0, 36, 70, 73, 82, 69, 72, 79, 83, 69].pack('C*') #74, not trades only, "$FIREHOSE"
        elsif (channel == "lobby") && (@trades_only == true)
          return [74, 1, 36, 70, 73, 82, 69, 72, 79, 83, 69].pack('C*') #74, trades only, "$FIREHOSE"
        else
          bytes = [74, 0]
          if (@trades_only == true)
            bytes[1] = 1
          end
          return bytes.concat(channel.bytes).pack('C*')
        end
      end

      def leave_binary_message(channel)
        if channel == "lobby"
          return [76, 36, 70, 73, 82, 69, 72, 79, 83, 69].pack('C*') #74, not trades only, "$FIREHOSE"
        else
          bytes = [76]
          return bytes.concat(channel.bytes).pack('C*')
        end
      end

      def valid_api_key?(api_key)
        return false unless api_key.is_a?(String)
        return false if api_key.empty?
        true
      end

    end
  end
end
