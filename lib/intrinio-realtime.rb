require 'logger'
require 'uri'
require 'timeout'
#require 'http'
require 'net/http'
require 'eventmachine'
require 'websocket-client-simple'

module Intrinio
  module Realtime
    SELF_HEAL_BACKOFFS = [0, 100, 500, 1000, 2000, 5000].freeze
    REALTIME = "REALTIME".freeze
    MANUAL = "MANUAL".freeze
    DELAYED_SIP = "DELAYED_SIP".freeze
    NASDAQ_BASIC = "NASDAQ_BASIC".freeze
    NO_SUBPROVIDER = "NONE".freeze
    CTA_A = "CTA_A".freeze
    CTA_B = "CTA_B".freeze
    UTP = "UTP".freeze
    OTC = "OTC".freeze
    IEX = "IEX".freeze
    CBOE_ONE = "CBOE_ONE".freeze
    EQUITIES_EDGE = "EQUITIES_EDGE".freeze
    PROVIDERS = [REALTIME, MANUAL, DELAYED_SIP, NASDAQ_BASIC, IEX, CBOE_ONE, EQUITIES_EDGE].freeze
    SUBPROVIDERS = [NO_SUBPROVIDER, CTA_A, CTA_B, UTP, OTC, NASDAQ_BASIC, IEX, CBOE_ONE, EQUITIES_EDGE].freeze
    ASK = "Ask".freeze
    BID = "Bid".freeze
    CLIENT_INFO_HEADER_KEY = "Client-Information".freeze
    CLIENT_INFO_HEADER_VALUE = "IntrinioRealtimeRubySDKv5.4".freeze
    MESSAGE_VERSION_HEADER_KEY = "UseNewEquitiesFormat".freeze
    MESSAGE_VERSION_HEADER_VALUE = "v2".freeze
    CONNECT_TIMEOUT_SECONDS = 30
    HTTP_TIMEOUT_SECONDS = 30
    CLOSE_TIMEOUT_SECONDS = 5
    WORKER_JOIN_TIMEOUT_SECONDS = 5

    def self.connect(options, on_trade, on_quote)
      EM.run do
        client = ::Intrinio::Realtime::Client.new(options, on_trade, on_quote)
        client.connect()
      end
    end

    class Trade
      def initialize(symbol, price, size, timestamp, total_volume, subprovider, market_center, condition)
        @symbol = symbol
        @price = price
        @size = size
        @timestamp = timestamp
        @total_volume = total_volume
        @subprovider = subprovider
        @market_center = market_center
        @condition = condition
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

      def subprovider
        @subprovider
      end

      def market_center
        @market_center
      end

      def condition
        @condition
      end

      def is_darkpool
        case @subprovider
        when CTA_A, CTA_B, UTP, OTC
          @market_center == nil || @market_center == 'D' || @market_center == 'E' || @market_center == "\0" || @market_center.empty?
        when NASDAQ_BASIC
          @market_center == nil || @market_center == 'L' || @market_center == '2' || @market_center == "\0" || @market_center.empty?
        else
          false
        end
      end

      def to_s
        [@symbol, @price, @size, @timestamp, @total_volume, @subprovider, @market_center, @condition].join(",")
      end
    end

    class Quote
      def initialize(type, symbol, price, size, timestamp, subprovider, market_center, condition)
        @type = type
        @symbol = symbol
        @price = price
        @size = size
        @timestamp = timestamp
        @subprovider = subprovider
        @market_center = market_center
        @condition = condition
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

      def subprovider
        @subprovider
      end

      def market_center
        @market_center
      end

      def condition
        @condition
      end

      def to_s
        [@symbol, @type, @price, @size, @timestamp, @subprovider, @market_center, @condition].join(",")
      end
    end

    class Client

      def initialize(options, on_trade, on_quote)
        raise "Options parameter is required" if options.nil? || !options.is_a?(Hash)
        @stop = false
        @trade_messages = Queue.new
        @quote_messages = Queue.new
        @message_available = Queue.new
        @stop_message = Object.new
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
        raise "Provider must be 'IEX', 'REALTIME', 'DELAYED_SIP', 'NASDAQ_BASIC', 'CBOE_ONE', or 'EQUITIES_EDGE', or 'MANUAL'" unless PROVIDERS.include?(@provider)

        @ip_address = options[:ip_address]
        raise "Missing option ip_address while in MANUAL mode." if @provider == MANUAL and (@ip_address.nil? || @ip_address.empty?)

        @trades_only = options[:trades_only]
        if @trades_only.nil?
          @trades_only = false
        end

        @delayed = options[:delayed]
        if @delayed.nil?
          @delayed = false
        end

        @thread_quantity = options[:threads]
        unless @thread_quantity
          @thread_quantity = 4
        end

        @threads = []
        @worker_generation = 0
        @worker_mutex = Mutex.new

        @channels = []
        @channels = parse_channels(options[:channels]) if options[:channels]
        bad_channels = @channels.select{|x| !x.is_a?(String)}
        raise "Invalid channels to join: #{bad_channels}" unless bad_channels.empty?
        @channels_mutex = Mutex.new

        if options[:logger] == false
          @logger = nil 
        elsif !options[:logger].nil?
          @logger = options[:logger]
        else
          @logger = Logger.new($stdout)
          @logger.level = Logger::INFO
        end

        @ready = false
        @connecting = false
        @closing = false
        @joined_channels = []
        @selfheal_timer = nil
        @connect_timer = nil
        @selfheal_backoffs = Array.new(SELF_HEAL_BACKOFFS)
        @ws = nil
        @connection_generation = 0
        @state_mutex = Mutex.new
        @lifecycle_mutex = Mutex.new
        @connect_timeout_seconds = CONNECT_TIMEOUT_SECONDS
        @http_timeout_seconds = HTTP_TIMEOUT_SECONDS
        @close_timeout_seconds = CLOSE_TIMEOUT_SECONDS
      end

      def provider
        @provider
      end
      
      def join(*channels)
        channels = parse_channels(channels)
        nonconforming = channels.select{|x| !x.is_a?(String)}
        return error("Invalid channels to join: #{nonconforming}") unless nonconforming.empty?

        @channels_mutex.synchronize do
          @channels.concat(channels)
          @channels.uniq!
        end
        debug "Joining channels #{channels}"
        
        refresh_channels()
      end
      
      def leave(*channels)
        channels = parse_channels(channels)
        nonconforming = channels.find{|x| !x.is_a?(String)}
        return error("Invalid channels to leave: #{nonconforming}") unless nonconforming.empty?
        
        @channels_mutex.synchronize do
          channels.each{|c| @channels.delete(c)}
        end
        debug "Leaving channels #{channels}"
        
        refresh_channels()
      end
      
      def leave_all
        @channels_mutex.synchronize {@channels = []}
        debug "Leaving all channels"
        refresh_channels()
      end

      def connect
        raise "Must be run from within an EventMachine run loop" unless EM.reactor_running?

        generation = nil
        reconnect_timer = nil
        already_connected = @lifecycle_mutex.synchronize do
          connected = @state_mutex.synchronize do
            if @ready || @connecting
              true
            else
              @closing = false
              @connecting = true
              @connection_generation += 1
              generation = @connection_generation
              reconnect_timer = @selfheal_timer
              @selfheal_timer = nil
              false
            end
          end
          start_workers unless connected
          connected
        end
        return warn("Already connected!") if already_connected

        cancel_timer(reconnect_timer)
        debug "Connecting..."

        EM.defer(
          proc { refresh_token },
          proc { |token| finish_authorization(generation, token) },
          proc { |exception| connection_attempt_failed(generation, exception) }
        )
      end
      
      def disconnect
        @lifecycle_mutex.synchronize do
          socket = nil
          reconnect_timer = nil
          connect_timer = nil
          @state_mutex.synchronize do
            @closing = true
            @ready = false
            @connecting = false
            @connection_generation += 1
            socket = @ws
            @ws = nil
            reconnect_timer = @selfheal_timer
            connect_timer = @connect_timer
            @selfheal_timer = nil
            @connect_timer = nil
          end
          @channels_mutex.synchronize {@joined_channels = []}

          cancel_timer(reconnect_timer)
          cancel_timer(connect_timer)
          close_websocket(socket, true)
          stop_workers
        end
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
        return if message.nil? || message.empty?

        message_count = message.getbyte(0)
        raise "Message does not contain an event count" if message_count.nil?

        start_index = 1
        trades = []
        quotes = []
        message_count.times do
          raise "Message header is truncated at byte #{start_index}" if start_index + 2 > message.bytesize

          message_type = message.getbyte(start_index)
          message_length = message.getbyte(start_index + 1)
          if message_length.nil? || message_length < 2 || start_index + message_length > message.bytesize
            raise "Message body is truncated at byte #{start_index}"
          end

          chunk = message.byteslice(start_index, message_length)
          if message_type == 0
            trades << chunk
          else
            quotes << chunk
          end
          start_index += message_length
        end

        trades.each {|chunk| @trade_messages.enq(chunk)}
        quotes.each {|chunk| @quote_messages.enq(chunk)}
        (trades.length + quotes.length).times {@message_available.enq(true)}
      rescue StandardError => e
        error "Error adding message to queues: #{e}"
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

      def parse_subprovider(byte)
        case byte
        when 0
          NO_SUBPROVIDER
        when 1
          CTA_A
        when 2
          CTA_B
        when 3
          UTP
        when 4
          OTC
        when 5
          NASDAQ_BASIC
        when 6
          IEX
        when 7
          CBOE_ONE
        when 8
          EQUITIES_EDGE
        else
          IEX
        end
      end

      def parse_trade(data, start_index)
        symbol_length = data[start_index + 2]
        condition_length = data[start_index + 26 + symbol_length]
        symbol = data[start_index + 3, symbol_length].map!{|c| c.chr}.join
        price = parse_float32(data[start_index + 6 + symbol_length, 4])
        size = parse_uint32(data[start_index + 10 + symbol_length, 4])
        timestamp = parse_uint64(data[start_index + 14 + symbol_length, 8])
        total_volume = parse_uint32(data[start_index + 22 + symbol_length, 4])
        subprovider = parse_subprovider(data[start_index + 3 + symbol_length])
        market_center = data[start_index + 4 + symbol_length, 2].pack("C*").encode!('UTF-8', 'UTF-16LE')
        condition = if condition_length > 0 then data[start_index + 27 + symbol_length, condition_length].map!{|c| c.chr}.join else "" end

        return Trade.new(symbol, price, size, timestamp, total_volume, subprovider, market_center, condition)
      end

      def parse_quote(data, start_index, msg_type)
        symbol_length = data[start_index + 2]
        condition_length = data[start_index + 22 + symbol_length]
        type = case when msg_type == 1 then ASK when msg_type == 2 then BID end
        symbol = data[start_index + 3, symbol_length].map!{|c| c.chr}.join
        price = parse_float32(data[start_index + 6 + symbol_length, 4])
        size = parse_uint32(data[start_index + 10 + symbol_length, 4])
        timestamp = parse_uint64(data[start_index + 14 + symbol_length, 8])
        subprovider = parse_subprovider(data[start_index + 3 + symbol_length])
        market_center = data[start_index + 4 + symbol_length, 2].pack("C*").encode!('UTF-8', 'UTF-16LE')
        condition = if condition_length > 0 then data[start_index + 23 + symbol_length, condition_length].map!{|c| c.chr}.join else "" end

        return Quote.new(type, symbol, price, size, timestamp, subprovider, market_center, condition)
      end

      def handle_message(data, start_index)
        msg_type = data[start_index]
        msg_length = data[start_index + 1]
        case msg_type
        when 0 then
          trade = parse_trade(data, start_index)
          @on_trade.call(trade)
          return start_index + msg_length
        when 1, 2 then
          quote = parse_quote(data, start_index, msg_type)
          @on_quote.call(quote)
          return start_index + msg_length
        end
        return start_index + msg_length
      end

      def handle_data(generation)
        Thread.current.priority -= 1 rescue nil
        pop = nil
        until @stop || generation != @worker_generation do
          begin
            signal = @message_available.deq
            break if signal.equal?(@stop_message) || @stop || generation != @worker_generation

            # Always drain a trade first. Quotes can be extremely high volume, so a
            # shared FIFO lets them delay trades even when processing capacity is free.
            pop = nonblocking_dequeue(@trade_messages)
            pop = nonblocking_dequeue(@quote_messages) if pop.nil?
            next if pop.nil?

            data = pop.unpack('C*')
            handle_message(data, 0)
          rescue StandardError => e
            error "Error handling message from queue: #{e} #{pop}"
          rescue Exception => e
            break if @stop || generation != @worker_generation
            error "General error handling message from queue: #{e} #{pop}"
          end
        end
      end

      def refresh_token
        uri = URI.parse(auth_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true if (auth_url.include?("https"))
        http.open_timeout = @http_timeout_seconds
        http.read_timeout = @http_timeout_seconds
        http.write_timeout = @http_timeout_seconds if http.respond_to?(:write_timeout=)
        request = Net::HTTP::Get.new(uri.request_uri)
        request.add_field(CLIENT_INFO_HEADER_KEY, CLIENT_INFO_HEADER_VALUE)

        unless @api_key
          request.basic_auth(@username, @password)
        end

        response = http.start {|session| session.request(request)}

        raise "Unable to authorize" if response.code == "401"
        raise "Could not get auth token (HTTP #{response.code})" if response.code != "200"

        debug "Token refreshed"
        response.body
      end
      
      def auth_url 
        url = ""

        case @provider 
        when REALTIME then url = "https://realtime-mx.intrinio.com/auth"
        when IEX then url = "https://realtime-mx.intrinio.com/auth"
        when DELAYED_SIP then url = "https://realtime-delayed-sip.intrinio.com/auth"
        when NASDAQ_BASIC then url = "https://realtime-nasdaq-basic.intrinio.com/auth"
        when CBOE_ONE then url = "https://cboe-one.intrinio.com/auth"
        when EQUITIES_EDGE then url = "https://equities-edge.intrinio.com/auth"
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
        delayed_part = @delayed ? "&delayed=true" : ""

        case @provider
        when REALTIME then "wss://realtime-mx.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}&#{CLIENT_INFO_HEADER_KEY}=#{CLIENT_INFO_HEADER_VALUE}&#{MESSAGE_VERSION_HEADER_KEY}=#{MESSAGE_VERSION_HEADER_VALUE}#{delayed_part}"
        when IEX then "wss://realtime-mx.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}&#{CLIENT_INFO_HEADER_KEY}=#{CLIENT_INFO_HEADER_VALUE}&#{MESSAGE_VERSION_HEADER_KEY}=#{MESSAGE_VERSION_HEADER_VALUE}#{delayed_part}"
        when DELAYED_SIP then "wss://realtime-delayed-sip.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}&#{CLIENT_INFO_HEADER_KEY}=#{CLIENT_INFO_HEADER_VALUE}&#{MESSAGE_VERSION_HEADER_KEY}=#{MESSAGE_VERSION_HEADER_VALUE}#{delayed_part}"
        when NASDAQ_BASIC then "wss://realtime-nasdaq-basic.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}&#{CLIENT_INFO_HEADER_KEY}=#{CLIENT_INFO_HEADER_VALUE}&#{MESSAGE_VERSION_HEADER_KEY}=#{MESSAGE_VERSION_HEADER_VALUE}#{delayed_part}"
        when CBOE_ONE then "wss://cboe-one.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}&#{CLIENT_INFO_HEADER_KEY}=#{CLIENT_INFO_HEADER_VALUE}&#{MESSAGE_VERSION_HEADER_KEY}=#{MESSAGE_VERSION_HEADER_VALUE}#{delayed_part}"
        when EQUITIES_EDGE then "wss://equities-edge.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}&#{CLIENT_INFO_HEADER_KEY}=#{CLIENT_INFO_HEADER_VALUE}&#{MESSAGE_VERSION_HEADER_KEY}=#{MESSAGE_VERSION_HEADER_VALUE}#{delayed_part}"
        when MANUAL then "ws://" + @ip_address + "/socket/websocket?vsn=1.0.0&token=#{@token}&#{CLIENT_INFO_HEADER_KEY}=#{CLIENT_INFO_HEADER_VALUE}&#{MESSAGE_VERSION_HEADER_KEY}=#{MESSAGE_VERSION_HEADER_VALUE}#{delayed_part}"
        else raise "Unknown provider"
        end
      end

      def refresh_websocket(generation)
        headers = {
          :headers => {
            CLIENT_INFO_HEADER_KEY => CLIENT_INFO_HEADER_VALUE,
            MESSAGE_VERSION_HEADER_KEY => MESSAGE_VERSION_HEADER_VALUE
          }
        }

        old_socket = @state_mutex.synchronize {@ws}
        ws = open_websocket(socket_url, headers) do |socket|
          install_websocket_handlers(socket, generation)
          @state_mutex.synchronize do
            @ws = socket if generation == @connection_generation && !@closing
          end
        end

        unless current_connection?(generation, ws)
          close_websocket(ws, false)
          return
        end

        close_websocket(old_socket, false) if old_socket && !old_socket.equal?(ws)
        schedule_connect_timeout(generation, ws)
        info "Connection opening"
      end

      def open_websocket(url, headers, &block)
        WebSocket::Client::Simple.connect(url, headers, &block)
      end

      def install_websocket_handlers(ws, generation)
        # websocket-client-simple emits with instance_exec, so self inside a
        # raw handler is the socket. Rebind before touching client methods.
        bind_socket_event(ws, :open) do
          schedule_on_reactor {websocket_opened(generation, ws)}
        end

        bind_socket_event(ws, :message) do |frame|
          next unless current_connection?(generation, ws)
          if frame.respond_to?(:type) && frame.type != :binary
            debug "Ignoring non-binary websocket message"
            next
          end
          queue_message(frame.data) unless frame.data.nil?
        end

        bind_socket_event(ws, :close) do |exception|
          schedule_on_reactor {websocket_closed(generation, ws, exception)}
        end

        bind_socket_event(ws, :error) do |exception|
          schedule_on_reactor {websocket_errored(generation, ws, exception)}
        end
      end

      def bind_socket_event(ws, event, &callback)
        client = self
        ws.on(event) do |*args|
          client.instance_exec(*args, &callback)
        end
      end

      def websocket_opened(generation, ws)
        timer = nil
        opened = @state_mutex.synchronize do
          if generation == @connection_generation && @ws.equal?(ws) && !@closing
            @ready = true
            @connecting = false
            timer = @connect_timer
            @connect_timer = nil
            true
          else
            false
          end
        end
        return close_websocket(ws, false) unless opened

        cancel_timer(timer)
        @channels_mutex.synchronize {@joined_channels = []}
        info "Connection established"

        begin
          channels_refreshed = !PROVIDERS.include?(provider) || refresh_channels
          return unless channels_refreshed
          stop_self_heal
        rescue StandardError => e
          connection_attempt_failed(generation, e, ws)
        end
      end

      def websocket_closed(generation, ws, exception)
        return unless current_connection?(generation, ws)
        info "Connection closing...: #{exception}"
        connection_attempt_failed(generation, exception || StandardError.new("Websocket closed"), ws)
      end

      def websocket_errored(generation, ws, exception)
        return unless current_connection?(generation, ws)
        error "Connection error: #{exception}"
        connection_attempt_failed(generation, exception || StandardError.new("Websocket error"), ws)
      end
      
      def refresh_channels
        state = @state_mutex.synchronize do
          [@ready, @ws, @connection_generation]
        end
        return unless state[0] && state[1]

        ws = state[1]
        generation = state[2]
        debug "Refreshing channels"

        desired_channels = nil
        @channels_mutex.synchronize do
          desired_channels = Array.new(@channels)
          joined_channels = Array.new(@joined_channels)

          # Keep the desired and server-side subscription sets in lockstep. Calls
          # to join/leave wait briefly while these sends complete, then perform
          # another refresh with their newer desired set.
          new_channels = desired_channels - joined_channels
          new_channels.each do |channel|
            msg = join_binary_message(channel)
            ws.send(msg, :type => :binary)
            raise "Websocket changed while joining channels" unless current_connection?(generation, ws)
            @joined_channels << channel unless @joined_channels.include?(channel)
            info "Joined #{channel}"
          end

          old_channels = joined_channels - desired_channels
          old_channels.each do |channel|
            msg = leave_binary_message(channel)
            ws.send(msg, :type => :binary)
            raise "Websocket changed while leaving channels" unless current_connection?(generation, ws)
            @joined_channels.delete(channel)
            info "Left #{channel}"
          end
        end

        debug "Current channels: #{desired_channels}"
        true
      rescue StandardError => e
        connection_attempt_failed(generation, e, ws) if generation && ws
        false
      end
      
      def try_self_heal
        delay = nil
        @state_mutex.synchronize do
          return if @closing || @ready || @connecting || @selfheal_timer

          delay = @selfheal_backoffs.first
          @selfheal_backoffs.delete_at(0) if @selfheal_backoffs.count > 1
          # A marker prevents close and error callbacks for the same failed socket
          # from scheduling two reconnect loops before EM.add_timer returns.
          @selfheal_timer = :scheduling
        end
        debug "Attempting to self-heal"

        timer = nil
        timer = EM.add_timer(delay / 1000.0) do
          should_connect = @state_mutex.synchronize do
            active = @selfheal_timer.equal?(timer) || @selfheal_timer == :scheduling
            @selfheal_timer = nil if active
            active && !@closing && !@ready && !@connecting
          end
          connect if should_connect
        end
        @state_mutex.synchronize do
          @selfheal_timer = timer if @selfheal_timer == :scheduling
        end
      end
      
      def stop_self_heal
        timer = @state_mutex.synchronize do
          value = @selfheal_timer
          @selfheal_timer = nil
          @selfheal_backoffs = Array.new(SELF_HEAL_BACKOFFS)
          value
        end
        cancel_timer(timer)
      end

      def finish_authorization(generation, token)
        authorized = @state_mutex.synchronize do
          if generation == @connection_generation && @connecting && !@closing
            @token = token
            true
          else
            false
          end
        end
        return unless authorized

        refresh_websocket(generation)
      rescue StandardError => e
        connection_attempt_failed(generation, e)
      end

      def connection_attempt_failed(generation, exception, socket = nil)
        failed_socket = nil
        connect_timer = nil
        current = @state_mutex.synchronize do
          socket_matches = socket.nil? || @ws.equal?(socket)
          if generation == @connection_generation && socket_matches && !@closing
            failed_socket = @ws
            @ws = nil
            @ready = false
            @connecting = false
            connect_timer = @connect_timer
            @connect_timer = nil
            true
          else
            false
          end
        end
        return unless current

        @channels_mutex.synchronize {@joined_channels = []}
        cancel_timer(connect_timer)
        close_websocket(failed_socket, false)
        message = exception.respond_to?(:message) ? exception.message : exception.to_s
        error "Connection attempt failed: #{message}"
        try_self_heal
      end

      def schedule_connect_timeout(generation, ws)
        timer = EM.add_timer(@connect_timeout_seconds) do
          connection_attempt_failed(
            generation,
            Timeout::Error.new("Websocket connect timed out after #{@connect_timeout_seconds} seconds"),
            ws
          )
        end

        previous_timer = nil
        keep_timer = @state_mutex.synchronize do
          if generation == @connection_generation && @ws.equal?(ws) && @connecting && !@closing
            previous_timer = @connect_timer
            @connect_timer = timer
            true
          else
            false
          end
        end
        cancel_timer(previous_timer)
        cancel_timer(timer) unless keep_timer
      end

      def current_connection?(generation, ws)
        @state_mutex.synchronize do
          generation == @connection_generation && @ws.equal?(ws) && !@closing
        end
      end

      def start_workers
        @worker_mutex.synchronize do
          live_threads = @threads.select(&:alive?)
          return if live_threads.length == @thread_quantity

          live_threads.each(&:kill)
          @threads.each {|thread| thread.join(0.1) if thread.alive?}
          @threads = []
          clear_message_queues
          @stop = false
          @worker_generation += 1
          generation = @worker_generation
          @thread_quantity.times do
            @threads << Thread.new {handle_data(generation)}
          end
        end
      end

      def stop_workers
        @worker_mutex.synchronize do
          @stop = true
          @worker_generation += 1
          threads = Array.new(@threads)
          threads.length.times {@message_available.enq(@stop_message)}

          threads.each do |thread|
            next unless thread.alive?
            next if thread.equal?(Thread.current)
            unless thread.join(WORKER_JOIN_TIMEOUT_SECONDS)
              warn "Worker thread timed out while stopping"
              thread.kill
              thread.join(0.1)
            end
          end

          @threads = []
          clear_message_queues
          @stop = false
        end
      end

      def clear_message_queues
        @trade_messages.clear
        @quote_messages.clear
        @message_available.clear
      end

      def nonblocking_dequeue(queue)
        queue.deq(true)
      rescue ThreadError
        nil
      end

      def close_websocket(ws, wait_for_close)
        return if ws.nil?

        close_thread = Thread.new do
          begin
            ws.close
          rescue StandardError => e
            error "Error closing websocket: #{e.message}"
          end
        end
        return unless wait_for_close

        unless close_thread.join(@close_timeout_seconds)
          warn "Websocket close timed out"
          close_thread.kill
          close_thread.join(0.1)
        end
      end

      def cancel_timer(timer)
        return if timer.nil? || timer == :scheduling
        EM.cancel_timer(timer)
      rescue StandardError
        nil
      end

      def schedule_on_reactor(&block)
        if EM.reactor_running?
          EM.schedule(&block)
        else
          block.call
        end
      end
      
      def ready(val)
        @state_mutex.synchronize {@ready = val}
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
