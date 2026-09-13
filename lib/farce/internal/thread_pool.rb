# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # Run blocks on a bounded set of reusable threads.
    # Workers start on demand. Capacity limits the total running and queued jobs.
    # Each caller waits for its block's result and receives any exception it raises.
    # Queue waits can yield through Ruby's scheduler hooks when those are available.
    #
    # An interrupted caller cancels its job if it has not started. Once a job has
    # started, the caller waits for it to finish before unwinding its own cleanup.
    # Closing stops new submissions, finishes accepted jobs, and joins the workers.
    class ThreadPool
      # Fetch or create the pool shared by all threads and fibers in this Ractor.
      # Closing it is explicit and terminal. Later calls return the same closed pool.
      def self.current
        Ractor.store_if_absent(name) { new }
      end

      # Read the configured worker limit for the current Ractor.
      def self.default_max_threads
        config = CONFIG.freeze
        Ractor.main? ? config.main_thread_pool_size : config.additional_thread_pool_size
      end

      class Job
        def initialize(operation)
          @operation = operation
          @mutex     = Thread::Mutex.new
          @result    = Thread::Queue.new
          @done      = Thread::Queue.new
          @started   = @cancelled = false
        end

        def run
          operation = @mutex.synchronize do
            @started = true
            @operation unless @cancelled
          end
          @value = operation&.call
        rescue Exception => e # rubocop:disable Lint/RescueException -- deliver job failures without losing a worker
          @error = e
        ensure
          @operation = nil
        end

        def finish
          @done << true
          @result << [@value, @error]
        end

        def value
          value, error = @result.pop
          raise error if error
          value
        end

        def cancel_and_wait
          # Skip a job that has not started. Otherwise wait for its block to finish
          # before the caller can clean up resources that the block still uses.
          Thread.handle_interrupt(Exception => :never) do
            skipped = @mutex.synchronize do
              unless @started
                @cancelled = true
                @operation = nil
                true
              end
            end
            unless skipped
              Fiber.respond_to?(:blocking) ? Fiber.blocking { @done.pop } : @done.pop
            end
          end
        end
      end
      private_constant :Job

      attr_reader :max_threads, :capacity

      # Limit worker threads and accepted jobs. Capacity defaults to twice the thread limit.
      def initialize(max_threads: ThreadPool.default_max_threads, capacity: nil)
        @max_threads = Integer(max_threads)
        @capacity    = capacity.nil? ? @max_threads * 2 : Integer(capacity)

        raise ArgumentError, "max_threads must be positive" unless @max_threads.positive?
        raise ArgumentError, "capacity must be at least max_threads" if @capacity < @max_threads

        @mutex   = Thread::Mutex.new
        @jobs    = Thread::Queue.new
        @slots   = Thread::SizedQueue.new(@capacity)
        @workers = []
        @pending = 0
        @closed  = false

        @capacity.times { @slots << true }
      end

      # Wait for capacity, run the block on a worker, and return its value or raise its exception.
      def call(&operation)
        raise ArgumentError, "no block given" unless operation
        admitted = @slots.pop
        raise IOError, "thread pool is closed" unless admitted
        job = Job.new(operation)
        submitted = false
        Thread.handle_interrupt(Exception => :never) do
          submit(job)
          submitted = true
        end
        job.value
      ensure
        if submitted
          job.cancel_and_wait
        elsif admitted
          release_slot
        end
      end

      # Return the number of workers created so far.
      def size = @mutex.synchronize { @workers.size }

      # Report whether the pool has stopped accepting jobs.
      def closed? = @mutex.synchronize { @closed }

      # Stop accepting jobs, wake callers waiting for capacity, and finish accepted jobs.
      def close
        workers = @mutex.synchronize do
          raise ThreadError, "a worker cannot close its own pool" if @workers.include?(Thread.current)
          @closed = true
          @slots.close
          @jobs.close
          @workers.dup
        end
        Fiber.respond_to?(:blocking) ? Fiber.blocking { workers.each(&:join) } : workers.each(&:join)
        nil
      end

      private

      def submit(job)
        @mutex.synchronize do
          raise IOError, "thread pool is closed" if @closed
          @workers << Thread.new { work } if @workers.size < @max_threads && @workers.size <= @pending
          @pending += 1
          @jobs << job
        end
      end

      def work
        while job = @jobs.pop
          job.run
          @mutex.synchronize { @pending -= 1 }
          release_slot
          job.finish
          job = nil
        end
      end

      def release_slot
        @slots << true
      rescue ::ClosedQueueError
        # Closing the pool has already woken callers waiting for capacity.
        nil
      end
    end
  end
end
