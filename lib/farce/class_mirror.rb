# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Map Ruby classes to a parallel inheritance hierarchy.
  # Undefined classes use the nearest defined ancestor's mirror.
  # An optional block turns each lookup into a cached value for that source class.
  #
  # @example Specialize behavior with ordinary method inheritance
  #   mirror = Farce::ClassMirror.new
  #   mirror.define(Object) { def label = "object" }
  #   mirror.define(Array) { def label = "array of #{super}" }
  #   mirror[Array].new.label # => "array of object"
  class ClassMirror
    include Farce::Shareable::Tracked

    # @param base_class [Class] the mirror for BasicObject
    # @yieldparam mirror [Class] the nearest defined mirror class
    # @yieldparam klass [Class] the class passed to {#[]}
    # @yieldreturn [Object] a Ractor-shareable value to cache for klass
    # @note The block must be convertible to a shareable proc.
    def initialize(base_class = Class.new, &)
      raise TypeError, "Class expected, got #{base_class.class}" unless base_class.is_a?(Class)
      @mapping  = Strict::Map.new({ BasicObject => base_class })
      @cache    = Strict::WeakKeyMap.new
      @callback = block_given? ? Ractor.shareable_proc(&) : nil
      super()
    end

    # Look up a mirror or the cached result of the constructor block.
    # @param klass [Class] the source class
    # @return [Object] the mirror class or the block result
    # @raise [TypeError] if klass is not a Class
    def [](klass)
      raise TypeError, "Class expected, got #{klass.class}" unless klass.is_a?(Class)
      @cache.store_if_absent(klass) do
        result = lookup(klass)
        @callback ? @callback.call(result, klass) : result
      end
    end

    # Define or extend a mirror class from the main Ractor.
    # Missing ancestors are defined automatically. The block defines methods
    # in an included module, so `super` can call earlier definitions.
    # Existing lookup results are invalidated after each definition.
    # @param klass [Class] the source class
    # @yield evaluated as a module body
    # @return [Class] the mirror class
    # @raise [Ractor::IsolationError] outside the main Ractor
    # @raise [TypeError] if klass is not a Class
    def define(klass, &)
      check_frozen!
      raise Ractor::IsolationError, "must be called from main Ractor" unless Ractor.main?
      raise TypeError, "Class expected, got #{klass.class}" unless klass.is_a?(Class)
      mixin  = Module.new(&) if block_given?
      mirror = @mapping.store_if_absent(klass) { Class.new(define(klass.superclass)) }
      mirror.include(mixin) if mixin
      @cache.clear
      mirror
    end

    private

    def lookup(klass)
      raise TypeError, "Class expected, got #{klass.class}" unless klass.is_a?(Class)
      @mapping.fetch(klass) { lookup(klass.superclass) }
    end
  end
end
