require "base64"
require "digest"
require "stringio"
require "zlib"

require_relative "distribution/errors"
require_relative "distribution/xml"
require_relative "distribution/endpoints"
require_relative "distribution/schemas"
require_relative "distribution/documents"
require_relative "distribution/results"
require_relative "distribution/manifestation"
require_relative "distribution/responses"
require_relative "distribution/client"

module DfeRb
  module Nfe
    # Documents of interest and explicit recipient manifestations, through Ambiente Nacional.
    module Distribution
    end
  end
end
