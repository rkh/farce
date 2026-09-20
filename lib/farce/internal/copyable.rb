# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # Preserve the publication guarantees of public shareable wrappers.
    module Copyable
      def duplicable? = true

      private

      def initialize_dup(other)
        super
        publish_copy if is_a?(Shareable)
      end

      def initialize_clone(other, freeze: nil)
        super
        publish_copy if is_a?(Shareable) && freeze != false
      end

      def publish_copy
        Ractor.make_shareable(self) if Internal.native_ractors?
        freeze
      end
    end
  end
end
