require "did_you_mean"

module DfeRb
  module Nfe
    # Maps the names a developer can use for the children of a schema element (English name,
    # official tag, snake_case tag) to the child. It follows "flatten" links, so the invoice
    # can be filled without spelling out every level (`number` lives in infNFe/ide).
    class NameIndex
      # Levels whose fields are reachable straight from their parent's scope.
      FLATTEN = {"infNFe" => %w[ide], "det" => %w[prod imposto]}.freeze

      # Entries whose English name stands for a path rather than a single child.
      PATHS = {
        "infNFe" => {payment: %w[pag detPag], payments: %w[pag detPag]}
      }.freeze

      @cache = {}

      class << self
        def for(element)
          @cache[element.path] ||= new(element)
        end
      end

      attr_reader :element

      def initialize(element)
        @element = element
        @names = {}
        PATHS.fetch(element.tag, {}).each { |name, tags| register(name.to_s, tags) }
        Names.table_for(element.tag).each do |name, tag|
          path = locate(tag)
          register(name.to_s, path) if path
        end
        element.each_element do |child|
          register(Names.snake(child.tag), [child.tag])
          register(child.tag, [child.tag])
        end
        FLATTEN.fetch(element.tag, []).each do |flat|
          child = element.find(flat) or next
          NameIndex.for(child).names.each { |name, tags| register(name, [flat, *tags]) }
        end
      end

      # Tag chain from this element down to the child called `tag`, through flattened levels.
      def locate(tag)
        return [tag] if element.find(tag)

        FLATTEN.fetch(element.tag, []).each_with_object([]) do |flat, found|
          child = element.find(flat)
          inner = child && NameIndex.for(child).locate(tag)
          found << [flat, *inner] if inner
        end.first
      end

      attr_reader :names

      # The chain of elements to walk (last one is the target) for `name`, or nil.
      def lookup(name)
        tags = @names[name.to_s] or return
        chain = tags.each_with_object([]) do |tag, elements|
          found = (elements.last || element).find(tag)
          break unless found

          elements << found
        end
        chain unless chain.nil? || chain.size < tags.size
      end

      def suggestions(name)
        DidYouMean::SpellChecker.new(dictionary: @names.keys).correct(name.to_s).first(3)
      end

      private

      def register(name, tags)
        @names[name] ||= tags
      end
    end

    # The object handed to builder blocks. Any field of its schema element can be set by
    # calling a method named after it; groups take keyword arguments, a hash or a block.
    #
    #   nfe.series 1
    #   nfe.issuer name: "ACME", address: {street: "Rua A"}
    #   nfe.item { |i| i.description "Widget" }
    #
    # It's a BasicObject so fields named like Kernel methods (format, test, open...) work.
    class Scope < BasicObject
      # Positional shorthands for groups: `payment :money, "10.00"`.
      POSITIONAL = {
        "detPag" => %i[kind amount],
        "NFref" => %i[key],
        "obsCont" => %i[field text]
      }.freeze

      attr_reader :__element, :__data

      def initialize(element, data)
        @__element = element
        @__data = data
      end

      def method_missing(name, *args, **kwargs, &block)
        key = name.to_s.chomp("=")
        handler = Sugar.handler(@__element.tag, key)
        return handler.call(self, @__data, args, kwargs, block) if handler

        __apply(key, args, kwargs, block)
      end

      def respond_to_missing?(name, include_private = false) = !NameIndex.for(@__element).lookup(name.to_s.chomp("=")).nil?

      def respond_to?(name, include_private = false) = respond_to_missing?(name, include_private)

      def inspect = "#<DfeRb::Nfe::Scope #{@__element.path}>"

      def to_s = inspect

      # Sets several fields at once from a Hash (the same names the block methods take).
      def __assign(attributes)
        attributes.each do |name, value|
          next if value.nil?

          key = name.to_s
          handler = Sugar.handler(@__element.tag, key)
          if handler
            handler.call(self, @__data, [value], {}, nil)
          elsif value.is_a?(::Hash)
            __apply(key, [], value, nil)
          else
            __apply(key, [value], {}, nil)
          end
        end
        self
      end

      # Resolves `name` and stores the values (or reads, when called without any).
      def __apply(name, args, kwargs, block)
        attribute = __attribute_name(name)
        return __attribute(attribute, args) if attribute

        index = NameIndex.for(@__element)
        chain = index.lookup(name)
        unless chain
          hint = index.suggestions(name)
          ::Kernel.raise ::NoMethodError,
            "#{@__element.tag} has no field #{name.inspect}#{" (did you mean #{hint.map(&:inspect).join(", ")}?)" unless hint.empty?}"
        end

        data = @__data
        chain[0...-1].each { |element| data = (data[element.tag] ||= {}) }
        target = chain.last
        (target.leaf? && target.type) ? __leaf(data, target, args, kwargs) : __group(data, target, args, kwargs, block)
      end

      # XML attribute (not child) called `name` on this element, e.g. xCampo on obsCont.
      def __attribute_name(name)
        mapped = Names.table_for(@__element.tag)[name.to_sym]
        return mapped.delete_prefix("@") if mapped&.start_with?("@")

        name if @__element.attributes.any? { |attribute| attribute.name == name }
      end

      def __attribute(attribute, args)
        return @__data["@#{attribute}"] if args.empty?

        @__data["@#{attribute}"] = args.first
        nil
      end

      def __leaf(data, target, args, kwargs)
        return data[target.tag] if args.empty? && kwargs.empty?

        value = (args.size > 1) ? args : args.first
        value = value.map { |item| __convert(target, item) } if value.is_a?(::Array)
        value = __convert(target, value) unless value.is_a?(::Array)
        if target.repeatable?
          (data[target.tag] ||= []).concat(::Kernel.Array(value))
        else
          data[target.tag] = value
        end
        nil
      end

      def __group(data, target, args, kwargs, block)
        if args.first.is_a?(::Array) && target.repeatable?
          args.first.each { |item| __group(data, target, [item], {}, nil) }
          return nil
        end

        attributes = __group_attributes(target, args, kwargs)
        child = {}
        if target.repeatable?
          list = (data[target.tag] ||= [])
          list << child
          child["@nItem"] = list.size if target.attributes.any? { |attribute| attribute.name == "nItem" }
        else
          child = (data[target.tag] ||= {})
        end

        scope = Scope.new(target, child)
        scope.__assign(attributes) unless attributes.empty?
        block&.call(scope)
        child
      end

      def __group_attributes(target, args, kwargs)
        first = args.first
        if first.is_a?(::Hash)
          first.merge(kwargs)
        elsif args.empty?
          kwargs
        else
          shorthand = POSITIONAL[target.tag] or ::Kernel.raise ::ArgumentError, "#{target.tag} takes keyword arguments"
          shorthand.zip(args).to_h.compact.merge(kwargs)
        end
      end

      # Friendly symbols (:normal, :money...) become the coded value; true/false become 1/0.
      def __convert(target, value)
        case value
        when ::Symbol then Names.enum_value(target.tag, value)
        when true then 1
        when false then 0
        else value
        end
      end
    end
  end
end
