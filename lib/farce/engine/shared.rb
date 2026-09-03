# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# This file is loaded both on JRuby and TruffleRuby, but not CRuby.
#-

require "farce/engine/shared/rebindable"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    include Autoloads["#{__dir__}/shared"]

    autoload :BasePort, "farce/engine/shared/port"
    autoload :Vault,    "farce/engine/shared/vault"
  end
end
