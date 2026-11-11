module DfeRb
  module Efd
    module Contribuicoes
      # The leiaute's version (COD_VER of 0000), which must be in force on DT_FIN
      # (Guia Prático, tabela 3.1.1): 006 (leiaute 3.2.0) since January 2020. PIS and
      # COFINS end on 31/12/2026, when the CBS takes their place (LC 214/2025), and
      # the file isn't used for facts after it (Nota Técnica 011/2026).
      module Version
        FROM = Date.new(2020, 1, 1)
        LAST_DAY = Date.new(2026, 12, 31)

        module_function

        def for(last_day)
          if last_day < FROM
            raise ArgumentError, "no leiaute of the EFD-Contribuições is written here before #{FROM.year}"
          elsif last_day > LAST_DAY
            raise ArgumentError, "PIS and COFINS end on #{LAST_DAY.strftime("%d/%m/%Y")}: there is no EFD-Contribuições after it"
          end

          "006"
        end
      end
    end
  end
end
