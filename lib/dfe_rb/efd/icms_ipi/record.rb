module DfeRb
  module Efd
    module IcmsIpi
      # A line of the file: a register with its values, by the lowercase names of its
      # fields (cod_sit:, vl_doc:), and the registers below it, which follow it in the file.
      # REG is the register's own code and is never given.
      class Record
        attr_reader :code, :values, :children

        def initialize(code, values = {})
          @code = code
          @register = Layout.fetch(code)
          unknown = values.keys.map(&:to_sym) - @register.fields.map(&:key)
          raise ArgumentError, "#{code} has no field #{unknown.map(&:upcase).join(", ")}" if unknown.any?

          @values = values.transform_keys(&:to_sym)
          @children = []
        end

        # Adds a register below this one (a C170 under its C100) and returns it.
        def add(code, values = {})
          child = Record.new(code, values)
          unless Layout.fetch(code).parent == self.code
            raise ArgumentError, "#{code} doesn't go under #{self.code}"
          end

          @children << child
          child
        end

        def [](name) = @values[name.to_sym]

        def []=(name, value)
          raise ArgumentError, "#{code} has no field #{name.upcase}" unless @register.fields.any? { |f| f.key == name.to_sym }

          @values[name.to_sym] = value
        end

        # This record and every one below it, in the order of the file: the children by
        # register code, those of one code in the order they were added.
        def each_line(&block)
          return enum_for(:each_line) unless block

          yield self
          @children.each_with_index.sort_by { |child, index| [child.code, index] }.each { |child, _| child.each_line(&block) }
        end

        # The line, raising ValidationError with every field that can't be written.
        def to_line
          issues = []
          texts = @register.fields.map do |field|
            next code if field.key == :reg

            value = @values[field.key]
            issues << "#{code} #{field.name} is required" if field.required? && blank?(value)
            begin
              field.format(value)
            rescue Formatter::Invalid => e
              issues << "#{code} #{field.name} #{e.message}"
              ""
            end
          end
          raise ValidationError, issues if issues.any?

          "|#{texts.join("|")}|"
        end

        private

        def blank?(value) = value.nil? || (value.is_a?(String) && value.strip.empty?)
      end
    end
  end
end
