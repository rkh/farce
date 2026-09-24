# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/unshared_vector"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class UnsharedVector
      prepend UnsharedVectorIteration
    end
  end
end
