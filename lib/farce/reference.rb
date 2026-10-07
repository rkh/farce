# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A delegating reference to a Farce::Abstract::Value object.
  # Marshal preserves the holder and wrapper without resolving the referenced value.
  #
  # @example
  #   atom = Farce::Atom.new(:example)
  #   ref  = Farce::Reference.new(atom)
  #   ref == :example # => true
  #
  #   atom.value = 42
  #
  #   ref == :example # => false
  #   ref == 42       # => true
  class Reference < BasicObject
    class Deep < Reference
      protected def method_missing(...) = @value.unwrap.__send__(...) # rubocop:disable Style/MissingRespondToMissing
    end

    module Inherited
      define_method(:dup,              ::Kernel.instance_method(:dup))
      define_method(:clone,            ::Kernel.instance_method(:clone))
      define_method(:freeze,           ::Kernel.instance_method(:freeze))
      define_method(:frozen?,          ::Kernel.instance_method(:frozen?))
      define_method(:initialize_copy,  ::Kernel.instance_method(:initialize_copy))
      define_method(:initialize_dup,   ::Kernel.instance_method(:initialize_dup))
      define_method(:initialize_clone, ::Kernel.instance_method(:initialize_clone))

      private :initialize_copy, :initialize_dup, :initialize_clone
    end

    private_constant :Deep, :Inherited
    include Inherited
    include Internal::Delegation

    # Creates a subclass of {Farce::Reference} that uses the given factory to create new values to reference
    # automatically.
    #
    # @example Creating a class for a specific value type
    #   # Example class that turns its value into an uppercase string
    #   class UpcaseValue
    #     include Farce::Abstract::Value
    #     attr_reader :value
    #     def initialize(value) = @value = -(value.to_s.upcase)
    #   end
    #
    #   # Create a reference class for UpcaseValue
    #   UpcaseRef = Farce::Reference[UpcaseValue]
    #
    #   UpcaseRef.new("hello") == "HELLO" # => true
    #
    # @example Subclassing a generated reference class
    #   # This is useful if you want to add custom methods
    #   class UpcaseRef < Farce::Reference[UpcaseValue]
    #     def wordle_compatible? = size == 5
    #   end
    def self.[](factory, deep: false)
      raise ::ArgumentError, "factory must be a class" unless factory.is_a?(::Class)
      raise ::ArgumentError, "factory must include Farce::Abstract::Value" unless factory < ::Farce::Abstract::Value

      klass = ::Class.new(deep ? Deep : Reference)
      klass.set_temporary_name("#{superclass.name}[#{factory.name}, deep: #{deep.inspect}]")
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

    # Creates a new reference to the given value.
    # @param value [Farce::Abstract::Value] the value to be referenced
    # @param deep [Boolean] whether to resolve nested values (like an {Envelope} inside of an {Atom})
    # @return [Farce::Reference] a new reference to the given value
    # @see #initialize
    def self.new(value, deep: false)
      value = deref(value)
      raise ::ArgumentError, "value must be a Farce::Abstract::Value" unless ::Farce::Abstract::Value === value
      return super(value) unless self == Reference && deep
      Deep.new(value)
    end

    # If reference is a {Farce::Reference}, dereference it to get the underlying {Farce::Abstract::Value value object}.
    #
    # @example
    #   ref = Farce::Reference.new(Farce::Atom.new(:example))
    #   ref == :example # => true
    #
    #   atom = Farce::Reference.deref(ref)
    #   atom.value = 42
    #
    #   ref == :example # => false
    #   ref == 42       # => true
    #
    # @return [Farce::Abstract::Value, BasicObject]
    #   the underlying value object, or the given reference if the argument is not a {Farce::Reference}
    def self.deref(reference)
      return reference unless Reference === reference
      ::Kernel.instance_method(:instance_variable_get).bind_call(reference, :@value)
    end

    # @overload initialize(value, deep: false)
    #   @param value [Farce::Abstract::Value] the value to be referenced
    #   @param deep [Boolean] whether to resolve nested values (like an {Envelope} inside of an {Atom})
    def initialize(value) = @value = value

    # @api private
    def marshal_dump = [1, @value, ::Kernel.instance_method(:frozen?).bind_call(self)]

    # @api private
    def marshal_load(data)
      @value, frozen = Internal::MarshalSupport.payload(data, 2)
      ::Kernel.instance_method(:freeze).bind_call(self) if frozen
    end

    # Marshal hook discovery must inspect this wrapper without resolving its target.
    def respond_to?(name, include_private = false) # rubocop:disable Style/OptionalBooleanParameter
      return true if name == :marshal_dump || name == :marshal_load
      return false if Internal.marshal_protocol_method?(name)
      method_missing(:respond_to?, name, include_private)
    end

    # Replacing the holder's value can make this false again.
    # @return [Boolean] whether this proxy and its current target are frozen
    def frozen? = super && method_missing(:frozen?)

    # Freeze the current target, then this proxy. The value holder may remain mutable.
    # @return [self] this object
    def freeze
      method_missing(:freeze)
      super
    end

    private

    def initialize_dup(other)
      super
      @value = Reference.deref(other).dup
    end

    def initialize_clone(other, freeze: nil)
      super
      @value = Reference.deref(other).clone
    end

    # Delegates all methods to the referenced value
    def method_missing(...) = @value.value.__send__(...) # rubocop:disable Style/MissingRespondToMissing
  end
end
