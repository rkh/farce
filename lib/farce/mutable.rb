# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A wrapper making generic Ruby objects shareable while preserving mutability.
  #
  # It achieves this by keeping an immutable copy of the object,
  # and performing an atomic update of this reference for mutating method calls.
  #
  # This means the entire object is copied whenever it is being mutated.
  #
  # You should therefore favor dedicated data structures whenever possible,
  # like using a {Map} instead of wrapping a Hash in a {Mutable}, or a {Vector}
  # instead of doing the same with an Array.
  #
  # Non-mutating calls do not incur this cost.
  #
  # @example
  #   shareable_string = Farce::Mutable.new("foo")
  #   Ractor.new(shareable_string) { it << "bar" }.join
  #   shareable_string.to_s # => "foobar"
  class Mutable < BasicObject
    module Inherited
      include ::Farce.const_get(:Internal)::Delegation
      include ::Farce.const_get(:Internal)::Inspect

      define_method(:dup,              ::Kernel.instance_method(:dup))
      define_method(:clone,            ::Kernel.instance_method(:clone))
      define_method(:is_a?,            ::Kernel.instance_method(:is_a?))
      define_method(:initialize_copy,  ::Kernel.instance_method(:initialize_copy))
      define_method(:initialize_dup,   ::Kernel.instance_method(:initialize_dup))
      define_method(:initialize_clone, ::Kernel.instance_method(:initialize_clone))

      private :initialize_copy, :initialize_dup, :initialize_clone
    end

    module Mutator
      extend self

      def prepare(value, in_place: false)
        return -value if value.is_a? String
        return value if value.frozen? || (Internal.native_ractors? && Ractor.shareable?(value))
        in_place ? value.freeze : value.dup.freeze
      end

      def deref(mutable) = ::Kernel.instance_method(:instance_variable_get).bind_call(mutable, :@atom).value
    end

    private_constant :Mutator, :Inherited
    include ::Farce::Shareable::Delegated
    include Inherited

    # Turns the given {Mutable} into a frozen copy of the underlying object.
    # @param mutable [Mutable] the mutable
    # @return [BasicObject] current snapshot of the object it is wrapping
    def self.deref(mutable) = Mutable === mutable ? Mutator.deref(mutable) : mutable

    # Creates a subclass of {Mutable} that automatically generates values based on the given factory (usually a class),
    # by invoking `new` on it with any arguments being passed on.
    #
    # @example
    #   # You should probably use Farce::Vector instead.
    #   MutableArray = Farce::Mutable[Array]
    #   MutableArray.new(2) # => #<MutableArray [nil, nil]>
    #
    # @param factory [#new] The factory to create a subclass for. Typically a class. Must be shareable.
    # @return [Class] The subclass of {Mutable}.
    def self.[](factory)
      raise ::Farce::Ractor::IsolationError, "factory is not shareable" unless ::Farce::Ractor.shareable?(factory)

      klass = ::Class.new(self)
      klass.set_temporary_name("#{name}[#{factory.name}]")
      klass.instance_variable_set(:@value_factory, factory)

      klass.class_eval <<~RUBY, __FILE__, __LINE__ + 1
        def self.new(...) = super(value_factory.new(...))
        def self.value_factory
          return @value_factory if defined?(@value_factory) && @value_factory
          superclass.value_factory
        end
      RUBY

      klass.singleton_class.class_eval "undef []", __FILE__, __LINE__
      klass
    end

    # Creates a new mutable version of the given object.
    # The object will be copied on initialization if it isn't frozen.
    # A frozen version of the object must be Ractor-shareable.
    # @param object [BasicObject] The object to wrap. Must implement `dup`, `freeze`, and `frozen?`.
    def initialize(object)
      @atom = Internal::Atom.new Mutator.prepare(object)
      super()
    end

    # @api private
    def marshal_dump = ::Kernel.raise(::TypeError, "Farce::Mutable cannot be marshaled")

    # Marshal hook discovery must inspect the wrapper without delegating to its snapshot.
    def respond_to?(name, include_private = false) # rubocop:disable Style/OptionalBooleanParameter
      return true if name == :marshal_dump
      return false if Internal.marshal_protocol_method?(name)
      method_missing(:respond_to?, name, include_private)
    end

    # @api private
    def is_a?(...) = super || @atom.value.is_a?(...)

    # @api private
    def inspect_with(inspector)
      value = @atom.value
      klass = ::Kernel.instance_method(:class).bind_call(self)
      name  = klass.name
      name += "[#{value.class.name}]" if klass == ::Farce::Mutable
      inspector.group("#<#{name}", ">") do
        inspector.breakable
        inspector.object(value)
      end
    end

    private

    # Delegates all methods to the frozen copy of the current value.
    # If it throws a `FrozenError` it reruns the method against an unfrozen duplicate of the value,
    # freezes it, and uses that as internal value.
    def method_missing(...) # rubocop:disable Style/MissingRespondToMissing
      @atom.value.__send__(...)
    rescue ::FrozenError
      result = nil
      @atom.update do |current|
        copy   = current.dup
        result = copy.__send__(...)
        result = self if result.equal?(copy)
        Mutator.prepare(copy, in_place: true)
      end
      result
    end

    def freeze_backend = @atom

    def initialize_copy(other)
      super
      @atom = Internal::Atom.new(Mutator.deref(other))
    end

    def initialize_dup(other)
      super
      publish_shareable_copy(other, operation: :dup)
    end

    def initialize_clone(other, freeze: nil)
      super
      publish_shareable_copy(other, operation: :clone, freeze:)
    end
  end
end
