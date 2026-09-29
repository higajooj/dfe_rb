require "bigdecimal"

require_relative "nfe/states"
require_relative "nfe/access_key"
require_relative "nfe/endpoints"
require_relative "nfe/status_codes"
require_relative "nfe/names"
require_relative "nfe/schema"
require_relative "nfe/schemas"
require_relative "nfe/formatter"
require_relative "nfe/xml_writer"
require_relative "nfe/sugar"
require_relative "nfe/scope"
require_relative "nfe/totals"
require_relative "nfe/resolver"
require_relative "nfe/validator"
require_relative "nfe/invoice"
require_relative "nfe/signature"
require_relative "nfe/errors"
require_relative "nfe/responses"
require_relative "nfe/results"
require_relative "nfe/requests"
require_relative "nfe/client"

module DfeRb
  # Emission of NF-e (modelo 55, layout 4.00).
  module Nfe
  end
end
