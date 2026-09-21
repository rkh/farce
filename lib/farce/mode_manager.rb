# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A mode manager encapsulates logic for dealing with Ruby objects that aren't Ractor-shareable.
  # It is a perfect companion piece for APIs that require Ractor-shareable objects.
  #
  # For instance, [Ratomic::Queue](https://mperham.github.io/ratomic/Ratomic/Queue.html) expects Ractor-shareable
  # objects without checking for them. Creating a thin wrapper with a mode manager allows you to use it safely and with
  # non-shareable objects.
  #
  # ```ruby
  # require "ratomic"
  # require "farce"
  #
  # class MyQueue
  #   include Farce::Shareable
  #
  #   def initialize(capacity: 1024, mode: :copy)
  #     @queue   = Ratomic::Queue.new(capacity)
  #     @manager = Farce::ModeManager.new(mode:)
  #   end
  #
  #   def pop = @manager.unwrap(@queue.pop)
  #
  #   def push(value, mode: nil)
  #     @queue.push(@manager.wrap(value, mode:))
  #     self
  #   end
  # end
  #
  # queue = MyQueue.new(capacity: 100, mode: :move)
  #
  # # consume the queue on a different Ractor
  # Ractor.new(queue) { |q| p Ractor.shareable?(q.pop) }
  #
  # object = Object.new
  # q.push(object)
  #
  # # push moved the object into the queue, so it is no longer accessible on the current Ractor
  # Ractor::MovedObject === object # => true
  # ```
  #
  # It is recommended to use a different mode manager for each instance of a queue, port, or whatever else you're
  # wrapping, as {#wrap} may create an {Envelope} and {#unwrap} will only unwrap envelopes created by the same mode
  # manager. This way users can still safely send envelopes they created between Ractors without them getting
  # unexpectedly claimed.
  #
  # @!macro modes
  class ModeManager
    include Internal::Copyable
    include Shareable::Immutable

    # The set of valid modes for wrapping values.
    MODES = ::Set[:copy, :move, :local, :make_shareable, :raise, :shareable_copy].freeze

    # @return [Symbol] The default mode to use when wrapping values.
    attr_reader :mode

    # @!macro modes
    # @param mode [Symbol] The default mode to use when wrapping values. Must be one of the valid modes.
    def initialize(mode: :copy)
      raise ArgumentError, "invalid mode: #{mode.inspect}" unless MODES.include?(mode)
      @mode = mode
      super()
    end

    # Wraps a value in an envelope if it is not Ractor-shareable.
    #
    # @!macro modes
    # @param value [BasicObject] The value to wrap.
    # @param mode [Symbol, nil] The mode to use when wrapping the value. If `nil`, the default mode will be used.
    # @return [BasicObject, Envelope]
    #   The value wrapped in an envelope if it is not Ractor-shareable, or the value itself if it is.
    def wrap(value, mode: nil)
      return value if Ractor.shareable?(value)

      case mode || self.mode
      when :copy           then Envelope::Copy.new(value, self)
      when :local          then Envelope::Local.new(value, self)
      when :make_shareable then Ractor.make_shareable(value)
      when :move           then Envelope::Move.new(value, self)
      when :raise          then raise Ractor::IsolationError, "value is not Ractor-shareable: #{value.inspect}"
      when :shareable_copy then Ractor.make_shareable(value, copy: true)
      else raise ArgumentError, "invalid mode: #{mode.inspect}"
      end
    end

    # Unwraps any envelope created by this mode manager, returning the value inside.
    # Other options, including other envelopes, will be returned as-is.
    # @param value [BasicObject, Envelope] The value to unwrap.
    # @return [BasicObject]
    #   The value inside the envelope if it was created by this mode manager, or the value itself if it was not.
    def unwrap(value)
      return value unless managed_envelope?(value)
      value.value
    end

    # Compares two values managed by this instance. Compatible envelopes can be
    # compared without claiming or opening them.
    # @param left [BasicObject, Envelope] The stored value.
    # @param right [BasicObject, Envelope] The comparison value.
    # @param identity [Boolean] Whether to compare by identity instead of equality.
    # @return [Boolean] Whether the values match.
    def same_value?(left, right, identity: false)
      left_managed  = managed_envelope?(left)
      right_managed = managed_envelope?(right)

      if left_managed && right_managed
        return false if identity && Envelope::Move === left && Envelope::Local === right && !left.owned?
        return left.same_value?(right, identity:)
      end

      return false if identity && left_managed
      return left.same_value?(right) if left_managed

      left  = unwrap(left)
      right = unwrap(right)
      return BasicObject.instance_method(:equal?).bind_call(left, right) if identity

      left == right
    end

    # @return [Boolean] Whether the value is an envelope managed by this mode manager.
    def managed_envelope?(value) = Envelope === value && value.auto_unwrap.equal?(self)
  end
end
