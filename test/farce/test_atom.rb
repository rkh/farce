# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestAtom < Test
    include Helpers::InternalTestHelpers

    def run(...) = Timeout.timeout(1) { super }

    def test_initialization_defaults_and_shareability
      atom = Atom.new

      assert_instance_of Internal::Atom, atom.instance_variable_get(:@atom)
      assert_nil atom.value
      assert_equal :copy, atom.mode
      refute_predicate atom, :compare_by_identity?
      assert_kind_of Abstract::Value, atom
      refute_predicate atom, :frozen?
      assert_predicate atom, :ractor_shareable?
      assert Ractor.shareable?(atom)
    end

    def test_initialization_accepts_modes_and_validates_options
      value = ModePayload.new(:value)
      atom = Atom.new(value, mode: :local, compare_by_identity: true)

      assert_same value, atom.value
      assert_equal :local, atom.mode
      assert_predicate atom, :compare_by_identity?

      error = assert_raises(ArgumentError) { Atom.new(mode: :invalid) }
      assert_equal "invalid mode: :invalid", error.message

      error = assert_raises(ArgumentError) { Atom.new(compare_by_identity: nil) }
      assert_equal "compare_by_identity must be a boolean", error.message
    end

    def test_stores_shareable_values_directly_and_uses_a_single_nil_placeholder
      atom = Atom.new(:value)
      internal = atom.instance_variable_get(:@atom)

      assert_same :value, internal.value

      atom.store(nil)

      refute_nil internal.value
      assert Ractor.shareable?(internal.value)
      assert_nil atom.value
    end

    def test_default_mode_applies_to_value_writer_and_store
      atom = Atom.new(mode: :local)
      first = ModePayload.new(:first)
      second = ModePayload.new(:second)

      atom.value = first

      assert_same first, atom.value
      assert_same second, atom.store(second)
      assert_same second, atom.get
      assert_equal :local, atom.mode
    end

    def test_store_mode_override_copies_and_automatically_unwraps_values
      atom = Atom.new(mode: :local)
      source = ModePayload.new(:original)
      stored = atom.store(source, mode: :copy)

      source.value = :changed

      refute_same source, stored
      assert_equal :original, stored.value
      assert_same stored, atom.value
      assert_same stored, atom.get(timeout: 0)
      assert_equal :local, atom.mode
    end

    def test_store_rejects_an_unshareable_value_in_raise_mode_without_changing_the_atom
      original = ModePayload.new(:original)
      atom = Atom.new(original, mode: :local)

      error = assert_raises(Ractor::IsolationError) do
        atom.store(ModePayload.new(:rejected), mode: :raise)
      end

      assert_match(/value is not Ractor-shareable/, error.message)
      assert_same original, atom.value
    end

    def test_swap_returns_the_automatically_unwrapped_previous_value
      original = ModePayload.new(:original)
      replacement = ModePayload.new(:replacement)
      atom = Atom.new(original, mode: :local)

      assert_same original, atom.swap(replacement)
      assert_same replacement, atom.value

      copied = ModePayload.new(:copied)

      assert_same replacement, atom.swap(copied, mode: :copy)
      refute_same copied, atom.value
      assert_equal :copied, atom.value.value
    end

    def test_store_if_absent_wraps_only_the_value_that_is_stored
      atom = Atom.new(mode: :local)
      value = ModePayload.new(:value)
      calls = 0

      assert_same(value, atom.store_if_absent do
        calls += 1
        value
      end)
      assert_same(value, atom.store_if_absent do
        calls += 1
        ModePayload.new(:other)
      end)
      assert_equal 1, calls
      assert_same value, atom.value
    end

    def test_store_if_absent_executes_once_under_contention
      atom = Atom.new
      calls = 0
      calls_lock = Mutex.new
      threads = 8.times.map do
        Thread.new do
          atom.store_if_absent do
            calls_lock.synchronize { calls += 1 }
            sleep 0.01
            42
          end
        end
      end

      assert_equal [42], threads.map(&:value).uniq
      assert_equal 1, calls
    end

    def test_compare_and_set_compares_copied_values_by_equality
      atom = Atom.new(ModePayload.new(:expected))
      replacement = ModePayload.new(:replacement)

      refute atom.compare_and_set(ModePayload.new(:other), replacement, mode: :local)
      assert atom.compare_and_set(ModePayload.new(:expected), replacement, mode: :local)
      assert_same replacement, atom.value
    end

    def test_compare_and_set_can_compare_non_shareable_values_without_claiming_them
      atom = Atom.new(ModePayload.new(:expected), mode: :move)
      envelope = atom.instance_variable_get(:@atom).value

      assert_instance_of Envelope::Move, envelope
      refute_predicate envelope, :claimed?
      refute atom.compare_and_set(ModePayload.new(:other), :nope)
      refute_predicate envelope, :claimed?
      assert atom.compare_and_set(ModePayload.new(:expected), :replacement)
      refute_predicate envelope, :claimed?
      assert_equal :replacement, atom.value
    end

    def test_compare_and_set_can_compare_by_identity
      original = ModePayload.new(:value)
      equal = ModePayload.new(:value)
      atom = Atom.new(original, mode: :local, compare_by_identity: true)

      refute atom.compare_and_set(equal, :nope)
      assert atom.compare_and_set(original, :replacement)
      assert_equal :replacement, atom.value
    end

    def test_failed_compare_and_set_does_not_wrap_the_replacement
      atom = Atom.new(:current)
      replacement = ModePayload.new(:replacement)

      refute atom.compare_and_set(:other, replacement, mode: :move)
      refute_operator Ractor::MovedObject, :===, replacement
      assert_equal :replacement, replacement.value
      assert_equal :current, atom.value
    end

    def test_update_receives_an_unwrapped_value_and_wraps_its_result
      original = ModePayload.new(:original)
      atom = Atom.new(original, mode: :local)
      seen = nil

      result = atom.update(mode: :copy) do |current|
        seen = current
        ModePayload.new(:updated)
      end

      assert_same original, seen
      assert_equal :updated, result.value
      assert_same result, atom.value
    end

    def test_failed_update_releases_the_internal_reservation
      original = ModePayload.new(:original)
      atom = Atom.new(original, mode: :local)

      assert_raises(Ractor::IsolationError) do
        atom.update(mode: :raise) { ModePayload.new(:rejected) }
      end

      assert_same original, atom.value
      assert_equal(:recovered, atom.update { :recovered })
    end

    def test_freezing_in_an_update_rejects_move_before_transferring_the_result
      atom = Atom.new(:original, mode: :move)
      result = ModePayload.new(:replacement)

      assert_raises(FrozenError) do
        atom.update do
          atom.freeze
          result
        end
      end

      assert_equal :replacement, result.value
      assert_equal :original, atom.value
    end

    def test_upsert_stores_an_initial_value_or_updates_the_current_value
      atom = Atom.new(mode: :local)
      initial = ModePayload.new(:initial)
      called = false

      assert_same(initial, atom.upsert(initial) { called = true })
      refute called

      result = atom.upsert(ModePayload.new(:ignored)) do |current|
        ModePayload.new(:"#{current.value}-updated")
      end

      assert_equal :"initial-updated", result.value
      assert_same result, atom.value
    end

    def test_updates_remain_atomic_under_contention
      atom = Atom.new(0)
      threads = 8.times.map do
        Thread.new do
          atom.update do |current|
            Thread.pass
            current + 1
          end
        end
      end

      threads.each(&:join)

      assert_equal 8, atom.value
    end

    def test_timeout_fallbacks_are_not_treated_as_stored_values
      atom = Atom.new(ModePayload.new(:current), mode: :local)
      entered = Thread::Queue.new
      release = Thread::Queue.new
      updater = Thread.new do
        atom.update do |current|
          entered << true
          release.pop
          current
        end
      end
      entered.pop

      fallback = Envelope::Local.new(:fallback, atom.instance_variable_get(:@manager))

      assert_same fallback, atom.get(timeout: 0) { fallback }
      assert_equal :store_timeout, atom.store(:new, timeout: 0) { :store_timeout }
      assert_equal :swap_timeout, atom.swap(:new, timeout: 0) { :swap_timeout }
      assert_same atom.value, atom.wait_until_changed(atom.value, timeout: 0) { atom.value }
    ensure
      release&.push(true)
      updater&.join
    end

    def test_wait_until_changed_uses_logical_value_comparison
      atom = Atom.new(ModePayload.new(:old))

      assert_equal :timeout,
        atom.wait_until_changed(ModePayload.new(:old), timeout: 0) { :timeout }

      waiter = Thread.new { atom.wait_until_changed(ModePayload.new(:old), timeout: 1) }
      atom.store(ModePayload.new(:new))
      result = waiter.value

      assert_equal :new, result.value
    end

    def test_wait_until_changed_can_compare_by_identity
      original = ModePayload.new(:value)
      equal = ModePayload.new(:value)
      atom = Atom.new(original, mode: :local, compare_by_identity: true)

      assert_same original, atom.wait_until_changed(equal, timeout: 0)
      assert_equal :timeout, atom.wait_until_changed(original, timeout: 0) { :timeout }
    end

    def test_wait_until_non_nil_returns_unwrapped_values_and_fallbacks
      atom = Atom.new

      assert_equal :timeout, atom.wait_until_non_nil(timeout: 0) { :timeout }

      waiter = Thread.new { atom.wait_until_non_nil(timeout: 1) }
      atom.store(ModePayload.new(:ready))

      assert_equal :ready, waiter.value.value
    end

    def test_copy_mode_transfers_non_shareable_values_between_ractors
      return unless Internal.native_ractors?
      source = ModePayload.new(:original)
      atom = Atom.new(source)
      source.value = :changed
      worker = Ractor.new(atom) do |shared|
        current = shared.value
        shared.update { |value| Helpers::ModePayload.new(:"#{value.value}-updated") }
        current.value
      end

      assert_equal :original, ractor_value(worker)
      assert_equal :"original-updated", atom.value.value
    end

    def test_can_be_constructed_in_a_non_main_ractor
      return unless Internal.native_ractors?

      worker = Ractor.new { Farce::Atom.new(:initial) }
      atom = ractor_value(worker)

      refute_predicate atom, :frozen?
      assert_equal :replacement, atom.store(:replacement)
    end

    def test_block_operations_require_a_block_before_wrapping_values
      atom = Atom.new

      assert_raises(LocalJumpError) { atom.store_if_absent }
      assert_raises(LocalJumpError) { atom.update }
      assert_raises(LocalJumpError) { atom.upsert(ModePayload.new(:value), mode: :move) }
    end
  end
end
