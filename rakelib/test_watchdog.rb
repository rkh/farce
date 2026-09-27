# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "shellwords"

class TestWatchdog
  DEFAULT_TIMEOUT        = RUBY_ENGINE == "truffleruby" ? 600 : 300
  DEFAULT_SHUTDOWN_GRACE = 5
  TIMEOUT_EXIT_STATUS    = 124
  POLL_INTERVAL          = 0.05

  attr_reader :seed

  def self.test_command(test_task, seed: nil)
    verbose = test_task.verbose || Rake::FileUtilsExt.verbose_flag == true
    options = Shellwords.split(test_task.option_list(verbose: verbose))
    seed ||= seed_from(options) || (Random.new_seed % 0x1_0000)
    options << "--seed=#{seed}" unless seed_from(options)
    options << "--verbose" if ENV["CI"] && !verbose_option?(options)

    command = [RbConfig.ruby]
    command.concat(Shellwords.split(test_task.ruby_opts_string))
    command << test_task.run_code
    command.concat(test_task.file_list.to_a)
    command.concat(options)
    [command, seed]
  end

  def self.seed_from(options)
    options.each_with_index do |option, index|
      if (match = option.match(/\A--seed=(.+)\z/))
        return match[1]
      end

      return options[index + 1] if option == "--seed"

      if (match = option.match(/\A-s(.+)\z/))
        return match[1]
      end

      return options[index + 1] if option == "-s"
    end

    nil
  end

  def self.verbose_option?(options)
    options.any? { |option| option == "--verbose" || option == "-v" }
  end

  def initialize(command, seed:, timeout: DEFAULT_TIMEOUT, shutdown_grace: DEFAULT_SHUTDOWN_GRACE,
                 diagnostics: true, output: $stderr)
    @command = command
    @seed = seed
    @timeout = Float(timeout)
    @shutdown_grace = Float(shutdown_grace)
    @diagnostics = diagnostics
    @output = output

    raise ArgumentError, "timeout must be positive" unless @timeout.positive?
    raise ArgumentError, "shutdown grace must not be negative" if @shutdown_grace.negative?
  end

  def run
    report "Test watchdog: seed #{seed}, timeout #{formatted_duration(@timeout)}"
    @pid = Process.spawn(*@command, spawn_options)
    install_signal_handlers

    status = wait_until(monotonic_time + @timeout)
    return process_status(status) if status

    report "Test watchdog timed out after #{formatted_duration(@timeout)} (seed #{seed}, pid #{@pid})."
    report "Replay with: TESTOPTS=#{Shellwords.escape("--seed=#{seed}")} bundle exec rake test:run"
    diagnose_and_terminate
    TIMEOUT_EXIT_STATUS
  ensure
    restore_signal_handlers
    unless @reaped || !@pid
      force_terminate_tree
      reap
    end
  end

  private

  def diagnose_and_terminate
    if windows?
      force_terminate_tree
      reap
      return
    end

    if @diagnostics
      sample_on_macos
      dump_jruby_threads
    end
    signal_process(@diagnostics ? "ABRT" : "TERM")
    wait_until(monotonic_time + @shutdown_grace)
    force_terminate_tree
    reap unless @reaped
  end

  def sample_on_macos
    return unless RbConfig::CONFIG.fetch("host_os").include?("darwin")
    return unless File.executable?("/usr/bin/sample")

    FileUtils.mkdir_p(diagnostics_directory)
    path = File.join(diagnostics_directory, "ruby-#{RUBY_VERSION}-seed-#{seed}-pid-#{@pid}.sample.txt")
    report "Capturing native stacks in #{path}"

    sampler = Process.spawn(
      "/usr/bin/sample", @pid.to_s, "1", "10", "-file", path,
      out: File::NULL, err: @output,
    )
    wait_for_sampler(sampler)
  rescue SystemCallError => e
    report "Could not capture native stacks: #{e.message}"
  end

  def dump_jruby_threads
    return unless RUBY_ENGINE == "jruby"

    report "Requesting a JVM thread dump from JRuby pid #{@pid}"
    signal_process("QUIT")
    sleep 0.5
  rescue ArgumentError, NotImplementedError, SystemCallError => e
    report "Could not request a JVM thread dump: #{e.message}"
  end

  def wait_for_sampler(sampler)
    deadline = monotonic_time + 3

    loop do
      return if Process.waitpid(sampler, Process::WNOHANG)
      break if monotonic_time >= deadline

      sleep POLL_INTERVAL
    end

    Process.kill("KILL", sampler)
    Process.waitpid(sampler)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  def install_signal_handlers
    @previous_signal_handlers = {}

    %w[INT TERM].each do |signal|
      @previous_signal_handlers[signal] = Signal.trap(signal) do
        signal_tree(signal)
      end
    end
  rescue ArgumentError
    restore_signal_handlers
  end

  def restore_signal_handlers
    return unless @previous_signal_handlers

    @previous_signal_handlers.each { |signal, handler| Signal.trap(signal, handler) }
    @previous_signal_handlers = nil
  end

  def wait_until(deadline)
    loop do
      waited_pid, status = Process.waitpid2(@pid, Process::WNOHANG)
      if waited_pid
        @reaped = true
        return status
      end

      remaining = deadline - monotonic_time
      return unless remaining.positive?

      sleep [POLL_INTERVAL, remaining].min
    end
  rescue Errno::ECHILD
    nil
  end

  def process_status(status)
    return status.exitstatus if status.exited?

    128 + status.termsig
  end

  def signal_process(signal)
    Process.kill(signal, @pid)
  rescue Errno::ESRCH
    nil
  end

  def signal_tree(signal)
    if windows?
      force_terminate_tree
    else
      Process.kill(signal, -@pid)
    end
  rescue Errno::ESRCH
    nil
  end

  def force_terminate_tree
    if windows?
      system("taskkill", "/PID", @pid.to_s, "/T", "/F", out: File::NULL, err: File::NULL)
    else
      Process.kill("KILL", -@pid)
    end
  rescue Errno::EPERM
    signal_process("KILL")
  rescue Errno::ESRCH
    nil
  end

  def reap
    Process.waitpid(@pid)
    @reaped = true
  rescue Errno::ECHILD
    @reaped = true
  end

  def spawn_options
    windows? ? { new_pgroup: true } : { pgroup: true }
  end

  def windows?
    RbConfig::CONFIG.fetch("host_os").match?(/mswin|mingw/)
  end

  def diagnostics_directory
    ENV.fetch("TEST_WATCHDOG_DIAGNOSTICS", "tmp/test-watchdog")
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def formatted_duration(duration)
    duration == duration.to_i ? "#{duration.to_i}s" : "#{duration}s"
  end

  def report(message)
    @output.puts(message)
    @output.flush
  end
end
