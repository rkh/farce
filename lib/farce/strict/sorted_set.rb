# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable concurrent set maintained in ascending order.
    class SortedSet < Farce::Abstract::SortedSet
      include Shareable::Delegated

      private

      def new_map(entries = nil, compare_keys_by_identity: false, **)
        raise ArgumentError, "sorted sets do not support identity comparison" if compare_keys_by_identity
        Farce::Strict::TreeMap.new(entries)
      end
    end
  end
end
