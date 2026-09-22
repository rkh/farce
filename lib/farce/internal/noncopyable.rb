# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # Coordination objects own live state that cannot be duplicated.
    module Noncopyable
      def dup         = initialize_copy(self)
      def clone(...)  = initialize_copy(self)

      private def initialize_copy(_other) = raise(TypeError, "#{self.class} cannot be copied")
    end
  end
end
