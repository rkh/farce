# frozen_string_literal: true

require_relative "../../setup"
module Farce
  class TestFlag < Test
    include Helpers::InternalTestHelpers

    Flag = Internal::Flag

    def test_default_and_initial_value
      refute Flag.new.value
      refute Flag.new(false).value
      assert Flag.new(true).value
    end

    def test_flag_is_frozen_and_shareable
      return unless Internal.native_ractors?

      flag = Flag.new

      assert_predicate flag, :frozen?
      assert Ractor.shareable?(flag)
    end

    def test_frozen_uninitialized_flag_cannot_be_initialized
      return unless RUBY_ENGINE == "ruby"

      flag = Flag.allocate
      flag.freeze

      assert Ractor.shareable?(flag)
      assert_raises(FrozenError) { flag.send(:initialize, true) }
      assert_raises(RuntimeError) { flag.value }
    end

    def test_initial_value_must_be_a_boolean
      [nil, 0, :true, "false"].each do |value| # rubocop:disable Lint/BooleanSymbol
        assert_raises(ArgumentError) { Flag.new(value) }
      end
    end

    def test_value_get_set_store_writer_and_swap
      flag = Flag.new

      refute flag.value
      refute flag.get
      assert flag.set
      assert flag.value
      assert flag.swap(false)
      refute flag.value
      assert flag.store(true)
      assert flag.get
      refute flag.value = false
      refute flag.value
      refute flag.swap(true)
      assert flag.value
    end

    def test_store_and_swap_validate_before_mutating
      flag = Flag.new(true)

      assert_raises(ArgumentError) { flag.store(nil) }
      assert flag.value
      assert_raises(ArgumentError) { flag.swap(1) }
      assert flag.value
    end

    def test_compare_and_set
      flag = Flag.new

      assert flag.compare_and_set(false, true)
      assert flag.value
      refute flag.compare_and_set(false, true)
      assert flag.value
      assert flag.compare_and_set(true, false)
      refute flag.value
    end

    def test_compare_and_set_validates_both_arguments_before_mutating
      flag = Flag.new(false)

      assert_raises(ArgumentError) { flag.compare_and_set(nil, true) }
      refute flag.value
      assert_raises(ArgumentError) { flag.compare_and_set(true, 1) }
      refute flag.value
    end

    def test_toggle_returns_the_new_value
      flag = Flag.new

      assert flag.toggle
      refute flag.toggle
      assert flag.toggle
      assert flag.value
    end

    def test_toggles_are_exact_across_threads
      flag = Flag.new
      thread_count = 8
      toggles_per_thread = 1_000
      threads = thread_count.times.map do
        Thread.new { toggles_per_thread.times.map { flag.toggle } }
      end
      returned_values = threads.flat_map(&:value)

      refute flag.value
      assert_equal thread_count * toggles_per_thread / 2, returned_values.count(true)
      assert_equal thread_count * toggles_per_thread / 2, returned_values.count(false)
    end

    def test_toggles_are_exact_across_ractors
      flag = Flag.new
      ractor_count = 4
      toggles_per_ractor = 1_000
      workers = ractor_count.times.map do
        Ractor.new(flag, toggles_per_ractor) do |shared, count|
          count.times { shared.toggle }
          shared.object_id
        end
      end
      worker_object_ids = workers.map { |worker| ractor_value(worker) }

      refute flag.value
      assert_equal [flag.object_id], worker_object_ids.uniq
    end

    def test_flag_sent_to_a_ractor_is_the_same_object
      flag = Flag.new
      worker = Ractor.new do
        received = Ractor.receive
        received.set
        received.object_id
      end

      worker << flag

      assert_equal flag.object_id, ractor_value(worker)
      assert flag.value
    end
  end
end
