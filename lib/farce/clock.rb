# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Wrapper module for clock-related functionality.
  # Converts everything to a monotonic clock time in seconds, from when `farce/clock` was loaded.
  # @see Farce.clock
  module Clock
    extend self

    CLOCK_MONOTONIC = Process::CLOCK_MONOTONIC
    CUTOFF_CLOCK    = 600           # 10 minutes
    CUTOFF_TIME     = 1_000_000_000 # September 9, 2001 or 31-ish years ¯\_(ツ)_/¯
    MONOTONIC       = Process.clock_gettime(CLOCK_MONOTONIC)
    REAL_TIME       = Process.clock_gettime(Process::CLOCK_REALTIME)
    TIME_DIFF       = REAL_TIME - MONOTONIC
    private_constant :CLOCK_MONOTONIC, :CUTOFF_CLOCK, :CUTOFF_TIME, :MONOTONIC, :REAL_TIME, :TIME_DIFF

    # Converts the given value to a monotonic clock time in seconds, assuming that it already represents a clock time.
    # Returns the current clock time if no value is given.
    #
    # Same as calling {#parse parse(clock: value)}
    #
    # @param value [nil, #to_f] the value to convert to clock time
    # @raise [ArgumentError] if the resulting clock time is NaN
    # @return [Float] the clock time in seconds
    def clock(value) = validate_timestamp(value ? value.to_f : current)

    # Returns the current monotonic clock time in seconds.
    # @return [Float] the clock time in seconds
    def current = Process.clock_gettime(CLOCK_MONOTONIC) - MONOTONIC

    # Converts the given value to a monotonic clock time in seconds.
    #
    # @param value [nil, Numeric, Time, ActiveSupport::Duration, Hash]
    #   The value to convert to clock time
    #
    #   If the value is `nil`, it is treated as the current time.
    #
    #   Numeric values that aren't an ActiveSupport::Duration use the following cutoffs:
    #   * Up to 600 (10 minutes): Offsets from the current time.
    #   * Greater than 600, up to one billion: Clock times (like the value returned by {#current}).
    #   * Greater than one billion: UNIX timestamps (like the value returned by `Time.now.to_f`).
    #
    #   Hashes may contain up to one key-value pair, with the key being one of the following:
    #   * `:at`, `:time`, or `:timeout_at` for {#time fixed times}
    #   * `:delay`, `:in`, `:offset`, `:timeout`, or `:wait` for {#offset relative offsets}
    #   * `:clock` for {#clock clock times}
    #
    # @raise [ArgumentError] if the resulting clock time is NaN
    # @return [Float] the clock time in seconds
    def parse(value)
      case value
      when nil, UNDEFINED then return current
      when Float, Integer then return value > CUTOFF_CLOCK ? time(value) : offset(value)
      when Time           then return time(value)
      when Hash
        case value.size
        when 0 then return current
        when 1 then return public_send(*value.first)
        end
      when MAYBE::ActiveSupport::Duration then return offset(value)
      else
        return at(value.to_time) if value.respond_to?(:to_time)
        return parse(value.to_f) if value.is_a?(Numeric)
      end
      raise TypeError, "Cannot convert #{value.inspect} to clock time"
    end

    # Converts the given value to a monotonic clock time in seconds.
    # The value is assumed to be a fixed point in time (independent of the current time).
    #
    # If the value is numeric and greater than one billion, it is treated as a UNIX timestamp.
    # Meaning that you can't pass a clock time greater than 31 years, or a timestamp before September 9, 2001.
    #
    # @param value [Numeric, Time] the value to convert to clock time
    # @raise [ArgumentError] if the resulting clock time is NaN
    # @return [Float] the clock time in seconds
    def time(value)
      case value
      when Float, Integer then timestamp = value > CUTOFF_TIME ? value - REAL_TIME : Float(value)
      when Time           then timestamp = value.to_f - REAL_TIME
      when Numeric        then return time(value.to_f)
      else raise TypeError, "Cannot convert #{value.class} to clock time"
      end
      validate_timestamp(timestamp)
    end

    # Converts the given value to a monotonic clock time in seconds.
    # The value is assumed to be a relative offset from the current time.
    #
    # @param value [Numeric] the value to convert to clock time
    # @raise [ArgumentError] if the resulting clock time is NaN
    # @return [Float] the clock time in seconds
    def offset(value)
      return validate_timestamp(current + value.to_f) if value.is_a?(Numeric)
      raise TypeError, "Cannot convert #{value.class} to clock time"
    end

    alias now        current
    alias at         time
    alias timeout_at time
    alias delay      offset
    alias in         offset
    alias timeout    offset
    alias wait       offset

    private

    def validate_timestamp(timestamp)
      raise ArgumentError, "timestamp must not be NaN" if timestamp.nan?
      timestamp
    end
  end
end
