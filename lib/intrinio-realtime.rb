require 'logger'
require 'uri'
require 'http'
require 'eventmachine'
require 'websocket-client-simple'

module Intrinio
  module Realtime
    HEARTBEAT_TIME = 1
    IEX_HEARTBEAT_MSG = {topic: 'phoenix', event: 'heartbeat', payload: {}, ref: nil}.to_json
    SELF_HEAL_BACKOFFS = [0,100,500,1000,2000,5000]
    DEFAULT_POOL_SIZE = 100
    IEX = "iex"
    QUODD = "quodd"
    PROVIDERS = [IEX, QUODD]

    def self.connect(options, &b)
      EM.run do
        client = ::Intrinio::Realtime::Client.new(options)
        client.on_quote(&b)
        client.connect()
      end
    end

    class Client
      def initialize(options) 
        raise "Options parameter is required" if options.nil? || !options.is_a?(Hash)
        
        @username = options[:username]
        @password = options[:password]
        raise "Username and password are required" if @username.nil? || @username.empty? || @password.nil? || @password.empty?
        
        @provider = options[:provider]
        raise "Provider must be 'quodd' or 'iex'" unless PROVIDERS.include?(@provider)
        
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
        info "Connection closed"
      end
      
      private
      
      def refresh_token
        @token = nil
        
        response =  HTTP.basic_auth(:user => @username, :pass => @password).get(auth_url)
        return fatal("Unable to authorize") if response.status == 401
        return fatal("Could not get auth token") if response.status != 200
        
        @token = response.body
        debug "Token refreshed"
      end
      
      def auth_url 
        case @provider 
        when IEX then "https://realtime.intrinio.com/auth"
        when QUODD then "https://api.intrinio.com/token?type=QUODD"
        end
      end
      
      def socket_url 
        case @provider 
        when IEX then URI.escape("wss://realtime.intrinio.com/socket/websocket?vsn=1.0.0&token=#{@token}")
        when QUODD then URI.escape("ws://www6.quodd.com/WebStreamer/webStreamer/intrinio/#{@token}")
        end
      end
      
      def refresh_websocket
        me = self
        
        @ws.close() unless @ws.nil?
        @ready = false
        @joined_channels = []
        
        @ws = ws = WebSocket::Client::Simple.connect(socket_url)

        ws.on :open do
          me.send :ready, true
          me.send :info, "Connection established"
          me.send :start_heartbeat
          me.send :refresh_channels
          me.send :stop_self_heal
        end

        ws.on :message do |frame|
          message = frame.data
          me.send :debug, "Message: #{message}"
          
          begin
            json = JSON.parse(message)

            quote = case me.send(:provider)
            when IEX
              if json["event"] == "quote"
                json["payload"]
              end
            when QUODD
              if json["action"] == "quotes" || json["action"] == "trades"
                json
              end
            end
            
            if quote
              me.send :process_quote, quote
            end
          rescue StandardError => e
            me.send :error, "Could not parse message: #{message} #{e}"
          end
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
            debug "Heartbeat"
          end
        end
      end
      
      def heartbeat_msg
        case @provider 
        when IEX then IEX_HEARTBEAT_MSG
        end
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
            ticker: channel,
            action: "subscribe"
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
            ticker: channel,
            action: "unsubscribe"
          }
        end
      end
    end
  end
end
