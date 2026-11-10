module DfeRb
  module Efd
    module IcmsIpi
      # The file is ISO-8859-1 (Latin-1). Text with characters outside it keeps what it
      # can: typographic quotes and dashes become their ASCII kin, accented letters
      # outside Latin-1 lose the accent, anything else becomes a space.
      module Latin1
        REPLACEMENTS = {
          "‘" => "'", "’" => "'", "‚" => "'", "“" => '"', "”" => '"', "„" => '"', "–" => "-", "—" => "-", "‒" => "-",
          "…" => "...", "•" => "-", "€" => "EUR", "™" => "TM", " " => " "
        }.freeze

        module_function

        def text(value)
          return value if value.ascii_only?

          value.unicode_normalize(:nfc).each_char.map { |char| latin1?(char) ? char : fallback(char) }.join
        end

        def latin1?(char) = char.ord <= 0xFF

        def fallback(char)
          REPLACEMENTS.fetch(char) do
            base = char.unicode_normalize(:nfkd).each_char.select { |c| latin1?(c) }.join
            base.empty? ? " " : base
          end
        end
      end
    end
  end
end
