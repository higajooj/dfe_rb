module DfeRb
  module Efd
    module IcmsIpi
      # The leiaute's version (COD_VER of 0000), by the year of the period's last day:
      # the version must be in force on DT_FIN (Tabela Versão do Leiaute, item 3.1.1 of
      # the Nota Técnica of Ato COTEPE/ICMS 44/2018). From 2027 the leiaute is 021 (NT
      # 2026.001), whose registers aren't written here yet.
      module Version
        BY_YEAR = {2019 => "013", 2020 => "014", 2021 => "015", 2022 => "016", 2023 => "017", 2024 => "018", 2025 => "019", 2026 => "020"}.freeze

        module_function

        def for(last_day)
          BY_YEAR.fetch(last_day.year) { raise ArgumentError, "no leiaute of the EFD ICMS/IPI is written here for #{last_day.year}" }
        end
      end
    end
  end
end
