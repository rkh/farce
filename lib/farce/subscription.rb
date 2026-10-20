# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A publisher subscription that can be paused or permanently canceled.
  # Disabling skips new messages. Unsubscribing drains an existing callback queue before stopping it.
  class Subscription
    include Internal::Freeze::Unfreezable
    include Internal::Noncopyable

    # Raised when an operation is attempted on an unsubscribed subscription.
    UnsubscribedError = Class.new(StandardError)

    # @return [Publisher, Ractor::Port, Queue, Counter, Flag, Atom, Set, Vector, Signal, Proc]
    #   the subscriber associated with this subscription
    attr_reader :subscriber

    # @return [Farce::Abstract::Publisher] the publisher associated with this subscription
    attr_reader :publisher

    # @api private
    attr_reader :key

    # @!visibility private
    def initialize(publisher, subscriber, map, callback: false, source: nil, &)
      @callback      = callback
      @enabled       = Flag.new(true)
      @key           = (source || subscriber).__id__
      @map           = map
      @publish       = Ractor.shareable_lambda(&)
      @publisher     = publisher
      @subscribed    = Flag.new(true)
      @subscriber    = subscriber
      # Keep Proc identities alive without making their captured state shareable.
      @source        = source && Envelope.new(source, mode: :local)
      super()
      __freeze__
    end
    private_class_method :new

    # @api private
    def publish(payload)
      return unless enabled?
      @publish.call(subscriber, payload)
      true
    rescue ClosedQueueError, Ractor::ClosedError, FrozenError
      unsubscribe
      false
    end

    # @return [Boolean] whether the subscription is currently enabled
    def enabled? = @subscribed.value && @enabled.value

    # @return [Boolean] whether the subscription has not been permanently canceled
    def subscribed? = @subscribed.value

    # Enables the subscription, allowing it to receive published payloads.
    # @raise [UnsubscribedError] if the subscription has been unsubscribed
    # @return [void]
    def enable
      raise UnsubscribedError, "Cannot enable a subscription that has been unsubscribed" unless @subscribed.value
      @enabled.value = true
    end

    # Disables the subscription, preventing it from receiving published payloads.
    # @return [void]
    def disable = @enabled.value = false

    # Removes the subscription permanently, allowing it and the subscriber to be garbage collected.
    # @return [BasicObject, nil] the subscriber, or nil if already unsubscribed
    def unsubscribe
      return unless @subscribed.compare_and_set(true, false)
      @map.delete_pair(key, self)
      subscriber.seal if @callback
      subscriber
    end
    alias cancel unsubscribe

    private

    define_method(:__freeze__, Kernel.instance_method(:freeze))
  end
end
