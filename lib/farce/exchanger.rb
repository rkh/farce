# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable rendezvous with transfer modes for unshareable values.
  # Values received from a partner are automatically unwrapped.
  #
  # @example Exchanging mutable values between Ractors
  #   exchanger = Farce::Exchanger.new
  #   worker    = Farce::Ractor.new(exchanger) { |shared| shared.exchange([:worker]) }
  #   exchanger.exchange([:main]) # => [:worker]
  class Exchanger < Farce::Abstract::Exchanger
    include Shareable::Unfreezable

    # @!macro modes
    # @param mode [Symbol] the default mode used to transfer values between Ractors
    def initialize(mode: :copy)
      @manager   = ModeManager.new(mode:)
      @exchanger = Internal::Exchanger.new
      super()
    end

    # The default mode used to transfer values between Ractors.
    # @return [Symbol]
    def mode = @manager.mode

    # (see Abstract::Exchanger#exchange)
    # The offered value is prepared before waiting. A timeout does not undo copying,
    # moving, or freezing it. The fallback result is returned unchanged.
    # @!macro modes
    # @param mode [Symbol, nil] the transfer mode, or nil to use the exchanger's default mode
    def exchange(offered, timeout: nil, mode: nil)
      offered   = @manager.wrap(offered, mode:)
      timed_out = false
      result    = @exchanger.exchange(offered, timeout:) { timed_out = true }
      return @manager.unwrap(result) unless timed_out
      yield if block_given?
    end
  end
end
