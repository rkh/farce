# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # Local variant of {Farce::Publisher}.
    class Publisher < Abstract::Publisher
      include Shareable::Unfreezable

      # The scope with independent contents.
      # @return [Symbol] The configured scope name.
      attr_reader :scope

      # @overload initialize(*subscribers)
      #   (see Farce::Abstract#initialize)
      def initialize(*, scope: :ractor)
        raise ArgumentError, "Invalid scope: #{scope.inspect}" unless Farce::SCOPES.include?(scope)
        @scope = scope
        super(*)
      end

      private

      def map = Internal::Storage.store_if_absent(self, scope:) { Unshared::Map.new }

      def default_mode = :local
    end
  end
end
