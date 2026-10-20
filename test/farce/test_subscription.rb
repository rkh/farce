# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestSubscription < Test
    include Helpers::InternalTestHelpers

    class Inbox
      include Shareable::Unfreezable

      attr_reader :messages

      def initialize
        @messages = Queue.new
        super
      end
    end

    class ChildInbox < Inbox
    end

    def test_custom_delivery_is_inherited_by_subclasses
      publisher = Publisher.new
      inbox = ChildInbox.new

      assert_raises(ArgumentError) { publisher.subscribe(inbox) }
      Subscription.define(Inbox) { |payload| subscriber.messages << payload }
      subscription = publisher.subscribe(inbox)
      worker = Ractor.new(publisher) do |pub|
        pub.publish(:message)
        :done
      end

      assert_equal :done, ractor_value(worker)
      assert_kind_of Subscription, subscription
      assert_equal :message, inbox.messages.try_pop
      subscription.disable
      publisher.publish(:disabled)

      assert_predicate inbox.messages, :empty?
      subscription.enable
      publisher.publish(:enabled)

      assert_equal :enabled, inbox.messages.try_pop
      subscription.unsubscribe
      publisher.publish(:canceled)

      assert_predicate inbox.messages, :empty?
    end

    def test_definition_requires_a_block_and_concrete_classes
      assert_raises(LocalJumpError) { Subscription.define(Inbox) }
      assert_raises(TypeError) { Subscription.define(Enumerable) { nil } }
      assert_raises(TypeError) { Subscription.define(nil) { nil } }
    end

    def test_definition_is_restricted_to_the_main_ractor
      worker = Ractor.new do
        Farce::Subscription.define(String) { nil }
        :unexpected
      rescue Ractor::IsolationError
        :rejected
      end

      assert_equal :rejected, ractor_value(worker)
    end

    def test_main_ractor_subscribers
      publisher = Publisher.new(Ractor.main)
      publisher.publish(:message)

      assert_equal :message, Ractor.receive
    end

    def test_unsupported_subclasses_are_rejected_during_subscribe
      publisher = Publisher.new

      assert_raises(ArgumentError) { publisher.subscribe(Class.new.new) }
      assert_raises(ArgumentError) { publisher.subscribe(42) }
      assert_raises(ArgumentError) { publisher.subscribe(true) }
    end

    def test_constructor_is_not_public
      assert_raises(NoMethodError) { Subscription.new }
    end

    def test_loading_subscriptions_does_not_load_concurrent_replacements
      output, error, status = ruby_isolated(<<~'RUBY', coverage: false)
        require "farce"
        pattern = %r{/farce/concurrent(?:/|\.rb)}
        before = $LOADED_FEATURES.grep(pattern)
        autoload = Farce.autoload?(:Concurrent)
        Farce::Subscription
        raise "loaded Farce::Concurrent" unless before == $LOADED_FEATURES.grep(pattern)
        raise "resolved Farce::Concurrent autoload" unless autoload == Farce.autoload?(:Concurrent)
        raise "loaded concurrent-ruby" if defined?(::Concurrent::AtomicReference)
        puts "ok"
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
      assert_equal "ok\n", output
    end

    def test_first_subscription_can_be_created_in_another_ractor
      output, error, status = ruby_isolated(<<~'RUBY')
        require "farce"
        worker = Farce::Ractor.new do
          output = Farce::Queue.new
          publisher = Farce::Publisher.new(output)
          publisher.publish(:message)
          output.pop
        end
        value = worker.respond_to?(:value) ? worker.value : worker.take
        abort "unexpected delivery: #{value.inspect}" unless value == :message
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
    end
  end
end
