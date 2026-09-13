# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    StrictMap          = Map
    StrictWeakKeyMap   = WeakKeyMap
    StrictWeakMap      = WeakMap
    StrictWeakValueMap = WeakValueMap
  end
end
