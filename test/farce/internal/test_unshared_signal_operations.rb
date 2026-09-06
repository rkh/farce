# frozen_string_literal: true

return unless RUBY_ENGINE == "ruby"

require_relative "../../setup"

module Farce
  module Internal
    class TestUnsharedSignalOperations < Test
      def test_signal_subclasses_retain_their_ruby_protocol
        [UnsharedSignal, UnsharedIOSignal, UnsharedBlockSignal].each do |base|
          subclass = Class.new(base) do
            def broadcast = raise("custom broadcast")
          end
          signal = subclass.new
          queue = UnsharedPriorityQueue.new(signal:)

          error = assert_raises(RuntimeError) { queue.push(1.5, :value) }
          assert_equal "custom broadcast", error.message
          assert_equal 0, queue.size
          assert_equal base.new.fiber_wait, signal.fiber_wait
          assert_raises(Ractor::IsolationError) { PriorityQueue.new(signal:) }
        end
      end

      def test_explicit_signal_classes_and_factory
        assert_instance_of UnsharedSignal, UnsharedSignal.for(:auto)
        assert_instance_of UnsharedIOSignal, UnsharedSignal.for(:io)
        assert_instance_of UnsharedBlockSignal, UnsharedSignal.for(:block)
        assert_equal :io, UnsharedIOSignal.new.fiber_wait
        assert_equal :block, UnsharedBlockSignal.new.fiber_wait
        [nil, false, "io", :unknown].each do |mode|
          assert_raises(ArgumentError) { UnsharedSignal.for(mode) }
        end
      end

      def test_timeout_coercion_cannot_lose_a_broadcast
        signal = UnsharedSignal.new
        observed = signal.generation
        timeout = Object.new
        timeout.define_singleton_method(:to_f) do
          signal.broadcast
          0.0
        end

        assert_equal 1, signal.wait(observed, timeout:)
        assert_equal 0, signal.num_waiting
      end

      def test_uninitialized_frozen_and_copied_signals
        signal = UnsharedSignal.allocate
        assert_raises(RuntimeError) { signal.generation }
        assert_raises(RuntimeError) { UnsharedPriorityQueue.new(signal:) }
        signal.freeze
        assert_raises(FrozenError) { signal.send(:initialize) }
        signal = UnsharedSignal.new
        assert_raises(RuntimeError) { signal.send(:initialize) }
        assert_raises(TypeError) { signal.dup }
        assert_raises(TypeError) { signal.clone }
        refute Ractor.shareable?(signal)
      end
    end
  end
end
