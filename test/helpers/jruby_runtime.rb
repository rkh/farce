# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "java"
require "jruby"

module Helpers
  # A fresh Ruby runtime with its own environment and streams in the current JVM.
  # Timeouts interrupt Ruby execution. Use a subprocess for uninterruptible native
  # work, process signals, or changes to JVM-wide state.
  class JrubyRuntime
    Status = Data.define(:exitstatus) do
      def success? = exitstatus.zero?
    end

    def initialize(arguments, env:)
      @container = Java::OrgJrubyEmbed::ScriptingContainer.new(Java::OrgJrubyEmbed::LocalContextScope::SINGLETHREAD)
      @provider  = @container.provider
      @config    = @provider.ruby_instance_config

      @config.environment = ENV.to_h.merge(env).compact.to_java(Java::JavaUtil::Map)

      @config.set_update_native_env_enabled(false)

      @config.hard_exit         = false
      @config.current_directory = Dir.pwd
      @output                   = Java::JavaIo::ByteArrayOutputStream.new
      @error                    = Java::JavaIo::ByteArrayOutputStream.new
      @config.output            = Java::JavaIo::PrintStream.new(@output, true, "UTF-8")
      @config.error             = Java::JavaIo::PrintStream.new(@error, true, "UTF-8")
      @config.input             = Java::JavaIo::ByteArrayInputStream.new([].to_java(:byte))

      @config.process_arguments(arguments.to_java(:string))

      @mutex     = Mutex.new
      @timed_out = false
      @interrupt = nil
    end

    def timed_out? = @timed_out

    def run(timeout:)
      worker = Thread.new { execute }
      unless worker.join(timeout)
        @mutex.synchronize do
          @timed_out = true
          thread, exception = @interrupt
          thread&.raise(exception)
        end
        raise "Isolated Ruby did not stop after its timeout. Use ruby_subprocess for this test." unless worker.join(5)
      end
      [contents(@output), contents(@error), Status.new(worker.value & 0xff)]
    end

    private

    def execute
      runtime = nil
      initialization_error = capture { runtime = @provider.runtime }
      return exit_status(initialization_error) if initialization_error
      cancelled = @mutex.synchronize do
        thread = JRuby.reference(runtime.thread_service.main_thread)
        @interrupt = [thread, runtime.new_runtime_error("isolated Ruby timeout").exception]
        @timed_out
      end

      raised = capture { runtime.run_from_main(@config.script_source, "-e") } unless cancelled
      runtime.current_context.error_info = JRuby.reference(raised.exception) if raised.respond_to?(:exception)
      status = exit_status(raised)
      # Unlike ScriptingContainer#terminate, tear_down preserves failing at_exit
      # statuses, including Minitest and coverage shutdown hooks.
      teardown = capture { runtime.tear_down }
      teardown ? exit_status(teardown) : status
    ensure
      @mutex.synchronize { @interrupt = nil }
      @provider.terminate
    end

    def capture(&block)
      # Ruby exceptions belong to the child runtime. A Java boundary catches
      # them without letting a child SystemExit terminate the parent Ruby thread.
      callable = lambda do
        block.call
        nil
      end.to_java(Java::JavaUtilConcurrent::Callable)
      future = Java::JavaUtilConcurrent::FutureTask.new(callable)
      future.run
      future.get
    rescue Java::JavaUtilConcurrent::ExecutionException => e
      e.cause
    end

    def exit_status(raised)
      return 0 unless raised
      if raised.respond_to?(:exception)
        error = raised.exception
        if Java::OrgJruby::RubySystemExit === JRuby.reference(error)
          # Copy the primitive value so the result cannot retain the child runtime.
          return JRuby.reference(error.status).get_long_value
        end
        @config.error.print(@config.trace_type.print_backtrace(JRuby.reference(error), false))
      elsif raised.respond_to?(:status)
        return raised.status
      else
        @config.error.print(raised.to_string)
      end
      1
    end

    def contents(stream)
      String.from_java_bytes(stream.to_byte_array).force_encoding(Encoding.default_external)
    end
  end
end
