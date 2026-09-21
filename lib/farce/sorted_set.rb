# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable concurrent set maintained in ascending order.
  # Membership uses `<=>`. Comparator-equivalent elements occupy one slot.
  # Transfer modes have the same behavior and restrictions as Farce::Set.
  #
  # @example Traverse priorities in order
  #   priorities = Farce::SortedSet[30, 10, 20]
  #   priorities.to_a # => [10, 20, 30]
  class SortedSet < Farce::Abstract::SortedSet
    include Shareable::Delegated

    # The default transfer mode for elements.
    # @return [Symbol] The configured transfer mode.
    def mode = @manager.mode

    protected

    def value_modes? = true

    private

    def initialize_value_mode(mode)
      mode = :copy if UNDEFINED.equal?(mode)
      @manager = ModeManager.new(mode:)
    end

    def new_map(entries = nil, compare_keys_by_identity: false, **)
      raise ArgumentError, "sorted sets do not support identity comparison" if compare_keys_by_identity
      Farce::Strict::TreeMap.new(entries)
    end
  end
end
