# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Defines a reusable extension for adding methods to target classes.
  # These methods can either be activated as refinements, or installed globally to extend the target classes.
  #
  # ```ruby
  # DoubleSize = Farce::Extension.define(String) do
  #   def double_size = size * 2
  # end
  #
  # module Namespace
  #   using DoubleSize
  #   "hello".double_size # => 10
  # end
  #
  # "hello".respond_to?(:double_size) # => false
  #
  # DoubleSize.install
  # "hello".respond_to?(:double_size) # => true
  # ```
  #
  # ## Extending multiple classes
  #
  # An extension can also modify multiple target classes simultaneously:
  #
  # ```ruby
  # DoubleSize = Farce::Extension.new do
  #   define(String) { def double_size = size * 2 }
  #   define(Array) { def double_size = sum(&:double_size) }
  # end
  #
  # using DoubleSize
  # ["hello", "foo"].double_size # => 16
  # ```
  class Extension < Module
    # @api private
    class Mixin < Module # :nodoc:
      attr_reader :extension, :target

      def initialize(extension, target, &)
        @extension = extension
        @target    = target
        super(&)
      end

      def name = -"#{@extension.name}[#{@target.inspect}]"

      def install
        return if @target.ancestors.include?(self)
        @target.prepend(self)
      end
    end
    private_constant :Mixin

    # @overload define(*targets)
    #   Defines an extension for the given target classes.
    #   @param targets [Array<Class>] the target classes to define methods for
    #   @yield the block containing method definitions
    #   @yieldreceiver [Module, Refinement] the module/refinement used for extending the target class.
    #   @return [Extension] the newly created extension instance
    #   @see Extension#define
    def self.define(...) = new { define(...) }

    # Creates a new extension.
    # @yield Optional block for `define` calls or adding methods to the extension itself.
    # @yieldreceiver [Extension] the extension instance itself.
    def initialize
      check_state!
      @definitions = Internal::StrictMap.new
      @lock        = Lock.new
      @installed   = Flag.new
      super
    end

    # @api private
    def [](target) = @definitions[target]

    # Defines additional methods for a given target class.
    #
    # The given block will be invoked at least twice. Once in the context of a refinement for the target class,
    # and once in the context of the mixin module that will be prepended to the target class.
    #
    # @example
    #   extension = Farce::Extension.new
    #   extension.define(String) { def double_size = size * 2 }
    #
    #   module Namespace
    #     using extension
    #     String.method_defined?(:double_size) # => true
    #   end
    #
    #   String.method_defined?(:double_size) # => false
    #   extension.install
    #   String.method_defined?(:double_size) # => true
    #
    # @param targets [Array<Class>] the target classes to define methods for
    # @yield the block containing method definitions
    # @yieldreceiver [Module, Refinement] the module/refinement used for extending the target class.
    # @return [self] the extension instance
    def define(*targets, &)
      @lock.synchronize do
        check_state!
        targets.each do |target|
          refine(target, &)
          mixin = @definitions.store_if_absent(target) { Mixin.new(self, target) }
          mixin.module_eval(&)
          mixin.install if installed?
        end
      end
      self
    end

    # Installs the extension globally.
    # @return [void]
    def install
      @lock.synchronize do
        return false if installed?
        check_state!(allow_frozen: true)
        @definitions.each_value(&:install)
        yield if block_given?
        @installed.set
      end
    end

    # @return [Boolean] whether the extension has been installed
    def installed? = @installed.set?

    # Freezes the extension.
    #
    # No {#define definitions} can be added after freezing the extension.
    # @return [self] the frozen extension
    def freeze
      return self if frozen?
      @lock.synchronize do
        @definitions.freeze
        super
      end
    end

    private

    def check_state!(allow_frozen: false)
      raise Ractor::IsolationError, "must be called from main Ractor" if Internal.native_ractors? && !Ractor.main?
      Internal::Freeze.check(self) unless allow_frozen
    end
  end
end
