#!/usr/bin/env ruby
$:.unshift File.expand_path '../lib', File.dirname(__FILE__)
require 'rubygems'
require 'intrinio-realtime'
require 'thread/pool'

# Provide your Intrinio API access keys (found in https://intrinio.com/account)
username = "YOUR_INTRINIO_API_USERNAME"
password = "YOUR_INTRINIO_API_PASSWORD"

# Setup a logger
logger = Logger.new($stdout)
logger.level = Logger::INFO

# Specify options
options = {
  username: username, 
  password: password, 
  provider: Intrinio::Realtime::IEX,
  channels: ["MSFT","AAPL","GE"],
  logger: logger
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
