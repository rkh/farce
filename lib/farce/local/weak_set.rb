# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable weak set with independent mutable contents in each scope.
    class WeakSet < Farce::Abstract::WeakSet
      include Shareable::Delegated

      # The scope with independent contents.
      # @return [Symbol] The configured scope name.
      def scope = map_backend.scope

      private def new_map(...) = Farce::Local::WeakMap.new(...)
    end
  end
end
