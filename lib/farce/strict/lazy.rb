# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A shareable lazy value that retains its shareable result directly.
    # The factory runs once, even when threads or Ractors access it concurrently.
    # A failed factory or an unshareable result can be retried on the next access.
    #
    # @example Compute one shared snapshot
    #   lazy = Farce::Strict::Lazy.new { [:ready].freeze }
    #   lazy.value # => [:ready]
    class Lazy < Abstract::Lazy
      include Shareable::Tracked

      # Resolve and freeze the slot without freezing the result.
      # @return [self]
      def freeze
        value
        internal_atom.freeze
        super
      end
    end
  end
end
