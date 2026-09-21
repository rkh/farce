# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/weak_atom/base"
require "farce/engine/shared/weak_map/reference"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Only the Vault accesses this slot. Publishing belongs here so interrupted
    # callers cannot leave a committed value without notifying its observers.
    class VaultWeakAtomSlot
      def initialize(value, changes, freeze_state)
        @reference = UnsharedWeakMapWeakReference.for(value)
        @changes = changes
        @freeze_state = freeze_state
      end

      def value = @reference.read.last

      def store(value)
        raise FrozenError, "can't modify frozen weak atom" if @freeze_state.value

        @reference = UnsharedWeakMapWeakReference.for(value)
        @changes.update { |generation| generation + 1 }
        nil
      end
    end
    private_constant :VaultWeakAtomSlot

    class WeakAtom < WeakAtomBase
      OWNER = Atom.new
      private_constant :OWNER

      private

      def initialize_storage(value)
        @token = Object.new.freeze
        @vault = OWNER.store_if_absent { Vault.new }
        @vault.weak_atom(@token, :create, value, @changes, @freeze_state)
        Internal::Freeze.publish(self)
      end

      def validate_value(value)
        return if ::Ractor.shareable?(value)
        raise Ractor::IsolationError, "value must be Ractor-shareable"
      end

      def read_value = @vault.weak_atom(@token, :read)
      def write_value(value) = @vault.weak_atom(@token, :store, value)
    end
  end
end
