require "webmock/rspec"

# The SEFAZ web services must never be reached from specs.
WebMock.disable_net_connect!(allow_localhost: true)
