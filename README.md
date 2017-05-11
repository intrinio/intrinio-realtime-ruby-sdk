# Intrinio Ruby SDK for Real-Time Stock Prices

[Intrinio](https://intrinio.com/) provides real-time stock prices from the [IEX stock exchange](https://iextrading.com/), via a two-way WebSocket connection. To get started, [subscribe here](https://intrinio.com/data/realtime-stock-prices) and follow the instructions below.

## Requirements

- Ruby 2.3.1

## Features

* Receive streaming, real-time price quotes from the IEX stock exchange
  * Bid, ask, and last price
  * Order size
  * Order execution timestamp
* Subscribe to updates from individual securities
* Subscribe to updates for all securities (contact us for special access)

## Installation
```
gen install intrinio-realtime
```

## Example Usage
```ruby
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

```

## Handling Quotes

When handling quotes, make sure to do so in a non-blocking fashion. We recommend using the (thread)[https://github.com/meh/ruby-thread] gem to setup a thread pool for operations like writing quotes to database (or anything else involving time-consuming I/O). If your handling code blocks, no new quotes will be received until the code is finished. So in order to make sure you receive all incoming quotes, handle the individual quotes with a thread pool. For listening to individual security channels, we recommend a thread pool size of 50. For the $lobby channel, we recommend 500 or higher. If you find that the quotes are not being processed quickly enough, increase the pool size - it is likely that they are being backed up in the thread pool's backlog (which you can check by accessing `pool.backlog`).

## Quote Fields

```ruby
{ type: 'ask',
  timestamp: 1493409509.3932788,
  ticker: 'GE',
  size: 13750,
  price: 28.97 }
```

*   **type** - the quote type
  *    **`last`** - represents the last traded price
  *    **`bid`** - represents the top-of-book bid price
  *    **`ask`** - represents the top-of-book ask price
*   **timestamp** - a Unix timestamp (with microsecond precision)
*   **ticker** - the ticker of the security
*   **size** - the size of the `last` trade, or total volume of orders at the top-of-book `bid` or `ask` price
*   **price** - the price in USD

## Channels

To receive price quotes from the Intrinio Real-Time API, you need to instruct the client to "join" a channel. A channel can be
* A security ticker (`AAPL`, `MSFT`, `GE`, etc)
* The security lobby (`$lobby`) where all price quotes for all securities are posted
* The security last price lobby (`$lobby_last_price`) where only last price quotes for all securities are posted

Special access is required for both lobby channeles. [Contact us](mailto:sales@intrinio.com) for more information.

## API Keys
You will receive your Intrinio API Username and Password after [creating an account](https://intrinio.com/signup). You will need a subscription to the [IEX Real-Time Stock Prices](https://intrinio.com/data/realtime-stock-prices) data feed as well.

## Documentation

### Methods

`Intrinio::Realtime.connect(options, &block)` - Connects to the Intrinio Realtime feed and provides quotes to the given block.
* **Parameter** `options.username`: Your Intrinio API Username
* **Parameter** `options.password`: Your Intrinio API Password
* **Parameter** `options.channels`: (optional) An array of channels to join after connecting
* **Parameter** `options.logger`: (optional) A Ruby logger to use for logging
* **Parameter** `&block`: A block that receives a quote as its only parameter. *NOTE*: This block _must_ execute in a non-blocking fashion (by using a thread pool, for example). Otherwise quotes will be dropped until it is done blocking.
```ruby
Intrinio::Realtime.connect(options) do |quote|
  # handle quote in a non-blocking fashion
end
```

---------

`Intrinio::Realtime::Client.new(options)` - Creates a new instance of the Intrinio Realtime Client.
* **Parameter** `options.username`: Your Intrinio API Username
* **Parameter** `options.password`: Your Intrinio API Password
* **Parameter** `options.channels`: (optional) An array of channels to join after connecting
* **Parameter** `options.logger`: (optional) A Ruby logger to use for logging
```ruby
options = {
  username: username, 
  password: password, 
  channels: ["MSFT","AAPL","GE"]
}
client = Intrinio::Realtime::Client.new(options)
client.on_quote do |quote|
  # handle quote in a non-blocking fashion
end
client.connect()
```

---------

`client.connect()` - Retrieves an auth token, opens the WebSocket connection, starts the self-healing and heartbeat intervals, joins requested channels.

---------

`client.disconnect()` - Closes the WebSocket, stops the self-healing and heartbeat intervals. You _must_ call this to dispose of the client.

---------

`client.on_quote(&block)` - Invokes the given block when a quote has been received.
* **Parameter** `block` - The block to invoke. The quote will be passed as an argument to the block.
```ruby
client.on_quote do |quote|
  # handle quote in a non-blocking manner
end
```

---------

`client.join(...channels)` - Joins the given channels. This can be called at any time. The client will automatically register joined channels and establish the proper subscriptions with the WebSocket connection.
* **Parameter** `channels` - An argument list or array of channels to join. 
```ruby
client.join("AAPL", "MSFT", "GE")
client.join(["GOOG", "VG"])
client.join("$lobby")
```

---------

`client.leave(...channels)` - Leaves the given channels.
* **Parameter** `channels` - An argument list or array of channels to leave.
```ruby
client.leave("AAPL", "MSFT", "GE")
client.leave(["GOOG", "VG"])
client.leave("$lobby")
```

---------

`client.leave_all()` - Leaves all channels.
