# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "timeout"

if RUBY_ENGINE == "ruby"
  internal = Farce.const_get(:Internal, false)
  container_classes = %i[
    Atom Counter Exchanger Flag Lock Map Queue Signal Unshareable Vector WeakMap WeakKeyMap WeakValueMap
  ]
  container_classes.each do |name|
    next if %i[WeakMap WeakKeyMap WeakValueMap].include?(name) && !internal.const_defined?(:NATIVE_WEAK_MAPS, false)
    internal.__send__(:remove_const, name) if internal.autoload?(name)
  end
  version = RUBY_VERSION[/^\d+\.\d+/]
  require "farce/engine/ruby/#{version}/farce"
end

module Helpers
  module InternalTestHelpers
    def shared_string(value)
      value.dup.freeze
    end

    def ractor_value(ractor)
      ractor.respond_to?(:value) ? ractor.value : ractor.take
    end

    # A frozen-shareable native object can become visible to another Ractor
    # during the last few instructions of initialization. Keep a worker
    # polling an indirect constant before publication begins, then verify that
    # its first permitted native call observes the committed state rather than
    # the transient uninitialized state.
    def assert_atomic_ractor_publication(
      container_class,
      iterations: Gem.win_platform? ? 200 : 2_000
    )
      holder = Module.new
      events = Ractor::Port.new if defined?(Ractor::Port)
      stopping = Farce::Flag.new
      worker_finished = false
      worker = Ractor.new(holder, events, stopping) do |target_holder, event_port, stop|
        report = ->(value) { event_port ? event_port << value : Ractor.yield(value) }
        loop do
          break if stop.value || Ractor.receive == :stop

          reported_isolation = false
          loop do
            break if stop.value

            target = target_holder.const_get(:TARGET, false)
            observation = begin
              target.size
            rescue StandardError => e
              [e.class.name, e.message]
            end
            report.call(observation)
            break
          rescue Ractor::IsolationError, NameError
            unless reported_isolation
              report.call(:isolated)
              reported_isolation = true
            end
            Thread.pass
          end
        end
        :done
      end
      failure = nil

      Timeout.timeout(10) do
        iterations.times do |index|
          target = container_class.allocate
          holder.const_set(:TARGET, target)
          worker.send(:probe)
          started = events ? events.receive : worker.take

          failure ||= [index, :publication_started, started] unless started == :isolated
          yield target, worker
          observation = events ? events.receive : worker.take
          failure ||= [index, :first_observation, observation] unless observation.eql?(0)
          holder.__send__(:remove_const, :TARGET)
        end
      end

      worker.send(:stop)

      assert_nil failure, "publication failed at #{failure.inspect}"
      completion = ractor_value(worker)
      worker_finished = true

      assert_equal :done, completion
    ensure
      stopping&.value = true
      begin
        worker&.send(:stop)
      rescue Ractor::ClosedError
        nil
      end
      begin
        # Ruby 3.4 can be blocked in Ractor.yield when the publisher is interrupted.
        # Consume pending observations as well as the final result to release it.
        if worker && !worker_finished
          Timeout.timeout(5) { loop { break if ractor_value(worker) == :done } }
        end
      rescue Ractor::ClosedError
        nil
      ensure
        holder&.__send__(:remove_const, :TARGET) if
          holder&.const_defined?(:TARGET, false)
      end
    end

    def open_file_descriptor_count
      directory = ["/dev/fd", "/proc/self/fd"].find { |path| File.directory?(path) }
      directory && Dir.children(directory).length
    rescue SystemCallError
      nil
    end
  end
end
