# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!parse
  #   class Port < Farce::Ractor::Port
  #   end
  #
  # `Ractor::Port` subclass with additional features, namely {#owned? ownership tracking} and {#send mode based sending}.
  class Port < Internal::Port
    include Shareable

    MANAGER = ModeManager.new
    MODES   = ModeManager::MODES.to_h do |mode|
      if mode == :copy
        subclass = self
      else
        subclass = Class.new(Port)
        subclass.set_temporary_name("#{name}[#{mode.inspect}]")
        subclass.class_eval "def self.mode = #{mode.inspect}", __FILE__, __LINE__
      end
      [mode, subclass]
    end.freeze

    private_constant :MANAGER, :MODES

    # @api private
    def self.[](mode)
      raise ArgumentError, "mode mismatch: #{mode.inspect} vs #{self.mode.inspect}" if self != Port && mode != self.mode
      MODES.fetch(mode) { raise ArgumentError, "invalid mode: #{mode.inspect}" }
    end

    # @api private
    # @see #initialize
    def self.new(mode: nil)
      return super() if mode.nil? || mode == self.mode
      self[mode].new
    end

    # @api private
    def self.mode = :copy

    # @overload initialize(mode: :copy)
    #   Creates a new port with the given default mode.
    #
    #   @!macro modes
    #   @param mode [Symbol] The default mode to use when sending values through this port.
    def initialize
      # Important: Cannot set instance variables on a Ractor::Port.
      Internal::Storage[self] = true
      super
    end

    # @attribute [r] mode
    # The port's default mode. Set via {#initialize}.
    # @return [Symbol] The default mode of this port.
    def mode = self.class.mode

    # Checks ractor ownership of this port. The ractor owning this port is the only one that can receive messages
    # through the port or close it.
    # @return [Boolean] `true` if the current Ractor owns this port, `false` otherwise.
    def owned? = !!Internal::Storage[self]

    # Sends a message through the port.
    #
    # @overload send(message, mode: self.mode, auto_local: true)
    #   Sends a message through the port with the given mode.
    #
    #   @!macro modes
    #   @param message [BasicObject] The message to send.
    #   @param mode [Symbol] The mode to use when sending the message.
    #   @param auto_local [Boolean]
    #     If true and send is called from the owning ractor, then the message will be sent in `:local` mode regardless
    #     of the specified mode.
    #
    # @overload send(message, move:, auto_local: false)
    #   Sends a message through the port with the given move flag.
    #   @param message [BasicObject] The message to send.
    #   @param move [Boolean]
    #     If true, the message will be sent in `:move` mode. If false, the message will be sent in the port's default
    #     mode, unless that mode is `:move`, in which case it will be sent in `:copy` mode.
    #   @param auto_local [Boolean]
    #     If true and send is called from the owning ractor, then the message will be sent in `:local` mode regardless
    #     of the specified move flag.
    # @raise [Farce::Ractor::ClosedError] if the port is closed.
    # @return [self]
    def send(message, move: nil, mode: nil, auto_local: nil)
      raise Ractor::ClosedError, "port is closed" if closed?
      auto_local = !mode.nil? if auto_local.nil?
      mode = :local if auto_local && owned?

      if mode.nil?
        if move.nil?
          mode = self.class.mode
        elsif move
          mode = :move
        else
          mode = self.class.mode
          mode = :copy if mode == :move
        end
      end

      super(MANAGER.wrap(message, mode:))
    end

    # Receives a message from the port. Blocks until a message is available or the timeout is reached.
    # @param timeout [Numeric, nil] The maximum time to wait for a message, in seconds. If `nil`, waits indefinitely.
    # @return [BasicObject, nil] The received message, or `nil` if the timeout was reached.
    # @raise [Farce::Ractor::ClosedError] if the port is closed.
    def receive(timeout: nil) = MANAGER.unwrap(super)

    # @return [String] A string representation of the port, including its class name and mode.
    def inspect = super.sub("#<Ractor::Port ", "#<#{self.class.name[/\A[^\[]+/]} mode:#{mode} ")

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
