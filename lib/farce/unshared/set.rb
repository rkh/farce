# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe set for mutable elements used within one Ractor.
    class Set < Farce::Abstract::Set
      include Unshareable

      private def new_map(...) = Farce::Unshared::Map.new(...)
    end
  end
end
