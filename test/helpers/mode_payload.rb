# frozen_string_literal: true

module Helpers
  class ModePayload
    include Farce::Unshareable::Movable
    include Farce::Unshareable::Copyable

    attr_accessor :value

    def initialize(value)
      @value = value
    end

    def ==(other) = other.is_a?(self.class) && value == other.value

    def inspect = "#<ModePayload #{value.inspect}>"
  end
end
