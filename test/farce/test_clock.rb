# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestClock < Test
    class TestNumeric < Numeric
      def initialize(value)
        super()
        @value = value
      end

      def to_f = @value
    end

    def test_current_returns_elapsed_monotonic_time
      before = Clock.current
      sleep 0.001
      after = Clock.current

      assert_operator before, :>=, 0.0
      assert_operator after, :>=, before
    end

    def test_aliases_can_be_first_called_concurrently_from_non_main_ractors
      skip "native Ractors are unavailable" unless Internal.native_ractors?

      output, error, status = ruby_isolated(<<~'RUBY')
        require "farce"
        Farce::Clock

        workers = 8.times.map do
          # This subprocess does not load the Windows startup barrier in test/setup.rb.
          GC.start if Gem.win_platform?
          ::Ractor.new do
            ::Ractor.main.send(:ready)
            ::Ractor.receive

            before = Farce::Clock.current
            now = Farce::Clock.now
            at = Farce::Clock.at(700)
            timeout_at = Farce::Clock.timeout_at(701)
            offsets = {
              delay: Farce::Clock.delay(1),
              in: Farce::Clock.in(1),
              timeout: Farce::Clock.timeout(1),
              wait: Farce::Clock.wait(1)
            }
            after = Farce::Clock.current

            raise "now returned an invalid clock time" unless now.between?(before, after)
            raise "at changed a fixed clock time" unless at == 700.0
            raise "timeout_at changed a fixed clock time" unless timeout_at == 701.0
            offsets.each do |name, value|
              raise "#{name} returned an invalid deadline" unless value.between?(before + 1, after + 1)
            end
          end
        end

        workers.size.times { raise "worker was not ready" unless ::Ractor.receive == :ready }
        workers.each { |worker| worker.send(:start) }
        workers.each { |worker| worker.respond_to?(:value) ? worker.value : worker.take }
        puts "ok"
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
      assert_equal "ok", output.strip
    end

    def test_clock_returns_current_time_without_value
      assert_current_offset(0) { Clock.clock(nil) }
    end

    def test_remaining_returns_nil_without_a_deadline
      assert_nil Clock.remaining(nil)
    end

    def test_remaining_returns_seconds_until_a_future_deadline
      deadline = Clock.timeout(60)
      before = deadline - Clock.current
      actual = Clock.remaining(deadline)
      after = deadline - Clock.current

      assert_operator actual, :<=, before
      assert_operator actual, :>=, after
    end

    def test_remaining_returns_zero_for_expired_deadlines
      assert_equal 0, Clock.remaining(Clock.timeout(-1))
      assert_equal 0, Clock.remaining(0)
    end

    def test_remaining_rejects_nan
      error = assert_raises(ArgumentError) { Clock.remaining(Float::NAN) }

      assert_equal "timestamp must not be NaN", error.message
    end

    def test_parse_finishes_hash_iteration_before_calling_a_converter
      options = {}
      value = Object.new
      value.define_singleton_method(:to_f) do
        options[:converted] = true
        1.5
      end
      options[:clock] = value

      assert_in_delta 1.5, Clock.parse(options)
      assert options[:converted]
    end

    def test_clock_converts_value_to_float
      assert_in_delta 1.25, Clock.clock(1.25)
      assert_in_delta 2.0, Clock.clock(2)
    end

    def test_clock_rejects_nan
      error = assert_raises(ArgumentError) { Clock.clock(Float::NAN) }

      assert_equal "timestamp must not be NaN", error.message
    end

    def test_parse_treats_nil_as_current_time
      assert_current_offset(0) { Clock.parse(nil) }
    end

    def test_parse_treats_small_numbers_as_offsets
      assert_current_offset(0.1) { Clock.parse(0.1) }
      assert_current_offset(600) { Clock.parse(600) }
    end

    def test_parse_treats_larger_clock_sized_numbers_as_fixed_clock_times
      assert_in_delta 600.1, Clock.parse(600.1)
      assert_equal 1_000_000_000, Clock.parse(1_000_000_000)
    end

    def test_parse_treats_unix_timestamp_sized_numbers_as_wall_times
      assert_wall_time_offset(60) { Clock.parse(Time.now.to_f + 60) }
    end

    def test_parse_accepts_time_objects
      assert_wall_time_offset(60) { Clock.parse(Time.now + 60) }
    end

    def test_parse_accepts_objects_convertible_to_time
      target = Time.now + 60
      value = Object.new
      value.define_singleton_method(:to_time) { target }

      assert_wall_time_offset(60) { Clock.parse(value) }
    end

    def test_parse_accepts_non_float_numeric_values
      assert_current_offset(0.1) { Clock.parse(TestNumeric.new(0.1)) }
      assert_in_delta 600.1, Clock.parse(TestNumeric.new(600.1))
    end

    def test_parse_accepts_empty_hash_as_current_time
      assert_current_offset(0) { Clock.parse({}) }
    end

    def test_parse_dispatches_single_key_hashes
      assert_in_delta 12.5, Clock.parse(clock: 12.5)
      assert_in_delta 700.0, Clock.parse(at: 700)
      assert_in_delta 701.0, Clock.parse(time: 701)
      assert_in_delta 702.0, Clock.parse(timeout_at: 702)

      assert_current_offset(0.1) { Clock.parse(delay: 0.1) }
      assert_current_offset(0.1) { Clock.parse(in: 0.1) }
      assert_current_offset(0.1) { Clock.parse(offset: 0.1) }
      assert_current_offset(0.1) { Clock.parse(timeout: 0.1) }
      assert_current_offset(0.1) { Clock.parse(wait: 0.1) }
    end

    def test_parse_rejects_hashes_with_more_than_one_entry
      error = assert_raises(TypeError) { Clock.parse(delay: 1, timeout: 2) }

      assert_includes error.message, "Cannot convert"
    end

    def test_parse_rejects_unknown_values
      error = assert_raises(TypeError) { Clock.parse(Object.new) }

      assert_includes error.message, "Cannot convert"
    end

    def test_parse_rejects_nan
      error = assert_raises(ArgumentError) { Clock.parse(delay: Float::NAN) }

      assert_equal "timestamp must not be NaN", error.message
    end

    def test_time_accepts_clock_times
      assert_in_delta 601.0, Clock.time(601)
      assert_in_delta 601.5, Clock.time(601.5)
    end

    def test_time_accepts_wall_times
      assert_wall_time_offset(60) { Clock.time(Time.now + 60) }
      assert_wall_time_offset(60) { Clock.time(Time.now.to_f + 60) }
    end

    def test_time_accepts_non_float_numeric_values
      assert_in_delta 601.5, Clock.time(TestNumeric.new(601.5))
    end

    def test_time_rejects_other_values
      error = assert_raises(TypeError) { Clock.time("601") }

      assert_equal "Cannot convert String to clock time", error.message
    end

    def test_time_rejects_nan
      error = assert_raises(ArgumentError) { Clock.time(Float::NAN) }

      assert_equal "timestamp must not be NaN", error.message
    end

    def test_offset_accepts_numeric_values
      assert_current_offset(0.1) { Clock.offset(0.1) }
      assert_current_offset(1) { Clock.offset(1) }
    end

    def test_offset_rejects_other_values
      error = assert_raises(TypeError) { Clock.offset("1") }

      assert_equal "Cannot convert String to clock time", error.message
    end

    def test_offset_rejects_nan
      error = assert_raises(ArgumentError) { Clock.offset(Float::NAN) }

      assert_equal "timestamp must not be NaN", error.message
    end

    def test_farce_clock_delegates_to_clock_parse
      assert_current_offset(0.1) { Farce.clock(0.1) }
      assert_in_delta 601.0, Farce.clock(601)
    end

    private

    def assert_current_offset(offset)
      before = Clock.current + offset
      actual = yield
      after = Clock.current + offset

      assert_operator actual, :>=, before
      assert_operator actual, :<=, after
    end

    def assert_wall_time_offset(offset)
      actual = yield

      assert_in_delta offset, actual - Clock.current, 0.1
    end
  end
end
