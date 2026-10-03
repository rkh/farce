# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby" && RUBY_VERSION >= "4" && !Gem.win_platform?

require_relative "../setup"
require "farce/integrations/ractor_sharing"
require "timeout"

module Farce
  class TestRactorTVarTransaction < Test
    module CommitHook
      def commit
        Thread.current[:farce_tvar_commit_hook]&.call
        super
      end
    end

    Integrations::RactorSharing::Commit.prepend(CommitHook)

    def test_mixed_publication
      variable = ::Ractor::TVar.new(10)
      atoms = [Strict::Atom.new(0), Atom.new(0), Unshared::Atom.new(0), Local::Atom.new(0)]
      vectors = [Strict::Vector.new([0]), Vector.new([0]), Unshared::Vector.new([0])]
      maps = [Strict::Map.new({ key: 0 }), Map.new({ key: 0 }), Unshared::Map.new({ key: 0 })]
      trees = [Strict::TreeMap.new({ 1 => 0 }), TreeMap.new({ 1 => 0 })]

      assert Transaction.run(variable) { |tx, value|
        value.value -= 3
        atoms.each { tx[it].value = 3 }
        vectors.each { tx[it][0] = 3 }
        maps.each { tx[it][:key] = 3 }
        trees.each { tx[it][1] = 3 }
      }
      assert_equal 7, variable.value
      atoms.each { assert_equal 3, it.value }
      vectors.each { assert_equal [3], it.to_a }
      maps.each { assert_equal 3, it[:key] }
      trees.each { assert_equal 3, it[1] }
    end

    def test_abort_and_wrapper_lifetime
      variable = ::Ractor::TVar.new(1)
      atom = Strict::Atom.new(1)
      wrapper = nil

      refute(Transaction.run do |tx|
        wrapper = tx[variable]
        wrapper.value = 2
        tx[atom].value = 2
        tx.abort!
      end)
      assert_equal [1, 1], [variable.value, atom.value]
      assert_raises(Transaction::ClosedError) { wrapper.value }
      assert_raises(Transaction::ClosedError) { wrapper.value = 3 }
    end

    def test_conflict_restores_portable_values_and_retries
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Unshared::Vector.new([0])
      count = 0

      with_hook(lambda {
        Thread.current[:farce_tvar_commit_hook] = nil
        ::Ractor.atomically { variable.value = 5 }
      }) do
        assert Transaction.run(retries: 1) { |tx|
          count += 1
          tx[variable].value += 1
          tx[atom].value += 1
          tx[vector][0] += 1
        }
      end
      assert_equal 2, count
      assert_equal [6, 1, [1]], [variable.value, atom.value, vector.to_a]
    end

    def test_exception_before_foreign_commit_restores_all_participants
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Unshared::Vector.new([0])
      attempt = Transaction.new

      with_hook(-> { raise "foreign step failed" }) do
        assert_raises(RuntimeError) do
          attempt.run do |tx|
            tx[variable].value = 1
            tx[atom].value = 1
            tx[vector][0] = 1
          end
        end
      end
      assert_equal :failed, attempt.state
      assert_equal [0, 0, [0]], [variable.value, atom.value, vector.to_a]
      assert(Transaction.run do |tx|
        tx[variable].value = 2
        tx[atom].value = 2
        tx[vector][0] = 2
      end)
    end

    def test_exception_after_stm_publication_finishes_farce_publication
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Unshared::Vector.new([0])
      attempt = Transaction.new
      trace = TracePoint.new(:c_return) do |event|
        next unless event.method_id == :atomically && event.self == ::Ractor
        trace.disable
        raise "after STM publication"
      end
      with_hook(-> { trace.enable }) do
        error = assert_raises(RuntimeError) do
          attempt.run do |tx|
            tx[variable].value = 1
            tx[atom].value = 1
            tx[vector][0] = 1
          end
        end
        assert_equal "after STM publication", error.message
      end
      assert_equal :committed, attempt.state
      assert_equal [1, 1, [1]], [variable.value, atom.value, vector.to_a]
      assert(Transaction.run do |tx|
        tx[variable].value = 2
        tx[atom].value = 2
        tx[vector][0] = 2
      end)
    ensure
      trace&.disable
    end

    def test_views_are_sealed_before_external_code
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      attempt = Transaction.new
      wrapper = nil

      with_hook(-> { wrapper.value = 9 }) do
        assert_raises(Transaction::ClosedError) do
          attempt.run do |tx|
            wrapper = tx[atom]
            wrapper.value = 1
            tx[variable].value = 1
          end
        end
      end
      assert_equal [0, 0], [variable.value, atom.value]
    end

    def test_native_and_portable_reader_reentry_raises
      [Strict::Atom.new(0), Strict::Vector.new([0]), Unshared::Vector.new([0]),
       Strict::Map.new({ key: 0 }), Strict::TreeMap.new({ 1 => 0 })].each do |object|
        variable = ::Ractor::TVar.new(0)
        read = case object
               when Abstract::Atom then -> { object.value }
               when Abstract::Vector then -> { object.each.to_a }
               when Abstract::TreeMap then -> { object[1] }
               else -> { object[:key] }
               end

        with_hook(read) do
          assert_raises(ThreadError) do
            Transaction.run do |tx|
              tx[variable].value = 1
              wrapped = tx[object]
              wrapped.size if Abstract::Map === object
            end
          end
        end
        assert_equal 0, variable.value
      end
    end

    def test_reserved_readers_and_freeze_wait_for_commit
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Strict::Vector.new([0])
      portable = Unshared::Vector.new([0])
      map = Strict::Map.new({ key: 0 })
      tree = Strict::TreeMap.new({ 1 => 0 })
      ready = Queue.new
      resume = Queue.new
      worker = Thread.new do
        with_hook(lambda {
          ready << true
          resume.pop
        }) do
          Transaction.run do |tx|
            tx[variable].value = 1
            tx[atom].value = 1
            tx[vector][0] = 1
            tx[vector].push(2)
            tx[portable][0] = 1
            tx[map][:key] = 1
            tx[tree][1] = 1
          end
        end
      end
      Timeout.timeout(5) { ready.pop }
      operations = [
        [-> { atom.value }, 1],
        [-> { atom.wait_until_non_nil }, 1],
        [-> { atom.wait_until_changed(-1) }, 1],
        [-> { vector[0] }, 1],
        [-> { vector.fetch(0) }, 1],
        [-> { vector.size }, 2],
        [-> { vector.to_a }, [1, 2]],
        [-> { vector.each.to_a }, [1, 2]],
        [-> { vector.reverse_each.to_a }, [2, 1]],
        [-> { portable.each.to_a }, [1]],
        [-> { portable.reverse_each.to_a }, [1]],
        [-> { map[:key] }, 1],
        [-> { tree[1] }, 1],
        [lambda {
          atom.freeze
          atom.value
        }, 1]
      ]
      entered = Queue.new
      readers = operations.map do |operation, expected|
        [Thread.new do
          entered << true
          operation.call
        end, expected]
      end
      operations.size.times { Timeout.timeout(5) { entered.pop } }

      readers.each { assert_nil it.first.join(0.01) }
      resume << true

      assert Timeout.timeout(5) { worker.value }
      readers.each { |reader, expected| assert_equal expected, Timeout.timeout(5) { reader.value } }
      assert_predicate atom, :frozen?
    ensure
      resume << true if worker&.alive?
      worker&.join(5)
      readers&.each { it.first.join(5) }
    end

    def test_read_only_and_size_only_reservations_release_on_failure
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(1)
      map = Strict::Map.new({ key: 1 })

      with_hook(-> { raise "abort reserved reads" }) do
        assert_raises(RuntimeError) do
          Transaction.run do |tx|
            tx[variable].value = 1
            tx[atom].value
            tx[map].size
          end
        end
      end
      assert_equal 1, atom.value
      assert_equal 1, map.size
      assert(Transaction.run do |tx|
        tx[variable].value = 1
        tx[atom].value
        tx[map].size
      end)
      assert_equal 1, variable.value
    end

    def test_nested_stm_is_rejected_before_publication
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)

      ::Ractor.atomically do
        assert_raises(ArgumentError) do
          Transaction.run do |tx|
            tx[atom].value = 1
            tx[variable].value = 1
          end
        end
      end
      assert_equal [0, 0], [variable.value, atom.value]
    end

    def test_value_conversion_and_same_source_enrollment
      variable = ::Ractor::TVar.new(nil)
      value = [1]

      assert(Transaction.run do |tx|
        assert_same tx[variable], tx[variable]
        assert_same tx[variable], tx[tx[variable]]
        tx[variable].value = value
      end)
      assert_same value, variable.value
      assert ::Ractor.shareable?(value)
      refute_respond_to variable, :transaction_snapshot
    end

    def test_local_freeze_from_another_scope_waits
      variable = ::Ractor::TVar.new(0)
      local = Local::Atom.new(0, scope: :fiber)
      ready = Queue.new
      resume = Queue.new
      entered = Queue.new
      worker = Thread.new do
        with_hook(lambda {
          ready << true
          resume.pop
        }) do
          Transaction.run do |tx|
            tx[variable].value = 1
            tx[local].value = 1
          end
        end
      end
      Timeout.timeout(5) { ready.pop }
      freezer = Thread.new do
        entered << true
        local.freeze
      end
      Timeout.timeout(5) { entered.pop }

      assert_nil freezer.join(0.02)
      resume << true

      assert Timeout.timeout(5) { worker.value }
      Timeout.timeout(5) { freezer.value }

      assert_predicate local, :frozen?
      assert_equal 1, variable.value
      assert_raises(FrozenError) { local.value = 2 }
    ensure
      resume << true if worker&.alive?
      worker&.join(5)
      freezer&.join(5)
    end

    def test_ready_result_waits_honor_timeouts_during_reservation
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(1)
      vector = Strict::Vector.new([1])
      ready = Queue.new
      resume = Queue.new
      worker = Thread.new do
        with_hook(lambda {
          ready << true
          resume.pop
        }) do
          Transaction.run do |tx|
            tx[variable].value = 1
            tx[atom].value
            tx[vector][0]
          end
        end
      end
      Timeout.timeout(5) { ready.pop }

      assert_nil atom.wait_until_non_nil(timeout: 0.01)
      assert_nil atom.wait_until_changed(0, timeout: 0.01)
      assert_nil vector.wait_until_non_nil(0, timeout: 0.01)
      assert_nil vector.wait_until_changed(0, 0, timeout: 0.01)
      resume << true

      assert Timeout.timeout(5) { worker.value }
      assert_equal 1, atom.value
      assert_equal [1], vector.to_a
    ensure
      resume << true if worker&.alive?
      worker&.join(5)
    end

    def test_gc_during_foreign_step
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Strict::Vector.new([0])

      with_hook(lambda {
        GC.start
        GC.compact
      }) do
        assert(Transaction.run do |tx|
          tx[variable].value = 1
          tx[atom].value = 1
          tx[vector][0] = 1
        end)
      end
      assert_equal [1, 1, [1]], [variable.value, atom.value, vector.to_a]
    end

    def test_source_changed_before_reservation_does_not_publish_tvars
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      portable = Unshared::Vector.new([0])

      refute Transaction.run(retries: 0) { |tx|
        tx[variable].value = 1
        tx[atom].value = 1
        tx[portable][0] = 1
        atom.value = 5
      }
      assert_equal [0, 5, [0]], [variable.value, atom.value, portable.to_a]
      assert(Transaction.run do |tx|
        tx[variable].value = 2
        tx[atom].value = 2
        tx[portable][0] = 2
      end)
    end

    def test_busy_participant_does_not_leave_partial_reservations
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Strict::Vector.new([0])
      ready = Queue.new
      resume = Queue.new
      worker = Thread.new do
        atom.update do
          ready << true
          resume.pop
          5
        end
      end
      Timeout.timeout(5) { ready.pop }

      refute Transaction.run(retries: 0) { |tx|
        tx[variable].value = 1
        tx[vector][0] = 1
        tx[atom].value = 1
      }
      assert_equal [0, [0]], [variable.value, vector.to_a]
      resume << true

      assert_equal 5, Timeout.timeout(5) { worker.value }
      assert(Transaction.run do |tx|
        tx[variable].value = 2
        tx[vector][0] = 2
        tx[atom].value = 2
      end)
    ensure
      resume << true if worker&.alive?
      worker&.join(5)
    end

    def test_ractor_can_commit_shared_participants
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Strict::Vector.new([0])
      worker = ::Ractor.new(variable, atom, vector) do |tvar, source, items|
        Farce.transaction do |tx|
          tx[tvar].value = 1
          tx[source].value = 1
          tx[items][0] = 1
        end
      end

      assert worker.value
      assert_equal [1, 1, [1]], [variable.value, atom.value, vector.to_a]
    end

    def test_foreign_exception_during_portable_lock_acquisition_releases_the_lock
      variable = ::Ractor::TVar.new(0)
      vector = Unshared::Vector.new([0])
      backend = vector.instance_variable_get(:@vector)
      mutex = backend.instance_variable_get(:@mutex)
      trace = TracePoint.new(:return, :c_return) do |event|
        next unless event.method_id == :try_lock && event.self.equal?(mutex)
        trace.disable
        raise "after lock acquisition"
      end
      assert_raises(RuntimeError) do
        Transaction.run do |tx|
          tx[variable].value = 1
          tx[vector][0] = 1
          trace.enable
        end
      end
      refute_predicate mutex, :locked?
      assert_equal [0, [0]], [variable.value, vector.to_a]
      assert(Transaction.run do |tx|
        tx[variable].value = 2
        tx[vector][0] = 2
      end)
    ensure
      trace&.disable
    end

    def test_frozen_participant_rejects_mixed_publication
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)

      refute Transaction.run(retries: 0) { |tx|
        tx[variable].value = 1
        tx[atom].value = 1
        atom.freeze
      }
      assert_equal [0, 0], [variable.value, atom.value]
    end

    def test_require_tvar_activates_transaction_integration
      output, error, status = ruby_isolated(<<~RUBY, coverage: false)
        $VERBOSE = true
        require "farce"
        require "ractor/tvar"
        tvar = Ractor::TVar.new(0)
        raise "integration missing" unless Farce.transaction { |tx| tx[tvar].value = 1 }
        raise "wrong value" unless tvar.value == 1
      RUBY
      assert_predicate status, :success?, "#{output}\n#{error}"
      refute_includes error, "circular require"
    end

    def test_async_exception_is_deferred_until_publication_finishes
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Unshared::Vector.new([0])
      attempt = nil
      ready = Queue.new
      resume = Queue.new
      worker = Thread.new do
        attempt = Transaction.new
        with_hook(lambda {
          ready << true
          resume.pop
        }) do
          attempt.run do |tx|
            tx[variable].value = 1
            tx[atom].value = 1
            tx[vector][0] = 1
          end
        end
      rescue RuntimeError => e
        e.message
      end
      Timeout.timeout(5) { ready.pop }
      worker.raise(RuntimeError, "cancel during commit")
      resume << true

      assert_equal "cancel during commit", Timeout.timeout(5) { worker.value }
      assert_equal :committed, attempt.state
      assert_equal [1, 1, [1]], [variable.value, atom.value, vector.to_a]
      vector[0] = 2
      atom.value = 2

      assert_equal [2, [2]], [atom.value, vector.to_a]
    ensure
      resume << true if worker&.alive?
      worker&.join(5)
    end

    def test_scheduled_readers_wait_without_blocking_the_commit_fiber
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Strict::Vector.new([0])
      map = Strict::Map.new({ key: 0 })
      tree = Strict::TreeMap.new({ 1 => 0 })
      scheduler = Helpers::QueueTestScheduler.new
      wait = scheduler.method(:io_wait)
      woken = {}.compare_by_identity
      scheduler.define_singleton_method(:io_wait) do |*arguments|
        fiber = Fiber.current
        if woken[fiber]
          wait.call(*arguments)
        else
          woken[fiber] = true
          0
        end
      end
      reads = []
      Fiber.set_scheduler(scheduler)
      Fiber.schedule do
        with_hook(lambda {
          [-> { atom.value }, -> { vector[0] }, -> { map[:key] }, -> { tree[1] }].each do |read|
            Fiber.schedule { reads << read.call }
          end
          Fiber.scheduler.kernel_sleep(0)
        }) do
          Transaction.run do |tx|
            tx[variable].value = 1
            tx[atom].value = 1
            tx[vector][0] = 1
            tx[map][:key] = 1
            tx[tree][1] = 1
          end
        end
      end
      Fiber.set_scheduler(nil)

      assert_equal [1, 1, 1, 1], reads
      assert_operator scheduler.io_wait_calls, :>, 0
    ensure
      Fiber.set_scheduler(nil) if Fiber.scheduler
    end

    def test_concurrent_mixed_commits_preserve_all_updates
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Unshared::Vector.new([0])
      workers = 2.times.map do |index|
        Thread.new do
          40.times do
            objects = index.zero? ? [atom, vector] : [vector, atom]
            raise "commit failed" unless Transaction.run(retries: 200) do |tx|
              objects.each do |source|
                Abstract::Atom === source ? tx[source].value += 1 : tx[source][0] += 1
              end
              tx[variable].value += 1
            end
          end
        end
      end
      workers.each { |worker| Timeout.timeout(10) { worker.value } }

      assert_equal [80, 80, [80]], [variable.value, atom.value, vector.to_a]
    ensure
      workers&.each { it.join(5) }
    end

    def test_native_backends_can_freeze_before_initialization
      [Internal::Atom, Internal::Vector, Internal::Map, Internal::UnsharedMap,
       Internal::TreeMap, Internal::ShareableTreeMap, Internal::UnsafeTreeMap].each do |klass|
        backend = klass.allocate

        assert_same backend, backend.freeze
        assert_predicate backend, :frozen?
      end
    end

    private

    def with_hook(hook)
      previous = Thread.current[:farce_tvar_commit_hook]
      Thread.current[:farce_tvar_commit_hook] = hook
      yield
    ensure
      Thread.current[:farce_tvar_commit_hook] = previous
    end
  end
end
