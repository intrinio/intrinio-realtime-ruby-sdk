gem build intrinio-realtime
gem push $(la | grep "intrinio-realtime.*\.gem$" | tail -n 1)