module DfeRb
  module Nfe
    module Distribution
      # Current generic events carry alphanumeric CNPJ/key/Id and 4-digit status codes.
      # The manifestation detail schemas are unchanged; NT 2020.001 supplies sequence rules.
      module Schemas
        DIRECTORY = File.expand_path("../../xml/schemas", __dir__)
        @compiled = {}
        @lock = Mutex.new

        module_function

        def issues(xml, package:, file:)
          schema = @lock.synchronize do
            @compiled[[package, file]] ||= begin
              path = File.join(DIRECTORY, package, file)
              Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(path), path) { |config| config.strict.nonet })
            end
          end
          schema.validate(Xml.parse(xml)).map { |error| error.message.strip }
        end

        def validate!(xml, package:, file:)
          problems = issues(xml, package: package, file: file)
          raise ValidationError, problems unless problems.empty?
        end
      end
    end
  end
end
