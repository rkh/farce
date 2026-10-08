# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "pp"

module Farce
  class TestMutableTransaction < Test
    include Helpers::InternalTestHelpers

    class Payload
      attr_reader :value

      def initialize(value)
        @value = value
      end

      def add(amount, offset:, &block)
        @value += block.call(amount + offset)
        self
      end

      def fail_after_write
        @value += 1
        raise ArgumentError, "mutation failed"
      end
    end

    def test_commits_mutable_values_with_other_participants
      first = Mutable.new(+"queued")
      second = Mutable.new([1])
      atom = Atom.new(0)
      map = Map.new
      vector = Vector.new
      snapshot = Mutable.deref(first)

      assert(Farce.transaction(first, second, atom, map, vector) do |tx, text, list, count, mapping, sequence|
        assert_operator Transaction::Mutable, :===, text
        assert_same text, tx[first]
        assert_same text, tx[text]
        refute_respond_to text, :freeze
        refute Ractor.shareable?(text) if Internal.native_ractors?

        assert_same text, text.replace("running")
        assert_same list, list.push(2)
        count.value = 1
        mapping[:state] = :running
        sequence.push(:started)

        assert_equal "running", Mutable.deref(text)
        assert_equal [1, 2], Mutable.deref(list)
        assert_equal "queued", Mutable.deref(first)
        assert_equal [1], Mutable.deref(second)
        assert_equal 0, atom.value
        assert_empty map
        assert_empty vector
      end)
      assert_equal "queued", snapshot
      assert_equal "running", Mutable.deref(first)
      assert_equal [1, 2], Mutable.deref(second)
      assert_equal 1, atom.value
      assert_equal :running, map[:state]
      assert_equal [:started], vector.to_a
      assert_predicate Mutable.deref(first), :frozen?
      assert_predicate Mutable.deref(second), :frozen?
    end

    def test_abort_discards_all_staged_mutations
      mutable = Mutable.new([1])
      atom = Atom.new(0)
      snapshot = Mutable.deref(mutable)

      refute(Farce.transaction(mutable, atom) do |tx, view, reference|
        view.push(2)
        reference.value = 1
        tx.abort!
      end)
      assert_same snapshot, Mutable.deref(mutable)
      assert_equal 0, atom.value
    end

    def test_exception_discards_all_staged_mutations
      mutable = Mutable.new([1])
      atom = Atom.new(0)
      snapshot = Mutable.deref(mutable)

      assert_raises(ArgumentError) do
        Farce.transaction(mutable, atom) do |_, view, reference|
          view.push(2)
          reference.value = 1
          raise ArgumentError, "failed attempt"
        end
      end
      assert_same snapshot, Mutable.deref(mutable)
      assert_equal 0, atom.value
    end

    def test_nonlocal_exit_discards_staged_mutations
      mutable = Mutable.new([1])
      snapshot = Mutable.deref(mutable)
      catch(:stop) do
        Farce.transaction(mutable) do |_, view|
          view.push(2)
          throw :stop
        end
      end

      assert_same snapshot, Mutable.deref(mutable)
    end

    def test_forwards_arguments_keywords_blocks_and_mutation_results
      source = Payload.new(1)
      mutable = Mutable.new(source)

      assert(Farce.transaction(mutable) do |_, view|
        assert_same view, view.add(2, offset: 3) { it * 2 }
        assert_equal 11, view.value
        assert_predicate Mutable.deref(view), :frozen?
        assert_equal 1, mutable.value
      end)
      assert_equal 11, mutable.value
      assert_equal 1, source.value
    end

    def test_preserves_nil_and_scalar_mutation_results
      mutable = Mutable.new([1, 2])

      assert(Farce.transaction(mutable) do |_, view|
        assert_equal 2, view.pop
        assert_nil(view.reject! { false })
        assert_equal [1], Mutable.deref(view)
      end)
      assert_equal [1], Mutable.deref(mutable)
    end

    def test_rescued_mutation_error_poison_attempt
      mutable = Mutable.new(Payload.new(1))
      atom = Atom.new(0)
      snapshot = Mutable.deref(mutable)
      transaction = Transaction.new

      refute(transaction.run(mutable, atom) do |_, view, reference|
        view.add(2, offset: 0) { it }
        reference.value = 1
        error = assert_raises(ArgumentError) { view.fail_after_write }

        assert_equal "mutation failed", error.message
      end)
      refute_predicate transaction, :retryable?
      assert_same snapshot, Mutable.deref(mutable)
      assert_equal 0, atom.value
    end

    def test_rescued_missing_method_discards_prior_writes
      mutable = Mutable.new([1])
      atom = Atom.new(0)

      refute(Farce.transaction(retries: 0) do |tx|
        tx[mutable].push(2)
        tx[atom].value = 1
        assert_raises(NoMethodError) { tx[mutable].missing_method }
      end)
      assert_equal [1], Mutable.deref(mutable)
      assert_equal 0, atom.value
    end

    def test_rejected_nested_value_discards_other_participant_writes
      return unless Internal.native_ractors?
      mutable = Mutable.new([1])
      atom = Atom.new(0)
      child = []
      snapshot = Mutable.deref(mutable)

      refute(Farce.transaction(retries: 0) do |tx|
        tx[atom].value = 1
        assert_raises(Ractor::IsolationError) { tx[mutable].push(child) }
      end)
      assert_same snapshot, Mutable.deref(mutable)
      assert_equal 0, atom.value
      refute_predicate child, :frozen?
      mutable.push(2)

      assert_equal [1, 2], Mutable.deref(mutable)
    end

    def test_concurrent_mutation_conflicts_without_losing_the_live_write
      mutable = Mutable.new([1])
      atom = Atom.new(0)

      refute(Farce.transaction(retries: 0) do |tx|
        tx[mutable].push(2)
        tx[atom].value = 1
        Thread.new { mutable.push(3) }.value
      end)
      assert_equal [1, 3], Mutable.deref(mutable)
      assert_equal 0, atom.value
    end

    def test_retry_uses_a_fresh_snapshot_and_closes_the_previous_view
      mutable = Mutable.new([1])
      stale = nil
      attempts = 0

      assert(Farce.transaction(retries: 1) do |tx|
        attempts += 1
        view = tx[mutable]
        if attempts == 1
          stale = view
          view.push(2)
          Thread.new { mutable.push(3) }.value
        else
          assert_raises(Transaction::ClosedError) { stale.sum }
          assert_equal [1, 3], Mutable.deref(view)
          view.push(4)
        end
      end)
      assert_equal 2, attempts
      assert_equal [1, 3, 4], Mutable.deref(mutable)
    end

    def test_read_only_observation_conflicts_with_a_live_mutation
      mutable = Mutable.new([1])
      atom = Atom.new(0)

      refute(Farce.transaction(retries: 0) do |tx|
        assert_equal 1, tx[mutable].sum
        tx[atom].value = 1
        Thread.new { mutable.push(2) }.value
      end)
      assert_equal [1, 2], Mutable.deref(mutable)
      assert_equal 0, atom.value
    end

    def test_read_only_attempt_keeps_the_original_snapshot
      mutable = Mutable.new([1, 2])
      snapshot = Mutable.deref(mutable)

      assert(Farce.transaction(mutable) do |_, view|
        assert_equal 3, view.sum
        assert_same snapshot, Mutable.deref(view)
        assert_equal([2, 4], view.map { it * 2 })
        assert_equal 7, view.instance_exec(4) { sum + it }
        assert_same(snapshot, view.instance_eval { self })
      end)
      assert_same snapshot, Mutable.deref(mutable)
    end

    def test_freezing_before_commit_discards_all_staged_writes
      mutable = Mutable.new([1])
      atom = Atom.new(0)

      refute(Farce.transaction(retries: 0) do |tx|
        tx[mutable].push(2)
        tx[atom].value = 1
        Thread.new { mutable.freeze }.value
      end)
      assert_equal [1], Mutable.deref(mutable)
      assert_equal 0, atom.value
      assert_predicate mutable, :frozen?
    end

    def test_frozen_mutable_allows_read_only_transactions_and_rejects_writes
      mutable = Mutable.new([1]).freeze
      atom = Atom.new(0)

      assert(Farce.transaction(mutable) do |_, view|
        assert_equal 1, view.sum
        assert_predicate view, :frozen?
      end)
      refute(Farce.transaction(retries: 0) do |tx|
        tx[atom].value = 1
        assert_raises(FrozenError) { tx[mutable].push(2) }
      end)
      assert_equal [1], Mutable.deref(mutable)
      assert_equal 0, atom.value
    end

    def test_closed_views_reject_snapshot_access_and_metadata_reads
      mutable = Mutable.new([1])
      view = nil

      assert(Farce.transaction(mutable) { |_, wrapper| view = wrapper })
      %i[sum class inspect frozen? dup clone].each do |method|
        assert_raises(Transaction::ClosedError) { view.__send__(method) }
      end
      assert_raises(Transaction::ClosedError) { view.push(2) }
      assert_raises(Transaction::ClosedError) { Mutable.deref(view) }
      assert_raises(Transaction::ClosedError) { view.respond_to?(:sum) }
      assert_raises(Transaction::ClosedError) { view.is_a?(Mutable) }
      assert_raises(Transaction::ClosedError) { PP.pp(view, +"") }
    end

    def test_views_reject_other_fibers_without_poisoning_the_owner
      mutable = Mutable.new([1])

      assert(Farce.transaction(mutable) do |_, view|
        error = Fiber.new do
          view.push(2)
        rescue StandardError => e
          e
        end.resume

        assert_instance_of Transaction::OwnershipError, error
        view.push(3)
      end)
      assert_equal [1, 3], Mutable.deref(mutable)
    end

    def test_views_cannot_be_adopted_by_another_attempt
      mutable = Mutable.new([1])

      refute(Farce.transaction(retries: 0) do |tx|
        view = tx[mutable]
        view.push(2)
        assert_raises(TypeError) do
          Farce.transaction { |other| other[view] }
        end
      end)
      assert_equal [1], Mutable.deref(mutable)
    end

    def test_views_cannot_be_copied_or_frozen
      %i[dup clone freeze].each do |method|
        mutable = Mutable.new([1])

        refute(Farce.transaction(retries: 0) do |tx|
          view = tx[mutable]
          view.push(2)
          assert_raises(method == :freeze ? NoMethodError : TypeError) { view.__send__(method) }
        end)
        assert_equal [1], Mutable.deref(mutable)
      end
    end

    def test_factory_subclasses_keep_transaction_support
      factory = Mutable[Array]
      mutable = factory.new(2, 1)

      assert(Farce.transaction(mutable) do |_, view|
        view.push(2)

        assert_equal [1, 1, 2], Mutable.deref(view)
        assert_equal [1, 1], Mutable.deref(mutable)
      end)
      assert_equal [1, 1, 2], Mutable.deref(mutable)
      assert_operator factory, :===, mutable
    end

    def test_participant_lookup_uses_the_wrappers_class
      Transaction.define(Payload) { |_object, _transaction| :underlying_factory }
      mutable = Mutable.new(Payload.new(1))

      assert_same Payload, mutable.class
      assert(Farce.transaction(mutable) do |_, view|
        assert_operator Transaction::Mutable, :===, view
        view.add(1, offset: 0) { it }
      end)
      assert_equal 2, mutable.value
    end

    def test_mutable_values_stored_in_a_map_can_be_enrolled_explicitly
      map = Map.new({ first: +"queued", second: +"waiting" }, mode: :mutable)
      # Emulated Ractors pass ordinary strings through without a wrapper.
      return unless Internal.native_ractors?

      refute(Farce.transaction(retries: 0) do |tx|
        tx[tx[map][:first]].replace("running")
        tx[tx[map][:second]] << " for worker"
        tx.fail!(retryable: false)
      end)
      assert_equal "queued", map[:first].to_s
      assert_equal "waiting", map[:second].to_s
      assert(Farce.transaction do |tx|
        tx[tx[map][:first]].replace("running")
        tx[tx[map][:second]] << " for worker"
      end)
      assert_equal "running", map[:first].to_s
      assert_equal "waiting for worker", map[:second].to_s
    end

    def test_transactions_can_run_in_another_ractor
      mutable = Mutable.new([1])
      atom = Atom.new(0)
      worker = Ractor.new(mutable, atom) do |shared, reference|
        Farce.transaction(shared, reference) do |_, view, count|
          view.push(2)
          count.value = 1
        end
      end

      assert ractor_value(worker)
      assert_equal [1, 2], Mutable.deref(mutable)
      assert_equal 1, atom.value
    end

    def test_first_transaction_wrapper_can_load_in_another_ractor
      return unless Internal.native_ractors?
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        mutable = Farce::Mutable.new([1])
        Farce::Transaction
        abort "wrapper loaded eagerly" unless $LOADED_FEATURES.grep(%r{farce/transaction/}).empty?
        worker = Ractor.new(mutable) do |shared|
          Farce.transaction(shared) { |_, view| view.push(2) }
        end
        committed = worker.respond_to?(:value) ? worker.value : worker.take
        puts [committed, Farce::Mutable.deref(mutable)].inspect
      RUBY

      assert_predicate status, :success?, error
      assert_equal "[true, [1, 2]]\n", output
    end

    def test_readers_never_observe_a_staged_mutation
      mutable = Mutable.new([1])
      entered = Thread::Queue.new
      release = Thread::Queue.new
      worker = Thread.new do
        Farce.transaction(mutable) do |_, view|
          view.push(2)
          entered.push(true)
          release.pop
        end
      end
      entered.pop

      assert_equal [1], Mutable.deref(mutable)
      release.push(true)

      assert_predicate worker, :value
      assert_equal [1, 2], Mutable.deref(mutable)
    ensure
      release&.push(true)
      worker&.join
    end

    def test_unfrozen_shareable_targets_are_rejected_before_mutation
      return unless Internal.native_ractors?
      target = Counter.new(1)
      mutable = Mutable.new(target)
      atom = Atom.new(0)

      refute(Farce.transaction(retries: 0) do |tx|
        tx[atom].value = 1
        error = assert_raises(TypeError) { tx[mutable] }

        assert_equal "mutable transactions require a frozen snapshot", error.message
      end)
      assert_equal 1, target.value
      assert_equal 0, atom.value
    end
  end
end
