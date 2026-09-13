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

    autoload :BasePort,             "farce/engine/shared/port"
    autoload :StrictMap,            "farce/engine/shared/strict_map"
    autoload :StrictWeakKeyMap,     "farce/engine/shared/strict_map"
    autoload :StrictWeakMap,        "farce/engine/shared/strict_map"
    autoload :StrictWeakValueMap,   "farce/engine/shared/strict_map"
    autoload :Vault,                "farce/engine/shared/vault"
    autoload :UnsharedMap,          "farce/engine/shared/unshared_weak_map"
    autoload :UnsharedWeakMap,      "farce/engine/shared/unshared_weak_map"
    autoload :UnsharedWeakKeyMap,   "farce/engine/shared/unshared_weak_map"
    autoload :UnsharedWeakValueMap, "farce/engine/shared/unshared_weak_map"
  end
end
