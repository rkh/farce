# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable bounded map that evicts the least frequently used entry.
  # Equal-frequency victims are selected by recency. Transfer modes apply to values.
  # Individual reads and writes increment frequency. Observation does not.
  class LFUMap < Farce::Abstract::LFUMap
    include Shareable::Delegated

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

    protected

    def unwrap_value(value) = @manager.unwrap(value)

    def wrap_value(value)
      check_frozen!
      @manager.wrap(value)
    end

    private

    def each_for_inspect(&)             = internal_map.each(&)
    def inspect_value(inspector, value) = super(inspector, value, @manager)
    def new_bounded_map(...)            = Internal::StrictLFUMap.new(...)
    def freeze_backend                  = internal_map

    def new_key_locks(compare_keys_by_identity:)
      Internal::KeyLockMap.new(registry_class: Farce::Strict::Map, compare_keys_by_identity:)
    end
  end
end
