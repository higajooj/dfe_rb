require "dfe_rb"
require "stringio"
require "zlib"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  # Specs tagged `live: true` talk to the real SEFAZ homologacao and need a certificate. Run
  # them with DFE_RB_LIVE=1 (see spec/live).
  config.filter_run_excluding live: true unless ENV["DFE_RB_LIVE"]

  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
end
