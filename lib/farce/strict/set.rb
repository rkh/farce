# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable concurrent set of shareable elements.
    class Set < Farce::Abstract::Set
      include Shareable::Delegated

      private def new_map(...) = Farce::Strict::Map.new(...)
    end
  end
end
