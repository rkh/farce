# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby" && RUBY_VERSION >= "4" && !Gem.win_platform?

require_relative "../setup"
require "farce/integrations/ractor_tmvar"
require "timeout"

module Farce
  class TestRactorTMVarTransaction < Test
    def test_operations_share_staged_state_without_changing_live_storage
      variable = ::Ractor::TMVar.new(1)

      assert(Transaction.run(variable) do |tx, wrapped|
        assert_same wrapped, tx[variable]
        assert_same wrapped, tx[wrapped]
        refute_predicate wrapped, :empty?
        assert_equal 1, wrapped.read
        assert_equal 1, wrapped.try_read
        assert_equal 1, wrapped.swap(2)
        assert_equal 2, wrapped.try_take
        assert_predicate wrapped, :empty?
        assert_nil wrapped.try_take
        assert_nil wrapped.try_read
        assert wrapped.try_put(3)
        refute wrapped.try_put(4)
        assert_equal 3, wrapped.take
        assert_equal 5, wrapped.put(5)
        assert_equal 5, wrapped.read
        assert_equal 1, variable.read
      end)
      assert_equal 5, variable.read
    end

    def test_mixed_publication_with_tvar_native_and_portable_participants
      pending = ::Ractor::TMVar.new(10)
      empty = ::Ractor::TMVar.new(::Ractor::TMVar::EMPTY)
      variable = ::Ractor::TVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Unshared::Vector.new([0])

      assert(Farce.transaction do |tx|
        value = tx[pending].take
        tx[empty].put(value)
        tx[variable].value = value
        tx[atom].value = value
        tx[vector][0] = value
      end)
      assert_predicate pending, :empty?
      assert_equal [10, 10, 10, [10]], [empty.read, variable.value, atom.value, vector.to_a]
    end

    def test_abort_and_exception_discard_staged_changes
      variable = ::Ractor::TMVar.new(1)
      atom = Strict::Atom.new(1)

      refute(Transaction.run do |tx|
        tx[atom].value = tx[variable].swap(2)
        tx.abort!
      end)
      assert_raises(RuntimeError) do
        Transaction.run do |tx|
          tx[variable].take
          tx[atom].value = 2
          raise "discard"
        end
      end
      assert_equal [1, 1], [variable.read, atom.value]
    end

    def test_unavailable_operations_retry_within_the_farce_limit
      { read: [], take: [], swap: [2], put: [2] }.each do |operation, arguments|
        value = operation == :put ? 1 : ::Ractor::TMVar::EMPTY
        variable = ::Ractor::TMVar.new(value)
        atom = Strict::Atom.new(0)
        attempts = 0

        refute(Transaction.run(retries: 2) do |tx|
          attempts += 1
          tx[atom].value = 1
          tx[variable].public_send(operation, *arguments)
        end)
        assert_equal 3, attempts
        assert_equal 0, atom.value
        assert_equal value, variable.instance_variable_get(:@tvar).value
      end
    end

    def test_retry_takes_a_fresh_snapshot_and_discards_previous_farce_writes
      variable = ::Ractor::TMVar.new(::Ractor::TMVar::EMPTY)
      atom = Strict::Atom.new(0)
      vector = Unshared::Vector.new([0])
      attempts = 0

      assert(Transaction.run(retries: 1) do |tx|
        attempts += 1
        wrapped = tx[variable]
        tx[atom].value += 1
        tx[vector][0] += 1
        ::Ractor.atomically { variable.put(7) } if attempts == 1

        assert_equal 7, wrapped.take
      end)
      assert_equal 2, attempts
      assert_equal [1, [1]], [atom.value, vector.to_a]
      assert_predicate variable, :empty?
    end

    def test_rescued_retry_condition_still_discards_the_attempt
      variable = ::Ractor::TMVar.new(::Ractor::TMVar::EMPTY)
      atom = Strict::Atom.new(0)

      refute(Transaction.run(retries: 0) do |tx|
        tx[atom].value = 1
        begin
          tx[variable].read
        rescue Internal::TransactionConflict
          tx[variable].put(2)
        end
      end)
      assert_predicate variable, :empty?
      assert_equal 0, atom.value
    end

    def test_try_operations_allow_other_writes_to_commit
      empty = ::Ractor::TMVar.new(::Ractor::TMVar::EMPTY)
      full = ::Ractor::TMVar.new(1)
      atom = Strict::Atom.new(0)

      assert(Transaction.run do |tx|
        assert_nil tx[empty].try_read
        assert_nil tx[empty].try_take
        refute tx[full].try_put(2)
        tx[atom].value = 3
      end)
      assert_equal 3, atom.value
      assert_predicate empty, :empty?
      assert_equal 1, full.read
    end

    def test_nil_is_a_full_value
      variable = ::Ractor::TMVar.new

      assert(Transaction.run do |tx|
        refute_predicate tx[variable], :empty?
        assert_nil tx[variable].take
        assert_predicate tx[variable], :empty?
        assert tx[variable].try_put(nil)
        refute_predicate tx[variable], :empty?
      end)
      refute_predicate variable, :empty?
      assert_nil variable.read
    end

    def test_underlying_tvar_and_tmvar_share_enrollment
      variable = ::Ractor::TMVar.new(1)
      storage = variable.instance_variable_get(:@tvar)

      assert(Transaction.run do |tx|
        tx[storage].value = 2

        assert_equal 2, tx[variable].take
        assert_equal ::Ractor::TMVar::EMPTY, tx[storage].value
        tx[storage].value = 3

        assert_equal 3, tx[variable].swap(4)
        assert_equal 4, tx[storage].value
      end)
      assert_equal 4, variable.read
    end

    def test_wrapper_cannot_be_copied_or_adopted_by_another_attempt
      variable = ::Ractor::TMVar.new(1)

      refute(Transaction.run do |tx|
        tx[variable].swap(2)
        assert_raises(TypeError) { tx[variable].dup }
      end)
      assert_equal 1, variable.read

      refute(Transaction.run do |outer|
        refute(Transaction.run do |inner|
          assert_raises(TypeError) { inner[outer[variable]] }
        end)
      end)
    end

    def test_foreign_write_conflict_discards_all_staged_changes
      variable = ::Ractor::TMVar.new(1)
      atom = Strict::Atom.new(0)
      vector = Unshared::Vector.new([0])

      refute(Transaction.run(retries: 0) do |tx|
        tx[variable].swap(2)
        tx[atom].value = 2
        tx[vector][0] = 2
        ::Ractor.atomically { variable.swap(3) }
      end)
      assert_equal [3, 0, [0]], [variable.read, atom.value, vector.to_a]
    end

    def test_read_only_tmvar_is_validated_at_commit
      variable = ::Ractor::TMVar.new(1)
      atom = Strict::Atom.new(0)

      refute(Transaction.run(retries: 0) do |tx|
        tx[atom].value = tx[variable].read
        ::Ractor.atomically { variable.swap(2) }
      end)
      assert_equal [2, 0], [variable.read, atom.value]
    end

    def test_replacements_are_made_shareable_and_conversion_errors_poison_attempts
      variable = ::Ractor::TMVar.new(::Ractor::TMVar::EMPTY)
      value = [1]
      atom = Strict::Atom.new(0)

      assert(Transaction.run { |tx| tx[variable].put(value) })
      assert_same value, variable.read
      assert ::Ractor.shareable?(value)

      refute(Transaction.run do |tx|
        tx[atom].value = 1
        assert_raises(::Ractor::Error) { tx[variable].swap(Thread.current) }
      end)
      assert_same value, variable.read
      assert_equal 0, atom.value
    end

    def test_operations_reject_closed_and_foreign_fiber_access
      variable = ::Ractor::TMVar.new(1)
      wrapper = nil

      assert(Transaction.run do |tx|
        wrapper = tx[variable]
        assert_raises(Transaction::OwnershipError) { Fiber.new { wrapper.read }.resume }
      end)
      { read: [], try_read: [], take: [], try_take: [], empty?: [], put: [2], try_put: [2], swap: [2] }
        .each do |operation, arguments|
          assert_raises(Transaction::ClosedError) { wrapper.public_send(operation, *arguments) }
        end
      assert_equal 1, variable.read
    end

    def test_nested_stm_is_rejected_before_publication
      variable = ::Ractor::TMVar.new(1)
      atom = Strict::Atom.new(0)

      ::Ractor.atomically do
        assert_raises(ArgumentError) do
          Transaction.run do |tx|
            tx[atom].value = 2
            tx[variable].take
          end
        end
      end
      assert_equal [1, 0], [variable.read, atom.value]
    end

    def test_shared_tmvar_works_from_another_ractor
      variable = ::Ractor.make_shareable(::Ractor::TMVar.new(1))
      atom = Strict::Atom.new(0)
      worker = ::Ractor.new(variable, atom) do |pending, received|
        begin
          ::Ractor::TVar.new(0)
        rescue ::Ractor::UnsafeError
          next :unsafe_dependency
        end
        Farce.transaction { |tx| tx[received].value = tx[pending].take }
      end

      result = Timeout.timeout(5) { worker.respond_to?(:value) ? worker.value : worker.take }
      skip "loaded TVar provider does not support child Ractors" if result == :unsafe_dependency

      assert result
      assert_predicate variable, :empty?
      assert_equal 1, atom.value
    end

    def test_concurrent_mixed_commits_preserve_all_updates
      variable = ::Ractor::TMVar.new(0)
      atom = Strict::Atom.new(0)
      vector = Unshared::Vector.new([0])
      workers = 2.times.map do
        Thread.new do
          40.times do
            raise "commit failed" unless Transaction.run(retries: 200) do |tx|
              wrapped = tx[variable]
              wrapped.swap(wrapped.read + 1)
              tx[atom].value += 1
              tx[vector][0] += 1
            end
          end
        end
      end
      workers.each { |worker| Timeout.timeout(10) { worker.value } }

      assert_equal [80, 80, [80]], [variable.read, atom.value, vector.to_a]
    ensure
      workers&.each { it.join(5) }
    end

    def test_dependency_load_orders_and_explicit_loading
      ["require", "Kernel.require"].product(%i[before after explicit]).each do |loader, order|
        source = case order
                 when :before then "require 'ractor/tmvar'; require 'farce'"
                 when :after then "require 'farce'; #{loader}('ractor/tmvar')"
                 else
                   "ENV['FARCE_AUTOLOAD_INTEGRATIONS'] = 'false'; require 'farce'; " \
                   "require 'farce/integrations/ractor_tmvar'"
                 end
        output, error, status = ruby_isolated(<<~RUBY)
          #{source}
          variable = Ractor::TMVar.new(1)
          raise "commit failed" unless Farce.transaction { |tx| tx[variable].swap(2) }
          raise "wrong value" unless variable.read == 2
        RUBY

        assert_predicate status, :success?, "#{output}\n#{error}"
        refute_includes error, "circular require"
      end
    end
  end
end
