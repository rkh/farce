# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A scoped value store.
  #
  # @example A per-ractor cache
  #   cache = Farce::Local.new { ActiveSupport::Cache::MemoryStore.new }
  #   cache.value.read('city')               # => nil
  #   cache.value.write('city', "Duckburgh") # => true
  #   cache.value.read('city')               # => "Duckburgh"
  #
  #   Ractor.new(cache) do |cache|
  #     cache.value.read('city') # => nil (each Ractor has its own cache)
  #   end
  #
  # @example Per fiber locale
  #   locale = Farce::Local.new("en-US", scope: :fiber)
  #   locale.value # => "en-US"
  #
  #   Fiber.new do
  #     locale.value = "de-DE"
  #     locale.value # => "de-DE"
  #   end.resume
  #
  #   locale.value # => "en-US"
  #
  # If you want the wrapper to be invisible, use {Farce::LocalRef} instead.
  # Use a block to create independent mutable values for each scope.
  class Local
    include Abstract::Value
    include Shareable

    MANAGER = ModeManager.new
    private_constant :MANAGER

    attr_reader :scope

    # @overload initialize(default = nil, scope: :ractor)
    #   @param default [BasicObject] the default value for the local.
    #   @param scope [Symbol] the scope of the local (e.g., :ractor, :fiber).
    #
    # @overload initialize(scope: :ractor)
    #   @yield
    #     Block will be called the first time when the local's value is read for each scope
    #     (unless it has been explicitly set).
    #   @yieldreturn [BasicObject] the initial value for the scope.
    def initialize(default = nil, scope: :ractor, &)
      raise ArgumentError, "Invalid scope: #{scope}" unless Internal::Storage::SCOPES.include?(scope)
      @scope       = scope
      @initializer = Ractor.shareable_proc(&) if block_given?
      @default     = MANAGER.wrap(default, mode: :copy)
      super()
    end

    # Stores the value returned by the block if the local is not already set for the current scope.
    #
    # @example
    #   local = Farce::Local.new(scope: :ractor)
    #   local.store_if_absent { ObjectSpace::WeakMap.new }
    #
    # @yield
    #   Block that returns the value to store if absent.
    # @yieldreturn [BasicObject] the value to store if absent.
    def store_if_absent(&)
      raise LocalJumpError, "no block given" unless block_given?
      storage.store_if_absent(self, &)
    end

    # @return [BasicObject] the current value of the local for the current scope.
    def value
      storage = self.storage
      return storage.store_if_absent(self, &@initializer) if @initializer
      storage.key?(self) ? storage[self] : MANAGER.unwrap(@default)
    end

    # Sets the current value of the local for the current scope.
    # @param value [BasicObject] the value to set for the current scope.
    def value=(value)
      storage[self] = value
    end

    private def storage = Internal::Storage.scope(@scope)
  end
end
