# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable set with independent mutable contents in each scope.
    class Set < Farce::Abstract::Set
      include Shareable::Delegated

      # The scope with independent contents.
      # @return [Symbol] The configured scope name.
      def scope = map_backend.scope

      private def new_map(...) = Farce::Local::Map.new(...)
    end
  end
end
