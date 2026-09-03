# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestStorage < Test
      def test_stores_and_fetches_values
        storage = Storage.new

        storage[:symbol] = 1
        storage["string"] = 2

        assert_equal 1, storage[:symbol]
        assert_equal 2, storage["string"]
        assert storage.key?(:symbol)
        assert storage.key?("string")
        refute storage.key?(:missing)
      end

      def test_supports_explicit_strong_and_weak_modes
        storage = Storage.new
        weak_key = Object.new

        storage[:symbol, :strong] = :strong
        storage[weak_key, :weak] = :weak

        assert_equal :strong, storage[:symbol, mode: :strong]
        assert_equal :weak, storage[weak_key, mode: :weak]
      end

      def test_auto_mode_keeps_strings_strong
        storage = Storage.new
        key = +"string"

        storage[key] = :value

        assert_equal :value, storage[key]
        assert_nil storage.instance_variable_get(:@weak)
        assert_equal({ key => :value }, storage.instance_variable_get(:@strong))
      end

      def test_store_if_absent_only_yields_for_missing_keys
        storage = Storage.new
        calls = 0

        first = storage.store_if_absent(:key) do
          calls += 1
          false
        end
        second = storage.store_if_absent(:key) do
          calls += 1
          true
        end

        refute first
        refute second
        assert_equal 1, calls
      end

      def test_dig_fetches_nested_values
        storage = Storage.new
        storage[:key] = { nested: { value: 1 } }

        assert_equal 1, storage.dig(:key, :nested, :value)
        assert_nil storage.dig(:missing, :nested)
      end

      def test_class_methods_delegate_to_scope
        storage = Storage.new

        Storage.[]=(:key, storage, :strong, { nested: :value })

        assert_equal({ nested: :value }, Storage[:key, scope: storage, mode: :strong])
        assert_equal :value, Storage.dig(:key, :nested, scope: storage, mode: :strong)
        assert_equal :created, Storage.store_if_absent(:created, scope: storage) { :created }
      end

      def test_clear_removes_strong_and_weak_values
        storage = Storage.new
        weak_key = Object.new

        storage[:strong] = :strong
        storage[weak_key, :weak] = :weak
        storage.clear

        refute storage.key?(:strong)
        refute storage.key?(weak_key, :weak)
      end

      def test_invalid_scope_raises
        error = assert_raises(ArgumentError) { Storage.scope(:invalid) }

        assert_equal "Invalid scope: :invalid", error.message
      end

      def test_global_scope_is_rejected
        error = assert_raises(ArgumentError) { Storage.scope(:global) }

        assert_equal "global scope is not supported", error.message
      end

      def test_scope_accepts_storage_instance
        storage = Storage.new

        assert_same storage, Storage.scope(storage)
      end

      def test_scope_maps_classes_to_named_scopes
        assert_same Storage.thread, Storage.scope(Thread)
        assert_same Storage.fiber, Storage.scope(Fiber)
      end

      def test_scope_rejects_invalid_classes
        error = assert_raises(ArgumentError) { Storage.scope(String) }

        assert_equal "Invalid scope: String", error.message
      end

      def test_scope_rejects_invalid_objects
        error = assert_raises(ArgumentError) { Storage.scope(nil) }

        assert_equal "Invalid scope: nil", error.message
      end

      def test_named_scopes_return_stable_storage
        assert_same Storage.ractor, Storage.ractor
        assert_same Storage.thread_group, Storage.thread_group(Thread.current.group)
        assert_same Storage.thread, Storage.thread(Thread.current)
        assert_same Storage.fiber_storage, Storage.fiber_storage
        assert_same Storage.fiber, Storage.fiber(Fiber.current)
      end

      def test_ractor_scope_is_local_to_current_ractor
        main_storage = Storage.ractor
        ractor = Ractor.new do
          Farce.const_get(:Internal, false).const_get(:Storage, false).ractor.object_id
        end

        object_id = ractor.respond_to?(:value) ? ractor.value : ractor.take

        refute_equal main_storage.object_id, object_id
      end

      def test_invalid_mode_raises
        storage = Storage.new
        error = assert_raises(ArgumentError) { storage[:key, mode: :invalid] }

        assert_equal "Invalid mode: :invalid", error.message
      end

      def test_thread_safe_store_if_absent_only_yields_once
        storage = Storage::ThreadSafe.new
        calls = 0
        mutex = Mutex.new

        threads = 10.times.map do
          Thread.new do
            storage.store_if_absent(:key) do
              mutex.synchronize { calls += 1 }
              Thread.pass
              :value
            end
          end
        end

        assert_equal Array.new(10, :value), threads.map(&:value)
        assert_equal 1, calls
      end
    end
  end
end
