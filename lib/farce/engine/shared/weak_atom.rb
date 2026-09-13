# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/unshared_weak_atom"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    WeakAtom = UnsharedWeakAtom
  end
end
