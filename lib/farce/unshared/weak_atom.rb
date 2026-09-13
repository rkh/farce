# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe weak atomic reference for values used within one Ractor.
    #
    # @example Referencing a mutable object within one Ractor
    #   items = []
    #   atom  = Farce::Unshared::WeakAtom.new(items)
    #   atom.value.equal?(items) # => true
    #   items << :job
    #   atom.value # => [:job]
    #
    #   items = nil
    #   # Once the array is collected, atom.value returns nil.
    #
    # @example Atomically replacing the referenced object
    #   original    = []
    #   replacement = [:job]
    #   atom        = Farce::Unshared::WeakAtom.new(original, compare_by_identity: true)
    #   atom.compare_and_set(original, replacement) # => true
    #   atom.value.equal?(replacement)              # => true
    class WeakAtom < Abstract::WeakAtom
      include Unshareable

      private def internal_atom_class = Internal::UnsharedWeakAtom
    end
  end
end
