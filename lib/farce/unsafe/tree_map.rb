# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unsafe
    # @!macro unsafe
    # A {Abstract::TreeMap tree map} that is not thread-safe and cannot be shared between Ractors.
    class TreeMap < Abstract::TreeMap
      include Unshareable

      undef_method :transaction_wrapper

      private

      def new_tree_map(...)   = Internal::UnsafeTreeMap.new(...)
      def new_key_locks       = nil
      def with_key_lock(_key) = yield
    end
  end
end
