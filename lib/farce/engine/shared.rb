# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/rebindable"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    include Autoloads["#{__dir__}/shared"]

    autoload :BasePort, "farce/engine/shared/port"
  end
end
