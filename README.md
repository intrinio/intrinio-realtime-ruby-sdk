# Intrinio Ruby SDK for Real-Time Multi-Exchange prices feed

SDK for working with Intrinio's realtime IEX, delayed SIP, CBOE One, or NASDAQ Basic prices feeds.  Get a comprehensive view with increased market volume and enjoy minimized exchange and per user fees.

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
  provider: Intrinio::Realtime::IEX, # IEX, REALTIME (interchangable with IEX), DELAYED_SIP, NASDAQ_BASIC, CBOE_ONE, or MANUAL
  channels: ["MSFT","AAPL","GE","GOOG","F","AMZN"],
  logger: logger,
  threads: 4,
  trades_only: false,
  delayed: false # set to true if you have realtime access and want to force 15 minute delayed mode.
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

### Equities Trade Conditions

| Value | Description                                       |
|-------|---------------------------------------------------|
| @     | Regular Sale                                      |
| A     | Acquisition                                       |
| B     | Bunched Trade                                     |
| C     | Cash Sale                                         |
| D     | Distribution                                      |
| E     | Placeholder                                       |
| F     | Intermarket Sweep                                 |
| G     | Bunched Sold Trade                                |
| H     | Priced Variation Trade                            |
| I     | Odd Lot Trade                                     |
| K     | Rule 155 Trade (AMEX)                             |
| L     | Sold Last                                         |
| M     | Market Center Official Close                      |
| N     | Next Day                                          |
| O     | Opening Prints                                    |
| P     | Prior Reference Price                             |
| Q     | Market Center Official Open                       |
| R     | Seller                                            |
| S     | Split Trade                                       |
| T     | Form T                                            |
| U     | Extended Trading Hours (Sold Out of Sequence)     |
| V     | Contingent Trade                                  |
| W     | Average Price Trade                               |
| X     | Cross/Periodic Auction Trade                      |
| Y     | Yellow Flag Regular Trade                         |
| Z     | Sold (Out of Sequence)                            |
| 1     | Stopped Stock (Regular Trade)                     |
| 4     | Derivatively Priced                               |
| 5     | Re-Opening Prints                                 |
| 6     | Closing Prints                                    |
| 7     | Qualified Contingent Trade (QCT)                  |
| 8     | Placeholder for 611 Exempt                        |
| 9     | Corrected Consolidated Close (Per Listing Market) |


### Equities Trade Conditions (CBOE One)
Trade conditions for CBOE One are represented as the integer representation of a bit flag.

None                      = 0,
UpdateHighLowConsolidated = 1,
UpdateLastConsolidated    = 2,
UpdateHighLowMarketCenter = 4,
UpdateLastMarketCenter    = 8,
UpdateVolumeConsolidated  = 16,
OpenConsolidated          = 32,
OpenMarketCenter          = 64,
CloseConsolidated         = 128,
CloseMarketCenter         = 256,
UpdateVolumeMarketCenter  = 512


### Equities Quote Conditions

| Value | Description                                 |
|-------|---------------------------------------------|
| R     | Regular                                     |
| A     | Slow on Ask                                 |
| B     | Slow on Bid                                 |
| C     | Closing                                     |
| D     | News Dissemination                          |
| E     | Slow on Bid (LRP or Gap Quote)              |
| F     | Fast Trading                                |
| G     | Trading Range Indication                    |
| H     | Slow on Bid and Ask                         |
| I     | Order Imbalance                             |
| J     | Due to Related - News Dissemination         |
| K     | Due to Related - News Pending               |
| O     | Open                                        |
| L     | Closed                                      |
| M     | Volatility Trading Pause                    |
| N     | Non-Firm Quote                              |
| O     | Opening                                     |
| P     | News Pending                                |
| S     | Due to Related                              |
| T     | Resume                                      |
| U     | Slow on Bid and Ask (LRP or Gap Quote)      |
| V     | In View of Common                           |
| W     | Slow on Bid and Ask (Non-Firm)              |
| X     | Equipment Changeover                        |
| Y     | Sub-Penny Trading                           |
| Z     | No Open / No Resume                         |
| 1     | Market Wide Circuit Breaker Level 1         |
| 2     | Market Wide Circuit Breaker Level 2         |        
| 3     | Market Wide Circuit Breaker Level 3         |
| 4     | On Demand Intraday Auction                  |        
| 45    | Additional Information Required (CTS)       |      
| 46    | Regulatory Concern (CTS)                    |     
| 47    | Merger Effective                            |    
| 49    | Corporate Action (CTS)                      |   
| 50    | New Security Offering (CTS)                 |  
| 51    | Intraday Indicative Value Unavailable (CTS) |

## Channels
You may subscribe to a list of securities by subscribing to each individually, or subscribe to all available securities by subscribing to 'lobby'.  Lobby requires your account to have firehose connection permission enabled.

## API Keys
You will receive your Intrinio API Key after [creating an account](https://intrinio.com/signup). You will need a subscription to a [realtime data feed](https://intrinio.com/real-time-multi-exchange) as well.

## Documentation

### Methods

`Intrinio::Realtime.connect(options, on_trade, on_quote)` - Connects to the Intrinio Realtime feed and provides quotes to the given lambdas.
* **Parameter** `options.api_key`: Your Intrinio API Key
* **Parameter** `options.provider`: The real-time data provider to use (`Intrinio::Realtime::IEX` or DELAYED_SIP, or CBOE_ONE, NASDAQ_BASIC, MANUAL)
* **Parameter** `options.channels`: (optional) An array of channels to join after connecting
* **Parameter** `options.logger`: (optional) A Ruby logger to use for logging
* **Parameter** `options.threads`: The quantity of threads used for processing market events.
* **Parameter** `options.trades_only`: True or False.  True indicates you only want trade events.  False indicates you want trade and quote (bid/ask) events.
* **Parameter** `options.delayed`: set to true if you have realtime access and want to force 15 minute delayed mode. Has no effect outside of that scenario.
* **Parameter** `on_trade`: The lambda to fire when a trade happens.  Accepts a trade object as input.
* **Parameter** `on_quote`: The lambda to fire when a quote happens.  Accepts a quote object as input.
```ruby
Intrinio::Realtime.connect(options, on_trade, on_quote)
```

---------

`Intrinio::Realtime::Client.new(options, on_trade, on_quote)` - Creates a new instance of the Intrinio Realtime Client.
* **Parameter** `options.api_key`: Your Intrinio API Key
* **Parameter** `options.provider`: The real-time data provider to use (`Intrinio::Realtime::IEX` or DELAYED_SIP, CBOE_ONE, NASDAQ_BASIC, MANUAL)
* **Parameter** `options.channels`: (optional) An array of channels to join after connecting
* **Parameter** `options.logger`: (optional) A Ruby logger to use for logging
* **Parameter** `options.threads`: The quantity of threads used for processing market events.
* **Parameter** `options.trades_only`: True or False.  True indicates you only want trade events.  False indicates you want trade and quote (bid/ask) events.
* **Parameter** `options.delayed`: set to true if you have realtime access and want to force 15 minute delayed mode. Has no effect outside of that scenario.
* **Parameter** `on_trade`: The lambda to fire when a trade happens.  Accepts a trade object as input.
* **Parameter** `on_quote`: The lambda to fire when a quote happens.  Accepts a quote object as input.
```ruby
options = {
  api_key: api_key,
  provider: Intrinio::Realtime::IEX, # IEX, REALTIME (interchangable with IEX), DELAYED_SIP, NASDAQ_BASIC, CBOE_ONE, or MANUAL
  channels: ["MSFT","AAPL","GE","GOOG","F","AMZN"],
  logger: logger,
  threads: 4,
  trades_only: false,
  delayed: false # set to true if you have realtime access and want to force 15 minute delayed mode.
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
