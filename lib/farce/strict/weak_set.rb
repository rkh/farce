# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable concurrent set that retains shareable elements weakly.
    class WeakSet < Farce::Abstract::WeakSet
      include Shareable::Delegated

      private def new_map(...) = Farce::Strict::WeakMap.new(...)
    end
  end
end
