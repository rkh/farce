# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # Unshared variant of {Farce::Publisher}.
    class Publisher < Abstract::Publisher
      include Unshareable

      # @overload initialize(*subscribers)
      #   (see Farce::Abstract#initialize)
      def initialize(...)
        @map = Unshared::Map.new
        super
      end

      private

      attr_reader :map

      def default_mode = :local
    end
  end
end
