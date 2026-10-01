# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # An {Abstract::Atom Atom} that is part of a transaction.
    class Atom < Abstract::Atom
      include Wrapper

      # (see Abstract::Atom#compare_by_identity?)
      # @see Abstract::Atom#compare_by_identity?
      def compare_by_identity? = access { @object.compare_by_identity? }

      # (see Abstract::Atom#value)
      # @see Abstract::Atom#value
      def value = access { unwrap_stored(@working.value) }
      alias get value

      # (see Abstract::Atom#value=)
      # @see Abstract::Atom#value=
      def value=(value)
        store(value)
      end

      # (see Abstract::Atom#store)
      # @see Abstract::Atom#store
      def store(value, mode: nil)
        write { unwrap_stored(@working.store(wrap(value, mode:))) }
      end

      # (see Abstract::Atom#swap)
      # @see Abstract::Atom#swap
      def swap(value, mode: nil)
        write { unwrap_stored(@working.swap(wrap(value, mode:))) }
      end

      # (see Abstract::Atom#update)
      # @see Abstract::Atom#update
      def update(mode: nil)
        require_block!(block_given?)
        write { unwrap_stored(@working.store(wrap(yield(unwrap_stored(@working.value)), mode:))) }
      end

      # (see Abstract::Atom#store_if_absent)
      # @see Abstract::Atom#store_if_absent
      def store_if_absent(mode: nil)
        require_block!(block_given?)
        write { value.nil? ? store(yield, mode:) : value }
      end

      # (see Abstract::Atom#upsert)
      # @see Abstract::Atom#upsert
      def upsert(initial, mode: nil)
        require_block!(block_given?)
        write { store(value.nil? ? initial : yield(value), mode:) }
      end

      # (see Abstract::Atom#compare_and_set)
      # @see Abstract::Atom#compare_and_set
      def compare_and_set(expected, replacement, mode: nil)
        write do
          next compared(@working.compare_and_set(expected, replacement)) unless @manager
          next compared(false) unless matches?(@working.value, expected, identity: @object.compare_by_identity?)
          @working.store(wrap(replacement, mode:))
          true
        end
      end

      Wrapper.inherit(self, :compare_by_identity?, :unwrap)
    end
  end
end
