# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable bounded map that evicts the least recently used entry.
  # Transfer modes apply to values. Equality-mode mutable string keys become immutable.
  # Individual reads and writes update recency. Iteration and key observation do not.
  #
  # @example Keeping copied values in a small cache
  #   cache = Farce::LRUMap.new(max_size: 2, mode: :copy)
  #   cache[:first] = [1]
  #   cache[:second] = [2]
  #   cache[:first]
  #   cache[:third] = [3]
  #
  #   cache.key?(:second) # => false
  class LRUMap < Farce::Abstract::LRUMap
    include Shareable

    # @!macro modes
    # @param entries [Hash, Array<Array(BasicObject, BasicObject)>, Abstract::Map, #each, nil]
    #   Optional initial entries. Entries are stored sequentially and may be evicted.
    # @param mode [Symbol] The default value transfer mode.
    def initialize(entries = nil, mode: :copy, **)
      @manager = ModeManager.new(mode:)
      super(entries, **)
    end

    # The default transfer mode for values.
    # @return [Symbol]
    def mode = @manager.mode

    # Keys must be shareable, except equality-mode strings that can be snapshotted.
    # @return [true]
    def shareable_keys? = true

    # Values are stored in Ractor-shareable representations.
    # @return [true]
    def shareable_values? = true

    private

    def new_bounded_map(...) = Internal::StrictLRUMap.new(...)

    def new_key_locks(compare_keys_by_identity:)
      Internal::KeyLockMap.new(registry_class: Farce::Strict::Map, compare_keys_by_identity:)
    end

    def unwrap_value(value) = @manager.unwrap(value)
    def wrap_value(value)   = @manager.wrap(value)
  end
end
