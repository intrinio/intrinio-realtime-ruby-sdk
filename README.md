# Intrinio Ruby SDK for Real-Time Multi-Exchange prices feed

SDK for working with Intrinio's realtime Multi-Exchange prices feed.  Intrinio’s Multi-Exchange feed bridges the gap by merging real-time equity pricing from the IEX and MEMX exchanges. Get a comprehensive view with increased market volume and enjoy no exchange fees, no per-user requirements, no permissions or authorizations, and little to no paperwork.

[Intrinio](https://intrinio.com/) provides real-time stock prices via a two-way WebSocket connection. To get started, [subscribe to a real-time data feed](https://intrinio.com/real-time-multi-exchange) and follow the instructions below.

[Documentation for our legacy realtime client](https://github.com/intrinio/intrinio-realtime-ruby-sdk/tree/2.2.0)

## Requirements

- Ruby 2.7.5

## Docker
Add your API key to the simple.rb file, then
```
docker compose build
docker compose run client
```

## Features

* Receive streaming, real-time price quotes (last trade, bid, ask)
* Subscribe to updates from individual securities
* Subscribe to updates for all securities

## Installation
```
gem install intrinio-realtime
```

## Example Usage
```ruby
#!/usr/bin/env ruby
$:.unshift File.expand_path '../lib', File.dirname(__FILE__)
require 'rubygems'
require 'intrinio-realtime'
require 'thread/pool'
require 'eventmachine'

# Provide your Intrinio API access keys (found in https://intrinio.com/account)
api_key = ""

# Setup a logger
logger = Logger.new($stdout)
logger.level = Logger::INFO

# Specify options
options = {
  api_key: api_key,
  provider: Intrinio::Realtime::REALTIME,
  channels: ["MSFT","AAPL","GE","GOOG","F","AMZN"],
  logger: logger,
  threads: 4,
  trades_only: false
}

on_trade = -> (trade) {logger.info "TRADE! #{trade}"}
on_quote = -> (quote) {logger.info "QUOTE! #{quote}"}

# Start listening for quotes
Intrinio::Realtime.connect(options, on_trade, on_quote)
```

## Handling Quotes

There are thousands of securities, each with their own feed of activity.  We highly encourage you to make your trade and quote handlers has short as possible and follow a queue pattern so your app can handle the volume of activity.

## Quote Data Format

### Quote Message

```ruby
class Quote
  def initialize(type, symbol, price, size, timestamp)
    @type = type
    @symbol = symbol
    @price = price
    @size = size
    @timestamp = timestamp
  end
  #...
end
```

*   **symbol** - the ticker of the security
*   **type** - the quote type
*    **`ask`** - represents the top-of-book ask price
*    **`bid`** - represents the top-of-book bid price
*   **price** - the price in USD
*   **size** - the size of the `last` trade, or total volume of orders at the top-of-book `bid` or `ask` price
*   **timestamp** - a Unix timestamp (nanoseconds since unix epoch)


### Trade Message

```ruby
class Trade
  def initialize(symbol, price, size, timestamp, total_volume)
    @symbol = symbol
    @price = price
    @size = size
    @timestamp = timestamp
    @total_volume = total_volume
  end
  #...
end
```

*   **symbol** - the ticker of the security
*   **total_volume** - the total volume of trades for the security so far today.
*   **price** - the price in USD
*   **size** - the size of the `last` trade, or total volume of orders at the top-of-book `bid` or `ask` price
*   **timestamp** - a Unix timestamp (nanoseconds since unix epoch)
## Channels
You may subscribe to a list of securities by subscribing to each individually, or subscribe to all available securities by subscribing to 'lobby'.  Lobby requires your account to have firehose connection permission enabled.

## API Keys
You will receive your Intrinio API Key after [creating an account](https://intrinio.com/signup). You will need a subscription to a [realtime data feed](https://intrinio.com/real-time-multi-exchange) as well.

## Documentation

### Methods

`Intrinio::Realtime.connect(options, on_trade, on_quote)` - Connects to the Intrinio Realtime feed and provides quotes to the given lambdas.
* **Parameter** `options.api_key`: Your Intrinio API Key
* **Parameter** `options.provider`: The real-time data provider to use (`Intrinio::Realtime::REALTIME`)
* **Parameter** `options.channels`: (optional) An array of channels to join after connecting
* **Parameter** `options.logger`: (optional) A Ruby logger to use for logging
* **Parameter** `options.threads`: The quantity of threads used for processing market events.
* **Parameter** `options.trades_only`: True or False.  True indicates you only want trade events.  False indicates you want trade and quote (bid/ask) events.
* **Parameter** `on_trade`: The lambda to fire when a trade happens.  Accepts a trade object as input.
* **Parameter** `on_quote`: The lambda to fire when a quote happens.  Accepts a quote object as input.
```ruby
Intrinio::Realtime.connect(options, on_trade, on_quote)
```

---------

`Intrinio::Realtime::Client.new(options, on_trade, on_quote)` - Creates a new instance of the Intrinio Realtime Client.
* **Parameter** `options.api_key`: Your Intrinio API Key
* **Parameter** `options.provider`: The real-time data provider to use (`Intrinio::Realtime::REALTIME`)
* **Parameter** `options.channels`: (optional) An array of channels to join after connecting
* **Parameter** `options.logger`: (optional) A Ruby logger to use for logging
* **Parameter** `options.threads`: The quantity of threads used for processing market events.
* **Parameter** `options.trades_only`: True or False.  True indicates you only want trade events.  False indicates you want trade and quote (bid/ask) events.
* **Parameter** `on_trade`: The lambda to fire when a trade happens.  Accepts a trade object as input.
* **Parameter** `on_quote`: The lambda to fire when a quote happens.  Accepts a quote object as input.
```ruby
options = {
  api_key: api_key,
  provider: Intrinio::Realtime::REALTIME,
  channels: ["MSFT","AAPL","GE","GOOG","F","AMZN"],
  logger: logger,
  threads: 4,
  trades_only: false
}
client = Intrinio::Realtime::Client.new(options, on_trade, on_quote)
client.connect()
```

---------

`client.connect()` - Retrieves an auth token, opens the WebSocket connection, starts the self-healing and heartbeat intervals, joins requested channels.

---------

`client.disconnect()` - Closes the WebSocket, stops the self-healing and heartbeat intervals. You _must_ call this to dispose of the client.

---------

`client.join(...channels)` - Joins the given channels. This can be called at any time. The client will automatically register joined channels and establish the proper subscriptions with the WebSocket connection.
* **Parameter** `channels` - An argument list or array of channels to join. You can also use the special symbol, "lobby" to join the firehose channel and recieved updates for all ticker symbols. You must have a valid "firehose" subscription.
```ruby
client.join("AAPL", "MSFT", "GE")
client.join(["GOOG", "VG"])
client.join("lobby")
```

---------

`client.leave(...channels)` - Leaves the given channels.
* **Parameter** `channels` - An argument list or array of channels to leave.
```ruby
client.leave("AAPL", "MSFT", "GE")
client.leave(["GOOG", "VG"])
client.leave("lobby")
```

---------

`client.leave_all()` - Leaves all channels.
