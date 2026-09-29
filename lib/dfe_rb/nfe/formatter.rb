require "bigdecimal"
require "date"

module DfeRb
  module Nfe
    # Turns Ruby values into the exact text the layout demands for an element's type:
    # decimals with the right number of places, ISO dates with a whole-hour UTC offset,
    # digit codes with their leading zeros, text without characters SEFAZ rejects.
    module Formatter
      # Raised for a value that cannot be written for its element; the writer collects these
      # as validation issues instead of failing on the first.
      class Invalid < StandardError; end

      FRACTION = /\\\.(?:\[0-9\]|\[1-9\]|0)\{(\d+)(?:,(\d+))?\}/
      FIXED_DIGITS = /\A\[0-9\]\{(\d+)\}\z/

      module_function

      # The text for `value` in `element`, or nil when a zero must be left out because the
      # type does not admit it (the *Opc decimal types).
      def format(value, element)
        type = element.type
        case value
        when Time, DateTime then format_time(value, type)
        when Date then value.strftime("%Y-%m-%d")
        when BigDecimal, Float then decimal(BigDecimal(value.to_s), element)
        when Integer then integer(value, element)
        when true, false then raise Invalid, "expected a value, got #{value.inspect}"
        else
          text(value.to_s, element)
        end
      end

      def integer(value, element)
        type = element.type
        return decimal(BigDecimal(value), element) if decimal_type?(type)

        digits = value.to_s
        fixed = fixed_digits(type)
        (fixed && value >= 0) ? digits.rjust(fixed, "0") : digits
      end

      def text(value, element)
        type = element.type
        return decimal(parse_decimal(value), element) if decimal_type?(type)

        clean = sanitize(value)
        if clean.each_char.any? { |char| char.ord > 0xFF }
          raise Invalid, "contains characters outside ISO-8859-1 (#{clean.each_char.select { |c| c.ord > 0xFF }.uniq.join})"
        end
        if type.min_length && clean.length < type.min_length
          raise Invalid, "is too short (#{clean.length} characters, minimum #{type.min_length})"
        end
        if type.max_length && clean.length > type.max_length
          raise Invalid, "is too long (#{clean.length} characters, maximum #{type.max_length})"
        end

        clean
      end

      PUNCTUATION = /[.\-\/\s()]/
      CODE_PATTERN = /\A(?:\[[0-9A-Z,-]+\]|\{\d+(?:,\d+)?\}|[|()]|[A-Z]+)+\z/

      # Accepts formatted codes ("11.222.333/0001-81", "01001-000", "8471.30.12"): when `value`
      # doesn't fit the element's pattern but does once punctuation is gone (and letters are
      # upcased), the cleaned value is used. Anything else is returned untouched.
      def forgive(value, element)
        type = element.type
        return value unless value.is_a?(String) && type && !type.patterns.empty? && !decimal_type?(type) && code_like?(type)
        return value if regexes(type).any? { |regex| regex.match?(value) }

        cleaned = value.gsub(PUNCTUATION, "")
        [cleaned, cleaned.upcase].find { |candidate| regexes(type).any? { |regex| regex.match?(candidate) } } || value
      end

      # NFC, control characters and line breaks to single spaces, no surrounding spaces:
      # TString forbids leading/trailing spaces and any character below U+0020.
      def sanitize(value)
        text = value.to_s
        text = text.dup.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::BINARY
        text.scrub.unicode_normalize(:nfc).gsub(/[[:cntrl:]]+/, " ").strip
      end

      def decimal_type?(type) = type&.name.to_s.start_with?("TDec")

      def parse_decimal(value)
        raise Invalid, "expected a number, got #{value.inspect}" unless value.strip.match?(/\A[+-]?\d+(\.\d+)?\z/)

        BigDecimal(value.strip)
      end

      # Formats to the smallest number of places the type's patterns accept, at least as many
      # as it requires (money always has two).
      def decimal(value, element)
        type = element.type
        raise Invalid, "must not be negative" if value.negative?

        places = fraction_places(type)
        rounded = value.round(places.max, half: :up)
        return nil if rounded.zero? && type.name.end_with?("Opc") && element.optional?

        (places.min..places.max).each do |scale|
          next unless rounded.round(scale) == rounded

          candidate = plain(rounded, scale)
          return candidate if regexes(type).any? { |regex| regex.match?(candidate) }
        end
        plain(rounded, places.max)
      end

      def plain(number, scale)
        integer, fraction = number.to_s("F").split(".")
        return integer if scale.zero?

        "#{integer}.#{fraction.to_s.ljust(scale, "0")[0, scale]}"
      end

      # min..max decimal places the type's patterns talk about; variable-length types ("v")
      # start at zero.
      def fraction_places(type)
        @places ||= {}
        @places[[type.name, type.patterns]] ||= begin
          counts = type.patterns.flat_map { |pattern| pattern.scan(FRACTION) }
          lows = counts.map { |low, _| low.to_i }
          highs = counts.map { |low, high| (high || low).to_i }
          variable = type.name.match?(/v\z|\d{2}v/)
          ((variable || lows.empty?) ? 0 : lows.min)..(highs.max || 0)
        end
      end

      # Cached by pattern: inline types all carry their base type's name.
      def regexes(type)
        @regexes ||= {}
        @regexes[type.patterns] ||= type.patterns.map { |pattern| Regexp.new("\\A(?:#{pattern})\\z") }
      end

      # Types made of digits and capitals only (CNPJ, CEP, NCM, IE, phone...), as opposed to
      # free text.
      def code_like?(type)
        type.patterns.all? { |pattern| pattern.match?(CODE_PATTERN) }
      end

      def fixed_digits(type)
        return unless type.patterns.size == 1

        type.patterns.first[FIXED_DIGITS, 1]&.to_i
      end

      def format_time(time, type)
        return time.strftime("%Y-%m-%d") if type&.name == "TData"

        time = time.to_time if time.is_a?(DateTime) # keeps the offset; DateTime has no utc_offset

        offset = time.utc_offset
        raise Invalid, "needs a whole-hour UTC offset (got #{time.strftime("%:z")})" unless (offset % 3600).zero?

        time.strftime("%Y-%m-%dT%H:%M:%S%:z")
      end
    end
  end
end
