# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# This file is loaded both on JRuby and TruffleRuby, but not CRuby.
#-

require "farce/engine/shared/rebindable"
require "farce/engine/shared/trie"
require "farce/engine/shared/portable_transaction"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    include Autoloads["#{__dir__}/shared"]

    # TruffleRuby 34 omits superclass constants. JRuby 10 can include names
    # hidden by private constants. Normalize inherited enumeration for Walker.
    def walker_constants(object, inherit)
      names = object.constants(inherit)
      return names unless inherit

      if Class === object && object != Object
        parent = object.superclass
        while parent && parent != Object
          names |= parent.constants(true)
          parent = parent.superclass
        end
      end

      ancestors = object.ancestors
      names.select do |name|
        owner = ancestors.find { it.const_defined?(name, false) }
        owner.constants(false).include?(name)
      end
    end

    # define_method supplies the receiver. Rebinding first is unnecessary without
    # native Ractor isolation and can change the method context used by super.
    def prepare_method_definition(&definition) = definition

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
