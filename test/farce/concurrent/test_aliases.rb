# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Concurrent
    class TestAliases < Test
      def test_array_alias
        assert_same Farce::Vector, Concurrent::Array
      end

      def test_atom_alias
        assert_same Farce::Atom, Concurrent::Atom
      end

      def test_atomic_boolean_alias
        assert_same Farce::Flag, Concurrent::AtomicBoolean
      end

      def test_atomic_fixnum_alias
        assert_same Farce::Counter, Concurrent::AtomicFixnum
      end

      def test_exchanger_alias
        assert_same Farce::Exchanger, Concurrent::Exchanger
      end

      def test_hash_alias
        assert_same Farce::Map, Concurrent::Hash
      end

      def test_lock_alias
        assert_same Farce::Lock, Concurrent::Lock
      end

      def test_lock_local_var_alias
        assert_same Concurrent::FiberLocalVar, Concurrent::LockLocalVar
      end

      def test_map_alias
        assert_same Farce::Map, Concurrent::Map
      end

      def test_read_write_lock_alias
        assert_same Farce::ReadWriteLock, Concurrent::ReadWriteLock
      end
    end
  end
end
