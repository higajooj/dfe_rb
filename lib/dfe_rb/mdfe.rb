require "bigdecimal"

require_relative "mdfe/signature"
require_relative "mdfe/access_key"
require_relative "mdfe/schema"
require_relative "mdfe/schemas"
require_relative "mdfe/xml_writer"
require_relative "mdfe/names"
require_relative "mdfe/sugar"
require_relative "mdfe/scope"
require_relative "mdfe/qr_code"
require_relative "mdfe/resolver"
require_relative "mdfe/validator"
require_relative "mdfe/manifest"
require_relative "mdfe/document"
require_relative "mdfe/errors"
require_relative "mdfe/status_codes"
require_relative "mdfe/endpoints"
require_relative "mdfe/requests"
require_relative "mdfe/responses"
require_relative "mdfe/results"
require_relative "mdfe/client"

module DfeRb
  # Emission of MDF-e (modelo 58, layout 3.00).
  module Mdfe
  end
end
require_relative "mdfe/distribution"
