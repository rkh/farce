# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestFlagConcurrentCompatibility < Test
    include Helpers::InternalTestHelpers

    FLAG_TYPES = [Flag, Local::Flag].freeze

    def test_boolean_predicate_aliases_follow_initial_values_and_mutations
      FLAG_TYPES.each do |type|
        [false, true].each do |initial|
          flag = type.new(initial)

          assert_same initial, flag.true?, type.name
          assert_same !initial, flag.false?, type.name
          flag.toggle

          assert_same !initial, flag.true?, type.name
          assert_same initial, flag.false?, type.name
          flag.set

          assert_predicate flag, :true?
          refute_predicate flag, :false?
          flag.unset

          refute_predicate flag, :true?
          assert_predicate flag, :false?
        end
      end
    end

    def test_make_true_and_make_false_report_whether_the_value_changed
      FLAG_TYPES.each do |type|
        [false, true].each do |initial|
          flag = type.new(initial)

          assert_same !initial, flag.make_true, type.name
          assert_same true, flag.value, type.name
          assert_same false, flag.make_true, type.name
          assert_predicate flag, :true?
          refute_predicate flag, :false?
          assert_same true, flag.make_false, type.name
          assert_same false, flag.value, type.name
          assert_same false, flag.make_false, type.name
          refute_predicate flag, :true?
          assert_predicate flag, :false?
        end
      end
    end

    def test_make_true_and_make_false_reject_frozen_flags
      FLAG_TYPES.each do |type|
        [false, true].each do |initial|
          flag = type.new(initial).freeze

          assert_raises(FrozenError) { flag.make_true }
          assert_raises(FrozenError) { flag.make_false }
          assert_same initial, flag.value, type.name
          assert_same initial, flag.true?, type.name
          assert_same !initial, flag.false?, type.name
        end
      end
    end

    def test_make_true_and_make_false_each_allow_only_one_thread_to_change_the_value
      FLAG_TYPES.each do |type|
        [[:make_true, false, true], [:make_false, true, false]].each do |method, initial, target|
          flag = type.new(initial)
          ready = Thread::Queue.new
          start = Thread::Queue.new
          workers = 8.times.map do
            Thread.new do
              ready << true
              start.pop
              flag.public_send(method)
            end
          end
          begin
            Timeout.timeout(5) { workers.size.times { ready.pop } }
            workers.size.times { start << true }
            workers.each { assert it.join(5), "#{type}##{method} did not finish" }
            results = workers.map(&:value)

            assert_equal 1, results.count(true), "#{type}##{method}"
            assert_equal 7, results.count(false), "#{type}##{method}"
            assert_same target, flag.value, "#{type}##{method}"
          ensure
            workers.each(&:kill)
            workers.each(&:join)
          end
        end
      end
    end

    def test_local_boolean_compatibility_only_changes_the_current_thread_or_fiber
      %i[thread fiber].each do |scope|
        flag = Local::Flag.new(false, scope:)
        flag.make_true
        work = proc do
          before = [flag.true?, flag.false?]
          changed_true = flag.make_true
          after_true = [flag.true?, flag.false?]
          changed_false = flag.make_false
          [before, changed_true, after_true, changed_false, [flag.true?, flag.false?]]
        end
        result = scope == :thread ? Thread.new(&work).value : Fiber.new(&work).resume

        assert_equal [[false, true], true, [true, false], true, [false, true]], result, scope.to_s
        assert_predicate flag, :true?
        refute_predicate flag, :false?
      end
    end

    def test_local_boolean_compatibility_only_changes_the_current_ractor
      flag = Local::Flag.new(false)
      flag.make_true
      worker = Ractor.new(flag) do |local|
        [local.true?, local.false?, local.make_true, local.true?, local.make_false, local.false?]
      end

      assert_equal [false, true, true, true, true, true], ractor_value(worker)
      assert_predicate flag, :true?
      refute_predicate flag, :false?
    end

    def test_make_true_and_make_false_each_allow_only_one_ractor_to_change_the_value
      return unless Internal.native_ractors?

      [[:make_true, false, true], [:make_false, true, false]].each do |method, initial, target|
        flag = Flag.new(initial)
        workers = 4.times.map do
          Ractor.new(flag, method) { |shared, operation| shared.public_send(operation) }
        end
        results = workers.map { ractor_value(it) }

        assert_equal 1, results.count(true), method.to_s
        assert_equal 3, results.count(false), method.to_s
        assert_same target, flag.value, method.to_s
      end
    end
  end
end
