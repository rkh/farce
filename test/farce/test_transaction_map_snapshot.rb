# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestTransactionMapSnapshot < Test
    def test_derived_writes_validate_reads_from_other_keys
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ input: 2, output: 0 })
        atom = Strict::Atom.new(0)

        refute(Farce.transaction(retries: 0) do |tx|
          tx[map][:output] = tx[map][:input] * 3
          tx[atom].value = 1
          map[:input] = 4
        end)
        assert_equal({ input: 4, output: 0 }, map.to_h)
        assert_equal 0, atom.value
      end
    end

    def test_read_only_map_participants_are_validated
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ input: 1 })
        output = Strict::Map.new({ result: 0 })

        refute(Farce.transaction(retries: 0) do |tx|
          tx[output][:result] = tx[map][:input]
          map[:input] = 2
        end)
        assert_equal 0, output[:result]
      end
    end

    def test_absent_observations_detect_insertion_including_nil
      [Farce, Strict, Unshared, Local].each do |namespace|
        %i[index key fetch].each do |operation|
          map = namespace::Map.new
          atom = Strict::Atom.new(0)

          refute(Farce.transaction(retries: 0) do |tx|
            case operation
            when :index then assert_nil tx[map][:missing]
            when :key then refute tx[map].key?(:missing)
            when :fetch then assert_equal :default, tx[map].fetch(:missing, :default)
            end
            tx[atom].value = 1
            map[:missing] = nil
          end)
          assert map.key?(:missing)
          assert_equal 0, atom.value
        end
      end
    end

    def test_present_nil_observation_detects_deletion
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ input: nil, output: 0 })

        refute(Farce.transaction(retries: 0) do |tx|
          assert_nil tx[map][:input]
          tx[map][:output] = 1
          map.delete(:input)
        end)
        assert_equal({ output: 0 }, map.to_h)
      end
    end

    def test_repeated_reads_keep_the_first_observation
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ input: 1 })

        refute(Farce.transaction(retries: 0) do |tx|
          assert_equal 1, tx[map][:input]
          map[:input] = 2

          assert_equal 1, tx[map].fetch(:input)
          tx[map][:output] = tx[map][:input]

          assert_equal 1, tx[map][:output]
        end)
        assert_equal({ input: 2 }, map.to_h)
      end
    end

    def test_unobserved_changes_survive_commit
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ input: 1, removed: 0, changed: 0 })

        assert(Farce.transaction(retries: 0) do |tx|
          tx[map][:output] = tx[map][:input] + 1
          map.delete(:removed)
          map[:changed] = 2
          map[:added] = 3
        end)
        assert_equal({ input: 1, output: 2, changed: 2, added: 3 }, map.to_h)
      end
    end

    def test_blind_writes_also_validate_their_original_key
      [Farce, Strict, Unshared, Local].each do |namespace|
        %i[store delete swap cas].each do |operation|
          map = namespace::Map.new({ value: 0 })
          atom = Strict::Atom.new(0)

          refute(Farce.transaction(retries: 0) do |tx|
            case operation
            when :store then tx[map][:value] = 1
            when :delete then tx[map].delete(:value)
            when :swap then assert_equal 0, tx[map].swap(:value, 1)
            when :cas then assert tx[map].compare_and_set(:value, 0, 1)
            end
            tx[atom].value = 1
            map[:value] = 2
          end)
          assert_equal 2, map[:value]
          assert_equal 0, atom.value
        end
      end
    end

    def test_whole_map_operations_promote_and_validate_later_changes
      [Farce, Strict, Unshared, Local].each do |namespace|
        %i[keys to_a clear].each do |operation|
          map = namespace::Map.new({ value: 0 })
          atom = Strict::Atom.new(0)

          refute(Farce.transaction(retries: 0) do |tx|
            tx[map][:value] = 1
            tx[map].public_send(operation)
            tx[atom].value = 1
            map[:unrelated] = 2
          end)
          assert_equal({ value: 0, unrelated: 2 }, map.to_h)
          assert_equal 0, atom.value
        end
      end
    end

    def test_promotion_includes_unobserved_changes_and_staged_writes
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ value: 0, removed: 0 })

        assert(Farce.transaction(retries: 0) do |tx|
          tx[map][:value] = 1
          tx[map].delete(:removed)
          map[:unrelated] = 2

          assert_equal 2, tx[map].size
          assert_equal({ value: 1, unrelated: 2 }, tx[map].to_h)
          tx[map][:after_promotion] = 3
        end)
        assert_equal({ value: 1, unrelated: 2, after_promotion: 3 }, map.to_h)
      end
    end

    def test_promotion_rejects_changed_earlier_reads_and_retries
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ input: 1 })
        attempts = 0
        completed = 0

        assert(Farce.transaction(retries: 1) do |tx|
          attempts += 1
          tx[map][:output] = tx[map][:input] * 2
          map[:input] = 3 if attempts == 1

          assert_equal 2, tx[map].keys.size
          completed += 1
        end)
        assert_equal 2, attempts
        assert_equal 1, completed
        assert_equal({ input: 3, output: 6 }, map.to_h)
      end
    end

    def test_rescued_promotion_conflict_still_invalidates_attempt
      map = Strict::Map.new({ value: 0 })
      atom = Strict::Atom.new(0)

      refute(Farce.transaction(retries: 0) do |tx|
        tx[atom].value = 1

        assert_equal 0, tx[map][:value]
        map[:value] = 2
        begin
          tx[map].keys
        rescue StandardError
          tx[atom].value = 3
        end
      end)
      assert_equal 0, atom.value
    end

    def test_identity_keys_are_observed_separately
      [Farce, Strict, Unshared, Local].each do |namespace|
        first = "same".dup.freeze
        second = first.dup.freeze
        map = namespace::Map.new({ first => 0 }, compare_keys_by_identity: true)

        assert(Farce.transaction(retries: 0) do |tx|
          assert_equal 0, tx[map][first]
          tx[map][first] = 1
          map[second] = 2
        end)
        assert_equal 2, map.size
        assert_equal 1, map[first]
        assert_equal 2, map[second]
      end
    end

    def test_value_validation_uses_identity_even_with_value_comparison
      first = ["same"]
      map = Unshared::Map.new({ value: first })
      atom = Strict::Atom.new(0)

      refute(Farce.transaction(retries: 0) do |tx|
        assert_same first, tx[map][:value]
        tx[atom].value = 1
        map[:value] = first.dup
      end)
      assert_equal 0, atom.value
    end

    def test_point_reads_do_not_copy_the_whole_map
      map = Unshared::Map.new({ value: 0 })
      backend = map.instance_variable_get(:@map)
      snapshots = []
      backend.define_singleton_method(:transaction_snapshot) do
        snapshots << true
        super()
      end

      assert(Farce.transaction(retries: 0) do |tx|
        view = tx[map]

        assert_empty snapshots
        assert_equal 0, view[:value]
        view[:value] = 1

        refute view.key?(:missing)
        assert_empty snapshots
        assert_equal 1, view.keys.size
        assert_equal 1, snapshots.size
        view[:second] = 2
      end)
      assert_equal 1, snapshots.size
      assert_equal({ value: 1, second: 2 }, map.to_h)
    end

    def test_set_reads_validate_dependencies
      [Farce, Strict, Unshared, Local].each do |namespace|
        set = namespace::Set.new([1])
        atom = Strict::Atom.new(0)

        refute(Farce.transaction(retries: 0) do |tx|
          tx[atom].value = 1 if tx[set].include?(1)
          tx[set].add(2)
          set.delete(1)
        end)
        assert_empty set
        assert_equal 0, atom.value
      end
    end

    def test_commit_conflict_after_portable_application_restores_portable_state
      return unless Internal.const_defined?(:NativeTransactionEntry, false)

      atom = Unshared::Atom.new(0)
      map = Strict::Map.new({ value: 0 })
      backend = atom.instance_variable_get(:@atom)
      applied = ::Queue.new
      release = ::Queue.new
      backend.define_singleton_method(:transaction_snapshot) do
        super().tap do |entry|
          entry.define_singleton_method(:apply) do
            super()
            applied << true
            release.pop
          end
        end
      end
      worker = Thread.new do
        Farce.transaction(retries: 0) do |tx|
          tx[atom].value = 1
          tx[map][:value] = 1
        end
      end
      applied.pop
      map[:unrelated] = 2
      release << true

      refute worker.value
      assert_equal 0, atom.value
      assert_equal({ value: 0, unrelated: 2 }, map.to_h)
    ensure
      release << true if release
      worker&.kill
      worker&.join
    end

    def test_another_threads_unobserved_write_survives
      map = Strict::Map.new({ input: 1 })
      observed = ::Queue.new
      release = ::Queue.new
      worker = Thread.new do
        Farce.transaction(retries: 0) do |tx|
          tx[map][:output] = tx[map][:input] + 1
          observed << true
          release.pop
        end
      end
      observed.pop
      map[:unrelated] = 3
      release << true

      assert worker.value
      assert_equal({ input: 1, output: 2, unrelated: 3 }, map.to_h)
    ensure
      release << true if release
      worker&.kill
      worker&.join
    end

    def test_commit_conflicts_retry_with_fresh_read_observations
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ input: 1 })
        attempts = 0

        assert(Farce.transaction(retries: 1) do |tx|
          attempts += 1
          tx[map][:output] = tx[map][:input] * 2
          map[:input] = 4 if attempts == 1
        end)
        assert_equal 2, attempts
        assert_equal({ input: 4, output: 8 }, map.to_h)
      end
    end

    def test_absence_before_promotion_is_validated
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new

        refute(Farce.transaction(retries: 0) do |tx|
          refute tx[map].key?(:input)
          tx[map][:output] = 1
          map[:input] = nil
          tx[map].clear

          flunk "promotion should reject the changed absent key"
        end)
        assert_equal({ input: nil }, map.to_h)
      end
    end

    def test_normalized_reads_and_writes_share_observations
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ "a" => 0 }, normalize_keys: :succ)

        refute(Farce.transaction(retries: 0) do |tx|
          assert_equal 0, tx[map]["a"]
          tx[map]["result"] = 1
          map["a"] = 2
        end)
        assert_equal({ "b" => 2 }, map.to_h)
      end
    end

    def test_size_only_does_not_observe_values_or_key_identities
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ first: 1 })
        atom = Strict::Atom.new(0)

        assert(Farce.transaction(retries: 0) do |tx|
          tx[atom].value = tx[map].size
          map.delete(:first)
          map[:second] = 2

          assert_equal 1, tx[map].size
        end)
        assert_equal 1, atom.value
        assert_equal({ second: 2 }, map.to_h)
      end
    end

    def test_size_change_invalidates_other_participants
      [Farce, Strict, Unshared, Local].each do |namespace|
        [{}, { first: 1 }].each do |initial|
          map = namespace::Map.new(initial)
          atom = Strict::Atom.new(-1)

          refute(Farce.transaction(retries: 0) do |tx|
            tx[atom].value = tx[map].size
            map[:second] = 2

            assert_equal initial.size, tx[map].size
            assert_equal initial.empty?, tx[map].empty?
          end)
          assert_equal(-1, atom.value)
        end
      end
    end

    def test_size_includes_staged_changes_and_merges_unobserved_changes
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ first: 1, second: nil })

        assert(Farce.transaction(retries: 0) do |tx|
          view = tx[map]
          view[:third] = 3

          assert_equal 3, view.size
          view.delete(:second)

          assert_equal 2, view.length
          view[:first] = 4

          assert_equal 2, view.size
          map[:first] = 1
          map[:second] = nil
        end)
        assert_equal({ first: 4, third: 3 }, map.to_h)
      end
    end

    def test_size_and_key_dependencies_are_both_validated
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ first: 1 })
        atom = Strict::Atom.new(0)

        refute(Farce.transaction(retries: 0) do |tx|
          view = tx[map]
          tx[atom].value = view.size + view[:first]
          map[:first] = 2
        end)
        assert_equal 0, atom.value
      end
    end

    def test_size_observation_remains_a_dependency_after_full_promotion
      map = Strict::Map.new({ first: 1 })

      refute(Farce.transaction(retries: 0) do |tx|
        view = tx[map]

        assert_equal 1, view.size
        map[:second] = 2

        view.each { flunk "conflicted snapshot was enumerated" }
        flunk "enumeration must validate the earlier size read"
      end)
    end

    def test_unobserved_set_membership_changes_are_preserved
      [Farce, Strict, Unshared, Local].each do |namespace|
        set = namespace::Set.new([1])

        assert(Farce.transaction(retries: 0) do |tx|
          tx[set].add(2)
          set.add(3)
        end)
        assert_equal [1, 2, 3], set.to_a.sort
      end
    end

    def test_reinsertion_uses_the_replacement_key
      key_class = Struct.new(:value)
      [Farce, Strict, Unshared, Local].each do |namespace|
        [false, true].each do |present|
          first = key_class.new(1).freeze
          second = key_class.new(1).freeze
          map = namespace::Map.new(present ? { first => 1 } : {})

          assert(Farce.transaction(retries: 0) do |tx|
            view = tx[map]
            view[first] = 1 unless present
            view.delete(first)
            view[second] = 2
          end)
          assert_same second, map.getkey(first)
        end
      end
    end

    def test_size_only_reads_do_not_capture_full_snapshots
      map = Unshared::Map.new({ value: 1 })
      backend = map.method(:internal_map).call
      backend.define_singleton_method(:transaction_snapshot) { raise "unexpected full snapshot" }

      assert(Farce.transaction(retries: 0) do |tx|
        assert_equal 1, tx[map].size
        assert_equal 1, tx[map].length
        refute_empty tx[map]
        map[:value] = 2
      end)
      assert_equal 2, map[:value]
    end

    def test_count_only_validation_during_native_publication
      return unless Internal.const_defined?(:NativeTransactionEntry, false)
      map = Strict::Map.new({ value: 0 })
      return unless Internal::NativeTransactionEntry === map.method(:internal_map).call.transaction_size_snapshot(1)

      [false, true].each do |change_size|
        atom = Unshared::Atom.new(0)
        map = Strict::Map.new({ value: 0 })
        applied = ::Queue.new
        release = ::Queue.new
        backend = atom.instance_variable_get(:@atom)
        backend.define_singleton_method(:transaction_snapshot) do
          super().tap do |entry|
            entry.define_singleton_method(:apply) do
              super()
              applied << true
              release.pop
            end
          end
        end
        worker = Thread.new do
          Farce.transaction(retries: 0) { |tx| tx[atom].value = tx[map].size }
        end
        begin
          applied.pop
          map[change_size ? :other : :value] = 2
          release << true

          assert_equal !change_size, worker.value
          assert_equal change_size ? 0 : 1, atom.value
          assert_equal change_size ? 2 : 1, map.size
          assert_equal 2, map[change_size ? :other : :value]
        ensure
          release << true
          worker.kill
          worker.join
        end
      end
    end

    def test_count_only_commit_accepts_key_replacement_after_preparation
      map = Unshared::Map.new({ first: 1 })
      atom = Strict::Atom.new(0)
      backend = map.method(:internal_map).call
      backend.define_singleton_method(:transaction_size_snapshot) do |size|
        entry = super(size)
        if Internal::PortableTransaction::Entry === entry
          entry.define_singleton_method(:prepare) do
            super()
            map.delete(:first)
            map[:second] = 2
          end
        else
          map.delete(:first)
          map[:second] = 2
        end
        entry
      end

      assert(Farce.transaction(retries: 0) { |tx| tx[atom].value = tx[map].size })
      assert_equal 1, atom.value
      assert_equal({ second: 2 }, map.to_h)
    end

    def test_size_reads_inside_updates_do_not_wait_for_the_update
      map = Unshared::Map.new({ value: 1 })
      atom = Strict::Atom.new(0)
      map.update(:value) do |value|
        refute(Farce.transaction(retries: 0) { |tx| tx[atom].value = tx[map].size })
        value + 1
      end

      assert_equal 0, atom.value
      assert_equal 2, map[:value]
    end

    def test_size_conflicts_retry_with_a_fresh_count
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ value: 1 })
        atom = Strict::Atom.new(0)
        attempts = 0

        assert(Farce.transaction(retries: 1) do |tx|
          attempts += 1
          tx[atom].value = tx[map].size
          map[:other] = 2 if attempts == 1
        end)
        assert_equal 2, attempts
        assert_equal 2, atom.value
      end
    end

    def test_restoring_the_identical_observed_value_does_not_conflict
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::Map.new({ input: 1 })

        assert(Farce.transaction(retries: 0) do |tx|
          tx[map][:output] = tx[map][:input]
          map[:input] = 2
          map[:input] = 1
        end)
        assert_equal({ input: 1, output: 1 }, map.to_h)
      end
    end
  end
end
