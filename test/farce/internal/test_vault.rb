# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestVault < Test
      class PausedEquality
        def initialize(entered, release)
          @entered = entered
          @release = release
        end

        def ==(_other)
          @entered.push(true)
          @release.pop(timeout: 5)
          true
        end
      end

      class RecursiveEquality
        def initialize(vault)
          @vault = vault
        end

        def ==(_other) = @vault.copy_out(:other)
      end

      def test_commands_can_be_added_after_the_vault_starts
        return unless Internal.native_ractors?
        output, error, status = ruby_subprocess(<<~RUBY)
          require "farce"
          vault = Farce.const_get(:Internal)::Vault.new
          key = Object.new.freeze
          vault.copy_in(key, [1, 2, 3])
          [:test_size, :respond].each do |action|
            begin
              vault.send(:execute, action, key)
              raise "unexpected command"
            rescue NoMethodError, Ractor::RemoteError
              # Unknown commands and private transport methods are not callable.
            end
          end
          begin
            vault.send(:execute, :run, key)
            raise "recursive run accepted"
          rescue ArgumentError
            # Ruby rejects the command arguments before entering run.
          end
          raise "manager stopped after rejected run" unless vault.copy_out(key) == [1, 2, 3]

          module Farce
            module Internal
              class Vault
                class Manager
                  def test_size(key, _value, port)
                    respond(port, [true, @data[key].size].freeze)
                  end

                  def test_error(_key, _value, _port)
                    raise ArgumentError, "extension failure"
                  end
                end

                def test_size(key) = execute(:test_size, key)
                def test_error(key) = execute(:test_error, key)
                def test_shared_size(key) = shared_request(:test_size, key, :unused)
                def test_shared_error(key) = shared_request(:test_error, key, :unused)
              end
            end
          end

          raise "wrong reply" unless vault.test_size(key) == 3
          raise "wrong shared reply" unless vault.test_shared_size(key) == 3
          [:test_error, :test_shared_error].each do |operation|
            begin
              vault.public_send(operation, key)
              raise "missing error"
            rescue ArgumentError => error
              raise unless error.message == "extension failure"
            end
          end
          raise "value changed" unless vault.move_out(key) == [1, 2, 3]
          vault.copy_in(key, :recovered)
          raise "manager stopped" unless vault.copy_out(key) == :recovered
        RUBY

        assert_predicate status, :success?, "#{output}\n#{error}"
      end

      def test_untransferable_errors_do_not_strand_callers
        return unless Internal.native_ractors?
        output, error, status = ruby_subprocess(<<~RUBY)
          require "farce"
          module Farce
            module Internal
              class Vault
                class PayloadError < StandardError
                  def initialize
                    @callback = proc {}
                    super("payload failure")
                  end
                end

                class Manager
                  def test_payload(_key, _value, _port)
                    raise PayloadError
                  end

                  def test_cause(key, value, port)
                    test_payload(key, value, port)
                  rescue PayloadError
                    raise ArgumentError, "outer failure"
                  end
                end
              end
            end
          end

          vault = Farce.const_get(:Internal)::Vault.new
          key = Object.new.freeze
          vault.copy_in(key, :unchanged)
          { test_payload: "payload failure", test_cause: "outer failure" }.each do |action, message|
            begin
              vault.send(:execute, action, key)
              raise "missing error"
            rescue Ractor::RemoteError => error
              raise "missing message" unless error.message.include?(message)
              raise "missing class" unless error.message.include?(action == :test_payload ? "PayloadError" : "ArgumentError")
              raise "wrong ractor" unless error.ractor.equal?(vault.instance_variable_get(:@ractor))
              raise "missing backtrace" unless error.backtrace.any? { |line| line.include?(action.to_s) }
              raise "untransferable cause retained" unless error.cause.nil?
            end
            raise "manager stopped" unless vault.copy_out(key) == :unchanged

            # Atom replies already serialize class, message, and backtrace without the exception's payload.
            begin
              vault.send(:shared_request, action, key, nil)
              raise "missing shared error"
            rescue Farce.const_get(:Internal)::Vault::PayloadError, ArgumentError => error
              raise "wrong shared message" unless error.message == message
              raise "missing shared backtrace" unless error.backtrace.any? { |line| line.include?(action.to_s) }
            end
            raise "manager stopped after shared reply" unless vault.copy_out(key) == :unchanged
          end
        RUBY

        assert_predicate status, :success?, "#{output}\n#{error}"
      end

      def test_recursive_request_raises_without_stopping_the_vault
        return unless Internal.native_ractors?
        vault = Vault.new
        key = Object.new.freeze
        vault.copy_in(key, RecursiveEquality.new(vault))

        error = assert_raises(ThreadError) do
          Timeout.timeout(5) { vault.same_value?(key, :other, right_stored: false) }
        end

        assert_match(/recursive access from the Vault/, error.message)
        vault.copy_in(key, :recovered)

        assert_equal :recovered, Timeout.timeout(5) { vault.copy_out(key) }
      end

      def test_concurrent_callers_receive_their_own_copy_and_move_replies
        return unless Internal.native_ractors?
        vault = Vault.new
        workers = 8.times.map do |index|
          Thread.new do
            key = Object.new.freeze
            vault.copy_in(key, [index])
            [vault.copy_out(key), vault.move_out(key)]
          end
        end
        workers.each_with_index do |worker, index|
          assert worker.join(5), "Vault caller did not finish"
          assert_equal [[index], [index]], worker.value
        end
      ensure
        workers&.each { |worker| worker.kill if worker.alive? }
        workers&.each(&:join)
      end

      def test_copy_and_move_replies_progress_between_weak_map_requests
        return unless Internal.native_ractors?
        Timeout.timeout(30) do
          200.times do |index|
            map = Farce::WeakKeyMap.new
            source = [index]
            copied = map.store(:key, source, mode: :copy)

            assert_equal [index], copied
            refute_same source, copied
            assert_equal [index], map.store(:key, [index], mode: :move)
          end
        end
      end

      def test_interrupted_request_does_not_poison_later_replies
        return unless Internal.native_ractors?
        vault = Vault.new
        key = Object.new.freeze
        other_key = Object.new.freeze
        entered = Queue.new
        release = Queue.new
        vault.copy_in(key, PausedEquality.new(entered, release))
        vault.copy_in(other_key, :expected)
        worker = Thread.new { vault.same_value?(key, :other, right_stored: false) }

        assert entered.pop(timeout: 5), "Vault comparison never started"
        worker.kill

        assert worker.join(5), "interrupted caller did not finish"
        release.push(true)

        assert_equal :expected, Timeout.timeout(5) { vault.copy_out(other_key) }
        vault.copy_in(other_key, :replacement)

        assert_equal :replacement, Timeout.timeout(5) { vault.copy_out(other_key) }
      ensure
        release&.push(true)
        worker&.kill if worker&.alive?
        worker&.join
      end
    end
  end
end
