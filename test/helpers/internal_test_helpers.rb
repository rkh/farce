# frozen_string_literal: true

if RUBY_ENGINE == "ruby"
  internal = Farce.const_get(:Internal, false)
  container_classes = %i[
    Atom Counter Exchanger Flag Lock Map Queue Signal Unshareable Vector WeakMap WeakKeyMap WeakValueMap
  ]
  container_classes.each do |name|
    internal.__send__(:remove_const, name) if internal.autoload?(name)
  end
  version = RUBY_VERSION[/^\d+\.\d+/]
  require "farce/engine/ruby/#{version}/containers"
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
    def assert_atomic_ractor_publication(container_class, iterations: 20_000)
      holder = Module.new
      events = Ractor::Port.new if defined?(Ractor::Port)
      worker = Ractor.new(holder, events) do |target_holder, event_port|
        report = ->(value) { event_port ? event_port << value : Ractor.yield(value) }
        loop do
          break if Ractor.receive == :stop

          reported_isolation = false
          loop do
            target = target_holder.const_get(:TARGET, false)
            observation = begin
              target.size
            rescue StandardError => e
              [e.class.name, e.message]
            end
            report.call(observation)
            break
          rescue Ractor::IsolationError
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
          yield target
          observation = events ? events.receive : worker.take
          failure ||= [index, :first_observation, observation] unless observation.eql?(0)
          holder.__send__(:remove_const, :TARGET)
        end
      end

      worker.send(:stop)

      assert_nil failure, "publication failed at #{failure.inspect}"
      assert_equal :done, ractor_value(worker)
    ensure
      holder&.__send__(:remove_const, :TARGET) if
        holder&.const_defined?(:TARGET, false)
      begin
        worker&.send(:stop)
      rescue Ractor::ClosedError
        nil
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
