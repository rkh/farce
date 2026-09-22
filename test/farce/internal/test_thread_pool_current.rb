# frozen_string_literal: true
require_relative "../../setup"

module Farce
  module Internal
    class TestThreadPoolCurrent < Test
      def test_current_is_atomic_ractor_local_and_configured
        output, error, status = ruby_subprocess(<<~RUBY)
          require "farce/config"
          Farce.config do |config|
            config.main_thread_pool_size = 3
            config.additional_thread_pool_size = 1
          end
          require "farce"
          module Farce
            module Internal
              ThreadPool
              ready = Thread::Queue.new
              threads = 12.times.map do
                Thread.new do
                  ready.pop
                  ThreadPool.current
                end
              end
              12.times { ready << true }
              pools = threads.map(&:value)
              pool = ThreadPool.current
              raise "duplicate pools" unless pools.all? { |candidate| candidate.equal?(pool) }
              raise "wrong main limit" unless pool.max_threads == 3 && pool.capacity == 6
              raise "workers started eagerly" unless pool.size.zero?
              raise "config not frozen" unless Farce.config.frozen?
              raise "worker has different pool" unless pool.call { ThreadPool.current.equal?(pool) }
              explicit = ThreadPool.new(max_threads: 5)
              raise "explicit limit ignored" unless explicit.max_threads == 5
              explicit.close
              # Concurrent Ractors starting nested threads can stall CRuby 3.4.
              # Check each Ractor's pool separately. The threads above still
              # exercise concurrent initialization of the shared current pool.
              ids = 2.times.map do
                # This subprocess does not load test/setup's Windows Ractor-start barrier.
                GC.start if Farce::System.windows?
                task = Ractor.new do
                  current = ThreadPool.current
                  raise "wrong secondary limit" unless current.max_threads == 1 && current.capacity == 2
                  other = Thread.new { ThreadPool.current }.value
                  raise "thread has different pool" unless current.equal?(other)
                  raise "worker has different pool" unless current.call { ThreadPool.current.equal?(current) }
                  fresh = ThreadPool.new
                  raise "new ignored config" unless fresh.max_threads == 1
                  fresh.close
                  id = current.object_id
                  current.close
                  raise "closed pool replaced" unless ThreadPool.current.equal?(current)
                  id
                end
                task.respond_to?(:value) ? task.value : task.take
              end
              raise "ractors share pool" unless (ids + [pool.object_id]).uniq.size == 3
              pool.close
              raise "closed pool replaced" unless ThreadPool.current.equal?(pool)
              begin
                ThreadPool.current.call { true }
                raise "closed pool accepted work"
              rescue IOError
                # Closing the Ractor's shared pool is terminal.
              end
              puts "ok"
            end
          end
        RUBY

        assert_predicate status, :success?, error
        assert_equal "ok", output.strip
      end
    end
  end
end
