# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestPublisher < Test
    include Helpers::InternalTestHelpers

    class DeferredScheduler
      attr_reader :arguments, :options

      def schedule(*arguments, **options, &block)
        @arguments = arguments
        @options = options
        @block = block
      end

      def run = @block.call(*@arguments)
    end

    def publisher_class = Publisher

    def test_initial_subscribers
      queue = Queue.new
      publisher = publisher_class.new(queue)
      publisher.publish(:message)

      assert_equal :message, queue.try_pop
    end

    def test_block_subscription_is_registered_and_receives_payloads_in_order
      scheduler = DeferredScheduler.new
      received = []
      publisher = publisher_class.new
      subscription = publisher.subscribe(received, mode: :local, scheduler:) { |output, value| output << value }
      publisher.publish(nil).publish(false).publish(:message)

      assert_same subscription, publisher.subscription_for(subscription)
      subscription.unsubscribe
      scheduler.run

      assert_equal [nil, false, :message], received
    end

    def test_subscription_state
      publisher = publisher_class.new
      queue = Queue.new
      subscription = publisher.subscribe(queue)

      assert_predicate subscription, :subscribed?
      assert publisher.subscribed?(queue)
      assert_same publisher, subscription.publisher
      assert_same queue, subscription.subscriber
      assert_same subscription, publisher.subscription_for(queue)
      subscription.disable

      refute_predicate subscription, :enabled?
      assert_predicate subscription, :subscribed?
      publisher.publish(:disabled)

      assert_nil queue.try_pop
      subscription.enable
      publisher.publish(:enabled)

      assert_equal :enabled, queue.try_pop
      assert_same queue, subscription.unsubscribe
      refute_predicate subscription, :subscribed?
      refute_predicate subscription, :enabled?
      refute publisher.subscribed?(queue)
      subscription.publish(:stale)

      assert_nil queue.try_pop
      assert_nil subscription.unsubscribe
      assert_raises(Subscription::UnsubscribedError) { subscription.enable }
    end

    def test_disabled_callback_stops_on_unsubscribe
      scheduler = DeferredScheduler.new
      publisher = publisher_class.new
      subscription = publisher.subscribe(mode: :local, scheduler:) { raise "unexpected payload" }
      subscription.disable
      subscription.unsubscribe

      assert_predicate subscription.subscriber, :sealed?
      scheduler.run

      assert_predicate subscription.subscriber, :closed?
    end

    def test_full_callback_queue_drains_on_unsubscribe
      scheduler = DeferredScheduler.new
      received = []
      publisher = publisher_class.new
      subscription = publisher.subscribe(received, mode: :local, capacity: 1, scheduler:) { |out, value| out << value }
      publisher.publish(:first).publish(:dropped)
      subscription.unsubscribe

      assert_predicate subscription.subscriber, :sealed?
      scheduler.run

      assert_equal [:first], received
      assert_predicate subscription.subscriber, :closed?
    end

    def test_callback_failure_removes_subscription
      scheduler = DeferredScheduler.new
      publisher = publisher_class.new
      subscription = publisher.subscribe(mode: :local, scheduler:) { raise "callback failed" }
      publisher.publish(:message)

      assert_equal 1, subscription.subscriber.size

      error = assert_raises(RuntimeError) { scheduler.run }

      assert_equal "callback failed", error.message
      refute publisher.subscribed?(subscription)
      assert_predicate subscription.subscriber, :closed?
    end

    def test_duplicate_subscribers_and_replacement
      publisher = publisher_class.new
      queue = Queue.new
      first = publisher.subscribe(queue)

      assert_same first, publisher.subscribe(queue)
      assert_same first, publisher.subscribe(first)
      publisher.publish(:once)

      assert_equal :once, queue.try_pop
      assert_nil queue.try_pop
      first.unsubscribe
      replacement = publisher.subscribe(queue)
      first.unsubscribe

      refute_same first, replacement
      assert_same replacement, publisher.subscription_for(queue)
    end

    def test_counter_keys_use_identity_after_their_values_change
      first = Counter.new
      second = Counter.new
      publisher = publisher_class.new
      first_subscription = publisher.subscribe(first)
      second_subscription = publisher.subscribe(second)
      publisher.publish(:message)

      assert_equal 1, first.value
      assert_equal 1, second.value
      assert_same first_subscription, publisher.subscription_for(first)
      assert_same second_subscription, publisher.subscription_for(second)
    end

    def test_local_counter_and_flag_subscribers
      publisher = publisher_class.new
      counter = Local::Counter.new
      flag = Local::Flag.new
      publisher.subscribe(counter)
      publisher.subscribe(flag)
      publisher.publish(:message)

      assert_equal 1, counter.value
      assert_predicate flag, :value
    end

    def test_internal_counter_and_flag_subscribers
      publisher = publisher_class.new
      counter = Internal::Counter.new
      flag = Internal::Flag.new
      publisher.subscribe(counter)
      publisher.subscribe(flag)
      publisher.publish(:message)

      assert_equal 1, counter.value
      assert_predicate flag, :value
    end

    def test_closed_subscriber_is_removed_without_interrupting_other_deliveries
      closed = Queue.new
      open = Queue.new
      publisher = publisher_class.new
      publisher.subscribe(closed)
      publisher.subscribe(open)
      closed.close
      publisher.publish(:message)

      refute publisher.subscribed?(closed)
      assert_equal :message, open.try_pop
    end

    def test_supported_value_subscribers
      publisher = publisher_class.new
      counter = Counter.new
      flag = Flag.new
      atom = Atom.new
      set = Set.new
      vector = Vector.new
      signal = Signal.new
      generation = signal.generation
      [counter, flag, atom, set, vector, signal].each { publisher.subscribe(it) }
      publisher.publish(:first).publish(:second)

      assert_equal 2, counter.value
      assert_predicate flag, :value
      assert_equal :second, atom.value
      assert_equal Set[:first, :second], set
      assert_equal %i[first second], vector.to_a
      assert_equal generation + 2, signal.generation
    end

    def test_publisher_subscribers_forward_payloads_to_their_subscribers
      output = Queue.new
      direct = Queue.new
      downstream = publisher_class.new(output)
      upstream = publisher_class.new(downstream, direct)
      subscription = upstream.subscription_for(downstream)
      payload = [:message].freeze

      assert_same subscription, upstream.subscribe(downstream)
      assert_same downstream, subscription.subscriber
      [nil, false, payload].each { upstream.publish(it) }

      assert_equal([nil, false, payload], 3.times.map { output.try_pop })
      assert_equal([nil, false, payload], 3.times.map { direct.try_pop })
      assert_predicate output, :empty?
      assert_predicate direct, :empty?
    end

    def test_publisher_forwarding_can_be_disabled_and_canceled
      output = Queue.new
      downstream = publisher_class.new(output)
      upstream = publisher_class.new
      subscription = upstream.subscribe(downstream)
      subscription.disable
      upstream.publish(:disabled)

      assert_predicate output, :empty?
      subscription.enable
      upstream.publish(:enabled)

      assert_equal :enabled, output.try_pop
      upstream.unsubscribe(downstream)
      upstream.publish(:canceled)

      refute_predicate subscription, :subscribed?
      assert_predicate output, :empty?
      downstream.publish(:independent)

      assert_equal :independent, output.try_pop
    end

    def test_messages_flow_through_a_chain_of_publishers
      output = Queue.new
      last = publisher_class.new(output)
      middle = publisher_class.new(last)
      first = publisher_class.new(middle)
      first.publish(:message)

      assert_equal :message, output.try_pop
      assert_predicate output, :empty?
    end

    def test_forwarding_to_other_publisher_variants
      variants = [Publisher, Strict::Publisher, Local::Publisher]
      variants << Unshared::Publisher if [Unshared::Publisher, Local::Publisher].include?(publisher_class)
      variants.each do |variant|
        output = Queue.new
        downstream = variant.new(output)
        upstream = publisher_class.new(downstream)
        upstream.publish(:message)

        assert_equal :message, output.try_pop, variant.name
      end
    end

    def test_subscription_from_another_publisher_does_not_cancel_ours
      queue = Queue.new
      publisher = publisher_class.new
      other = publisher_class.new
      subscription = publisher.subscribe(queue)
      foreign = other.subscribe(queue)
      publisher.unsubscribe(foreign)

      assert_predicate subscription, :subscribed?
      assert_nil publisher.subscription_for(foreign)
    end

    def test_aliases_and_unknown_subscribers
      publisher = publisher_class.new
      queue = Queue.new
      publisher.monitor(queue)
      publisher.send(:first).broadcast(:second) << :third

      assert_equal(%i[first second third], 3.times.map { queue.try_pop })
      publisher.unmonitor(queue)
      publisher.cancel(queue)

      assert_nil publisher.subscription_for(queue)
      assert_nil publisher.unsubscribe(Object.new)
      assert_raises(ArgumentError) { publisher.subscribe(Object.new) }
    end

    def test_live_objects_reject_freezing_and_marshaling
      publisher = publisher_class.new
      subscription = publisher.subscribe(Queue.new)

      [publisher, subscription].each do |object|
        refute_predicate object, :frozen?
        assert_raises(TypeError) { object.freeze }
        assert_raises(TypeError) { Marshal.dump(object) }
        assert_raises(TypeError) { object.dup }
        assert_raises(TypeError) { object.clone }
      end
    end

    def test_default_scheduler_runs_callback_with_arguments
      output = Queue.new
      publisher = publisher_class.new
      subscription = publisher.subscribe(output, :prefix) { |out, prefix, value| out << [prefix, value] }
      publisher.publish(:message)

      assert_equal %i[prefix message], output.pop(timeout: 5)
      assert_same subscription, publisher.subscribe(subscription)
    ensure
      subscription&.unsubscribe
    end

    def test_proc_subscribers_are_registered_once_and_can_be_looked_up
      counter = Counter.new
      callback = proc { |value| value.increment }
      publisher = publisher_class.new
      subscription = publisher.subscribe(callback)

      assert_same subscription, publisher.subscribe(callback)
      assert_same subscription, publisher.subscribe(subscription)
      assert_same subscription, publisher.subscription_for(callback)
      publisher.publish(counter)

      assert_equal 1, counter.wait_until_value(1, timeout: 5)
      publisher.unsubscribe(callback)

      refute_predicate subscription, :subscribed?
      assert_nil publisher.subscription_for(callback)
    ensure
      subscription&.unsubscribe
    end

    def test_scheduler_rejection_rolls_back_subscription
      scheduler = DeferredScheduler.new
      def scheduler.schedule(...)
        super
        raise SchedulerClosedError, "scheduler closed"
      end
      publisher = publisher_class.new

      assert_raises(SchedulerClosedError) { publisher.subscribe(mode: :local, scheduler:) { nil } }
      queue, _, subscription = scheduler.arguments

      refute_predicate subscription, :subscribed?
      assert_predicate queue, :closed?
      assert_nil publisher.subscription_for(subscription)
    end

    def test_copy_mode_preserves_the_published_object
      scheduler = DeferredScheduler.new
      output = Queue.new
      publisher = publisher_class.new
      subscription = publisher.subscribe(output, mode: :copy, scheduler:) { |out, value| out << value }
      original = [:original]
      publisher.publish(original)
      original << :changed
      subscription.unsubscribe
      scheduler.run

      assert_equal :copy, scheduler.options[:mode]
      assert_equal :copy, subscription.subscriber.mode
      assert_equal Ractor.builtin? ? [:original] : %i[original changed], output.try_pop
      assert_equal %i[original changed], original
    end

    def test_callback_runs_on_the_current_fiber_scheduler
      return unless Fiber.respond_to?(:set_scheduler)
      Fiber.set_scheduler(Helpers::QueueTestScheduler.new)
      received = []
      publisher = publisher_class.new
      subscription = publisher.subscribe(mode: :local) do |value|
        received << [value, Internal.storage_thread(Thread.current)]
      end
      publisher.publish(:message)
      subscription.unsubscribe
      Fiber.set_scheduler(nil)

      assert_equal [[:message, Internal.storage_thread(Thread.current)]], received
      refute publisher.subscribed?(subscription)
    ensure
      subscription&.unsubscribe
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_canceled_handle_does_not_resolve_to_a_replacement
      queue = Queue.new
      publisher = publisher_class.new
      old = publisher.subscribe(queue)
      old.unsubscribe
      replacement = publisher.subscribe(queue)
      publisher.unsubscribe(old)

      assert_nil publisher.subscription_for(old)
      assert_predicate replacement, :subscribed?
    end

    def test_subscribes_to_ports_and_ractors
      publisher = publisher_class.new
      port = Port.new
      worker = Ractor.new { Ractor.receive }
      publisher.subscribe(port)
      publisher.subscribe(worker)
      publisher.publish(:message)

      assert_equal :message, port.receive(timeout: 5)
      assert_equal :message, ractor_value(worker)
      publisher.unsubscribe(worker)
      port.close
      publisher.publish(:closed)

      refute publisher.subscribed?(port)
    ensure
      port&.close
    end

    def test_external_callback_queue_closure_removes_subscription
      scheduler = DeferredScheduler.new
      publisher = publisher_class.new
      subscription = publisher.subscribe(mode: :local, scheduler:) { raise "unexpected callback" }
      subscription.subscriber.close
      scheduler.run

      refute_predicate subscription, :subscribed?
      assert_nil publisher.subscription_for(subscription)
    end

    def test_frozen_subscriber_is_removed
      publisher = publisher_class.new
      vector = Vector.new
      publisher.subscribe(vector)
      vector.freeze
      publisher.publish(:message)

      refute publisher.subscribed?(vector)
      assert_empty vector
    end

    def test_concurrent_subscribers_share_one_subscription
      publisher = publisher_class.new
      queue = Queue.new
      gate = Thread::Queue.new
      workers = 8.times.map do
        Thread.new do
          gate.pop
          publisher.subscribe(queue)
        end
      end
      workers.each { gate << true }
      subscriptions = workers.map do |worker|
        assert worker.join(5), "subscription worker did not finish"
        worker.value
      end

      assert_equal [subscriptions.first], subscriptions.uniq
      publisher.publish(:once)

      assert_equal :once, queue.try_pop
      assert_nil queue.try_pop
    ensure
      workers&.each { it.kill.join }
    end
  end

  class TestStrictPublisher < TestPublisher
    def publisher_class = Strict::Publisher

    def test_copy_mode_preserves_the_published_object
      scheduler = DeferredScheduler.new
      output = Queue.new
      publisher = publisher_class.new
      subscription = publisher.subscribe(output, mode: :copy, scheduler:) { |out, value| out << value }
      original = [:original].freeze
      publisher.publish(original)
      subscription.unsubscribe
      scheduler.run

      assert_equal :copy, scheduler.options[:mode]
      assert_equal :copy, subscription.subscriber.mode
      assert_same original, output.try_pop
    end

    def test_all_publish_methods_reject_unshareable_payloads_before_delivery
      publisher = publisher_class.new
      queue = Queue.new(mode: :local)
      counter = Counter.new
      publisher.subscribe(queue)
      publisher.subscribe(counter)
      payload = Helpers::ModePayload.new(:original)

      %i[publish send << broadcast].each do |method|
        assert_raises(Ractor::IsolationError, method.to_s) { publisher.public_send(method, payload) }
        assert_nil queue.try_pop
        assert_equal 0, counter.value
        assert_equal :original, payload.value
        refute_predicate payload, :frozen?
      end
    end

    def test_rejects_mutable_ruby_payloads_on_native_ractors
      return unless Internal.native_ractors?
      publisher = publisher_class.new

      [[], +"message", [[]].freeze].each do |payload|
        assert_raises(Ractor::IsolationError) { publisher.publish(payload) }
        refute Ractor.shareable?(payload)
      end
    end

    def test_all_publish_methods_preserve_shareable_payloads_and_default_to_nil
      queue = Queue.new
      publisher = publisher_class.new(queue)
      payload = Ractor.make_shareable({ values: [:message] })

      %i[publish send << broadcast].each do |method|
        assert_same publisher, publisher.public_send(method, payload)
        assert_same payload, queue.try_pop
        assert_same publisher, publisher.public_send(method, false)
        refute queue.try_pop
        assert_same publisher, publisher.public_send(method)
        assert_equal 1, queue.size
        assert_nil queue.try_pop
      end
    end
  end

  class TestUnsharedPublisher < TestPublisher
    def publisher_class = Unshared::Publisher

    def test_default_callback_keeps_its_binding_and_mutable_captures
      received = []
      completed = Queue.new
      receiver = self
      publisher = publisher_class.new
      subscription = publisher.subscribe do |value|
        received << value
        completed << equal?(receiver)
      end
      publisher.publish(:message)

      assert completed.pop(timeout: 5)
      assert_equal [:message], received
    ensure
      subscription&.unsubscribe
    end

    def test_unshared_and_local_value_subscribers
      publisher = publisher_class.new
      queue = Unshared::Queue.new
      counter = Local::Counter.new
      flag = Local::Flag.new
      atom = Unshared::Atom.new
      set = Unshared::Set.new
      vector = Unshared::Vector.new
      [queue, counter, flag, atom, set, vector].each { publisher.subscribe(it) }
      publisher.publish(:message)

      assert_equal :message, queue.try_pop
      assert_equal 1, counter.value
      assert_predicate flag, :value
      assert_equal :message, atom.value
      assert_includes set, :message
      assert_equal [:message], vector.to_a
    end
  end

  class TestLocalPublisher < TestUnsharedPublisher
    def publisher_class = Local::Publisher

    def test_forwarding_uses_the_downstream_publishers_current_scope
      parent = Queue.new
      child = Queue.new
      downstream = publisher_class.new(parent, scope: :thread)
      upstream = Publisher.new(downstream)
      worker = Thread.new do
        downstream.subscribe(child)
        upstream.publish(:child)
      end

      assert worker.join(5), "forwarding worker did not finish"
      assert_equal :child, child.try_pop
      assert_predicate parent, :empty?
      upstream.publish(:parent)

      assert_equal :parent, parent.try_pop
      assert_predicate child, :empty?
    ensure
      worker&.kill&.join
    end

    def test_scopes_keep_subscriptions_separate
      Farce::SCOPES.each do |scope|
        publisher = publisher_class.new(scope:)
        parent = Queue.new
        publisher.subscribe(parent)
        observed = Queue.new
        work = lambda do
          child = Queue.new
          observed << publisher.subscribed?(parent)
          publisher.subscribe(child)
          publisher.publish(:child)
          observed << child.try_pop
        end
        case scope
        when :fiber, :fiber_storage
          Fiber.new(storage: scope == :fiber_storage ? nil : true, &work).resume
        when :thread, :thread_group
          Thread.new(&work).join
        when :ractor
          remote = Ractor.new(publisher, parent, observed) do |pub, original, results|
            child = Queue.new
            results << pub.subscribed?(original)
            pub.subscribe(child)
            pub.publish(:child)
            results << child.try_pop
          end
          ractor_value(remote)
        end

        shared = scope == :thread_group

        assert_equal shared, observed.pop(timeout: 5), scope.to_s
        assert_equal :child, observed.pop(timeout: 5), scope.to_s
        if shared
          assert_equal :child, parent.try_pop, scope.to_s
        else
          assert_nil parent.try_pop, scope.to_s
        end
        publisher.publish(:parent)

        assert_equal :parent, parent.try_pop, scope.to_s
      end
    end

    def test_invalid_scope
      assert_raises(ArgumentError) { publisher_class.new(scope: :invalid) }
    end
  end

  class TestSharedPublisher < Test
    include Helpers::InternalTestHelpers

    def publisher_class = Publisher

    def test_publisher_forwarding_from_another_ractor
      output = Queue.new
      downstream = publisher_class.new(output)
      upstream = publisher_class.new(downstream)
      worker = Ractor.new(upstream) do |publisher|
        publisher.publish(:message)
        :done
      end

      assert_equal :done, ractor_value(worker)
      assert_equal :message, output.try_pop
    end

    def test_forwarding_preserves_strict_downstream_validation
      output = Queue.new(mode: :local)
      downstream = Strict::Publisher.new(output)
      upstream = publisher_class.new(downstream)

      assert_raises(Ractor::IsolationError) { upstream.publish(Helpers::ModePayload.new(:message)) }
      assert_predicate output, :empty?
      assert upstream.subscribed?(downstream)
      upstream.publish(:valid)

      assert_equal :valid, output.try_pop
    end

    def test_publish_and_cancel_from_another_ractor
      queue = Queue.new
      publisher = publisher_class.new(queue)
      subscription = publisher.subscription_for(queue)

      assert Ractor.shareable?(publisher)
      assert Ractor.shareable?(subscription)
      worker = Ractor.new(publisher, subscription) do |pub, sub|
        pub.publish(:remote)
        sub.unsubscribe
        pub.publish(:ignored)
        :done
      end

      assert_equal :done, ractor_value(worker)
      assert_equal :remote, queue.try_pop
      assert_nil queue.try_pop
      refute publisher.subscribed?(queue)
    end

    def test_remote_publisher_delivers_to_a_local_callback
      output = Queue.new
      publisher = publisher_class.new
      subscription = publisher.subscribe(output) { |out, payload| out << payload }
      worker = Ractor.new(publisher) do |pub|
        pub.publish(:remote)
        :done
      end

      assert_equal :done, ractor_value(worker)

      assert_equal :remote, output.pop(timeout: 5)
    ensure
      subscription&.unsubscribe
    end

    def test_callback_runs_on_a_ractor_scheduler
      output = Queue.new
      scheduler = Scheduler.new
      worker = scheduler.launch(Ractor)
      publisher = publisher_class.new
      subscription = publisher.subscribe(output, scheduler:) do |out, payload|
        out << [Ractor.main?, payload]
      end
      publisher.publish(:remote)

      assert_equal [false, :remote], output.pop(timeout: 5)
      subscription.unsubscribe
      scheduler.close
      worker.join if worker.respond_to?(:join)
    ensure
      subscription&.unsubscribe
      scheduler&.close
    end
  end

  class TestSharedStrictPublisher < TestSharedPublisher
    def publisher_class = Strict::Publisher
  end
end
