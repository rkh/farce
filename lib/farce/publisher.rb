# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A message multiplexer.
  # Implements the publisher-subscriber protocol.
  #
  # @example
  #   publisher = Farce::Publisher.new
  #
  #   # Count how many messages have been received
  #   counter = Farce::Counter.new
  #   publisher.subscribe(counter)
  #
  #   # Trigger a callback whenever a message is published
  #   publisher.subscribe do |message|
  #     puts "Received message: #{message}"
  #   end
  #
  #   # Send messages to a queue
  #   queue = Farce::Queue.new
  #   publisher.subscribe(queue)
  #
  #   # Keep track of the last published value
  #   atom = Farce::Atom.new
  #   publisher.subscribe(atom)
  #
  #   # Send messages to a Ractor
  #   ractor = Ractor.new do
  #     while message = Ractor.receive
  #       puts "Received message in Ractor: #{message}"
  #     end
  #   end
  #   publisher.subscribe(ractor)
  #
  #   # Publish some messages
  #   publisher.publish("Hello, world!")
  #   publisher.publish("Another message")
  #
  #   queue.pop     # => "Hello, world!"
  #   atom.value    # => "Another message"
  #   counter.value # => 2
  class Publisher < Farce::Abstract::Publisher
    include Shareable::Unfreezable

    # @overload initialize(*subscribers)
    #   (see Farce::Abstract#initialize)
    def initialize(*subscribers)
      @map = Strict::Map.new
      super()
      subscribers.each { subscribe(it) }
    end

    private attr_reader :map
  end
end
