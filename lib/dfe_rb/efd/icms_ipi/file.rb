module DfeRb
  module Efd
    module IcmsIpi
      # A line of the EFD ICMS/IPI, its register from Layout.
      class Record < Efd::Record
        LAYOUT = Layout
      end

      # The EFD ICMS/IPI file of a period (see Efd::File).
      #
      #   file = DfeRb::Efd::IcmsIpi::File.new
      #   file.add "0000", cod_ver: "020", cod_fin: 0, dt_ini: Date.new(2026, 1, 1), ...
      #   c100 = file.add "C100", ind_oper: 1, ind_emit: 0, ...
      #   c100.add "C190", cst_icms: "000", cfop: "5102", ...
      #   File.binwrite("efd.txt", file.to_latin1)
      class File < Efd::File
        BLOCKS = %w[0 B C D E G H K 1 9].freeze
        RECORD = Record
      end
    end
  end
end
