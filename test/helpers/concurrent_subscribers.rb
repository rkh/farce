# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Helpers
  module ConcurrentSubscribers
    def publisher_classes = [Farce::Unshared::Publisher, Farce::Local::Publisher]

    def test_atomic_fixnum_subscribers_count_messages
      publisher_classes.each do |klass|
        counter = concurrent_namespace::AtomicFixnum.new(5)
        publisher = klass.new(counter)
        publisher.publish(nil).publish(false).publish(:message)

        assert_equal 8, counter.value
      end
    end

    def test_atomic_boolean_subscribers_set_true_regardless_of_payload
      publisher_classes.each do |klass|
        boolean = concurrent_namespace::AtomicBoolean.new(false)
        publisher = klass.new(boolean)
        publisher.publish(false)

        assert_predicate boolean, :value
        boolean.value = false
        publisher.publish(nil)

        assert_predicate boolean, :value
      end
    end

    def test_reference_subscribers_store_the_latest_payload
      publisher_classes.each do |klass|
        reference_type = concurrent_namespace.const_defined?(:AtomicReference, false) ?
          concurrent_namespace::AtomicReference : concurrent_namespace::Atom
        reference = reference_type.new
        publisher = klass.new(reference)
        publisher.publish(false)

        refute reference.value
        publisher.publish(nil)

        assert_nil reference.value
        payload = [:message].freeze
        publisher.publish(payload)

        assert_same payload, reference.value
      end
    end

    def test_event_subscribers_can_be_disabled_reset_and_canceled
      publisher_classes.each do |klass|
        event = concurrent_namespace::Event.new
        publisher = klass.new
        subscription = publisher.subscribe(event)

        assert_same subscription, publisher.subscribe(event)
        subscription.disable
        publisher.publish(:disabled)

        refute_predicate event, :set?
        subscription.enable
        publisher.publish(false)

        assert event.wait(0)
        event.reset
        publisher.publish(nil)

        assert event.wait(0)
        publisher.unsubscribe(event)
        event.reset
        publisher.publish(:canceled)

        refute_predicate event, :set?
      end
    end

    def test_latch_subscribers_stop_counting_at_zero
      publisher_classes.each do |klass|
        latch = concurrent_namespace::CountDownLatch.new(2)
        publisher = klass.new(latch)
        publisher.publish(nil)

        assert_equal 1, latch.count
        refute latch.wait(0)
        publisher.publish(false).publish(:extra)

        assert_equal 0, latch.count
        assert latch.wait(0)
        assert publisher.subscribed?(latch)
      end
    end

    def test_notification_subscribers_do_not_transfer_the_payload
      publisher_classes.reject { it == Farce::Strict::Publisher }.each do |klass|
        event = concurrent_namespace::Event.new
        latch = concurrent_namespace::CountDownLatch.new(1)
        counter = concurrent_namespace::AtomicFixnum.new
        boolean = concurrent_namespace::AtomicBoolean.new
        publisher = klass.new(event, latch, counter, boolean)
        payload = Object.new
        publisher.publish(payload)

        refute_predicate payload, :frozen?
        assert event.wait(0)
        assert latch.wait(0)
        assert_equal 1, counter.value
        assert_predicate boolean, :value
      end
    end

    def test_subclasses_inherit_event_and_latch_delivery
      publisher_classes.each do |klass|
        event = Class.new(concurrent_namespace::Event).new
        latch = Class.new(concurrent_namespace::CountDownLatch).new(1)
        publisher = klass.new(event, latch)
        publisher.publish(:message)

        assert event.wait(0)
        assert latch.wait(0)
      end
    end

    def test_subscribers_observe_concurrent_publishing
      publisher_classes.each do |klass|
        counter = concurrent_namespace::AtomicFixnum.new
        latch = concurrent_namespace::CountDownLatch.new(20)
        publisher = klass.new(counter, latch)
        workers = 4.times.map { Thread.new { 5.times { publisher.publish(:message) } } }
        workers.each do |worker|
          assert worker.join(5), "publisher worker did not finish"
          worker.value
        end

        assert_equal 20, counter.value
        assert latch.wait(0)
      ensure
        workers&.each { it.kill.join }
      end
    end
  end
end
