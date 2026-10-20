# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestPublisherStdlibQueues < Test
    def publisher_class = Unshared::Publisher

    def test_queue_subscribers_preserve_payloads_and_identity
      queues.each do |queue|
        publisher = publisher_class.new(queue)
        subscription = publisher.subscription_for(queue)
        payload = []

        assert_same queue, subscription.subscriber
        assert_same subscription, publisher.subscribe(queue)
        publisher.publish(nil).publish(false).publish(payload)

        assert_equal 3, queue.size
        assert_nil queue.pop(true)
        refute queue.pop(true)
        assert_same payload, queue.pop(true)
        refute_predicate payload, :frozen?
        assert_predicate queue, :empty?
      end
    end

    def test_full_sized_queue_drops_messages_without_blocking_other_subscribers
      queue = ::Thread::SizedQueue.new(1)
      other = ::Thread::Queue.new
      queue << :existing
      publisher = publisher_class.new(queue, other)
      worker = Thread.new { publisher.publish(:dropped) }

      assert worker.join(5), "publish blocked on a full stdlib SizedQueue"
      assert_same publisher, worker.value
      assert_equal :existing, queue.pop(true)
      assert_equal :dropped, other.pop(true)
      assert publisher.subscribed?(queue)
      publisher.publish(:next)

      assert_equal :next, queue.pop(true)
      assert_equal :next, other.pop(true)
    ensure
      worker&.kill&.join
    end

    def test_closed_queues_are_unsubscribed_without_interrupting_delivery
      queues.each do |queue|
        other = ::Thread::Queue.new
        publisher = publisher_class.new(queue, other)
        subscription = publisher.subscription_for(queue)
        queue << :existing
        queue.close
        publisher.publish(:message)

        refute_predicate subscription, :subscribed?
        refute_predicate subscription, :enabled?
        assert_nil publisher.subscription_for(queue)
        assert_equal :existing, queue.pop(true)
        assert_equal :message, other.pop(true)
      end
    end

    def test_disabling_and_canceling_does_not_close_subscriber_queues
      queues.each do |queue|
        publisher = publisher_class.new
        subscription = publisher.subscribe(queue)
        subscription.disable
        publisher.publish(:disabled)

        assert_predicate queue, :empty?
        subscription.enable
        publisher.publish(:enabled)

        assert_equal :enabled, queue.pop(true)
        publisher.unsubscribe(queue)
        publisher.publish(:canceled)

        assert_predicate queue, :empty?
        refute_predicate queue, :closed?
        queue << :independent

        assert_equal :independent, queue.pop(true)
      end
    end

    def test_queue_subclasses_inherit_delivery_behavior
      unbounded = Class.new(::Thread::Queue).new
      bounded = Class.new(::Thread::SizedQueue).new(1)
      publisher = publisher_class.new(unbounded, bounded)
      publisher.publish(:message)

      assert_equal :message, unbounded.pop(true)
      assert_equal :message, bounded.pop(true)
    end

    private def queues = [::Thread::Queue.new, ::Thread::SizedQueue.new(3)]
  end

  class TestLocalPublisherStdlibQueues < TestPublisherStdlibQueues
    def publisher_class = Local::Publisher
  end
end
