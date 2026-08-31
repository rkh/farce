# frozen_string_literal: true

require_relative "../../setup"

module Farce
  class PriorityQueuePublicationReentry
    attr_reader :reentry_rejected

    def initialize(target)
      @target = target
      @reentry_rejected = false
    end

    def freeze
      begin
        @target.send(:initialize)
      rescue FrozenError, ThreadError
        @reentry_rejected = true
      end
      super
    end
  end

  class PriorityQueuePublicationResume
    attr_reader :contender_rejected

    def initialize(contender)
      @contender = contender
      @contender_rejected = false
    end

    def freeze
      contender = @contender
      @contender = nil
      @contender_rejected = contender.resume.is_a?(FrozenError)
      super
    end
  end

  class TestPriorityQueueInitialization < Test
    include Helpers::InternalTestHelpers

    def test_cruby_native_publication_is_atomic_at_first_ractor_visibility
      return unless RUBY_ENGINE == "ruby"

      assert_atomic_ractor_publication(Internal::PriorityQueue) do |queue|
        queue.send(:initialize, capacity: nil)
      end
    end

    def test_cruby_native_publication_recursively_shares_preinitialize_ivars
      return unless RUBY_ENGINE == "ruby"

      queue = Internal::PriorityQueue.allocate
      metadata = Object.new
      metadata.instance_variable_set(:@values, [1, 2, 3])
      queue.instance_variable_set(:@metadata, metadata)

      assert_same queue, queue.send(:initialize, capacity: nil)
      assert_predicate queue, :frozen?
      assert_predicate metadata, :frozen?
      assert_predicate metadata.instance_variable_get(:@values), :frozen?
      assert Ractor.shareable?(queue)
      assert Ractor.shareable?(metadata)

      worker = Ractor.new(queue) do |shared_queue|
        shared_queue.push(1.0, :from_ractor)
        [
          shared_queue.pop,
          shared_queue.instance_variable_get(:@metadata)
            .instance_variable_get(:@values)
        ]
      end
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal [:from_ractor, [1, 2, 3]], result
    end

    def test_cruby_native_publication_does_not_commit_an_unshareable_ivar
      return unless RUBY_ENGINE == "ruby"

      queue = Internal::PriorityQueue.allocate
      queue.instance_variable_set(:@thread, Thread.current)

      assert_raises(Ractor::Error) { queue.send(:initialize) }
      refute Ractor.shareable?(queue)
      assert_raises(RuntimeError) { queue.size }
    end

    def test_cruby_recursive_initialize_from_ivar_freeze_does_not_deadlock
      return unless RUBY_ENGINE == "ruby"

      queue = Internal::PriorityQueue.allocate
      metadata = PriorityQueuePublicationReentry.new(queue)
      queue.instance_variable_set(:@metadata, metadata)

      Timeout.timeout(2) { queue.send(:initialize) }

      assert_predicate metadata, :reentry_rejected
      assert Ractor.shareable?(queue)
    end

    def test_cruby_publication_rejects_an_initializer_paused_in_capacity_coercion
      return unless RUBY_ENGINE == "ruby"

      queue = Internal::PriorityQueue.allocate
      capacity = Object.new
      capacity.define_singleton_method(:to_int) do
        Fiber.yield(:capacity_paused)
        3
      end
      contender = Fiber.new do
        queue.send(:initialize, capacity: capacity)
      rescue FrozenError => e
        e
      end

      assert_equal :capacity_paused, contender.resume

      metadata = PriorityQueuePublicationResume.new(contender)
      queue.instance_variable_set(:@metadata, metadata)

      Timeout.timeout(2) { queue.send(:initialize, capacity: nil) }

      assert_predicate metadata, :contender_rejected
      assert Ractor.shareable?(queue)
      assert_nil queue.capacity
    end

    def test_concurrent_initializers_publish_one_matching_blocking_signal
      queue = Internal::PriorityQueue.allocate
      entered = Thread::Queue.new
      releases = 2.times.map { Thread::Queue.new }
      capacity_class = Class.new do
        define_method(:initialize) do |value, entered_queue, release_queue|
          @value = value
          @entered = entered_queue
          @release = release_queue
        end

        define_method(:to_int) do
          @entered << true
          @release.pop
          @value
        end
      end
      threads = []

      threads << Thread.new do
        queue.send(:initialize, capacity: capacity_class.new(3, entered, releases.fetch(0)))
      rescue StandardError => e
        e
      end
      Timeout.timeout(5) { entered.pop }

      threads << Thread.new do
        queue.send(:initialize, capacity: capacity_class.new(5, entered, releases.fetch(1)))
      rescue StandardError => e
        e
      end
      Timeout.timeout(5) { entered.pop }

      # The first initializer commits while the second still owns the most
      # recently created Ruby-side signal. The backend commit must restore the
      # winning signal atomically along with the storage state.
      releases.fetch(0) << true

      assert threads.fetch(0).join(5), "winning initializer did not finish"
      releases.fetch(1) << true

      assert threads.fetch(1).join(5), "losing initializer did not finish"

      assert_same queue, threads.fetch(0).value
      error = threads.fetch(1).value

      assert_instance_of RuntimeError, error
      assert_match(/already initialized/, error.message)
      assert_equal 3, queue.capacity

      backend_signal =
        if RUBY_ENGINE == "jruby" ||
            (RUBY_ENGINE == "truffleruby" && !TruffleRuby.native?)
          queue.instance_variable_get(:@change_signal)
        elsif RUBY_ENGINE == "truffleruby"
          queue.instance_variable_get(:@state).signal
        end
      assert_same queue.instance_variable_get(:@signal), backend_signal if backend_signal

      # JRuby's Java Phaser wait does not change Thread#status to "sleep". Its
      # backend/common signal identity above is the deterministic assertion;
      # ordinary blocking behavior is covered by the queue behavior suite.
      return if RUBY_ENGINE == "jruby" || RUBY_ENGINE == "truffleruby"

      consumer = Thread.new { queue.pop }
      Timeout.timeout(5) { Thread.pass until consumer.status == "sleep" }

      assert queue.push(1, :value)
      assert consumer.join(5), "push notified a different signal than pop awaited"
      assert_equal :value, consumer.value
    ensure
      releases&.each { it << true }
      threads&.each { it.kill if it.alive? }
      consumer&.kill if consumer&.alive?
    end
  end
end
