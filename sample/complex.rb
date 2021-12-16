#!/usr/bin/env ruby
$:.unshift File.expand_path '../lib', File.dirname(__FILE__)
require 'rubygems'
require 'intrinio-realtime'
require 'thread/pool'
require 'eventmachine'

# Provide your Intrinio API access keys (found in https://intrinio.com/account)
api_key = "YOUR_INTRINIO_API_KEY"

# Setup a logger
logger = Logger.new($stdout)
logger.level = Logger::INFO

# Specify options
options = {
  api_key: api_key,
  provider: Intrinio::Realtime::REALTIME,
  channels: ["MSFT","AAPL","GE","GOOG","F","AMZN"],
  #channels: ["lobby"],
  logger: logger,
  threads: 4,
  trades_only: false
}

on_trade = -> (trade) {logger.info "TRADE! #{trade}"}
on_quote = -> (quote) {logger.info "QUOTE! #{quote}"}

EventMachine.run do
  # Create a client
  ir = Intrinio::Realtime::Client.new(options, on_trade, on_quote)
  
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
