# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/engine/shared/unshared_weak_map"

module Farce
  class TestTransaction < Test
    include Helpers::InternalTestHelpers

    class Account
      def initialize(balance, ledger)
        @balance = balance
        @ledger = ledger
      end

      def transaction_wrapper(transaction)
        AccountWrapper.new(transaction[@balance], transaction[@ledger])
      end
    end

    AccountWrapper = Struct.new(:balance, :ledger) do
      def withdraw(amount)
        balance.update { |value| value - amount }
        ledger[:withdrawal] = amount
      end
    end

    def test_molecule_fields_share_atom_wrappers
      [Farce, Strict, Unshared, Local].each do |namespace|
        record = namespace::Molecule.define(:balance, :"display name").new(10, "Alice")

        assert(Farce.transaction do |tx|
          view = tx[record]

          assert_instance_of Transaction::Molecule, view
          assert_same tx[record.balance_atom], view.balance_atom
          view.balance = 20
          view.public_send(:"display name=", "Bob")

          assert_equal 20, view.balance
          assert_equal({ balance: 20, "display name": "Bob" }, view.to_h)
          refute Ractor.shareable?(view) if Internal.native_ractors?
        end)
        assert_equal 20, record.balance
        refute(Farce.transaction do |tx|
          tx[record].balance = 30
          tx[record].balance_atom.compare_and_set(99, 40)
        end)
        assert_equal 20, record.balance
      end
    end

    def test_set_membership_commit_and_rollback
      [Farce, Strict, Unshared, Local].each do |namespace|
        set = namespace::Set.new([1, 2])

        assert(Farce.transaction do |tx|
          view = tx[set]

          assert_instance_of Transaction::Set, view
          assert_same view, view.add?(3)
          assert_nil view.add?(2)
          assert_same view, view.delete?(1)
          assert_nil view.delete?(9)
          assert_equal [2, 3], view.to_a.sort
          refute Ractor.shareable?(view) if Internal.native_ractors?
        end)
        assert_equal [2, 3], set.to_a.sort
        refute(Farce.transaction do |tx|
          tx[set].clear
          tx[set].merge([7, 8])
          tx.abort!
        end)
        assert_equal [2, 3], set.to_a.sort
        refute(Farce.transaction do |tx|
          tx[set].add(4)
          set.add(5)
        end)
        assert_equal [2, 3, 5], set.to_a.sort
      end
    end

    def test_set_modes_identity_and_normalization
      set = Farce::Set.new(normalize: :downcase)

      assert(Farce.transaction do |tx|
        tx[set].add("HELLO")

        assert_includes tx[set], "Hello"
        assert_equal ["hello"], tx[set].to_a
      end)
      assert_equal ["hello"], set.to_a

      object = []
      identity = Farce::Set.new(compare_by_identity: true, mode: :local)

      assert(Farce.transaction do |tx|
        tx[identity].add(object)

        assert_includes tx[identity], object
        refute_includes tx[identity], []
        assert_same object, tx[identity].first
      end)
      assert_same object, identity.first

      assert_raises(TypeError) do
        Farce.transaction { |tx| tx[set].add("MOVE", mode: :move) }
      end
      assert_equal ["hello"], set.to_a
    end

    def test_tree_map_ordered_operations_and_conflicts
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::TreeMap.new({ 2 => :two, 1 => nil })

        assert(Farce.transaction do |tx|
          view = tx[map]

          assert_instance_of Transaction::TreeMap, view
          assert view.key?(1)
          assert_nil view.fetch(1)
          assert view.compare_and_set(1, nil, :one)
          view[3] = :three

          assert_equal [1, 2, 3], view.keys
          assert_equal 1, view.first_key
          assert_equal 3, view.last_key
          assert_equal [1, :one], view.shift
          assert_equal [3, :three], view.pop
          assert_equal :two, view.swap(2, :changed)
        end)
        assert_equal [[2, :changed]], map.to_a
        refute(Farce.transaction do |tx|
          tx[map][4] = :four
          map[5] = :five
        end)
        assert_equal [[2, :changed], [5, :five]], map.to_a
        refute(Farce.transaction do |tx|
          tx[map].clear
          tx[map].compare_and_set(99, nil, :absent)
        end)
        assert_equal [[2, :changed], [5, :five]], map.to_a
      end
      refute_respond_to Unsafe::TreeMap.new, :transaction_wrapper
    end

    def test_sorted_set_ordering_and_rollback
      [Farce, Strict, Unshared, Local].each do |namespace|
        set = namespace::SortedSet.new([3, 1])

        assert(Farce.transaction do |tx|
          assert_instance_of Transaction::Set, tx[set]
          tx[set].add(2)
          tx[set].delete(3)

          assert_equal [1, 2], tx[set].to_a
        end)
        assert_equal [1, 2], set.to_a
        refute(Farce.transaction do |tx|
          tx[set].clear
          tx.abort!
        end)
        assert_equal [1, 2], set.to_a
      end
    end

    def test_tree_reservation_prevents_commit
      [Farce, Strict, Unshared, Local].each do |namespace|
        map = namespace::TreeMap.new
        atom = Strict::Atom.new(0)
        ready = ::Queue.new
        release = ::Queue.new
        worker = Thread.new do
          map.store_if_absent(1) do
            ready << true
            release.pop
            :initialized
          end
        end
        ready.pop

        refute(Farce.transaction do |tx|
          tx[map][2] = :staged
          tx[atom].value = 1
        end)
        assert_empty map
        assert_equal 0, atom.value
      ensure
        release << true if release
        worker&.join
      end
    end

    def test_tree_normalizes_once_and_preserves_copy_modes
      map = Farce::TreeMap.new(normalize_keys: :succ)

      assert(Farce.transaction do |tx|
        tx[map]["a"] = ["value"]

        assert_equal ["b"], tx[map].keys
        assert_equal ["value"], tx[map]["a"]
        assert tx[map].compare_and_set("a", ["value"], ["updated"])
      end)
      assert_equal ["b"], map.keys
      assert_equal ["updated"], map["a"]
    end

    def test_all_new_families_commit_together_and_discard_together
      molecule = Local::Molecule.define(:value).new(1)
      set = Unshared::Set.new([1])
      tree = Strict::TreeMap.new({ 1 => 1 })
      sorted = Farce::SortedSet.new([1])
      atom = Strict::Atom.new(1)

      assert(Farce.transaction do |tx|
        tx[molecule].value = 2
        tx[set].add(2)
        tx[tree][2] = 2
        tx[sorted].add(2)
      end)
      refute(Farce.transaction do |tx|
        tx[molecule].value = 3
        tx[set].clear
        tx[tree].clear
        tx[sorted].clear
        tx[atom].compare_and_set(99, 0)
      end)
      assert_equal 2, molecule.value
      assert_equal [1, 2], set.to_a.sort
      assert_equal [1, 2], tree.keys
      assert_equal [1, 2], sorted.to_a
    end

    def test_tree_freeze_and_compaction
      map = Strict::TreeMap.new({ 1 => :one })

      refute(Farce.transaction do |tx|
        tx[map][2] = :two
        map.freeze
      end)
      assert_equal [[1, :one]], map.to_a
      map = Strict::TreeMap.new({ 1 => "one" })

      assert(Farce.transaction do |tx|
        tx[map][2] = "two"
        GC.start
        GC.compact if GC.respond_to?(:compact)

        assert_equal(%w[one two], tx[map].map { |_, value| value })
      end)
      assert_equal [1, 2], map.keys
    end

    def test_new_wrappers_close_after_failure_and_poison_rescued_errors
      record = Strict::Molecule.define(:balance).new(1)
      objects = [record, Strict::Set.new([1]), Strict::SortedSet.new([1]), Strict::TreeMap.new({ 1 => 1 })]
      objects.each do |object|
        wrapper = nil
        atom = Strict::Atom.new(0)

        refute(Farce.transaction do |tx|
          wrapper = tx[object]
          tx[atom].value = 1

          assert_raises(NoMethodError) { wrapper.unsupported_operation }
        end)
        assert_equal 0, atom.value
        assert_raises(Transaction::ClosedError) { wrapper.to_a }
      end
    end

    def test_molecule_retains_unusual_field_names
      record = Strict::Molecule.define(:sum, :"ends=").new(1, 2)

      assert(Farce.transaction do |tx|
        assert_equal 1, tx[record].sum
        assert_equal 2, tx[record].public_send(:"ends=")
        tx[record].sum = 3
        tx[record].public_send(:"ends==", 4)
      end)
      assert_equal 3, record.sum
      assert_equal 4, record.public_send(:"ends=")
    end

    def test_molecule_reads_validate_every_field_and_retry
      record = Strict::Molecule.define(:left, :right).new(1, 2)
      attempts = 0

      assert(Transaction.run(retries: 1) do |tx|
        attempts += 1
        tx[record].left = 3
        record.right = 4 if attempts == 1
      end)
      assert_equal 2, attempts
      assert_equal({ left: 3, right: 4 }, record.to_h)
    end

    def test_sorted_set_uses_comparator_membership_and_accepts_mutable_local_elements
      [Unshared, Local].each do |namespace|
        set = namespace::SortedSet.new
        element = [2]

        assert(Farce.transaction do |tx|
          tx[set].add(element)
          tx[set].add([1])
          tx[set].add([2])

          assert_equal [[1], [2]], tx[set].to_a
          assert_same element, tx[set].to_a.last
        end)
        assert_equal [[1], [2]], set.to_a
      end
    end

    def test_tree_and_set_frozen_in_another_local_scope
      [Local::TreeMap.new(scope: :fiber), Local::Set.new(scope: :fiber),
       Local::SortedSet.new(scope: :fiber)].each do |object|
        refute(Farce.transaction do |tx|
          view = tx[object]
          view.is_a?(Transaction::Set) ? view.add(1) : view[1] = 1
          Fiber.new { object.freeze }.resume
        end)
        assert_empty object
      end
    end

    def test_new_shared_wrappers_work_in_another_ractor
      return unless Internal.native_ractors?
      tree = Strict::TreeMap.new({ 1 => 1 })
      set = Strict::Set.new([1])
      sorted = Strict::SortedSet.new([1])

      worker = Ractor.new(tree, set, sorted) do |map, members, ordered|
        Farce.transaction do |tx|
          tx[map][2] = 2
          tx[members].add(2)
          tx[ordered].add(2)
        end
      end

      assert ractor_value(worker)
      assert_equal [1, 2], tree.keys
      assert_equal [1, 2], set.to_a.sort
      assert_equal [1, 2], sorted.to_a
    end

    def test_tree_comparator_exception_discards_other_writes
      tree = Strict::TreeMap.new({ 1 => 1 })
      atom = Strict::Atom.new(0)

      refute(Farce.transaction do |tx|
        tx[atom].value = 1

        assert_raises(ArgumentError) { tx[tree]["incomparable"] = 2 }
      end)
      assert_equal 0, atom.value
      assert_equal [[1, 1]], tree.to_a
    end

    class PublicationInterrupted < StandardError; end

    # Exercise the portable cell/index adapter even on CRuby's native maps.
    class PortableMapBackend < Internal.const_get(:UnsharedMapBase)
      def weak_keys? = false
      def weak_values? = false
      def transaction_snapshot = Internal::PortableTransaction.snapshot(self, :strong_map)
      def transaction_pairs = Internal::PortableTransaction::StrongMapEntry.pairs(@index)
    end

    def test_interruption_during_publication_is_delivered_after_commit
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
      transaction = nil
      worker = Thread.new do
        transaction = Transaction.new
        begin
          transaction.run do |tx|
            tx[atom].value = 1
            tx[map][:value] = 1
          end
        rescue PublicationInterrupted
          transaction.state
        end
      end
      applied.pop
      worker.raise(PublicationInterrupted)
      release << true

      assert_equal :committed, worker.value
      assert_equal 1, atom.value
      assert_equal 1, map[:value]
    ensure
      release << true if release
      worker&.kill
      worker&.join
    end

    def test_failure_after_portable_application_restores_all_storage
      atom = Unshared::Atom.new(0)
      map = Unshared::Map.new({ value: 0 })
      backend = PortableMapBackend.new({ value: 0 })
      map.instance_variable_set(:@map, backend)
      backend.define_singleton_method(:transaction_snapshot) do
        super().tap do |entry|
          entry.define_singleton_method(:apply) do
            super()
            raise PublicationInterrupted
          end
        end
      end

      assert_raises(PublicationInterrupted) do
        Farce.transaction do |tx|
          tx[atom].value = 1
          tx[map][:value] = 1
          tx[map][:new] = 2
        end
      end
      assert_equal 0, atom.value
      assert_equal({ value: 0 }, map.to_h)
      map.update(:value) { it + 1 }

      assert_equal 1, map[:value]
    end

    def test_scheduler_retries_after_initializer_releases_reservation
      skip "Fiber schedulers are unavailable" unless Fiber.respond_to?(:set_scheduler)

      begin
        map = Unshared::Map.new
        other = Strict::Atom.new(0)
        results = []
        attempts = 0
        scheduler = Helpers::QueueTestScheduler.new
        Fiber.set_scheduler(scheduler)
        Fiber.schedule do
          map.store_if_absent(:value) do
            Fiber.scheduler.kernel_sleep(0)
            1
          end
        end
        Fiber.schedule do
          results << Farce.transaction(retries: 100) do |tx|
            attempts += 1
            tx.fail! if attempts == 1
            tx[map][:value] = 2
            tx[other].value = 2
          end
        end
        Fiber.set_scheduler(nil)

        assert_equal [true], results
        assert_operator attempts, :>=, 2
        assert_equal 2, map[:value]
        assert_equal 2, other.value
        assert_operator scheduler.block_calls, :>, 0
      ensure
        Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
      end
    end

    def test_transaction_replacement_wakes_unshared_map_waiter
      map = Unshared::Map.new({ value: 0 })
      waiting = ::Queue.new
      waiter = Thread.new do
        waiting << true
        map.wait_until_changed(:value, 0, timeout: 5)
      end
      waiting.pop

      assert(Farce.transaction(retries: 100) { |tx| tx[map][:value] = 1 })
      assert_equal 1, waiter.value
    ensure
      waiter&.kill
      waiter&.join
    end

    def test_commit_mixed_objects
      atom = Strict::Atom.new(1)
      map = Strict::Map.new({ a: 2 })
      vector = Strict::Vector.new([3])

      assert(Farce.transaction do |tx|
        assert tx[atom].compare_and_set(1, 4)
        tx[map][:b] = tx[map][:a] + 1
        tx[vector].push(5)

        assert_equal 4, tx[atom].value
        assert_equal 1, atom.value
      end)
      assert_equal 4, atom.value
      assert_equal({ a: 2, b: 3 }, map.to_h)
      assert_equal [3, 5], vector.to_a
    end

    def test_failed_cas_discards_every_write
      atom = Strict::Atom.new(1)
      map = Strict::Map.new({ a: 2 })

      refute(Farce.transaction do |tx|
        tx[map].clear
        tx[atom].compare_and_set(0, 3)
      end)
      assert_equal 1, atom.value
      assert_equal({ a: 2 }, map.to_h)
    end

    def test_exception_discards_changes
      atom = Strict::Atom.new(1)
      assert_raises(RuntimeError) do
        Farce.transaction do |tx|
          tx[atom].value = 2
          raise "abort"
        end
      end
      assert_equal 1, atom.value
    end

    def test_concurrent_write_is_preserved_on_conflict
      atom = Strict::Atom.new(1)
      other = Strict::Atom.new(0)

      refute(Farce.transaction do |tx|
        tx[atom].value = 2
        tx[other].value = 1
        Thread.new { atom.value = 3 }.join
      end)
      assert_equal 3, atom.value
      assert_equal 0, other.value
    end

    def test_retry_starts_with_fresh_views
      atom = Strict::Atom.new(0)
      attempts = 0

      assert(Transaction.run(retries: 1) do |tx|
        attempts += 1
        tx[atom].update { |value| value + 1 }
        atom.value = 10 if attempts == 1
      end)
      assert_equal 2, attempts
      assert_equal 11, atom.value
    end

    def test_custom_wrapper_composes_one_transaction
      balance = Strict::Atom.new(20)
      ledger = Strict::Map.new
      account = Account.new(balance, ledger)

      assert(Farce.transaction do |tx|
        assert_same tx[account], tx[account]
        tx[account].withdraw(5)
      end)
      assert_equal 15, balance.value
      assert_equal 5, ledger[:withdrawal]

      refute(Farce.transaction do |tx|
        tx[account].withdraw(5)
        tx[balance].compare_and_set(99, 0)
      end)
      assert_equal 15, balance.value
      assert_equal 5, ledger[:withdrawal]
    end

    def test_ignored_false_cas_poison_attempt
      first = Strict::Atom.new(1)
      second = Strict::Atom.new(2)

      refute(Farce.transaction do |tx|
        refute tx[first].compare_and_set(0, 4)
        tx[second].value = 3
        true
      end)
      assert_equal 1, first.value
      assert_equal 2, second.value
    end

    def test_exception_is_not_retried
      atom = Strict::Atom.new(0)
      attempts = 0
      assert_raises(ArgumentError) do
        Transaction.run(retries: 3) do |tx|
          attempts += 1
          tx[atom].value = 1
          raise ArgumentError, "bad input"
        end
      end
      assert_equal 1, attempts
      assert_equal 0, atom.value
    end

    def test_abort_is_not_retried_even_when_rescued
      atom = Strict::Atom.new(0)
      attempts = 0

      refute(Transaction.run(retries: 3) do |tx|
        attempts += 1
        tx[atom].value = 1
        begin
          tx.abort!
        rescue StandardError
          # Deliberately try to continue a rejected attempt.
        end
      end)
      assert_equal 1, attempts
      assert_equal 0, atom.value
    end

    def test_retry_limit_and_failed_cas_retry
      atom = Strict::Atom.new(0)
      attempts = 0

      refute(Transaction.run(retries: 2) do |tx|
        attempts += 1
        tx[atom].compare_and_set(1, 2)
      end)
      assert_equal 3, attempts
      assert_equal 0, atom.value
    end

    def test_retry_option_validation
      [-1, nil, true, 1.0].each do |retries|
        assert_raises(ArgumentError) { Transaction.run(retries:) { true } }
      end
      assert_raises(LocalJumpError) { Transaction.run }
    end

    def test_wrapper_lifetime_and_attempt_state
      atom = Strict::Atom.new(0)
      wrapper = nil
      transaction = Transaction.new

      assert(transaction.run do |tx|
        wrapper = tx[atom]
        wrapper.value = 1
      end)
      assert_equal :committed, transaction.state
      assert_raises(Transaction::ClosedError) { wrapper.value = 2 }
      assert_raises(Transaction::ClosedError) { wrapper.value }
      assert_raises(Transaction::ClosedError) { transaction.run { true } }
      assert_equal 1, atom.value
    end

    def test_failed_attempt_wrappers_cannot_be_reused_by_retry
      atom = Strict::Atom.new(0)
      stale = nil
      attempts = 0

      assert(Transaction.run(retries: 1) do |tx|
        attempts += 1
        if attempts == 1
          stale = tx[atom]
          stale.value = 1
          atom.value = 2
        else
          assert_raises(Transaction::ClosedError) { stale.value }
          tx[atom].value = 3
        end
      end)
      assert_equal 3, atom.value
    end

    def test_wrappers_are_owned_by_the_attempt_fiber
      atom = Strict::Atom.new(0)

      assert(Farce.transaction do |tx|
        wrapper = tx[atom]
        error = Fiber.new do
          wrapper.value
        rescue StandardError => e
          e
        end.resume

        assert_instance_of Transaction::OwnershipError, error
        wrapper.value = 1
      end)
      assert_equal 1, atom.value
    end

    def test_nonlocal_exit_does_not_commit
      atom = Strict::Atom.new(0)
      catch(:stop) do
        Farce.transaction do |tx|
          tx[atom].value = 1
          throw :stop
        end
      end

      assert_equal 0, atom.value
    end

    def test_frozen_participant_prevents_other_writes
      atom = Strict::Atom.new(0)
      vector = Strict::Vector.new([1])

      refute(Farce.transaction do |tx|
        tx[atom].value = 1
        tx[vector][0] = 2
        vector.freeze
      end)
      assert_equal 0, atom.value
      assert_equal [1], vector.to_a
    end

    def test_rescued_operation_error_poison_attempt
      atom = Strict::Atom.new(0)
      vector = Strict::Vector.new([1])

      refute(Farce.transaction do |tx|
        tx[atom].value = 1
        assert_raises(IndexError) { tx[vector][-5] = 2 }
      end)
      assert_equal 0, atom.value
      assert_equal [1], vector.to_a
    end

    def test_map_clear_conflict_preserves_clear_and_discards_atom_change
      atom = Strict::Atom.new(0)
      map = Strict::Map.new({ x: 1 })

      refute(Farce.transaction do |tx|
        tx[map][:x] = 2
        tx[atom].value = 1
        Thread.new { map.clear }.join
      end)
      assert_empty map
      assert_equal 0, atom.value
    end

    def test_active_update_reservation_rejects_transaction
      atom = Strict::Atom.new(0)
      other = Strict::Atom.new(0)
      atom.update do |current|
        refute(Farce.transaction do |tx|
          tx[atom].value = 1
          tx[other].value = 1
        end)
        current + 2
      end

      assert_equal 2, atom.value
      assert_equal 0, other.value
    end

    def test_active_map_reservation_rejects_transaction
      map = Strict::Map.new({ x: 0 })
      atom = Strict::Atom.new(0)
      map.update(:x) do |value|
        refute(Farce.transaction do |tx|
          tx[map][:y] = 1
          tx[atom].value = 1
        end)
        value + 2
      end

      assert_equal({ x: 2 }, map.to_h)
      assert_equal 0, atom.value
    end

    def test_normalized_keys_and_nil_presence
      map = Map.new({ "empty" => nil }, normalize_keys: :to_sym)

      assert(Farce.transaction do |tx|
        assert tx[map].key?("empty")
        assert tx[map].compare_and_set("empty", nil, 1)
        tx[map].store_if_absent("new") { 2 }

        assert_equal 2, tx[map].fetch("new")
      end)
      assert_equal({ empty: 1, new: 2 }, map.to_h)
      refute(Farce.transaction { |tx| tx[map].compare_and_set(:absent, nil, 3) })
      refute map.key?(:absent)
    end

    def test_atom_map_and_vector_value_modes
      atom = Atom.new([1])
      map = Map.new({ x: [2] })
      vector = Vector.new([[3]])

      assert(Farce.transaction do |tx|
        assert tx[atom].compare_and_set([1], [4])
        tx[map].update(:x) { |value| value + [5] }

        assert tx[vector].compare_and_set(0, [3], [6])
      end)
      assert_equal [4], atom.value
      assert_equal [2, 5], map[:x]
      assert_equal [[6]], vector.to_a
    end

    def test_identity_comparisons
      first = "same"
      other = first.dup.freeze
      atom = Strict::Atom.new(first, compare_by_identity: true)

      refute(Farce.transaction { |tx| tx[atom].compare_and_set(other, :changed) })
      assert_same first, atom.value
      assert(Farce.transaction { |tx| tx[atom].compare_and_set(first, :changed) })
      assert_equal :changed, atom.value
    end

    def test_map_structural_changes
      map = Strict::Map.new({ old: 1 })

      assert(Farce.transaction do |tx|
        tx[map].clear
        100.times { |i| tx[map][i] = i }

        assert_equal 4, tx[map].delete(4)
        assert_equal 3, tx[map].swap(3, 9)
      end)
      assert_equal 99, map.size
      assert_equal 9, map[3]
      refute map.key?(:old)
      refute map.key?(4)
    end

    def test_vector_structural_changes
      vector = Strict::Vector.new([1, 2])

      assert(Farce.transaction do |tx|
        assert_equal 2, tx[vector].pop
        tx[vector][40] = 3
        tx[vector].update(-1) { |value| value + 1 }
      end)
      assert_equal 41, vector.size
      assert_equal 4, vector[-1]
      assert_equal 1, vector[0]
      assert vector.to_a[1...40].all?(&:nil?)
    end

    def test_unsupported_participant_discards_other_writes
      atom = Strict::Atom.new(0)
      assert_raises(TypeError) do
        Farce.transaction do |tx|
          tx[atom].value = 1
          tx[Counter.new]
        end
      end
      assert_equal 0, atom.value
    end

    def test_irreversible_transfer_is_rejected_before_it_runs
      atom = Atom.new(:original)
      %i[move make_shareable dedup proxy].each do |mode|
        input = [1]
        assert_raises(TypeError) { Farce.transaction { |tx| tx[atom].store(input, mode:) } }
        refute_predicate input, :frozen?
        assert_equal [1], input
        assert_equal :original, atom.value
      end
    end

    def test_waiters_are_notified_after_commit
      atom = Strict::Atom.new(0)
      started = Queue.new
      waiter = Thread.new do
        started << true
        atom.wait_until_changed(0, timeout: 2)
      end
      started.pop

      # The waiter briefly holds the same mutex while entering its wait.
      assert(Farce.transaction(retries: 100) { |tx| tx[atom].value = 1 })
      assert_equal 1, waiter.value
    ensure
      waiter&.kill
      waiter&.join
    end

    def test_contending_threads_do_not_lose_updates
      first = Strict::Atom.new(0)
      second = Strict::Atom.new(0)
      workers = 3.times.map do
        Thread.new do
          50.times do
            committed = Farce.transaction(retries: 1000) do |tx|
              tx[first].update { |value| value + 1 }
              tx[second].update { |value| value + 1 }
            end
            raise "retry limit exceeded" unless committed
          end
        end
      end
      workers.each(&:value)

      assert_equal 150, first.value
      assert_equal 150, second.value
    ensure
      workers&.each(&:kill)
      workers&.each(&:join)
    end

    def test_native_ractors_commit_shared_values
      return unless Internal.native_ractors?
      Farce.transaction { true }
      first = Strict::Atom.new(0)
      second = Strict::Atom.new(0)
      workers = 2.times.map do
        Ractor.new(first, second) do |a, b|
          30.times do
            committed = Farce.transaction(retries: 1000) do |tx|
              tx[a].update { |value| value + 1 }
              tx[b].update { |value| value + 1 }
            end
            raise "retry limit exceeded" unless committed
          end
          true
        end
      end
      workers.each { assert ractor_value(it) }

      assert_equal 60, first.value
      assert_equal 60, second.value
    end

    def test_snapshot_survives_gc_and_compaction
      atom = Strict::Atom.new("before")
      map = Strict::Map.new({ a: "before" })
      vector = Strict::Vector.new(["before"])

      assert(Farce.transaction do |tx|
        tx[atom].value = "after"
        tx[map][:b] = "after"
        tx[vector].push("after")
        GC.start
        GC.compact if GC.respond_to?(:compact)
      end)
      assert_equal "after", atom.value
      assert_equal "after", map[:b]
      assert_equal %w[before after], vector.to_a
    end

    def test_rescued_programming_errors_are_not_retried
      atom = Strict::Atom.new(0)
      vector = Strict::Vector.new([1])
      attempts = 0

      refute(Transaction.run(retries: 2) do |tx|
        attempts += 1
        tx[atom].value = 1
        assert_raises(IndexError) { tx[vector][-100] = 2 }
      end)
      assert_equal 1, attempts
      assert_equal 0, atom.value
    end

    def test_thread_cancellation_discards_staged_changes
      atom = Strict::Atom.new(0)
      map = Strict::Map.new
      started = Queue.new
      resume = Queue.new
      worker = Thread.new do
        Farce.transaction do |tx|
          tx[atom].value = 1
          tx[map][:a] = 2
          started << true
          resume.pop
        end
      end
      started.pop
      worker.kill
      worker.join

      assert_equal 0, atom.value
      assert_empty map
    ensure
      worker&.kill
      worker&.join
    end

    def test_unsupported_wrapper_method_invalidates_attempt
      atom = Strict::Atom.new(0)

      refute(Farce.transaction do |tx|
        tx[atom].value = 1
        assert_raises(NoMethodError) { tx[atom].unsupported_operation }
      end)
      assert_equal 0, atom.value
    end

    def test_vector_initialization_operations
      vector = Vector.new([nil])

      assert(Farce.transaction do |tx|
        assert_equal [1], tx[vector].store_if_absent(0) { [1] }
        assert_equal [1], tx[vector].store_if_absent(0) { raise "already present" }
        assert_equal [1, 2], tx[vector].upsert(0, []) { |value| value + [2] }
        assert_equal [3], tx[vector].upsert(1, [3]) { raise "missing" }
      end)
      assert_equal [[1, 2], [3]], vector.to_a
    end

    def test_mixed_local_unshared_and_strict_containers
      objects = [Local, Unshared, Strict].flat_map do |namespace|
        [namespace::Atom.new(1), namespace::Map.new({ value: 1 }), namespace::Vector.new([1])]
      end

      assert(Farce.transaction do |tx|
        objects.each_slice(3) do |atom, map, vector|
          assert_instance_of Transaction::Atom, tx[atom]
          assert_instance_of Transaction::Map, tx[map]
          assert_instance_of Transaction::Vector, tx[vector]
          tx[atom].value = 2
          tx[map][:value] = 2
          tx[vector][0] = 2
        end
      end)
      objects.each_slice(3) do |atom, map, vector|
        assert_equal [2, 2, 2], [atom.value, map[:value], vector[0]]
      end

      refute(Farce.transaction do |tx|
        objects.each_slice(3) do |atom, map, vector|
          tx[atom].value = 3
          tx[map][:value] = 3
          tx[vector][0] = 3
        end
        tx[objects.last].compare_and_set(0, 99, 4)
      end)
      objects.each_slice(3) do |atom, map, vector|
        assert_equal [2, 2, 2], [atom.value, map[:value], vector[0]]
      end
    end

    def test_mixed_backend_conflict_discards_portable_writes
      local = Local::Atom.new(1)
      strict = Strict::Map.new({ value: 1 })

      refute(Farce.transaction do |tx|
        tx[local].value = 2
        tx[strict][:value] = 2
        strict[:other] = 3
      end)
      assert_equal 1, local.value
      assert_equal({ value: 1, other: 3 }, strict.to_h)
    end

    def test_local_map_scope_is_preserved
      map = Local::Map.new({ value: 1 }, scope: :fiber)
      strict = Strict::Map.new

      assert(Farce.transaction do |tx|
        tx[map][:value] = 2
        tx[strict][:value] = 2
        Fiber.new do
          assert_equal 1, map[:value]
          map[:value] = 3
        end.resume
      end)
      assert_equal 2, map[:value]
      assert_equal 2, strict[:value]
    end

    def test_local_freeze_in_another_scope_invalidates_transaction
      map = Local::Map.new({ value: 1 }, scope: :fiber)
      strict = Strict::Atom.new(1)

      refute(Farce.transaction do |tx|
        tx[map][:value] = 2
        tx[strict].value = 2
        Fiber.new { map.freeze }.resume
      end)
      assert_equal 1, map[:value]
      assert_equal 1, strict.value
    end

    def test_transaction_and_wrappers_are_explicitly_unshareable
      transaction = Transaction.new

      assert_kind_of Unshareable, transaction
      assert(transaction.run do |tx|
        [Atom.new, Map.new, Vector.new].each do |object|
          wrapper = tx[object]

          assert_kind_of Unshareable, wrapper
          refute_predicate wrapper, :ractor_shareable?
          next unless Internal.native_ractors?

          refute Ractor.shareable?(wrapper)
          refute_respond_to wrapper, :freeze
          Object.instance_method(:freeze).bind_call(wrapper)

          refute Ractor.shareable?(wrapper)
        end
      end)
    end

    def test_unshared_map_conflicts_and_preserves_mutable_values
      value = []
      map = Unshared::Map.new({ value: value })
      strict = Strict::Atom.new(1)

      assert(Farce.transaction do |tx|
        assert_same value, tx[map][:value]
        tx[map][:other] = value
        tx[strict].value = 2
      end)
      assert_same value, map[:other]
      refute(Farce.transaction do |tx|
        tx[map][:other] = []
        tx[strict].value = 3
        map[:external] = value
      end)
      assert_same value, map[:external]
      assert_same value, map[:other]
      assert_equal 2, strict.value
    end

    def test_unshared_map_reservation_rejects_mixed_transaction
      map = Unshared::Map.new({ value: 1 })
      strict = Strict::Map.new
      map.update(:value) do |value|
        refute(Farce.transaction do |tx|
          tx[map][:other] = 2
          tx[strict][:value] = 2
        end)
        value + 1
      end

      assert_equal({ value: 2 }, map.to_h)
      assert_empty strict
    end

    def test_contending_mixed_maps_do_not_lose_updates
      local = Local::Map.new({ value: 0 })
      unshared = Unshared::Map.new({ value: 0 })
      strict = Strict::Map.new({ value: 0 })
      workers = 3.times.map do
        Thread.new do
          30.times do
            committed = Farce.transaction(retries: 1000) do |tx|
              [local, unshared, strict].each { |map| tx[map].update(:value) { it + 1 } }
            end
            raise "retry limit exceeded" unless committed
          end
        end
      end
      workers.each(&:value)

      [local, unshared, strict].each { assert_equal 90, it[:value] }
    ensure
      workers&.each(&:kill)
      workers&.each(&:join)
    end

    def test_local_and_strict_maps_in_another_ractor
      return unless Internal.native_ractors?
      local = Local::Map.new({ value: 1 })
      strict = Strict::Map.new({ value: 1 })
      Farce.transaction { true }
      worker = Ractor.new(local, strict) do |map, shared|
        committed = Farce.transaction do |tx|
          tx[map][:value] = 2
          tx[shared][:value] = 2
        end
        [committed, map[:value]]
      end

      assert_equal [true, 2], ractor_value(worker)
      assert_equal 1, local[:value]
      assert_equal 2, strict[:value]
    end

    def test_local_map_normalization_runs_once
      map = Local::Map.new(normalize_keys: :succ)

      assert(Farce.transaction do |tx|
        tx[map]["a"] = 1

        assert_equal 1, tx[map]["a"]
        assert tx[map].compare_and_set("a", 1, 2)
      end)
      assert_equal({ "b" => 2 }, map.to_h)
    end
  end
end
