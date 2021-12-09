#!/usr/bin/env ruby
$:.unshift File.expand_path '../lib', File.dirname(__FILE__)
require 'rubygems'
require 'intrinio-realtime'
require 'thread/pool'

# Provide your Intrinio API access keys (found in https://intrinio.com/account)
api_key = "OjU3ZTM4YTFjMWMzOGQ0ZjRjYTI1YWQxMDUzMzE1ZWJj"

# Setup a logger
logger = Logger.new($stdout)
logger.level = Logger::INFO

# Specify options
options = {
  api_key: api_key,
  provider: Intrinio::Realtime::REALTIME,
  channels: ["MSFT","AAPL","GE"],
  logger: logger,
  threads: 4
}

on_trade = -> (trade) {logger.info "TRADE! #{trade}"}

on_quote = -> (quote) {logger.info "QUOTE! #{quote}"}

# Start listening for quotes
Intrinio::Realtime.connect(options, on_trade, on_quote)
