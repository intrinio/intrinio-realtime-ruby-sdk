require 'logger'
require 'uri'
require 'http'
require 'eventmachine'
require 'websocket-client-simple'

module Intrinio
  module Realtime
    HEARTBEAT_TIME = 3
    SELF_HEAL_BACKOFFS = [0, 100, 500, 1000, 2000, 5000].freeze
    IEX = "iex".freeze
    QUODD = "quodd".freeze
    CRYPTOQUOTE = "cryptoquote".freeze
    FXCM = "fxcm".freeze
    PROVIDERS = [IEX, QUODD, CRYPTOQUOTE, FXCM].freeze

    def self.connect(options, &b)
      loop do
        EM.run do
          client = ::Intrinio::Realtime::Client.new(options)
          client.on_quote(&b)
          client.connect()
        end
      end
    end

    class Client

      def initialize(options)
        raise "Options parameter is required" if options.nil? || !options.is_a?(Hash)

        @error_handler = options[:error_handler] if options[:error_handler]

        @api_key = options[:api_key]
        raise "API Key was formatted invalidly." if @api_key && !valid_api_key?(@api_key)

        unless @api_key
          @username = options[:username]
          @password = options[:password]
          raise "API Key or Username and password are required" if @username.nil? || @username.empty? || @password.nil? || @password.empty?
        end

        @provider = options[:provider]
        raise "Provider must be 'CRYPTOQUOTE', 'FXCM', 'IEX', or 'QUODD'" unless PROVIDERS.include?(@provider)

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

        @quotes = EventMachine::Channel.new
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
      
      def on_quote(&b)
        @quotes.subscribe(&b)
      end
      
      def connect
        raise "Must be run from within an EventMachine run loop" unless EM.reactor_running?
        return warn("Already connected!") if @ready
        debug "Connecting..."
        
        begin
          @closing = false
          @ready = false
          refresh_token()
          refresh_websocket()
        rescue StandardError => e
          error("Connection error: #{e} \n#{e.backtrace.join("\n")}", exception: e)
          try_self_heal()
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
        info "Connection closed"
      end
      
      private
      
      def refresh_token
        @token = nil

        if @api_key
          response = HTTP.get(auth_url)
        else
          response = HTTP.basic_auth(:user => @username, :pass => @password).get(auth_url)
        end

        raise "unable to authorize" if response.status == 401
        raise "could not get auth token" if response.status != 200

        @token = response.body
        debug "Token refreshed"
      end
      
      def auth_url 
        url = ""

        case @provider 
        when IEX then url = "https://realtime.intrinio.com/auth"
        when QUODD then url = "https://api.intrinio.com/token?type=QUODD"
        when CRYPTOQUOTE then url = "https://crypto.intrinio.com/auth"
        when FXCM then url = "https://fxcm.intrinio.com/auth"
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
        when IEX then URI.escape("wss://realtime.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}")
        when QUODD then URI.escape("wss://www5.quodd.com/websocket/webStreamer/intrinio/#{@token}")
        when CRYPTOQUOTE then URI.escape("wss://crypto.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}")
        when FXCM then URI.escape("wss://fxcm.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}")
        end
      end

      def refresh_websocket
        me = self

        @ws.close() unless @ws.nil?
        @ready = false
        @joined_channels = []
        
        @ws = ws = WebSocket::Client::Simple.connect(socket_url)
        me.send :info, "Connection opening"

        ws.on :open do
          me.send :info, "Connection established"
          me.send :ready, true
          if [IEX, CRYPTOQUOTE, FXCM].include?(me.send(:provider))
            me.send :refresh_channels
          end
          me.send :start_heartbeat
          me.send :stop_self_heal
        end

        ws.on :message do |frame|
          message = frame.data
          me.send :debug, "Message: #{message}"
          
          begin
            json = JSON.parse(message)

            if json["event"] == "phx_reply" && json["payload"]["status"] == "error"
              me.send :error, json["payload"]["response"]
            end

            quote =
              case me.send(:provider)
              when IEX
                if json["event"] == "quote"
                  json["payload"]
                end
              when QUODD
                if json["event"] == "info" && json["data"]["message"] == "Connected"
                  me.send :refresh_channels
                elsif json["event"] == "quote" || json["event"] == "trade"
                  json["data"]
                end
              when CRYPTOQUOTE
                if json["event"] == "book_update" || json["event"] == "ticker" || json["event"] == "trade"
                  json["payload"]
                end
              when FXCM
                if json["event"] == "price_update"
                  json["payload"]
                end
              end
            
            if quote && quote.is_a?(Hash)
              me.send :process_quote, quote
            end
          rescue StandardError => e
            me.send :error, "Could not parse message: #{message} #{e}"
          end
        end
        
        ws.on :close do |e|
          me.send :ready, false
          me.send :error, "Connection closed: #{e}"
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
          msg = join_message(channel)
          @ws.send(msg.to_json)
          info "Joined #{channel}"
        end
        
        # Leave old channels
        old_channels = @joined_channels - @channels
        old_channels.each do |channel|
          msg = leave_message(channel)
          @ws.send(msg.to_json)
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
        case @provider 
        when IEX then {topic: 'phoenix', event: 'heartbeat', payload: {}, ref: nil}.to_json
        when QUODD then {event: 'heartbeat', data: {action: 'heartbeat', ticker: (Time.now.to_f * 1000).to_i}}.to_json
        when CRYPTOQUOTE, FXCM then {topic: 'phoenix', event: 'heartbeat', payload: {}, ref: nil}.to_json
        end
      end
      
      def stop_heartbeat
        EM.cancel_timer(@heartbeat_timer) if @heartbeat_timer
      end
      
      def try_self_heal
        debug "Attempting to self-heal"
        return if @closing
        
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
      
      def process_quote(quote)
        @quotes.push(quote)
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
      
      def error(message, exception: nil)
        if @error_handler
          @error_handler.call(exception)
        else
          message = "IntrinioRealtime | #{message}"
          @logger.error(message)
        end
        nil
      end
      
      def parse_channels(channels)
        channels.flatten!
        channels.uniq!
        channels.compact!
        channels
      end
      
      def parse_iex_topic(channel)
        case channel
        when "$lobby"
          "iex:lobby"
        when "$lobby_last_price"
          "iex:lobby:last_price"
        else
          "iex:securities:#{channel}"
        end
      end
      
      def join_message(channel)
        case @provider 
        when IEX
          {
            topic: parse_iex_topic(channel),
            event: "phx_join",
            payload: {},
            ref: nil
          }
        when QUODD
          {
            event: "subscribe",
            data: {
              ticker: channel,
              action: "subscribe"
            }
          }
        when CRYPTOQUOTE, FXCM
          {
            topic: channel,
            event: "phx_join",
            payload: {},
            ref: nil
          }
        end
      end
      
      def leave_message(channel)
        case @provider 
        when IEX
          {
            topic: parse_iex_topic(channel),
            event: "phx_leave",
            payload: {},
            ref: nil
          }
        when QUODD
          {
            event: "unsubscribe",
            data: {
              ticker: channel,
              action: "unsubscribe"
            }
          }
        when CRYPTOQUOTE, FXCM
          {
            topic: channel,
            event: "phx_leave",
            payload: {},
            ref: nil
          }
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
