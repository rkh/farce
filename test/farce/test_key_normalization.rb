# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestKeyNormalization < Test
    MAP_VARIANTS = [
      Map, WeakKeyMap,
      Strict::Map, Strict::WeakKeyMap, Strict::WeakValueMap, Strict::WeakMap,
      Unshared::Map, Unshared::WeakKeyMap, Unshared::WeakValueMap, Unshared::WeakMap,
      Local::Map, Local::WeakKeyMap, Local::WeakValueMap, Local::WeakMap
    ].freeze

    def test_symbol_normalizer_stores_and_observes_canonical_keys
      map = Map.new({ "one" => 1, one: 2 }, normalize_keys: :to_sym)

      assert_equal({ one: 2 }, map.to_h)
      assert_equal 2, map["one"]
      assert_equal :one, map.getkey("one")
    end

    def test_string_normalization_accepts_mutable_results
      [Map, Strict::Map].each do |type|
        map = type.new({ a: 10 }, normalize_keys: :to_s)

        assert_equal 10, map[:a]
        assert_equal 10, map.fetch(:a)
        assert_predicate map.keys.first, :frozen?
        map[:b] = 20

        assert_equal 20, map[:b]
        map.store(:a, 11)

        assert map.compare_and_set(:a, 11, 12)
        assert_equal 12, map.wait_until_non_nil(:a, timeout: 0)
        assert_equal 12, map.delete(:a)
      end
    end

    def test_string_normalization_does_not_freeze_the_original
      original = String.new("a")
      map = Map.new(normalize_keys: :itself)
      map[original] = 10
      original.replace("b")

      assert_equal 10, map["a"]
      assert_nil map[original]
      refute_predicate original, :frozen?
    end

    def test_identity_normalization_does_not_copy_string_results
      canonical = String.new("a").freeze
      map = Map.new(compare_keys_by_identity: true, normalize_keys: :itself)
      map[canonical] = 10

      assert_same canonical, map.keys.first
      assert_equal 10, map[canonical]
      mutable = String.new("a")
      if Ractor.shareable?(mutable)
        map[mutable] = 20

        assert_equal 20, map[mutable]
        refute_predicate mutable, :frozen?
      else
        assert_raises(Ractor::IsolationError) { map[mutable] = 20 }
      end
    end

    def test_direct_string_keys_are_frozen_snapshots
      MAP_VARIANTS.each do |type|
        key = String.new("a")
        map = type.new
        map[key] = 10
        stored = map.keys.first

        assert_predicate stored, :frozen?
        refute_predicate key, :frozen?
        key.replace("changed")

        assert_equal "a", stored
        assert_equal 10, map[String.new("a")]
        assert_equal 10, map.fetch(String.new("a"))
        assert map.key?(String.new("a"))
        assert_equal stored, map.getkey(String.new("a"))
        map.store(String.new("a"), 11)

        assert_equal 11, map.swap(String.new("a"), 12)
        assert map.compare_and_set(String.new("a"), 12, 13)
        assert_equal 14, map.update(String.new("a")) { |value| value + 1 }
        assert_equal 15, map.upsert(String.new("a"), 0) { |value| value + 1 }
        assert_equal 15, map.store_if_absent(String.new("a")) { flunk "existing key" }
        assert_equal 15, map.get(String.new("a"))
        assert_equal 15, map.wait_until_non_nil(String.new("a"), timeout: 0)
        assert_equal 15, map.wait_until_changed(String.new("a"), 0, timeout: 0)
        assert_equal 15, map.delete(String.new("a"))
      end
    end

    def test_direct_string_keys_in_lease_maps
      [LeaseMap, Unshared::LeaseMap, Local::LeaseMap].each do |type|
        map = type.new { {} }
        key = String.new("a")
        resource = []
        map[key] = resource
        key.replace("changed")

        assert_predicate map.keys.first, :frozen?
        checked_out = map.checkout(String.new("a"))

        assert_empty checked_out
        map.checkin(String.new("a"), checked_out)

        assert_empty map.delete(String.new("a"))
      end
    end

    def test_lookup_normalizer_is_one_step_and_ignores_hash_defaults
      aliases = Hash.new(:default)
      aliases["one"] = :one
      aliases[:one] = :other
      aliases.freeze
      map = Map.new(normalize_keys: aliases)
      map["one"] = 1
      map[:unknown] = 2

      assert_equal({ one: 1, unknown: 2 }, map.to_h)
      assert_nil map[:one]
      assert_equal 1, map["one"]
      assert_equal 2, map[:unknown]
    end

    def test_lookup_normalizer_preserves_false_and_nil_mappings
      aliases = { false => nil, nil => false }.freeze
      map = Map.new(normalize_keys: aliases)
      map[false] = 1
      map[nil] = 2

      assert_equal({ nil => 1, false => 2 }, map.to_h)
      assert_equal 2, map[nil]
      assert_equal 1, map[false]
    end

    def test_unshared_proc_is_retained_and_invoked_once
      calls = 0
      normalizer = lambda { |key|
        calls += 1
        key.to_sym
      }
      map = Unshared::Map.new(normalize_keys: normalizer)
      map[:one] = 1

      calls = 0

      assert_equal 1, map.wait_until_non_nil("one", timeout: 0)
      assert_equal 1, calls
      calls = 0

      assert_equal 1, map.store_if_absent("one") { flunk }
      assert_equal 1, calls
    end

    def test_shared_lookup_source_must_already_be_shareable
      return unless Internal.native_ractors?

      source = {}
      assert_raises(Ractor::IsolationError) { Map.new(normalize_keys: source) }
      refute_predicate source, :frozen?
    end

    def test_local_bounded_initial_entries_preserve_sequential_eviction
      map = Local::LRUMap.new(
        [["a", 1], ["b", 2], ["a", 3], ["c", 4]],
        max_size:       2,
        normalize_keys: :to_sym,
      )

      assert_equal({ a: 3, c: 4 }, map.to_h)
    end

    def test_local_tree_accepts_each_only_entries
      entries = Object.new
      def entries.each
        yield "one", 1
        yield "two", 2
      end

      map = Local::TreeMap.new(entries, normalize_keys: :to_sym)

      assert_equal({ one: 1, two: 2 }, map.to_h)
    end

    def test_lease_missing_error_preserves_original_key_and_receiver
      map = LeaseMap.new(normalize_keys: :to_sym) { { present: [] } }
      error = assert_raises(KeyError) { map.checkout("missing") }

      assert_equal "missing", error.key
      assert_same map, error.receiver
    end

    def test_lease_does_not_rewrite_block_key_errors
      map = Unshared::LeaseMap.new(normalize_keys: :to_sym) { { present: [] } }
      error = KeyError.new("from block")

      assert_same error, assert_raises(KeyError) { map.checkout("present") { raise error } }
      nested = assert_raises(KeyError) { map.checkout("present") { map.fetch("other") } }
      assert_equal "other", nested.key
    end

    def test_tree_and_bounded_maps_coordinate_on_canonical_keys
      [TreeMap.new(normalize_keys: :to_sym), LRUMap.new(max_size: 2, normalize_keys: :to_sym)].each do |map|
        map["one"] = 1

        assert_equal 1, map.store_if_absent(:one) { flunk }
        assert_equal [:one], map.keys
      end
    end

    def test_normalized_shared_map_remains_shareable
      map = Map.new({ "one" => 1 }, normalize_keys: :to_sym)

      assert Ractor.shareable?(map)
      ractor = Ractor.new(map) { it[:one] }

      assert_equal 1, ractor.respond_to?(:value) ? ractor.value : ractor.take
    end

    def test_shared_proc_normalizer_is_converted_during_construction
      map = Map.new(normalize_keys: :to_sym.to_proc)
      map["one"] = 1

      assert Ractor.shareable?(map)
      ractor = Ractor.new(map) { it[:one] }

      assert_equal 1, ractor.respond_to?(:value) ? ractor.value : ractor.take
    end

    def test_dup_and_clone_preserve_normalization
      map = Unshared::Map.new(normalize_keys: :to_sym)
      map["one"] = 1

      assert_equal 1, map.dup["one"]
      assert_equal 1, map.clone["one"]
    end

    def test_concurrent_variants_share_the_normalization_contract
      MAP_VARIANTS.each do |type|
        map = type.new({ "one" => 1 }, normalize_keys: :to_sym)

        assert_equal type, map.class
        assert_equal 1, map[:one]
        assert_equal [:one], map.keys
        assert map.key?("one")
      end
    end

    def test_lookup_source_identity_and_updates_are_visible_across_local_scopes
      one = String.new("one").freeze
      two = String.new("two").freeze
      aliases = Map.new({ one => :one })
      map = Local::Map.new(normalize_keys: aliases, scope: :fiber)
      map[one] = 1
      aliases[two] = :one

      assert_equal 1, map[two]
      result = Fiber.new do
        map[two] = 1
        map[one]
      end.resume

      assert_equal 1, result
    end

    def test_normalizer_failure_precedes_value_transfer
      value = []
      map = Map.new(mode: :move, normalize_keys: ->(_key) { raise "failed" })

      error = assert_raises(RuntimeError) { map.store(:key, value) }
      assert_equal "failed", error.message
      refute_operator Ractor::MovedObject, :===, value
    end

    def test_identity_comparison_applies_to_fresh_canonical_objects
      map = Unshared::Map.new(compare_keys_by_identity: true, normalize_keys: :dup.to_proc)
      map["one"] = 1

      assert_nil map["one"]
      assert_equal 1, map.size
    end

    def test_concurrent_decorator_has_only_classified_protocol
      map = Map.new(normalize_keys: :to_sym)
      backend = map.instance_variable_get(:@map)

      facade_protocol = Abstract::ConcurrentMap.public_instance_methods(false) |
        Internal.const_get(:MapValueModes).public_instance_methods(false)
      facade_helpers = %i[
        each_pair mode shareable_keys? shareable_values? values
        delete_if reject! compact! keep_if select! filter! transform_values! merge!
      ]
      backend_protocol = backend.class.public_instance_methods(false)

      assert_respond_to backend, :normalize_external_key
      assert_respond_to backend, :wait_until_changed_prepared
      assert_empty facade_protocol - backend_protocol - facade_helpers
      refute_includes backend.class.instance_methods(false), :method_missing
    end

    def test_tree_live_iteration_yields_canonical_keys_without_normalizing_again
      [TreeMap, Strict::TreeMap, Unshared::TreeMap, Local::TreeMap].each do |type|
        map = type.new({ 1 => :one, 2 => :two }, normalize_keys: ->(key) { key + 1 })
        pairs = []

        assert_same(map, map.each_live { |pair| pairs << pair })
        assert_equal [[2, :one], [3, :two]], pairs, type.name
        assert_equal pairs, map.each_live.to_a, type.name
      end
    end

    def test_extended_map_protocols_classify_every_public_operation
      protocols = {
        Abstract::TreeMap    => {
          operations: :TreeOperations,
          keyed:      %i[[] []= delete fetch getkey key? store_if_absent],
          key_free:   %i[
            clear compare_keys_by_identity? compare_values_by_identity? each each_key each_live each_pair each_value
            empty? first_key keys last_key length pop shareable_keys? shift size values
          ],
        },
        Abstract::BoundedMap => {
          operations: :BoundedOperations,
          keyed:      %i[[] []= delete fetch getkey key? store_if_absent],
          key_free:   %i[
            clear compare_keys_by_identity? compare_values_by_identity? each each_key each_pair each_value
            encode_with keys length max_size max_size= prune shift size values
          ],
        },
        Abstract::LeaseMap   => {
          operations: :LeaseOperations,
          keyed:      %i[
            [] []= available? checked_out? checkin checkout delete fetch getkey key? lease_for owned?
            store_if_absent try_checkout
          ],
          key_free:   %i[
            auto_lease clear compare_keys_by_identity? compare_values_by_identity? each each_key each_pair each_value
            duplicable? inspect keys shareable_keys? shareable_values? size to_a to_h values
          ],
        },
      }
      normalizer = Internal.const_get(:KeyNormalizer)

      protocols.each do |type, protocol|
        public_protocol = type.public_instance_methods(false)
        intercepted = normalizer.const_get(protocol.fetch(:operations)).instance_methods

        assert_empty public_protocol - protocol.fetch(:keyed) - protocol.fetch(:key_free), type.name
        assert_empty protocol.fetch(:keyed) - intercepted, type.name
      end
    end

    def test_bounded_aliases_share_one_loader_reservation
      normalized = Signal.new
      loader_entered = Signal.new
      release_loader = Queue.new
      normalizer = lambda do |key|
        normalized.broadcast if key == "alias"
        :one
      end
      map = Unshared::LRUMap.new(max_size: 2, normalize_keys: normalizer)

      loader_generation = loader_entered.generation
      first = Thread.new do
        map.store_if_absent("one") do
          loader_entered.broadcast
          release_loader.pop
          1
        end
      end
      loader_entered.wait(loader_generation)

      alias_normalized = normalized.generation
      second_loader = Signal.new
      second_loader_generation = second_loader.generation
      second = Thread.new do
        map.store_if_absent("alias") do
          second_loader.broadcast
          2
        end
      end
      normalized.wait(alias_normalized)

      refute second_loader.wait(second_loader_generation, timeout: 0.05)
      release_loader << true

      assert_equal 1, first.value
      assert_equal 1, second.value
    ensure
      release_loader << true if first&.alive?
      first&.join
      second&.join
    end
  end
end
