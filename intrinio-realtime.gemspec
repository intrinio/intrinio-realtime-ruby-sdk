lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "intrinio-realtime"
  spec.version       = "2.2.1"
  spec.authors       = ["Intrinio"]
  spec.email         = ["asolo@intrinio.com"]
  spec.description   = %q{Intrinio Ruby SDK for Real-Time Stock & Crypto Prices}
  spec.summary       = %q{Intrinio provides real-time stock & crypto prices from the IEX stock exchange, via a two-way WebSocket connection.}
  spec.homepage      = "https://github.com/intrinio/intrinio-realtime-ruby-sdk"
  spec.license       = "GPL-3.0"
  spec.files         = ["lib/intrinio-realtime.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "http", '~> 2.2'
  spec.add_dependency "eventmachine", '~> 1.2'
  spec.add_dependency "websocket-client-simple", '~> 0.3'
end
