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
  provider: Intrinio::Realtime::IEX, # or NASDAQ_BASIC, or CBOE_ONE, or DELAYED_SIP, or MANUAL
  channels: ["MSFT","AAPL","GE","GOOG","F","AMZN"],
  #channels: ["lobby"],
  logger: logger,
  threads: 4,
  trades_only: false,
  delayed: false # set to true if you have realtime access and want to force 15 minute delayed.
}

on_trade = -> (trade) {logger.info "TRADE! #{trade}"}
on_quote = -> (quote) {logger.info "QUOTE! #{quote}"}

# Start listening for quotes
Intrinio::Realtime.connect(options, on_trade, on_quote)
