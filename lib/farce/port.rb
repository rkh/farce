# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!parse
  #   class Port < Farce::Ractor::Port
  #   end
  #
  # `Ractor::Port` subclass with additional features, namely {#owned? ownership tracking} and
  # {#send mode based sending}.
  class Port < Internal::Port
    include Shareable

    MANAGER    = ModeManager.new
    SUBCLASSES = ModeManager::MODES.to_h do |mode|
      if mode == :copy
        normal = self
      else
        normal = Class.new(self)
        normal.set_temporary_name("#{name}[#{mode.inspect}]")
        normal.class_eval "def self.mode = #{mode.inspect}", __FILE__, __LINE__
      end

      auto_local = Class.new(normal)
      auto_local.set_temporary_name("#{name}[#{mode.inspect}, auto_local: true]")
      auto_local.class_eval "def self.auto_local? = true", __FILE__, __LINE__
      [mode, [normal, auto_local].freeze]
    end.freeze

    private_constant :MANAGER, :SUBCLASSES

    # @api private
    def self.[](mode, auto_local: false)
      if self == Port
        return SUBCLASSES.dig(mode, auto_local ? 1 : 0) || raise(ArgumentError, "invalid mode: #{mode.inspect}")
      end
      raise ArgumentError, "mode mismatch: #{mode.inspect} vs #{self.mode.inspect}" if mode != self.mode
      return self if auto_local? == auto_local
      raise ArgumentError, "auto_local mismatch: #{auto_local.inspect} vs #{auto_local?.inspect}"
    end

    # @api private
    def self.mode = :copy

    # @api private
    def self.auto_local? = false

    # @!visibility private
    # (see #initialize)
    def self.new(mode: nil, auto_local: nil)
      return super() if mode.nil? && auto_local.nil?
      auto_local = auto_local? if auto_local.nil?
      self[mode || self.mode, auto_local: auto_local].new
    end

    # @overload initialize(mode: :copy, auto_local: false)
    #   Creates a new port with the given default mode.
    #
    #   @!macro modes
    #
    #   @param mode [Symbol]
    #     The default mode to use when sending values through this port.
    #
    #   @param auto_local [Boolean]
    #     Whether to automatically use `:local` mode when sending values from the owning ractor.
    def initialize(...)
      # Important: Cannot set instance variables on a Ractor::Port.
      Internal::Storage[self] = true
      super
    end

    # @attribute [r] mode
    # The port's default mode. Set via {#initialize}.
    # @return [Symbol] The default mode of this port.
    # @see #send
    def mode = self.class.mode

    # Whether or not auto_local is enabled by default. Set via {#initialize}.
    # @return [Boolean] `true` if auto_local is enabled, `false` otherwise.
    # @see #send
    def auto_local? = self.class.auto_local?

    # Checks ractor ownership of this port. The ractor owning this port is the only one that can receive messages
    # through the port or close it.
    # @return [Boolean] `true` if the current Ractor owns this port, `false` otherwise.
    def owned? = !!Internal::Storage[self]

    # Sends a message through the port.
    #
    # @param message [BasicObject] The message to send.
    #
    # @param move [Boolean, nil]
    #   Used to determine `mode` if it is not explicitly specified.
    #   If true, the message will be sent in `:move` mode.
    #   If false, the message will be sent in the port's default mode, unless that mode is `:move`, in which case it
    #   will be sent in `:copy` mode.
    #
    # @param mode [Symbol, nil]
    #   The mode to use when sending the message. If nil, the mode will be determined by the `move` parameter and the
    #   port's default mode.
    #
    # @param auto_local [Boolean, nil]
    #   If `true`, or `nil` and {#auto_local?} is `true`, and send is called from the owning ractor, then the message
    #   will be sent in `:local` mode regardless of the specified mode or move flag.
    #
    # @raise [Farce::Ractor::ClosedError] if the port is closed.
    # @return [self]
    def send(message, move: nil, mode: nil, auto_local: nil)
      return super(message) if Ractor.shareable?(message)
      raise Ractor::ClosedError, "port is closed" if closed?
      auto_local = auto_local? if auto_local.nil?

      if auto_local && owned?
        mode = :local
      elsif mode.nil?
        mode = self.mode
        case move
        when true  then mode = :move
        when false then mode = :copy if mode == :move
        when nil # no-op
        else raise ArgumentError, "invalid move: #{move.inspect}"
        end
      end

      case mode
      when :copy then super(message)
      when :move then super(message, move: true)
      else super(MANAGER.wrap(message, mode:))
      end
    end

    alias << send
    alias push send

    # Receives a message from the port. Blocks until a message is available or the timeout is reached.
    # @param timeout [Numeric, nil] The maximum time to wait for a message, in seconds. If `nil`, waits indefinitely.
    # @return [BasicObject, nil] The received message, or `nil` if the timeout was reached.
    # @raise [Farce::Ractor::ClosedError] if the port is closed.
    def receive(timeout: nil) = MANAGER.unwrap(super)
    alias pop receive

    # @return [String] A string representation of the port, including its class name and mode.
    def inspect = super.sub(/\A#<.+? (?=(?:to|id):#?\d+)/, "#<Farce::Port mode:#{mode} ")

    # @api private
    def pretty_print(pp)
      string = inspect
      return pp.text(string) unless match = string.match(/\A#<([\w:]+)((?: \w+:#?\w+)+)>\z/)

      pp.group(1, "#<#{match[1]}", ">") do
        match[2].split.each do |pair|
          pp.breakable " "
          key, value = pair.split(":", 2)
          pp.text "#{key}:"
          pp.text value
        end
      end
    end
  end
end
