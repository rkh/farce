# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestFlagWaitConditions < Test
    TRUE_WAITS = %i[wait_until_set wait_until_true wait_while_unset wait_while_false].freeze
    FALSE_WAITS = %i[wait_until_unset wait_until_false wait_while_set wait_while_true].freeze

    def test_boolean_waits_and_aliases_return_matching_values
      { true => TRUE_WAITS, false => FALSE_WAITS }.each do |expected, methods|
        flag = flag_class.new(expected).freeze

        methods.each do |method|
          assert_equal expected, flag.public_send(method, timeout: 0) { flunk "unexpected timeout" }
        end
      end
    end

    def test_boolean_waits_and_aliases_forward_timeouts_and_fallbacks
      { true => TRUE_WAITS, false => FALSE_WAITS }.each do |expected, methods|
        flag = flag_class.new(!expected)
        methods.each do |method|
          assert_nil flag.public_send(method, timeout: 0)
          calls = 0
          result = flag.public_send(method, timeout: 0) do
            calls += 1
            :expired
          end

          assert_equal :expired, result
          assert_equal 1, calls
        end
      end
    end

    def test_each_wait_method_wakes_after_a_change
      { true => TRUE_WAITS, false => FALSE_WAITS }.each do |expected, methods|
        methods.each { |method| assert_wait_wakes(method, !expected, expected) }
      end

      assert_wait_wakes(:wait_until_changed, false, true, false)
      assert_wait_wakes(:wait_while_value, true, false, true)
      assert_wait_wakes(:wait_until_value, true, false, false)
      assert_wait_wakes(:wait_until_match, false, true, TrueClass)
      assert_wait_wakes(:wait_while_match, true, false, TrueClass)
      assert_wait_wakes(:wait_until, false, true) { |value| value }
      assert_wait_wakes(:wait_while, true, false) { |value| value }
    end

    def test_value_and_pattern_waits_preserve_false
      [false, true].each do |value|
        flag = flag_class.new(value)
        pattern = value ? TrueClass : FalseClass

        assert_equal value, flag.wait_until_value(value, timeout: 0)
        assert_nil flag.wait_until_value(!value, timeout: 0)
        assert_equal value, flag.wait_until_match(pattern, timeout: 0)
        assert_nil flag.wait_while_match(pattern, timeout: 0)
        assert_equal value, flag.wait_while_match(!value, timeout: 0)
        assert_equal value, flag.wait_while_value(!value, timeout: 0)
        assert_equal :expired, flag.wait_while_value(value, timeout: 0) { :expired }
      end
    end

    def test_value_and_pattern_waits_use_the_supplied_comparison
      flag = flag_class.new(false)
      equality = Object.new
      equality.define_singleton_method(:==) { |value| value.equal?(false) }
      pattern = Object.new
      pattern.define_singleton_method(:===) { |value| value.equal?(false) }

      assert_same false, flag.wait_until_value(equality, timeout: 0)
      assert_same false, flag.wait_until_match(pattern, timeout: 0)
      assert_nil flag.wait_while_match(pattern, timeout: 0)
    end

    def test_predicates_receive_the_boolean_and_accept_truthy_results
      flag = flag_class.new(false)
      seen = []
      result = flag.wait_until(timeout: 0) do |value|
        seen << value
        :matched
      end

      assert_same false, result
      assert_equal [false], seen
      assert_same false, flag.wait_while(timeout: 0) { nil }
      assert_nil flag.wait_while(timeout: 0) { :keep_waiting }
    end

    def test_predicates_recheck_changes_made_during_the_check
      %i[wait_until wait_while].each do |method|
        flag = flag_class.new(false)
        seen = []
        result = flag.public_send(method, timeout: 1) do |value|
          seen << value
          flag.set unless value
          method == :wait_until ? value : !value
        end

        assert_same true, result
        assert_equal [false, true], seen
      end
    end

    def test_zero_timeout_checks_the_predicate_once
      %i[wait_until wait_while].each do |method|
        flag = flag_class.new
        calls = 0
        result = flag.public_send(method, timeout: 0) do
          calls += 1
          method == :wait_while
        end

        assert_nil result
        assert_equal 1, calls
      end
    end

    def test_predicate_errors_propagate_and_missing_blocks_raise
      flag = flag_class.new
      %i[wait_until wait_while].each do |method|
        assert_raises(LocalJumpError) { flag.public_send(method, timeout: 0) }
        assert_raises(RuntimeError) { flag.public_send(method, timeout: 0) { raise "predicate failed" } }
      end
    end

    def test_wait_until_changed_and_wait_while_value_validate_booleans
      flag = flag_class.new
      %i[wait_until_changed wait_while_value].each do |method|
        [nil, 0, :true].each do |expected| # rubocop:disable Lint/BooleanSymbol
          assert_raises(ArgumentError) { flag.public_send(method, expected, timeout: 0) }
        end
      end
    end

    def test_all_wait_methods_validate_the_timeout_even_for_immediate_matches
      flag = flag_class.new(false)
      calls = (TRUE_WAITS + FALSE_WAITS).map { |method| [method] }
      calls += [[:wait_until_changed, true], [:wait_while_value, true], [:wait_until_value, false],
                [:wait_until_match, FalseClass], [:wait_while_match, TrueClass], [:wait_until], [:wait_while]]
      calls.each do |method, *arguments|
        [-1, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) do
            if %i[wait_until wait_while].include?(method)
              flag.public_send(method, *arguments, timeout:) { true }
            else
              flag.public_send(method, *arguments, timeout:)
            end
          end
        end
      end
    end

    def test_one_timeout_budget_covers_predicate_checks
      flag = flag_class.new
      calls = 0
      result = flag.wait_until(timeout: 0.001) do
        calls += 1
        sleep 0.002
        flag.toggle
        false
      end

      assert_nil result
      assert_equal 1, calls
    end

    def test_wait_does_not_block_a_fiber_scheduler
      return unless Fiber.respond_to?(:set_scheduler)
      flag = flag_class.new
      scheduler = Helpers::QueueTestScheduler.new
      events = []
      Fiber.set_scheduler(scheduler)
      Fiber.schedule { events << flag.wait_until_set(timeout: 5) }
      Fiber.schedule do
        events << flag.send(:change_signal).num_waiting
        flag.set
      end
      Fiber.set_scheduler(nil)

      assert_equal [1, true], events
    ensure
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
    end

    private

    def flag_class = Flag

    def assert_wait_wakes(method, initial, expected, *, &)
      flag = flag_class.new(initial)
      signal = flag.send(:change_signal)
      waiter = Thread.new { flag.public_send(method, *, timeout: 5, &) }
      Timeout.timeout(5) { Thread.pass until signal.num_waiting == 1 }
      flag.store(expected)

      assert waiter.join(5), "#{method} did not wake"
      assert_equal expected, waiter.value
      assert_equal 0, signal.num_waiting
    ensure
      waiter&.kill&.join
    end
  end

  class TestLocalFlagWaitConditions < TestFlagWaitConditions
    def test_waits_use_the_current_backing_for_every_scope
      Farce::SCOPES.each do |scope|
        flag = flag_class.new(scope:)

        assert_nil flag.wait_until_set(timeout: 0)
        assert_same true, flag.wait_until(timeout: 1) { |value|
          flag.set unless value
          value
        }
        assert_same false, flag.wait_while(timeout: 1) { |value|
          flag.unset if value
          value
        }
      end
    end

    def test_changes_in_another_thread_scope_do_not_satisfy_the_wait
      flag = flag_class.new(scope: :thread)
      writer = Thread.new { flag.set }
      writer.value

      assert_nil flag.wait_until_set(timeout: 0.01)
      assert_same false, flag.value
    end

    def test_new_thread_scope_starts_from_initial_value
      flag = flag_class.new(true, scope: :thread)
      flag.unset
      result = Thread.new { flag.wait_until_set(timeout: 0) }.value

      assert_same true, result
      assert_same false, flag.wait_until_unset(timeout: 0)
    end

    def test_another_ractor_has_an_independent_wait_value
      flag = flag_class.new
      worker = Ractor.new(flag) do |local|
        local.set
        local.wait_until_set(timeout: 0)
      end
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_same true, result
      assert_nil flag.wait_until_set(timeout: 0)
      assert_same false, flag.wait_until_unset(timeout: 0)
    end

    private def flag_class = Local::Flag
  end
end
