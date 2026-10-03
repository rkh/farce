# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/concurrent"

module Farce
  class ConcurrentTests < Test
    if RUBY_ENGINE == "ruby" && RUBY_VERSION >= "4" && !Gem.win_platform?
      def test_external_commit_allows_read_only_concurrent_tvars
        require "farce/integrations/ractor_sharing"
        foreign = ::Ractor::TVar.new(0)
        concurrent = ::Concurrent::TVar.new(2)
        atom = Strict::Atom.new(0)

        assert(Transaction.run do |tx|
          tx[foreign].value = tx[concurrent].value
          tx[atom].value = tx[concurrent].value
        end)
        assert_equal [2, 2, 2], [foreign.value, concurrent.value, atom.value]
      end

      def test_external_commit_rejects_writable_concurrent_tvars_before_publication
        require "farce/integrations/ractor_sharing"
        foreign = ::Ractor::TVar.new(0)
        concurrent = ::Concurrent::TVar.new(0)
        atom = Strict::Atom.new(0)
        vector = Unshared::Vector.new([0])

        assert_raises(TypeError) do
          Transaction.run do |tx|
            tx[foreign].value = 1
            tx[concurrent].value = 1
            tx[atom].value = 1
            tx[vector][0] = 1
          end
        end
        assert_equal [0, 0, 0, [0]], [foreign.value, concurrent.value, atom.value, vector.to_a]
        assert(Transaction.run do |tx|
          tx[concurrent].value = 2
          tx[atom].value = 2
        end)
      end
    end
    def test_commit_with_native_and_portable_participants
      tvar = ::Concurrent::TVar.new(10)
      other = ::Concurrent::TVar.new(0)
      atom = Strict::Atom.new(0)
      local = Local::Map.new
      unshared = Unshared::Vector.new

      assert(Transaction.run(tvar) do |tx, reference|
        assert_same tx[tvar], reference
        assert_same reference, tx[reference]
        reference.value -= 3
        tx[other].value += 1
        tx[atom].value += 3
        tx[local][:value] = 4
        tx[unshared] << 5

        assert_equal 7, reference.value
        assert_equal 7, tx.enlist(tvar).working.value
        assert_equal 0, atom.value
        assert_empty local
        assert_empty unshared
      end)
      assert_equal 7, tvar.value
      assert_equal 1, other.value
      assert_equal 3, atom.value
      assert_equal({ value: 4 }, local.to_h)
      assert_equal [5], unshared.to_a
    end

    def test_values_keep_identity_and_allow_nil_and_false
      tvar = ::Concurrent::TVar.new(nil)
      value = []

      assert(Farce.transaction do |tx|
        assert_nil tx[tvar].value
        tx[tvar].value = false

        refute tx[tvar].value
        tx[tvar].value = value

        assert_same value, tx[tvar].value
      end)
      assert_same value, tvar.value
    end

    def test_abort_and_failed_comparison_discard_all_writes
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)
      [true, false].each do |abort|
        refute(Farce.transaction(retries: 0) do |tx|
          tx[tvar].value = 2
          tx[atom].value = 2
          abort ? tx.abort! : tx[atom].compare_and_set(99, 3)
        end)
        assert_equal 1, tvar.value
        assert_equal 1, atom.value
      end
    end

    def test_exception_and_nonlocal_exit_discard_writes
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)

      assert_raises(RuntimeError) do
        Farce.transaction do |tx|
          tx[tvar].value = 2
          tx[atom].value = 2
          raise "stop"
        end
      end
      catch(:stop) do
        Farce.transaction do |tx|
          tx[tvar].value = 3
          tx[atom].value = 3
          throw :stop
        end
      end

      assert_equal 1, tvar.value
      assert_equal 1, atom.value
    end

    def test_locked_tvar_discards_already_staged_farce_and_tvar_writes
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)
      other = ::Concurrent::TVar.new(1)
      locked = Queue.new
      release = Queue.new
      worker = Thread.new do
        ::Concurrent.atomically do
          tvar.value = 3
          locked << true
          release.pop
        end
      end
      locked.pop

      refute(Farce.transaction(retries: 0) do |tx|
        tx[atom].value = 2
        tx[other].value = 2
        tx[tvar].value = 2
      end)
      assert_equal 1, atom.value
      assert_equal 1, other.value
      release << true
      worker.value

      assert_equal 3, tvar.value
    ensure
      worker&.kill
      worker&.join
    end

    def test_read_only_enrollment_holds_lock_until_attempt_finishes
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)

      assert(Farce.transaction do |tx|
        assert_equal 1, tx[tvar].value
        refute Thread.new { tvar.unsafe_lock.try_lock }.value
        tx[atom].value = 2
      end)
      assert_equal 1, tvar.value
      assert_equal 2, atom.value
    end

    def test_farce_conflict_restores_tvar_before_unlocking
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)
      local = Local::Atom.new(1)

      refute(Farce.transaction(retries: 0) do |tx|
        tx[tvar].value = 2
        tx[atom].value = 2
        tx[local].value = 2
        atom.value = 3
      end)
      assert_equal 1, tvar.value
      assert_equal 3, atom.value
      assert_equal 1, local.value
    end

    def test_retry_takes_a_fresh_snapshot
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(0)
      attempts = 0
      stale = nil

      assert(Farce.transaction(retries: 1) do |tx|
        attempts += 1
        if attempts == 1
          stale = tx[tvar]
          tx.fail!
        else
          assert_raises(Transaction::ClosedError) { stale.value }
        end
        tx[tvar].value += 1
        tx[atom].value = tx[tvar].value
      end)
      assert_equal 2, attempts
      assert_equal 2, tvar.value
      assert_equal 2, atom.value
    end

    def test_wrapper_lifetime_and_fiber_ownership
      tvar = ::Concurrent::TVar.new(1)
      wrapper = nil

      assert(Farce.transaction do |tx|
        wrapper = tx[tvar]

        assert_kind_of Unshareable, wrapper
        refute_predicate wrapper, :ractor_shareable?
        error = Fiber.new do
          wrapper.value
        rescue StandardError => e
          e
        end.resume

        assert_instance_of Transaction::OwnershipError, error
      end)
      assert_raises(Transaction::ClosedError) { wrapper.value }
      assert_raises(Transaction::ClosedError) { wrapper.value = 2 }
      assert_equal 1, tvar.value
    end

    def test_rescued_unsupported_operation_invalidates_attempt
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)

      refute(Farce.transaction(retries: 0) do |tx|
        tx[tvar].value = 2
        tx[atom].value = 2
        assert_raises(NoMethodError) { tx[tvar].unsafe_value = 3 }
      end)
      assert_equal 1, tvar.value
      assert_equal 1, atom.value
    end

    def test_frozen_tvar_rejects_writes
      tvar = ::Concurrent::TVar.new(1).freeze
      atom = Strict::Atom.new(1)

      assert(Farce.transaction { |tx| assert_equal 1, tx[tvar].value })
      assert_raises(FrozenError) do
        Farce.transaction do |tx|
          tx[atom].value = 2
          tx[tvar].value = 2
        end
      end
      assert_equal 1, atom.value
      assert_equal 1, tvar.value
    end

    def test_freezing_after_staging_prevents_commit
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)

      refute(Farce.transaction(retries: 0) do |tx|
        tx[tvar].value = 2
        tx[atom].value = 2
        tvar.freeze
      end)
      assert_equal 1, tvar.value
      assert_equal 1, atom.value
    end

    def test_snapshot_of_tvar_locked_by_concurrent_transaction_conflicts
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)

      ::Concurrent.atomically do
        assert_equal 1, tvar.value
        refute(Farce.transaction(retries: 0) do |tx|
          tx[atom].value = 2
          tx[tvar].value = 2
        end)
      end
      assert_equal 1, atom.value
      assert_equal 1, tvar.value
    end

    def test_busy_lock_retries_with_a_fresh_attempt
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)
      locked = Queue.new
      release = Queue.new
      worker = Thread.new do
        ::Concurrent.atomically do
          tvar.value = 3
          locked << true
          release.pop
        end
      end
      locked.pop
      attempts = 0

      assert(Farce.transaction(retries: 1) do |tx|
        attempts += 1
        tx[atom].value += 1
        if attempts == 2
          release << true
          worker.value
        end
        tx[tvar].value += 1
      end)
      assert_equal 2, attempts
      assert_equal 4, tvar.value
      assert_equal 2, atom.value
    ensure
      worker&.kill
      worker&.join
    end

    def test_reversed_enrollment_order_conflicts_without_waiting
      first = ::Concurrent::TVar.new(1)
      second = ::Concurrent::TVar.new(1)
      enrolled = Queue.new
      proceed = Queue.new
      worker = Thread.new do
        Farce.transaction(retries: 0) do |tx|
          tx[second].value = 2
          enrolled << true
          proceed.pop
          tx[first].value = 2
        end
      end
      enrolled.pop

      refute(Farce.transaction(retries: 0) do |tx|
        tx[first].value = 3
        proceed << true

        refute worker.value
        tx.fail!
      end)
      assert_equal 1, first.value
      assert_equal 1, second.value
    ensure
      worker&.kill
      worker&.join
    end

    def test_failed_snapshot_releases_its_lock
      tvar = ::Concurrent::TVar.new(1)
      def tvar.unsafe_value = raise "snapshot failed"

      assert_raises(RuntimeError) { Farce.transaction { |tx| tx[tvar] } }
      assert tvar.unsafe_lock.try_lock
    ensure
      tvar&.unsafe_lock&.unlock if tvar&.unsafe_lock&.owned?
    end

    def test_cancellation_during_enrollment_releases_lock
      tvar = ::Concurrent::TVar.new(1)
      started = Queue.new
      release = Queue.new
      tvar.define_singleton_method(:unsafe_value) do
        started << true
        release.pop
        1
      end
      worker = Thread.new { Farce.transaction { |tx| tx[tvar] } }
      started.pop
      worker.kill
      release << true
      worker.join

      assert tvar.unsafe_lock.try_lock
    ensure
      worker&.kill
      worker&.join
      tvar&.unsafe_lock&.unlock if tvar&.unsafe_lock&.owned?
    end

    def test_thread_cancellation_discards_staged_changes
      tvar = ::Concurrent::TVar.new(1)
      atom = Strict::Atom.new(1)
      started = Queue.new
      release = Queue.new
      worker = Thread.new do
        Farce.transaction do |tx|
          tx[tvar].value = 2
          tx[atom].value = 2
          started << true
          release.pop
        end
      end
      started.pop
      worker.kill
      worker.join

      assert_equal 1, tvar.value
      assert_equal 1, atom.value
    ensure
      worker&.kill
      worker&.join
    end

    def test_contending_farce_and_concurrent_transactions_do_not_lose_updates
      first = ::Concurrent::TVar.new(0)
      second = ::Concurrent::TVar.new(0)
      atom = Strict::Atom.new(0)
      workers = 3.times.map do
        Thread.new do
          30.times do
            committed = Farce.transaction(retries: 1000) do |tx|
              tx[first].value += 1
              tx[second].value += 1
              tx[atom].value += 1
            end
            raise "retry limit exceeded" unless committed
          end
        end
      end
      workers << Thread.new do
        30.times do
          ::Concurrent.atomically do
            first.value += 1
            second.value += 1
          end
        end
      end
      workers.each(&:value)

      assert_equal 120, first.value
      assert_equal 120, second.value
      assert_equal 90, atom.value
    ensure
      workers&.each(&:kill)
      workers&.each(&:join)
    end
  end
end
