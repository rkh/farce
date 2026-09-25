# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class ActiveSupportClockTests < Test
    def test_durations_are_offsets_regardless_of_numeric_cutoffs
      [-1.second, 0.seconds, 0.1.seconds, 600.seconds, 601.seconds, 1_000_000_001.seconds].each do |duration|
        [Clock.method(:parse), Farce.method(:clock)].each do |convert|
          before = Clock.current + duration.to_f
          actual = convert.call(duration)
          after = Clock.current + duration.to_f

          assert_operator actual, :>=, before
          assert_operator actual, :<=, after
        end
      end
    end

    def test_other_values_keep_core_parsing
      assert_in_delta 601.0, Clock.parse(601)
      assert_in_delta 601.0, Clock.parse(clock: 601)
      assert_equal Clock.time(Time.at(1_000_000_001)), Clock.parse(Time.at(1_000_000_001))
      assert_raises(TypeError) { Clock.parse("601") }
      assert_raises(ArgumentError) { Clock.parse(Float::NAN) }
    end
  end
end
