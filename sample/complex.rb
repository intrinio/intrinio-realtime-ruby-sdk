#!/usr/bin/env ruby
$:.unshift File.expand_path '../lib', File.dirname(__FILE__)
require 'rubygems'
require 'intrinio-realtime'
require 'thread/pool'
require 'eventmachine'

# Provide your Intrinio API access keys (found in https://intrinio.com/account)
api_key = "OjU3ZTM4YTFjMWMzOGQ0ZjRjYTI1YWQxMDUzMzE1ZWJj"

# Setup a logger
logger = Logger.new($stdout)
logger.level = Logger::INFO

# Specify options
options = {
  api_key: api_key,
  provider: Intrinio::Realtime::IEX,
  channels: ["AAPL","GE","MSFT"],
  logger: logger
}

# Setup a pool of 50 threads to handle quotes
pool = Thread.pool(50)

# Run your code in an EventMachine environment for event-driven, continuous execution
EventMachine.run do
  # Create a client
  ir = Intrinio::Realtime::Client.new(options)
  
  # Handle quotes
  ir.on_quote do |quote|
    # Process quote in next available thread
    pool.process do
      logger.info "QUOTE! #{quote}"
      sleep 0.100 # simulate 100ms for I/O operation
    end
  end
  
  # Start listening
  ir.connect()
  
  # Change channels after 3 seconds
  EventMachine.add_timer(3) do
    ir.leave_all()
    ir.join("BAC","LUV","F")
  end
  
  # Disconnect after 10 seconds
  EventMachine.add_timer(10) do
    ir.disconnect()
    EventMachine.stop()
  end
end
