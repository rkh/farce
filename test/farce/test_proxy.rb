# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "pp"
require "timeout"

module Farce
  class TestProxy < Test
    include Helpers::InternalTestHelpers

    class Target
      attr_reader :values

      def initialize = @values = []
      def echo(value, keyword:) = [value, keyword]

      def append(value)
        @values << value
        self
      end

      def nothing = nil
      def negative? = false
      def unsupported = Unshared::Map.new
      def fail! = raise ArgumentError, "target failed"
      def apply(value, &) = yield(value)
      def location = Ractor.current

      def wait_for_exit(ready)
        ready << true
        sleep
      end

      def closed_queue! = raise ClosedQueueError, "target queue closed"
      private def secret = :secret
    end

    module WrapperMethods
      def answer = 42
    end

    class DormantScheduler < ThreadExecutor
      def schedule(*, **, &) = self
    end

    class ChildTarget < Target; end

    class UnshareableTarget < Target
      include Farce::Unshareable
    end

    def setup
      @proxies = []
    end

    def teardown
      get = Kernel.instance_method(:instance_variable_get)
      @proxies.each do |proxy|
        supervisor = get.bind_call(proxy, :@supervisor)
        get.bind_call(supervisor, :@queue).seal
      end
    end

    def test_create_preserves_shareable_values
      assert_nil Proxy.create(nil)
      [false, 42, :value, "frozen"].each do |value|
        assert_same value, Proxy.create(value)
      end
    end

    def test_default_smart_rules_prepare_arguments_and_results
      proxy = proxy_for([])
      value = [1]
      proxy << value

      assert_same value, proxy.first
      assert_equal Internal.native_ractors?, value.frozen?
    end

    def test_default_smart_rules_reject_unsupported_arguments_and_results
      proxy = proxy_for(Target.new)

      assert_raises(Ractor::IsolationError) { proxy.append(Unshared::Map.new) }
      assert_raises(Ractor::IsolationError) { proxy.unsupported }
      assert_nil proxy.nothing
    end

    def test_delegates_arguments_and_copies_mutable_values
      target = Target.new
      register = Proxy::Register.new
      register.define(Target) do
        define_method(:echo) { |value, keyword:| super(__copy__(value), keyword: __copy__(keyword)) }
      end
      register.define(Target, layer: :inner) do
        define_method(:echo) { |*args, **kwargs| __copy__(super(*args, **kwargs)) }
      end
      proxy = proxy_for(target, register:)
      value = ["positional"]
      keyword = { nested: ["keyword"] }
      actual = proxy.echo(value, keyword:)

      assert_equal [value, keyword], actual
      if Ractor.builtin?
        refute_same value, actual[0]
        refute_same keyword, actual[1]
      end

      assert_same proxy, proxy.append(:item)
      assert_equal [:item], target.values
      assert_nil proxy.nothing
      assert_same false, proxy.negative?
    end

    def test_proxies_are_shareable_even_for_explicitly_unshareable_targets
      proxy = proxy_for(UnshareableTarget.new)

      assert Ractor.shareable?(proxy)
      assert_same proxy, Proxy.create(proxy)
      assert_nil ractor_value(Ractor.new(proxy, &:nothing))
    end

    def test_errors_propagate_and_do_not_stop_the_worker
      proxy = proxy_for(Target.new)

      assert_equal "target failed", assert_raises(ArgumentError) { proxy.fail! }.message
      assert_raises(NoMethodError, Ractor::RemoteError) { proxy.no_such_method }
      assert_equal "target queue closed", assert_raises(ClosedQueueError) { proxy.closed_queue! }.message
      assert_nil proxy.nothing
    end

    def test_forwards_shareable_blocks
      proxy = proxy_for(Target.new)

      assert_equal 6, proxy.apply(3) { |value| value * 2 }
    end

    def test_basic_object_targets
      proxy = proxy_for(BasicObject.new)

      assert_match(/BasicObject/, proxy.inspect)
      assert_same false, !proxy
    end

    def test_inspection_is_local
      proxy = proxy_for(Target.new)

      assert_match(/Farce::Proxy object=#<Farce::TestProxy::Target:/, proxy.inspect)
      assert_equal "#{proxy.inspect}\n", PP.pp(proxy, +"")
    end

    def test_calls_from_another_ractor_mutate_the_original
      target = Target.new
      proxy = proxy_for(target)

      assert Ractor.shareable?(proxy)
      worker = Ractor.new(proxy) do |remote|
        remote.append(:remote)
        [remote.location, remote.nothing, remote.negative?].freeze
      end

      assert_equal [Ractor.current, nil, false], ractor_value(worker)
      assert_equal [:remote], target.values
    end

    def test_register_layers_and_inheritance
      register = Proxy::Register.new
      register.define(Target, layer: :inner) { define_method(:nothing) { :inner } }
      register.define(Target) { define_method(:nothing) { [super(), :outer] } }
      proxy = proxy_for(Target.new, register:)

      assert_equal %i[inner outer], proxy.nothing
      assert_equal %i[inner outer], proxy_for(ChildTarget.new, register:).nothing
      assert_nil proxy_for(Target.new).nothing
    end

    def test_dedicated_membership_only_counts_exact_definitions_in_either_layer
      register = Proxy::Register.new

      [BasicObject, Object, Target, ChildTarget, Hash, Array].each do |klass|
        refute register.dedicated_proxy?(klass)
      end
      register.define(Hash) { define_method(:registered?) { true } }
      register.define(ChildTarget, layer: :inner) { define_method(:registered?) { true } }

      assert register.dedicated_proxy?(Hash)
      assert register.dedicated_proxy?(ChildTarget)
      [BasicObject, Object, Target, Array, Class.new(Hash)].each do |klass|
        refute register.dedicated_proxy?(klass)
      end
      register.define(Target) { define_method(:registered?) { true } }

      assert register.dedicated_proxy?(Target)
    end

    def test_dedicated_membership_observes_late_definitions_in_an_existing_ractor
      register = Proxy::Register.new
      ready = Strict::Queue.new
      release = Strict::Queue.new
      worker = Ractor.new(register, ready, release) do |definitions, started, gate|
        before = definitions.dedicated_proxy?(Target)
        started << true
        gate.pop
        [before, definitions.dedicated_proxy?(Target), definitions.dedicated_proxy?(ChildTarget)].freeze
      end
      ready.pop
      register.define(Target, layer: :inner) { define_method(:registered?) { true } }
      release << true

      assert_equal [false, true, false], ractor_value(worker)
    end

    def test_smart_mode_only_selects_proxies_for_exact_registered_classes
      skip "ordinary values are shareable on emulated Ractors" unless Internal.native_ractors?

      register = Proxy::Register.new
      register.define(Target) { define_method(:nothing) { :custom } }
      manager = ModeManager.new(mode: :smart, register:)
      proxy = manager.wrap(Target.new)
      @proxies << proxy

      assert_operator Proxy, :===, proxy
      assert_equal :custom, proxy.nothing
      assert_raises(Ractor::IsolationError) { manager.wrap(ChildTarget.new) }
    end

    def test_define_method_supports_cross_ractor_calls
      register = Proxy::Register.new
      register.define(Target) { define_method(:answer) { 42 } }
      proxy = proxy_for(Target.new, register:)

      assert_equal 42, ractor_value(Ractor.new(proxy, &:answer))
    end

    def test_define_method_accepts_unbound_methods
      register = Proxy::Register.new
      register.define(Target) { define_method(:answer, WrapperMethods.instance_method(:answer)) }
      proxy = proxy_for(Target.new, register:)

      assert_equal 42, ractor_value(Ractor.new(proxy, &:answer))
    end

    def test_create_from_block_and_initializer_error
      proxy = Proxy.create { [] }
      @proxies << proxy if Proxy === proxy

      assert_equal 0, proxy.length
      assert_same proxy, proxy << 42
      assert_equal 42, proxy.first
      assert_equal(42, Proxy.create { 42 })
      error = assert_raises(Ractor::RemoteError) { Proxy.create { raise ArgumentError, "initialization failed" } }
      assert_match(/initialization failed/, error.message)
    end

    def test_respond_to_includes_target_and_wrapper_methods
      register = Proxy::Register.new
      register.define(Target) { define_method(:custom) { :custom } }
      register.define(Target, layer: :inner) { define_method(:inner_custom) { :inner } }
      proxy = proxy_for(Target.new, register:)

      assert_respond_to proxy, :echo
      assert_respond_to proxy, :custom
      assert_respond_to proxy, :inner_custom
      refute_respond_to proxy, :no_such_method
      refute_respond_to proxy, :secret
      assert proxy.respond_to?(:secret, true) # rubocop:disable Minitest/AssertRespondTo
    end

    def test_copying_arguments_does_not_mutate_the_callers_object
      register = Proxy::Register.new
      register.define(Array) { define_method(:<<) { |value| super(__copy__(value)) } }
      register.define(Array, layer: :inner) { define_method(:first) { __copy__(super()) } }
      proxy = proxy_for([], register:)
      value = [1]
      proxy << value
      value << 2

      assert_equal(Ractor.builtin? ? [1] : [1, 2], proxy.first)
    end

    def test_explicit_argument_and_return_modes
      register = Proxy::Register.new
      register.define(Target) do
        define_method(:append) { |value| super(__proxy__(value)) }
      end
      register.define(Target, layer: :inner) do
        define_method(:values) { __proxy__(super()) }
      end
      target = Target.new
      proxy = proxy_for(target, register:)
      input = []
      proxy.append(input)
      proxy.values.first << :changed

      assert_equal [:changed], input
    end

    def test_concurrent_calls_keep_results_paired_with_requests
      proxy = proxy_for(Target.new)
      threads = 8.times.map do |index|
        Thread.new { proxy.echo(index, keyword: index + 1) }
      end

      assert_equal 8.times.map { |index| [index, index + 1] }, threads.map(&:value)
    end

    def test_create_uses_supplied_scheduler_without_installing_a_fiber_scheduler
      scheduler = ThreadExecutor.new
      result = Proxy.create(scheduler:) { !::Fiber.respond_to?(:scheduler) || ::Fiber.scheduler.nil? }

      assert result
      assert_nil Fiber.scheduler if Fiber.respond_to?(:scheduler)
    end

    def test_missing_initializer_is_rejected
      assert_raises(ArgumentError, LocalJumpError) { Proxy.create }
    end

    def test_register_rejects_invalid_layer
      register = Proxy::Register.new

      assert_raises(ArgumentError) { register.define(Target, layer: :unknown) { :unused } }
    end

    def test_calls_fail_after_owner_exits
      output = Strict::Queue.new
      release = Strict::Queue.new
      owner = Ractor.new(output, release) do |out, gate|
        proxy = Proxy.new(Target.new, scheduler: ThreadExecutor.new)
        proxy.nothing # Ensure the request handler has started.
        out << proxy
        gate.pop
      end
      proxy = output.pop(timeout: 5)
      release << true
      ractor_value(owner)

      refute_same nil, proxy, "proxy owner did not publish within 5 seconds"

      Timeout.timeout(5) do
        assert_raises(Ractor::RemoteError) { proxy.nothing }
      end
    end

    def test_calls_fail_when_owner_exits_before_handler_starts
      output = Strict::Queue.new
      owner = Ractor.new(output) do |out|
        out << Proxy.new(Target.new, scheduler: ThreadExecutor.new)
        :done
      end
      proxy = output.pop(timeout: 5)
      ractor_value(owner)

      refute_same nil, proxy, "proxy owner did not publish within 5 seconds"

      Timeout.timeout(5) do
        assert_raises(Ractor::RemoteError) { proxy.nothing }
      end
    end

    def test_waiting_call_fails_when_owner_exits
      output = Strict::Queue.new
      release = Strict::Queue.new
      ready = Strict::Queue.new
      owner = Ractor.new(output, release) do |out, gate|
        out << Proxy.new(Target.new, scheduler: ThreadExecutor.new)
        gate.pop
      end
      proxy = output.pop(timeout: 5)
      caller = Thread.new do
        proxy.wait_for_exit(ready)
      rescue Ractor::RemoteError => e
        e
      end
      ready.pop(timeout: 5)
      release << true
      ractor_value(owner)

      Timeout.timeout(5) { assert_kind_of Ractor::RemoteError, caller.value }
    ensure
      caller&.kill&.join
    end

    def test_owner_exit_wakes_callers_blocked_on_a_full_queue
      assert_blocked_callers_wake(ThreadExecutor)
    end

    def test_owner_exit_wakes_callers_before_handler_starts
      assert_blocked_callers_wake(DormantScheduler)
    end

    def test_fresh_process_can_call_a_block_created_proxy
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        proxy = Farce::Proxy.create { Object.new }
        abort "wrong class" unless proxy.class == Object
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
    end

    def test_fresh_process_can_construct_proxy_in_another_ractor
      return unless Internal.native_ractors?

      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"

        class Target
          def nothing = nil
        end
        sleeper = Thread.new { sleep }
        output = Farce::Strict::Queue.new
        release = Farce::Strict::Queue.new
        GC.start
        owner = Farce::Ractor.new(output, release) do |out, gate|
          scheduler = Farce::ThreadExecutor.new do |*args, &task|
            Farce::Ractor[:proxy_worker] = Thread.new(*args, &task)
          end
          proxy = Farce::Proxy.new(Target.new, scheduler:)
          proxy.nothing
          out << proxy
          gate.pop
        ensure
          # Ruby can report Ractor completion before terminating its child threads.
          # Join our worker before process shutdown can race that teardown.
          Farce::Ractor[:proxy_worker]&.kill&.join
        end
        proxy = output.pop(timeout: 5)
        release << true
        owner.respond_to?(:value) ? owner.value : owner.take
        sleeper.kill.join
        abort "proxy startup blocked by the queue wait" if nil.equal?(proxy)
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok", output.strip
    end

    def test_owned_ractor_stops_when_proxy_is_collected
      owner = Thread.new do
        proxy = Proxy.create { UnshareableTarget.new }
        ractor = proxy.location
        proxy = nil # rubocop:disable Lint/UselessAssignment -- Emulated Ractors retain the initializer's lexical scope.
        ractor
      end.value
      Timeout.timeout(10) do
        waiter = Thread.new { ractor_value(owner) }
        until waiter.join(0.05)
          RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        end

        assert waiter.join(0)
        waiter.value
      end
    end

    private

    def assert_blocked_callers_wake(scheduler_class)
      output = Strict::Queue.new
      release = Strict::Queue.new
      ready = Strict::Queue.new
      owner = Ractor.new(output, release, scheduler_class) do |out, gate, scheduler|
        out << Proxy.new(Target.new, scheduler: scheduler.new)
        gate.pop
      end
      proxy = output.pop(timeout: 5)
      get = Kernel.instance_method(:instance_variable_get)
      queue = get.bind_call(get.bind_call(proxy, :@supervisor), :@queue)
      callers = []
      3.times do |index|
        callers << Thread.new do
          proxy.wait_for_exit(ready)
        rescue Ractor::RemoteError => e
          e
        end
        assert ready.pop(timeout: 5) if index.zero? && scheduler_class == ThreadExecutor
      end

      Timeout.timeout(5) do
        # One queued request and at least one blocked producer, regardless of
        # whether the scheduler has started the consumer.
        Thread.pass until queue.size == 1 && queue.num_waiting.positive?
        release << true
        ractor_value(owner)
        callers.each { assert_kind_of Ractor::RemoteError, it.value }
      end
    ensure
      release&.close
      callers&.each { it.kill.join }
    end

    def proxy_for(object, **)
      proxy = Proxy.new(object, scheduler: ThreadExecutor.new, **)
      @proxies << proxy
      proxy
    end
  end
end
