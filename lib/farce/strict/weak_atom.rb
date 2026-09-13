# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable weak atomic reference that stores shareable values directly.
    #
    # @example Referencing a shareable object without keeping it alive
    #   resource = Object.new.freeze
    #   atom     = Farce::Strict::WeakAtom.new(resource, compare_by_identity: true)
    #   atom.value.equal?(resource) # => true
    #
    #   resource = nil
    #   # Once the object is collected, atom.value returns nil.
    #
    # @example Lazily storing a shareable value
    #   atom  = Farce::Strict::WeakAtom.new
    #   value = atom.store_if_absent { [1, 2, 3].freeze }
    #   atom.value.equal?(value) # => true
    #   # Keeping value referenced also keeps the atom's referent alive.
    class WeakAtom < Abstract::WeakAtom
      include Shareable

      private def internal_atom_class = Internal::WeakAtom
    end
  end
end
