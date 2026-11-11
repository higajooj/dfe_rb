require "bigdecimal"
require "date"

module DfeRb
  module Efd
    # A field of a register as the Guia Prático of its file lists it: its name, its type (C text,
    # N number, D a date written ddmmaaaa), its size (nil for none), its decimal places
    # (nil for a code or a whole number) and whether it is always required (O). A size
    # marked exact (CNPJ, CHV_NFE, COD_MUN...) takes that many characters, no fewer.
    #
    # Written in the layout as "NAME:spec", spec being the type, then the size, then
    # "=" when exact, ".n" for n decimal places and "!" when required:
    # "CNPJ:N14=", "VL_DOC:N.2!", "NOME:C100!", "DT_INI:D!".
    class Field
      SPEC = /\A(?<type>[CND])(?<size>\d+)?(?<exact>=)?(?:\.(?<decimals>\d))?(?<required>!)?\z/

      attr_reader :name, :type, :size, :decimals

      def self.parse(text)
        name, spec = text.split(":", 2)
        match = SPEC.match(spec.to_s) or raise ArgumentError, "bad field spec #{text.inspect}"
        new(name, match[:type].downcase.to_sym, size: match[:size]&.to_i, decimals: match[:decimals]&.to_i,
          exact: !match[:exact].nil?, required: !match[:required].nil?)
      end

      def initialize(name, type, size: nil, decimals: nil, exact: false, required: false)
        @name = name
        @type = type
        @size = size
        @decimals = decimals
        @exact = exact
        @required = required
      end

      def key = @key ||= name.downcase.to_sym

      def exact? = @exact

      def required? = @required

      def decimal? = !decimals.nil?

      # The text of the value in the file, raising Formatter::Invalid with why it can't
      # be written. Nil and blank text are an empty field.
      def format(value)
        return "" if value.nil? || (value.is_a?(String) && value.strip.empty?)

        case type
        when :d then date(value)
        when :n then decimal? ? decimal(value) : digits(value)
        else text(value)
        end
      end

      private

      def date(value)
        raise Formatter::Invalid, "is not a date (#{value.inspect})" unless value.respond_to?(:strftime)

        value.strftime("%d%m%Y")
      end

      def decimal(value)
        number = BigDecimal(value.to_s)
        rounded = number.round(decimals, BigDecimal::ROUND_HALF_UP)
        whole, fraction = rounded.abs.to_s("F").split(".")
        fraction = (fraction || "").ljust(decimals, "0")[0, decimals]
        sign = rounded.negative? ? "-" : ""
        text = decimals.zero? ? "#{sign}#{whole}" : "#{sign}#{whole},#{fraction}"
        raise Formatter::Invalid, "is too long (#{text})" if size && text.delete("-,").length > size

        text
      rescue ArgumentError, TypeError
        raise Formatter::Invalid, "is not a number (#{value.inspect})"
      end

      def digits(value)
        text = value.is_a?(Integer) ? value.to_s : value.to_s.strip
        raise Formatter::Invalid, "must have digits only (#{value.inspect})" unless text.match?(/\A\d+\z/)

        text = text.rjust(size, "0") if exact? && value.is_a?(Integer)
        check_size(text)
      end

      def text(value)
        clean = value.to_s.gsub(/[|\r\n\t]/, " ").gsub(/[[:cntrl:]]/, "").squeeze(" ").strip
        clean = Latin1.text(clean)
        return check_size(clean) if exact?

        size ? clean[0, size].rstrip : clean
      end

      def check_size(text)
        if exact? && text.length != size
          raise Formatter::Invalid, "must have #{size} characters (#{text})"
        elsif size && text.length > size
          raise Formatter::Invalid, "is too long (#{text.length} characters, maximum #{size})"
        end

        text
      end
    end
  end
end
