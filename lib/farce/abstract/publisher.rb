# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Shared superclass for all publisher implementations.
    #
    # Implements a publisher-subscriber (pub-sub) pattern.
    # @see Farce::Publisher
    class Publisher
      include Internal::Freeze::Unfreezable
      include Internal::Noncopyable

      # @param subscribers [Array<Publisher, Ractor::Port, Queue, Counter, Flag, Atom, Set, Vector, Signal, Proc>]
      #   the initial subscribers to add to the publisher, see {#subscribe}
      def initialize(*subscribers)
        @closed = Farce::Flag.new
        super()
        subscribers.each { subscribe(it) }
      end

      # @return [Boolean] whether the publisher is closed.
      def closed? = @closed.value

      # Publishes the given payload to all current subscribers.
      # @param payload [BasicObject] the payload to publish
      # @return [self] the publisher itself
      def publish(payload = nil)
        raise "Cannot publish to a closed publisher" if closed?
        map.each_value { it.publish(payload) }
        self
      end
      alias send      publish
      alias <<        publish
      alias broadcast publish

      # @overload subscribe(subscriber)
      #   Adds a subscriber to the publisher.
      #   Publisher subscribers forward messages synchronously to their own subscribers.
      #   Avoid subscribing publishers in a cycle.
      #
      #   @example Forward messages to another publisher
      #     upstream.subscribe(downstream)
      #     upstream.publish(:message) # also publishes to downstream's subscribers
      #
      #   @param subscriber [Publisher, Ractor, Ractor::Port, Queue, Counter, Flag, Atom, Set, Vector, Signal, Proc]
      #     The subscriber to add.
      #
      #     Calls one of the following methods:
      #     * {Ractor#send}
      #     * {Ractor::Port#send}
      #     * {Queue#try_push}
      #     * {Counter#increment} (without arguments)
      #     * {Flag#set}
      #     * {Atom#value=}
      #     * {Set#<<}
      #     * {Vector#<<}
      #     * {Signal#broadcast} (without arguments)
      #     * {Publisher#publish}
      #     * `Proc#call`
      #
      #     Set the default `mode`, `auto_local`, `capacity`, and similar options via initializers for these classes
      #     to influence how data transfer is handled.
      #
      # @overload subscribe(*args, mode: nil, scheduler: nil, capacity: nil)
      #   Adds a subscription callback.
      #   Messages run in order on the selected scheduler. A full queue drops new messages.
      #   Unsubscribing drains queued messages and stops the callback.
      #
      #   @example
      #     counter = Farce::Counter.new
      #
      #     publisher.subscribe(counter) do |counter, payload|
      #       counter.increment
      #       puts "Message ##{counter}: #{payload.inspect}"
      #     end
      #
      #   @param args [Array] additional arguments to pass to the subscriber
      #   @param mode [Symbol, nil] The transfer mode to use
      #   @param scheduler [#schedule, nil] The scheduler to use for running the block
      #   @param capacity [Integer, nil] the maximum queued messages, or nil for an unbounded queue
      #   @yield [*args, payload] the block to be called with the given arguments and payload
      #   @yieldparam args [Array] the additional arguments passed to the block
      #   @yieldparam payload [Object] the payload sent via {#publish}
      #
      # @return [Subscription] the created subscription
      def subscribe(...) = block_given? ? create_subscription(...) : add_subscription(...)
      alias monitor subscribe

      # @param subscriber [BasicObject] the subscriber to retrieve the subscription for
      # @return [Subscription, nil] the subscription for the given subscriber, or nil if none exists.
      def subscription_for(subscriber)
        if subscriber.is_a?(Subscription)
          return unless subscriber.publisher.equal?(self)
          subscription = map[subscriber.key]
          subscription if subscription.equal?(subscriber)
        else
          map[subscriber.__id__]
        end
      end

      # @return [Boolean] whether the given subscriber is currently subscribed.
      def subscribed?(subscriber) = !!subscription_for(subscriber)&.subscribed?

      # Unsubscribes the given subscriber from the publisher.
      # @param subscriber [BasicObject] the subscriber to unsubscribe
      # @return [void]
      def unsubscribe(subscriber) = subscription_for(subscriber)&.unsubscribe
      alias cancel    unsubscribe
      alias unmonitor unsubscribe

      private

      def default_mode = :smart
      def map          = raise NoMethodError, "Subclasses must implement the private `map` method"

      def add_subscription(subscriber)
        if subscriber.is_a?(Subscription)
          existing = subscription_for(subscriber)
          return existing if existing
          subscriber = subscriber.subscriber
        end

        return create_subscription(source: subscriber, &subscriber) if subscriber.is_a?(Proc)
        map = self.map

        map.store_if_absent(subscriber.__id__) do
          case subscriber
          when Internal::BasePort, Ractor
            build_subscription(subscriber, map) { _1.send(_2) }
          when Abstract::Publisher
            build_subscription(subscriber, map) { _1.publish(_2) }
          when Abstract::Queue
            build_subscription(subscriber, map) { _1.try_push(_2) }
          when Abstract::Counter
            build_subscription(subscriber, map) { |c, _| c.increment }
          when Abstract::Flag
            build_subscription(subscriber, map) { |f, _| f.set }
          when Abstract::Atom
            build_subscription(subscriber, map) { _1.value = _2 }
          when Abstract::Set, Abstract::Vector
            build_subscription(subscriber, map) { _1 << _2 }
          when Signal
            build_subscription(subscriber, map) { |s, _| s.broadcast }
          else
            raise ArgumentError, "Unsupported subscriber type: #{subscriber.class}"
          end
        end
      end

      def create_subscription(*, capacity: nil, mode: nil, scheduler: nil, source: nil, &callback)
        mode      ||= default_mode
        callback    = Ractor.shareable_proc(&callback) unless mode == :local || Ractor.shareable?(callback)
        scheduler ||= Farce
        queue       = Farce::Queue.new(capacity:, mode:)
        map         = self.map
        created     = false
        subscription = map.store_if_absent((source || queue).__id__) do
          created = true
          build_subscription(queue, map, callback: true, source:) { _1.try_push(_2) }
        end
        return subscription unless created

        scheduler.schedule(queue, callback, subscription, *, mode:) do |queue, callback, subscription, *args|
          loop do
            begin
              payload = queue.pop
            rescue ClosedQueueError
              break
            end
            callback.call(*args, payload)
          end
        ensure
          subscription.unsubscribe
          queue.close
        end

        scheduled = true
        subscription
      ensure
        unless scheduled
          subscription&.unsubscribe if created
          queue&.close
        end
      end

      def build_subscription(...) = Subscription.__send__(:new, self, ...)
    end
  end
end
