# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    module Inspect
      module Mixin
        def inspect
          inspector = StringInspector.create
          inspector.inspect(self)
        end

        def pretty_print(pp)
          inspector = PrettyPrinter.create(pp)
          inspector.object(self)
        end

        def pretty_print_cycle(pp)
          inspector = PrettyPrinter.create(pp)
          inspector.object_with_address(self)
        end

        def inspect_with(inspector, &)
          return inspector.object_group(self, &) if block_given?
          inspector.object_with_address(self)
        end
      end

      class Inspector
        def self.current                = Storage.fiber[-name]
        def self.create                 = current || new
        def initialize                  = @seen = ::Set.new.compare_by_identity
        def attributes(attributes, ...) = attributes.each { attribute(_1, _2, ...) }
        def object_group(object, &)     = group("#<#{object.class.name}", ">", &)
        def object_with_address(object) = text(Kernel.instance_method(:to_s).bind_call(object))

        def activate
          name = -self.class.name
          old  = Storage.fiber[name]

          begin
            Storage.fiber[name] = self
            yield
          ensure
            Storage.fiber[name] = old
          end
        end

        def attribute(key, value, mode_manager = nil)
          breakable
          text "#{key}="
          object(value, mode_manager)
        end

        def from_envelope(envelope, prefix = nil)
          if envelope.owned?
            text(prefix) if prefix
            object(envelope.value)
          else
            text(envelope.claimed? ? "claimed" : "unclaimed")
          end
          self
        end

        def object(object, mode_manager = nil)
          return object_with_address(object) if @seen.include?(object)
          return from_envelope(object) if mode_manager&.managed_envelope?(object)
          return foreign_inspect(object) unless object.is_a?(Mixin)

          activate do
            @seen << object
            object.inspect_with(self)
          end

          self
        end

        def hash_pair(key, ...)
          if Symbol === key
            key = key.to_s.inspect if key.inspect.match?(%r{\A:["$@!]|[%&*+\-/<=>@\]^`|~]\z})
            text("#{key}: ")
          else
            text("#{key.inspect} => ")
          end
          block_given? ? yield : object(...)
        end
      end

      class StringInspector < Inspector
        def initialize
          @output = +""
          super
        end

        def breakable(str = " ") = text(str)
        def text(str)            = @output << str
        def to_s                 = -@output

        def inspect(object)
          previous_output = @output
          @output = +""
          object(object)
          to_s
        ensure
          @output = previous_output
        end

        def foreign_inspect(object)
          text(object.inspect)
        rescue StandardError
          object_with_address(object)
        end

        def group(before = nil, after = nil)
          text(before) if before
          yield
          text(after) if after
        end

        def seplist(list, sep = nil, iter_method = :each)
          sep ||= -> { text(", ") }
          first = true
          list.__send__(iter_method) do |*args|
            sep.call unless first
            first = false
            yield(*args)
          end
        end
      end

      class PrettyPrinter < Inspector
        def self.create(pp) = current&.pp == pp ? current : new(pp)

        attr_reader :pp

        Internal.delegate(self, :@pp, :text, :object_group, :breakable, :seplist)

        def initialize(pp)
          @pp = pp
          super()
        end

        def foreign_inspect(object)
          pp.pp(object)
        rescue StandardError
          object_with_address(object)
        end

        def group(...) = @pp.group(1, ...)
      end

      def self.append_features(base) = base.include(Mixin)
      private_constant :Mixin, :Inspector, :PrettyPrinter
    end
  end
end
