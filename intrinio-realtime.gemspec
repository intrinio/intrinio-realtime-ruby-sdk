lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "intrinio-realtime"
  spec.version       = "4.1.1"
  spec.authors       = ["Intrinio"]
  spec.email         = ["admin@intrinio.com"]
  spec.description   = %q{Intrinio Ruby SDK for Real-Time Stock Prices}
  spec.summary       = %q{Intrinio provides real-time stock prices from its Multi-Exchange feed, via a two-way WebSocket connection.}
  spec.homepage      = "https://github.com/intrinio/intrinio-realtime-ruby-sdk"
  spec.license       = "GPL-3.0"
  spec.files         = ["lib/intrinio-realtime.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "eventmachine", '~> 1.2'
  spec.add_dependency "websocket-client-simple", '~> 0.3'
  spec.add_dependency "thread", '~> 0.2.2'
  spec.add_dependency "bigdecimal", '~> 1.4.0'
end
