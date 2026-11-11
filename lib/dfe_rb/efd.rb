require "bigdecimal"
require "date"

module DfeRb
  # SPED's Escrituração Fiscal Digital: the files a taxpayer delivers to the tax
  # authorities, built from the documents it issued and received.
  module Efd
    # The EFD ICMS/IPI (SPED Fiscal), monthly, per establishment.
    module IcmsIpi
    end

    # The EFD-Contribuições (PIS/Pasep and COFINS), monthly, for the whole company.
    module Contribuicoes
    end
  end
end

require_relative "efd/latin1"
require_relative "efd/field"
require_relative "efd/record"
require_relative "efd/file"

require_relative "efd/icms_ipi/layout"
require_relative "efd/icms_ipi/file"
require_relative "efd/icms_ipi/version"
require_relative "efd/icms_ipi/note"
require_relative "efd/icms_ipi/analytic"
require_relative "efd/icms_ipi/apuracao"

module DfeRb
  module Efd
    module IcmsIpi
      Field = Efd::Field
      Latin1 = Efd::Latin1
    end
  end
end
