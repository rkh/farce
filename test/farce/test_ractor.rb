# frozen_string_literal: true

require_relative "../setup"

require "farce"

module Farce
  class TestRactor < Test
    def test_reports_native_or_shim_status
      assert_equal native_ractors?, Ractor.builtin?
      assert_equal !native_ractors?, Ractor.shim?
    end

    def test_main_ractor_identity
      assert_predicate Ractor, :main?
      assert_same Ractor.current, Ractor.main
      assert_operator Ractor.count, :>=, 1
      assert_includes Ractor.threads, Thread.current
      assert_same Thread.main, Ractor.main_thread
    end

    def test_exposes_compatible_error_constants
      assert_operator Ractor::Error, :<=, RuntimeError
      assert_operator Ractor::ClosedError, :<=, StopIteration
      assert_operator Ractor::IsolationError, :<=, Ractor::Error
      assert_operator Ractor::MovedError, :<=, Ractor::Error
      assert_operator Ractor::RemoteError, :<=, Ractor::Error
      assert_operator Ractor::UnsafeError, :<=, Ractor::Error
      assert_raises(TypeError) { Ractor::MovedObject.new }
    end

    def test_ractor_local_storage
      storage_key = test_key(:storage)
      created_key = test_key(:created)
      Ractor[storage_key] = 1

      assert_equal 1, Ractor[storage_key]
      assert_equal 1, Ractor.store_if_absent(storage_key) { 2 }
      assert_equal 3, Ractor.store_if_absent(created_key) { 3 }
    end

    def test_make_shareable_and_shareable_predicate
      object = +"mutable"
      shareable = Ractor.make_shareable(object, copy: true)

      assert Ractor.shareable?(shareable)
      assert_equal !native_ractors?, Ractor.shareable?(object)
    end

    def test_shim_shareable_predicate_accepts_basic_objects
      return unless Ractor.shim?

      assert Ractor.shareable?(Class.new(BasicObject).new)
      refute Ractor.shareable?(Class.new(BasicObject) { include Unshareable }.new)
    end

    def test_shareable_proc_binds_self
      receiver = Ractor.make_shareable({ answer: 42 }, copy: true)
      rebound = Ractor.shareable_proc(self: receiver) { self[:answer] }

      refute_predicate rebound, :lambda?
      assert Ractor.shareable?(rebound)
      assert_equal 42, rebound.call
    end

    def test_shareable_lambda_binds_self
      receiver = Ractor.make_shareable({ answer: 42 }, copy: true)
      rebound = Ractor.shareable_lambda(self: receiver) { self[:answer] }

      assert_predicate rebound, :lambda?
      assert Ractor.shareable?(rebound)
      assert_equal 42, rebound.call
    end

    def test_new_ractor_returns_block_value
      ractor = Ractor.new(41, name: "farce-test") do |value|
        [Ractor.current.name, Ractor.current == Ractor.main, value + 1]
      end

      assert_kind_of Ractor, ractor
      assert_equal ["farce-test", false, 42], value(ractor)
    end

    def test_ractor_receives_messages
      ractor = Ractor.new do
        Ractor.receive
      end

      assert_same ractor, ractor.send(:message)
      assert_equal :message, value(ractor)
    end

    def test_new_requires_block
      assert_raises(ArgumentError) { Ractor.new }
    end

    def test_ractor_rejects_non_current_storage_access
      return if RUBY_ENGINE == "ruby" && RUBY_VERSION < "4"
      ractor = Ractor.new { Ractor.receive }

      assert_raises(RuntimeError) { ractor[:key] }
      assert_raises(RuntimeError) { ractor[:key] = :value }

      ractor.send(:done)

      assert_equal :done, value(ractor)
    end

    def test_ractor_current_allows_local_storage_access
      storage_key = test_key(:current_storage)
      ractor = Ractor.new(storage_key) do |key|
        Ractor.current[key] = :value
        Ractor.current[key]
      end

      assert_equal :value, value(ractor)
    end

    def test_join_waits_and_returns_self
      return if RUBY_ENGINE == "ruby" && RUBY_VERSION < "4"
      ractor = Ractor.new { :done }

      assert_same ractor, ractor.join
      assert_equal :done, value(ractor)
    end

    def test_ractor_monitor_reports_exit_status
      return if RUBY_ENGINE == "ruby" && RUBY_VERSION < "4"
      ractor = Ractor.new { Ractor.receive }
      port = Port.new

      assert ractor.monitor(port)
      ractor.send(:done)

      assert_equal :exited, port.receive
      assert_equal :done, value(ractor)
    end

    def test_ractor_unmonitor_stops_exit_notification
      return if RUBY_ENGINE == "ruby" && RUBY_VERSION < "4"
      skip "TODO: timeout not implemented" if RUBY_ENGINE == "ruby" && RUBY_VERSION < "4.1"
      ractor = Ractor.new { Ractor.receive }
      port = Port.new

      assert ractor.monitor(port)
      assert_same ractor, ractor.unmonitor(port)
      ractor.send(:done)

      assert_nil port.receive(timeout: 0.01)
      assert_equal :done, value(ractor)
    end

    def test_ractor_monitor_reports_already_terminated_status
      return if RUBY_ENGINE == "ruby" && RUBY_VERSION < "4"
      ractor = Ractor.new { :done }

      assert_equal :done, value(ractor)
      port = Port.new

      refute ractor.monitor(port)
      assert_equal :exited, port.receive
    end

    def test_ractor_monitor_reports_error_status
      return if RUBY_ENGINE == "ruby" && RUBY_VERSION < "4"
      port = Port.new
      ractor = nil

      with_report_on_exception(false) do
        ractor = Ractor.new { raise "boom" }

        assert_raises(RuntimeError) { value(ractor) }

        refute ractor.monitor(port)
      end

      assert_equal :aborted, port.receive
    end

    def test_inspect_includes_name_location_and_status
      ractor = Ractor.new(name: "inspect-test") { Ractor.receive }

      assert_match(/#<.*Ractor.* inspect-test .* (running|blocking)>/, ractor.inspect)
      ractor.send(:done)

      assert_equal :done, value(ractor)
      wait_for_ractor_termination(ractor)

      assert_match(/#<.*Ractor.* inspect-test .* terminated>/, ractor.inspect)
    end

    private

    def value(ractor) = ractor.respond_to?(:value) ? ractor.value : ractor.take

    def native_ractors?
      RUBY_ENGINE == "ruby"
    end

    def test_key(name)
      :"test_ractor_#{name}_#{object_id}"
    end

    def with_report_on_exception(value)
      previous = Thread.report_on_exception
      Thread.report_on_exception = value
      yield
    ensure
      Thread.report_on_exception = previous
    end

    def wait_for_ractor_termination(ractor)
      100.times do
        return if ractor.inspect.include?("terminated")

        sleep 0.001
      end
    end
  end
end
