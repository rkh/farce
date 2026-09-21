# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable atomic reference that strongly retains shareable values directly.
    # Values are stored without envelope wrapping or transfer modes.
    #
    # @example Updating a counter atomically
    #   counter = Farce::Strict::Atom.new(0)
    #   counter.update { |count| count + 1 } # => 1
    #   counter.compare_and_set(1, 2)       # => true
    #   counter.value                      # => 2
    #
    # @example Keeping an immutable snapshot
    #   snapshot = [1, 2, 3].freeze
    #   atom = Farce::Strict::Atom.new(snapshot)
    #   atom.value.equal?(snapshot) # => true
    #   atom.update { |items| (items + [4]).freeze } # => [1, 2, 3, 4]
    class Atom < Abstract::Atom
      include Shareable::Delegated

      # @param value [BasicObject, nil] the initial shareable value
      # @param compare_by_identity [Boolean] whether comparisons use object identity instead of equality
      def initialize(value = nil, compare_by_identity: false)
        @atom = Internal::StrictAtom.new(value, compare_by_identity:)
        super()
      end

      private def freeze_backend = @atom
    end
  end
end
