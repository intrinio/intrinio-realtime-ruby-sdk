#!/usr/bin/env ruby
$:.unshift File.expand_path '../lib', File.dirname(__FILE__)
require 'rubygems'
require 'intrinio-realtime'
require 'thread/pool'

# Provide your Intrinio API access keys (found in https://intrinio.com/account)
api_key = "YOUR_INTRINIO_API_KEY"

# Setup a logger
logger = Logger.new($stdout)
logger.level = Logger::INFO

# Specify options
options = {
  api_key: api_key,
  provider: Intrinio::Realtime::IEX,
  channels: ["MSFT","AAPL","GE"],
  logger: logger,
}

# Setup a pool of 50 threads to handle quotes
pool = Thread.pool(50)

# Start listening for quotes
Intrinio::Realtime.connect(options) do |quote|
  # Process quote in next available thread
  pool.process do
    logger.info "QUOTE! #{quote}"
    sleep 0.100 # simulate 100ms for I/O operation
  end
end
