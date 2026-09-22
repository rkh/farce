# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # Preserve the publication guarantees of public shareable wrappers.
    module Copyable
      private

      def initialize_dup(other)
        super
        publish_copy(other, operation: :dup) if is_a?(Shareable)
      end

      def initialize_clone(other, freeze: nil)
        super
        publish_copy(other, operation: :clone, freeze:) if is_a?(Shareable)
      end

      def publish_copy(other, operation:, freeze: nil)
        if respond_to?(:publish_shareable_copy, true)
          publish_shareable_copy(other, operation:, freeze:)
        elsif operation == :dup || freeze != false
          Ractor.make_shareable(self) if Internal.native_ractors?
          self.freeze
        end
      end
    end
  end
end
