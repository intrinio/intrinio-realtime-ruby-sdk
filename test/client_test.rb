require 'minitest/autorun'
require_relative '../lib/intrinio-realtime'

class FakeWebSocket
  attr_reader :sent

  def initialize
    @handlers = Hash.new {|hash, key| hash[key] = []}
    @sent = []
    @closed = false
    @send_error = nil
  end

  def on(event, &handler)
    @handlers[event] << handler
  end

  def emit(event, *data)
    # Match event_emitter, which runs listeners with instance_exec and rebinds self.
    @handlers[event].each {|handler| instance_exec(*data, &handler)}
  end

  def fail_next_send(exception)
    @send_error = exception
  end

  def send(data, options = {})
    if @send_error
      exception = @send_error
      @send_error = nil
      raise exception
    end
    @sent << [data, options]
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end
end

class ResilientTestClient < Intrinio::Realtime::Client
  attr_reader :auth_attempts, :sockets, :socket_options
  attr_accessor :auth_results, :connect_results

  def initialize(options, on_trade = proc {}, on_quote = proc {})
    super(options, on_trade, on_quote)
    @auth_attempts = 0
    @auth_results = []
    @connect_results = []
    @sockets = []
    @socket_options = []
    @test_mutex = Mutex.new
  end

  private

  def refresh_token
    result = @test_mutex.synchronize do
      @auth_attempts += 1
      @auth_results.empty? ? 'token' : @auth_results.shift
    end
    raise result if result.is_a?(Exception)
    result.call if result.respond_to?(:call)
    result
  end

  def open_websocket(_url, options)
    socket = FakeWebSocket.new
    @sockets << socket
    @socket_options << options
    yield socket
    result = @connect_results.empty? ? socket : @connect_results.shift
    raise result if result.is_a?(Exception)
    socket
  end
end

class RecordingQueueClient < Intrinio::Realtime::Client
  attr_reader :handled_types

  def initialize(options)
    super(options, proc {}, proc {})
    @handled_types = Queue.new
  end

  private

  def handle_message(data, start_index)
    @handled_types << data[start_index]
    start_index + data[start_index + 1]
  end
end

class DisconnectingQueueClient < Intrinio::Realtime::Client
  attr_reader :finished

  def initialize(options)
    super(options, proc {}, proc {})
    @finished = Queue.new
  end

  private

  def handle_message(data, start_index)
    disconnect
    @finished << true
    start_index + data[start_index + 1]
  end
end

class IntrinioRealtimeClientTest < Minitest::Test
  Frame = Struct.new(:data, :type)

  def setup
    @clients = []
  end

  def teardown
    @clients.each do |client|
      client.disconnect
    rescue StandardError
      nil
    end
  end

  def options(overrides = {})
    {
      :api_key => 'test-key',
      :provider => Intrinio::Realtime::MANUAL,
      :ip_address => 'localhost:1234',
      :threads => 1,
      :logger => false,
      :channels => ['AAPL']
    }.merge(overrides)
  end

  def build_client(overrides = {})
    client = ResilientTestClient.new(options(overrides))
    client.instance_variable_set(:@selfheal_backoffs, [0, 1, 5])
    @clients << client
    client
  end

  def within_event_machine(timeout = 2)
    failure = nil
    finished = false
    EM.run do
      finish = proc do |&checks|
        begin
          checks.call if checks
        rescue Exception => e
          failure = e
        ensure
          finished = true
          EM.stop
        end
      end

      yield finish
      EM.add_timer(timeout) do
        next if finished
        failure = Minitest::Assertion.new("Timed out after #{timeout} seconds")
        EM.stop
      end
    end
    raise failure if failure
  end

  def poll_until(condition, &success)
    timer = nil
    timer = EM.add_periodic_timer(0.005) do
      next unless condition.call
      timer.cancel
      success.call
    end
  end

  def ready?(client)
    client.instance_variable_get(:@ready)
  end

  def test_public_method_signatures_are_unchanged
    klass = Intrinio::Realtime::Client
    assert_equal [[:req, :options], [:req, :on_trade], [:req, :on_quote]], klass.instance_method(:initialize).parameters
    assert_equal [], klass.instance_method(:connect).parameters
    assert_equal [], klass.instance_method(:disconnect).parameters
    assert_equal [[:rest, :channels]], klass.instance_method(:join).parameters
    assert_equal [[:rest, :channels]], klass.instance_method(:leave).parameters
    assert_equal [], klass.instance_method(:leave_all).parameters
    assert_equal [[:req, :on_trade]], klass.instance_method(:on_trade).parameters
    assert_equal [[:req, :on_quote]], klass.instance_method(:on_quote).parameters
  end

  def test_trade_queue_is_drained_before_quote_queue
    client = RecordingQueueClient.new(options)
    @clients << client
    client.send(:start_workers)

    # Each two-byte chunk is enough for the recording handler. The packet puts
    # two quotes before a trade to prove scheduling is priority-based, not FIFO.
    client.send(:queue_message, [3, 1, 2, 2, 2, 0, 2].pack('C*'))

    types = Timeout.timeout(1) {3.times.map {client.handled_types.pop}}
    assert_equal [0, 1, 2], types
  end

  def test_bid_messages_are_dispatched
    quotes = []
    client = Intrinio::Realtime::Client.new(options, proc {}, proc {|quote| quotes << quote})
    @clients << client
    chunk = quote_chunk(2, 'AAPL')

    client.send(:handle_message, chunk.unpack('C*'), 0)

    assert_equal 1, quotes.length
    assert_equal Intrinio::Realtime::BID, quotes.first.type
    assert_equal 'AAPL', quotes.first.symbol
  end

  def test_auth_failures_retry_until_the_client_opens
    client = build_client
    client.auth_results = [IOError.new('temporary auth failure'), 'token']

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 1}) do
        client.sockets.first.emit(:open)
      end
      poll_until(-> {ready?(client)}) do
        finish.call do
          assert_equal 2, client.auth_attempts
          assert_equal 1, client.sockets.length
        end
      end
    end
  end

  def test_websocket_connect_failures_retry_until_success
    client = build_client
    client.connect_results = [IOError.new('upgrade failed')]

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 2}) do
        client.sockets.last.emit(:open)
      end
      poll_until(-> {ready?(client)}) do
        finish.call do
          assert_equal 2, client.auth_attempts
          assert_equal 2, client.sockets.length
          assert client.sockets.first.closed?
        end
      end
    end
  end

  def test_error_and_close_for_one_socket_start_only_one_reconnect
    client = build_client

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 1}) do
        first = client.sockets.first
        first.emit(:open)
        first.emit(:error, IOError.new('connection reset'))
        first.emit(:close, 'closed')
      end
      poll_until(-> {client.sockets.length == 2}) do
        client.sockets.last.emit(:open)
        EM.add_timer(0.05) do
          finish.call do
            assert_equal 2, client.auth_attempts
            assert_equal 2, client.sockets.length
            assert ready?(client)
          end
        end
      end
    end
  end

  def test_stale_socket_callbacks_do_not_break_a_reconnected_client
    client = build_client

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 1}) do
        client.sockets.first.emit(:open)
        client.sockets.first.emit(:close, 'closed')
      end
      poll_until(-> {client.sockets.length == 2}) do
        client.sockets.last.emit(:open)
      end
      poll_until(-> {ready?(client)}) do
        client.sockets.first.emit(:error, IOError.new('late stale error'))
        EM.add_timer(0.05) do
          finish.call do
            assert_equal 2, client.sockets.length
            assert ready?(client)
          end
        end
      end
    end
  end

  def test_reconnect_rejoins_channels_and_sends_binary_messages
    client = build_client

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 1}) do
        client.sockets.first.emit(:open)
      end
      poll_until(-> {client.sockets.first.sent.length == 1}) do
        client.sockets.first.emit(:close, 'closed')
      end
      poll_until(-> {client.sockets.length == 2}) do
        client.sockets.last.emit(:open)
      end
      poll_until(-> {client.sockets.last.sent.length == 1}) do
        finish.call do
          assert_equal({:type => :binary}, client.sockets.last.sent.first[1])
          assert_equal [74, 0].concat('AAPL'.bytes), client.sockets.last.sent.first[0].bytes
          headers = client.socket_options.last.fetch(:headers)
          assert_equal Intrinio::Realtime::CLIENT_INFO_HEADER_VALUE,
                       headers.fetch(Intrinio::Realtime::CLIENT_INFO_HEADER_KEY)
        end
      end
    end
  end

  def test_channels_added_while_disconnected_are_joined_after_reconnect
    client = build_client
    client.instance_variable_set(:@selfheal_backoffs, [50])

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 1}) do
        client.sockets.first.emit(:open)
      end
      poll_until(-> {ready?(client)}) do
        client.sockets.first.emit(:close, 'closed')
        client.join('MSFT')
      end
      poll_until(-> {client.sockets.length == 2}) do
        client.sockets.last.emit(:open)
      end
      poll_until(-> {client.sockets.last.sent.length == 2}) do
        finish.call do
          joined = client.sockets.last.sent.map {|message, _| message.bytes.drop(2).pack('C*')}
          assert_equal ['AAPL', 'MSFT'], joined
        end
      end
    end
  end

  def test_hung_websocket_handshake_times_out_and_retries
    client = build_client
    client.instance_variable_set(:@connect_timeout_seconds, 0.02)

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 2}) do
        client.sockets.last.emit(:open)
      end
      poll_until(-> {ready?(client)}) do
        finish.call do
          assert client.sockets.first.closed?
          assert_equal 2, client.auth_attempts
        end
      end
    end
  end

  def test_send_failure_while_rejoining_retries_again
    client = build_client

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 1}) do
        client.sockets.first.emit(:open)
      end
      poll_until(-> {client.sockets.first.sent.length == 1}) do
        client.sockets.first.emit(:close, 'closed')
      end
      poll_until(-> {client.sockets.length == 2}) do
        client.sockets[1].fail_next_send(IOError.new('send failed'))
        client.sockets[1].emit(:open)
      end
      poll_until(-> {client.sockets.length == 3}) do
        client.sockets[2].emit(:open)
      end
      poll_until(-> {ready?(client) && client.sockets[2].sent.length == 1}) do
        finish.call do
          assert_equal 3, client.auth_attempts
          assert client.sockets[1].closed?
        end
      end
    end
  end

  def test_start_after_disconnect_creates_a_fresh_socket_and_rejoins
    client = build_client

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 1}) do
        client.sockets.first.emit(:open)
      end
      poll_until(-> {ready?(client) && client.sockets.first.sent.length == 1}) do
        client.disconnect
        client.connect
      end
      poll_until(-> {client.sockets.length == 2}) do
        client.sockets.last.emit(:open)
      end
      poll_until(-> {ready?(client) && client.sockets.last.sent.length == 1}) do
        finish.call do
          assert_equal 2, client.auth_attempts
          assert_equal ['AAPL'], client.instance_variable_get(:@channels)
          assert client.sockets.first.closed?
        end
      end
    end
  end

  def test_repeated_connect_while_authorizing_is_single_flight
    release_auth = Queue.new
    client = build_client
    client.auth_results = [proc {release_auth.pop; 'token'}]

    within_event_machine do |finish|
      client.connect
      capture_io {client.connect}
      poll_until(-> {client.auth_attempts == 1}) do
        release_auth << true
      end
      poll_until(-> {client.sockets.length == 1}) do
        client.sockets.first.emit(:open)
      end
      poll_until(-> {ready?(client)}) do
        finish.call do
          assert_equal 1, client.auth_attempts
          assert_equal 1, client.sockets.length
        end
      end
    end
  end

  def test_disconnect_can_be_called_from_a_market_event_callback
    client = DisconnectingQueueClient.new(options)
    @clients << client
    client.send(:start_workers)

    client.send(:queue_message, [1, 0, 2].pack('C*'))

    Timeout.timeout(1) {client.finished.pop}
    assert_empty client.instance_variable_get(:@threads)
  end

  def test_disconnect_during_authorization_ignores_the_late_result
    release_auth = Queue.new
    client = build_client
    client.auth_results = [proc {release_auth.pop; 'late-token'}]

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.auth_attempts == 1}) do
        client.disconnect
        release_auth << true
        EM.add_timer(0.05) do
          finish.call do
            assert_empty client.sockets
            refute ready?(client)
          end
        end
      end
    end
  end

  def test_disconnect_clears_queued_events_and_restart_preserves_channels
    client = RecordingQueueClient.new(options)
    @clients << client
    client.send(:queue_message, [1, 0, 2].pack('C*'))

    client.disconnect
    client.send(:start_workers)
    sleep 0.02

    assert client.handled_types.empty?
    assert_equal ['AAPL'], client.instance_variable_get(:@channels)
  ensure
    client.send(:stop_workers) if client
  end

  def test_non_binary_websocket_messages_are_ignored
    client = build_client

    within_event_machine do |finish|
      client.connect
      poll_until(-> {client.sockets.length == 1}) do
        client.sockets.first.emit(:open)
      end
      poll_until(-> {ready?(client)}) do
        client.sockets.first.emit(:message, Frame.new('server warning', :text))
        EM.add_timer(0.02) do
          finish.call do
            assert ready?(client)
            assert client.instance_variable_get(:@trade_messages).empty?
            assert client.instance_variable_get(:@quote_messages).empty?
          end
        end
      end
    end
  end

  private

  def quote_chunk(type, symbol)
    condition = ''.b
    market_center = 'Q'.encode('UTF-16LE').bytes
    length = 23 + symbol.bytesize + condition.bytesize
    bytes = [type, length, symbol.bytesize]
    bytes.concat(symbol.bytes)
    bytes << 0
    bytes.concat(market_center)
    bytes.concat([101.5].pack('e').bytes)
    bytes.concat([100].pack('V').bytes)
    bytes.concat([123_456].pack('Q<').bytes)
    bytes << condition.bytesize
    bytes.concat(condition.bytes)
    bytes.pack('C*')
  end
end
