# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "delegate"

module Farce
  # A delegate object for a scoped local reference.
  #
  # @example A per-ractor cache
  #   cache = Farce::LocalRef.new { ActiveSupport::Cache::MemoryStore.new }
  #   cache.read('city')               # => nil
  #   cache.write('city', "Duckburgh") # => true
  #   cache.read('city')               # => "Duckburgh"
  #
  #   Ractor.new(cache) do |cache|
  #     cache.read('city') # => nil (each Ractor has its own cache)
  #   end
  #
  # If you want a value object rather than a delegate, use {Farce::Local} instead.
  # Use a block to create independent mutable values for each scope.
  class LocalRef < Delegator
    # @overload initialize(default = nil, scope: :ractor)
    #   @param default [BasicObject] the default value for the local.
    #   @param scope [Symbol] the scope of the local (e.g., :ractor, :fiber).
    #
    # @overload initialize(scope: :ractor)
    #   @yield
    #     Block will be called the first time when the local's value is read for each scope
    #     (unless it has been explicitly set).
    #   @yieldreturn [BasicObject] the initial value for the scope.
    def initialize(...) # rubocop:disable Lint/MissingSuper
      # Delegator#initialize would call __setobj__ and overwrite the lazy local.
      @value = Local.new(...)
    end

    # @api private
    def __getobj__ = @value.value # :nodoc:

    # @api private
    def __setobj__(value) = @value.value = value # :nodoc:
  end
end
