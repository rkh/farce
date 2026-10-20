# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Concurrent
    class TestSubscribers < Test
      include Helpers::ConcurrentSubscribers
      include Helpers::InternalTestHelpers

      def concurrent_namespace = Farce::Concurrent
      def publisher_classes = [Publisher, Strict::Publisher, Unshared::Publisher, Local::Publisher]

      def test_replacements_receive_messages_from_another_ractor
        [Publisher, Strict::Publisher].each do |klass|
          event = Event.new
          latch = CountDownLatch.new(1)
          counter = AtomicFixnum.new
          boolean = AtomicBoolean.new
          reference = Atom.new
          publisher = klass.new(event, latch, counter, boolean, reference)
          worker = Ractor.new(publisher) do |pub|
            pub.publish(:message)
            :done
          end

          assert_equal :done, ractor_value(worker)
          assert event.wait(0)
          assert latch.wait(0)
          assert_equal 1, counter.value
          assert_predicate boolean, :value
          assert_equal :message, reference.value
        end
      end
    end
  end
end
