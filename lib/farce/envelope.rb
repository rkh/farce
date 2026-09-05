# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # An envelope can be used to wrap an unshareable value in a shareable object.
  #
  # Once created, the envelope can be shared between Ractors without any objects being moved or copied until the
  # envelope is opened.
  #
  # When a Ractor attempts to open an envelope, it attempts "claim" it. Some envelopes may only be claimed by a single
  # Ractor, others can be claimed by any Ractor. Claims cannot be taken back.
  #
  # @!method claim
  #   Attempts to claim the envelope for the current Ractor.
  #   @return [Envelope, nil]
  #     The envelope if the claim was successful, or `nil` if the envelope has already been claimed by another Ractor.
  #
  # @!method claimed?
  #   @return [Boolean] `true` if the envelope has been claimed by any Ractor, `false` otherwise.
  #
  # @!method owned?
  #   @return [Boolean] `true` if the envelope has been claimed by the current Ractor, `false` otherwise.
  class Envelope
    VAULT_ATOM = Internal::Atom.new
    private_constant :VAULT_ATOM

    include Shareable
    include Abstract::Value

    # Raised when trying to claim an envelope that has already been claimed by another Ractor.
    class AlreadyClaimed < Ractor::IsolationError
    end

    # An envelope that copies its contents. Can be opened by multiple Ractors.
    # The value will be copied once when the envelope is created, and then once per Ractor that opens the envelope.
    #
    # @!method new(value)
    #   @!scope class
    #   @param (see Farce::Envelope#initialize)
    #   @return [Copy, Share] A new envelope wrapping the given value.
    class Copy < Farce::Envelope
      # @overload initialize(value)
      #   @param [Object] value The value to wrap in the envelope.
      def initialize(value, auto_unwrap = nil)
        @vault = VAULT_ATOM.store_if_absent { Internal::Vault.new }
        super
        @vault.copy_in(self, value)
      end

      # (see Envelope#claim)
      def claim = self

      # (see Envelope#claimed?)
      def claimed? = true

      # (see Envelope#owned?)
      def owned? = true

      private def retrieve = @vault.copy_out(self)
    end

    # An envelope that moves its contents. Can only be opened by a single Ractor.
    # The value will be moved once when the envelope is created, and then once when the envelope is opened.
    #
    # @!method new(value)
    #   @!scope class
    #   @param (see Farce::Envelope#initialize)
    #   @return [Move, Share] A new envelope wrapping the given value.
    class Move < Farce::Envelope
      # @overload initialize(value)
      #   @param [Object] value The value to wrap in the envelope.
      def initialize(value, auto_unwrap = nil)
        @vault = VAULT_ATOM.store_if_absent { Internal::Vault.new }
        @owner = Internal::Atom.new
        super
        @vault.move_in(self, value)
      end

      # (see Envelope#claim)
      def claim
        owner = @owner.store_if_absent { Ractor.current }
        self if owner == Ractor.current
      end

      # (see Envelope#claimed?)
      def claimed? = !@owner.value.nil?

      # (see Envelope#owned?)
      def owned? = @owner.value == Ractor.current

      private def retrieve = @vault.move_out(self)
    end

    # An envelope that keeps its contents local to the Ractor that created it.
    # Can only be opened by the Ractor that created it.
    #
    # @!method new(value)
    #   @!scope class
    #   @param (see Farce::Envelope#initialize)
    #   @return [Local, Share] A new envelope wrapping the given value.
    class Local < Farce::Envelope
      # @overload initialize(value)
      #   @param value [Object] The value to wrap in the envelope.
      def initialize(value, auto_unwrap = nil)
        @owner = Ractor.current
        Internal::Storage.ractor[self] = value
        super
      end

      # (see Envelope#claim)
      def claim = owned? ? self : nil

      # (see Envelope#claimed?)
      def claimed? = true

      # (see Envelope#owned?)
      def owned? = @owner == Ractor.current
    end

    # An envelope that wraps a Ractor-shareable value. Can be opened by any Ractor.
    # Defeats the purpose of an envelope, but is provided for code that expects an envelope.
    #
    # @!method new(value)
    #   @!scope class
    #   @param (see Farce::Envelope#initialize)
    #   @return [Share] A new envelope wrapping the given value.
    class Share < Farce::Envelope
      attr_reader :value

      # @overload initialize(value)
      #   @param value [Object] The value to wrap in the envelope. Must be shareable.
      def initialize(value, auto_unwrap = nil)
        raise ArgumentError, "value must be shareable" unless Ractor.shareable?(value)
        @value = value
        super
      end

      # (see Envelope#claim)
      def claim = self

      # (see Envelope#claimed?)
      def claimed? = true

      # (see Envelope#owned?)
      def owned? = true
    end

    # @note
    #   The keyword arguments are only accepted by Envelope itself, not by its subclasses.
    #   Also, if multiple keyword arguments are provided, `mode` takes precedence over `local`, which takes precedence
    #   over `move`.
    #
    # Creates an envelope wrapping the given value. If the value is Ractor-shareable, a {Share} envelope will be
    # created. Otherwise, the type of envelope will be determined by the keyword arguments.
    #
    # @overload new(value, move: false)
    #   @param value [BasicObject] The value to wrap in the envelope.
    #   @param move [Boolean] Whether to create a {Move} envelope. Ignored if `local` or `mode` is provided.
    #   @return [Envelope] A new envelope wrapping the given value.
    #
    # @overload new(value, local: false)
    #   @param value [BasicObject] The value to wrap in the envelope.
    #   @param local [Boolean] Whether to create a {Local} envelope. Ignored if `mode` is provided.
    #   @return [Envelope] A new envelope wrapping the given value.
    #
    # @overload new(value, mode:)
    #   @param value [BasicObject] The value to wrap in the envelope.
    #   @param mode [Symbol, nil] The type of envelope to create. Can be `:move`, `:copy`, or `:local`.
    #   @return [Envelope] A new envelope wrapping the given value.
    #
    # @return [Envelope] A new envelope wrapping the given value.
    def self.new(value, *, **)
      return super if self != Envelope
      return Share.new(value, *) if Ractor.shareable?(value)
      subclass_for(**).new(value, *)
    end

    def self.subclass_for(move: false, local: false, mode: nil)
      case mode
      when :move  then Move
      when :copy  then Copy
      when :local then Local
      when nil    then local ? Local : (move ? Move : Copy)
      else raise ArgumentError, "invalid mode: #{mode.inspect}"
      end
    end
    private_class_method :subclass_for

    # @api private
    attr_reader :auto_unwrap

    # @overload initialize(value)
    #   @param value [BasicObject] The value to wrap in the envelope.
    def initialize(_, auto_unwrap = nil)
      raise ArgumentError, "auto_unwrap needs to be shareable" unless Ractor.shareable?(auto_unwrap)
      @auto_unwrap = auto_unwrap
      super()
    end

    # Attempts to claim the envelope for the current Ractor.
    # Raises an exception if it was unable to claim the envelope.
    # @return [Envelope] The envelope if the claim was successful.
    # @raise [AlreadyClaimed] If the envelope has already been claimed by another Ractor.
    def claim! = claim || raise(AlreadyClaimed, "envelope has already been claimed by another Ractor")

    # Attempts to claim the envelope and retrieves the value if successful.
    # May be called multiple times.
    # @return [BasicObject] The value wrapped in the envelope.
    # @raise [AlreadyClaimed] If the envelope has already been claimed by another Ractor.
    def value = Internal::Storage.ractor.store_if_absent(self) { claim! && retrieve }

    # Compares wrapped values. Compatible envelopes can be compared without
    # claiming or opening either envelope.
    # @param other [BasicObject, Envelope] The value or envelope to compare.
    # @param identity [Boolean] Whether to compare the values by identity instead of equality.
    # @return [Boolean] Whether the wrapped values match.
    def same_value?(other, identity: false)
      if comparison_vault
        other_vault = other.comparison_vault if Envelope === other
        if comparison_vault.equal?(other_vault)
          return comparison_vault.same_value?(self, other, identity:)
        elsif !(Envelope === other) && Ractor.shareable?(other)
          return comparison_vault.same_value?(self, other, identity:, right_stored: false)
        end
      end

      left  = value
      right = other.value if Envelope === other
      return BasicObject.instance_method(:equal?).bind_call(left, right) if identity

      left == right
    end

    # @return [String] String representation of the map, suitable for debugging.
    def inspect
      return "#<#{self.class.name} value=#{value.inspect}>" if owned?
      "#<#{self.class.name} #{claimed? ? "claimed" : "unclaimed"}>"
    end

    # @api private
    # @return [void]
    def pretty_print(pp)
      pp.group(1, "#<#{self.class.name} ", ">") do
        if owned?
          pp.text "value="
          pp.pp(value)
        else
          pp.text claimed? ? "claimed" : "unclaimed"
        end
      end
    end

    protected

    def comparison_vault = defined?(@vault) && @vault
  end
end
