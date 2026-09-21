# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe set that retains mutable elements weakly within one Ractor.
    class WeakSet < Farce::Abstract::WeakSet
      include Unshareable

      private def new_map(...) = Farce::Unshared::WeakMap.new(...)
    end
  end
end
