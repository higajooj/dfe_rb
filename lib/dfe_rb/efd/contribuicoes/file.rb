module DfeRb
  module Efd
    module Contribuicoes
      # A line of the EFD-Contribuições, its register from Layout.
      class Record < Efd::Record
        LAYOUT = Layout
      end

      # The EFD-Contribuições file of a period (see Efd::File): the company's (its
      # head office's) 0000 to 0110, an 0140 for each establishment with its
      # participants, units and items below it, a C010 for each with its notes below,
      # and the apuração of Block M.
      #
      #   file = DfeRb::Efd::Contribuicoes::File.new
      #   file.add "0000", cod_ver: "006", tipo_escrit: 0, dt_ini: Date.new(2026, 1, 1), ...
      #   establishment = file.add "0140", nome: "ACME LTDA", cnpj: "12345678000195", ...
      #   establishment.add "0150", cod_part: "11222333000181", ...
      #   c100 = file.add("C010", cnpj: "12345678000195", ind_escri: "2").add("C100", ...)
      #   File.binwrite("efd.txt", file.to_latin1)
      class File < Efd::File
        BLOCKS = %w[0 A C D F I M P 1 9].freeze
        RECORD = Record
      end
    end
  end
end
