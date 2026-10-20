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

    REGISTER = ClassMirror.new(self)
    private_constant :REGISTER

    class << self
      protected :new
    end

    # Register delivery behavior for subscriber classes from the main Ractor.
    # Subclasses inherit the nearest registered delivery method.
    #
    # @example
    #   Farce::Subscription.define(MyInbox) { |payload| subscriber.push(payload) }
    #
    # @param classes [Array<Class>] the subscriber classes to support
    # @yieldparam payload [BasicObject] the published payload
    # @yieldreceiver [Subscription] the subscription whose {#subscriber} receives the payload
    # @note The block must be convertible to a shareable proc.
    # @return [void]
    def self.define(*classes, &)
      raise LocalJumpError, "no block given" unless block_given?
      definition = Internal.prepare_method_definition(&)
      classes.each do |klass|
        REGISTER.define(klass) do
          define_method(:deliver, definition)
          private :deliver
        end
      end
    end

    # @api private
    def self.build(publisher, subscriber, ...)
      handler = REGISTER[subscriber.class]
      unless handler.private_method_defined?(:deliver)
        raise ArgumentError, "Unsupported subscriber type: #{subscriber.class}"
      end
      handler.new(publisher, subscriber, ...)
    end

    # @return [BasicObject] the subscriber associated with this subscription
    attr_reader :subscriber

    # @return [Farce::Abstract::Publisher] the publisher associated with this subscription
    attr_reader :publisher

    # @api private
    attr_reader :key

    # @!visibility private
    def initialize(publisher, subscriber, map, callback: false, source: nil)
      # Keep Proc identities alive without making their captured state shareable.
      @source     = source && Envelope.new(source, mode: :local)
      @callback   = callback
      @enabled    = Flag.new(true)
      @key        = (source || subscriber).__id__
      @map        = map
      @publisher  = publisher
      @subscribed = Flag.new(true)
      @subscriber = subscriber
      super()
      __freeze__
    end

    # @api private
    def publish(payload)
      return unless enabled?
      deliver(payload)
      true
    rescue ::ClosedQueueError, Ractor::ClosedError, FrozenError
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

    require "farce/subscription/definitions"
  end
end
