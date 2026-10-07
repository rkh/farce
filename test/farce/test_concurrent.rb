# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestConcurrent < Test
    def test_concurrent_transaction_integration
      output, error, status = ruby_isolated(<<~RUBY, timeout: 60)
        require "subprocess/concurrent"
        if RUBY_ENGINE == "ruby"
          raise "C extension not loaded" unless Concurrent.c_extensions_loaded?
          raise "wrong atomic implementation" unless Concurrent::AtomicReference < Concurrent::CAtomicReference
        end
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_concurrent_transaction_integration_without_c_extension
      return unless RUBY_ENGINE == "ruby"

      output, error, status = ruby_isolated(<<~RUBY, timeout: 60)
        # Exercise the native loader's fallback as if concurrent-ruby-ext were absent.
        module WithoutConcurrentCExtension
          private

          def require(path, ...)
            if ["concurrent/concurrent_ruby_ext", "concurrent/#{RUBY_VERSION[0..2]}/concurrent_ruby_ext"].include?(path)
              error = LoadError.new("concurrent-ruby-ext unavailable")
              error.define_singleton_method(:path) { path }
              raise error
            end
            super
          end
        end
        Object.prepend(WithoutConcurrentCExtension)
        require "subprocess/concurrent"
        raise "C extension loaded" if Concurrent.c_extensions_loaded?
        raise "wrong atomic implementation" unless Concurrent::AtomicReference < Concurrent::MutexAtomicReference
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_loading_concurrent_before_and_after_farce
      %w[concurrent concurrent/tvar].each do |feature|
        ["require", "Kernel.require"].each do |loader|
          [true, false].each do |before|
            source = before ? "#{loader}(#{feature.inspect}); require \"farce\"" :
              "require \"farce\"; #{loader}(#{feature.inspect})"
            output, error, status = ruby_isolated(<<~RUBY, coverage: false)
              #{source}
              raise "require return changed" if #{loader}(#{feature.inspect})
              raise "TVar extended" if Concurrent::TVar.method_defined?(:transaction_snapshot)
              tvar = Concurrent::TVar.new(1)
              raise "transaction failed" unless Farce.transaction { |tx| tx[tvar].value = 2 }
              raise "wrong value" unless tvar.value == 2
              raise "integration not active" unless Farce::Integrations.load_active == [:concurrent, :weakref]
              raise "configuration frozen" if Farce.config.frozen?
              map = Concurrent::Map.new
              map[:values] = [1]
              converted = Farce.enfarce(map)
              raise "wrong map class" unless converted.instance_of?(Farce::Map)
              raise "wrong vector class" unless converted[:values].instance_of?(Farce::Vector)
              raise "wrong values" unless converted[:values].to_a == [1]
            RUBY

            assert_predicate status, :success?, "#{output}\n#{error}"
          end
        end
      end
    end

    def test_explicit_loading_when_autoload_is_disabled
      output, error, status = ruby_isolated(<<~RUBY, coverage: false)
        ENV["FARCE_AUTOLOAD_INTEGRATIONS"] = "false"
        require "farce"
        require "concurrent/tvar"
        tvar = Concurrent::TVar.new(1)
        begin
          Farce.transaction { |tx| tx[tvar] }
          raise "integration loaded implicitly"
        rescue TypeError
        end
        require "farce/integrations/concurrent"
        raise "TVar extended" if Concurrent::TVar.method_defined?(:transaction_snapshot)
        raise "transaction failed" unless Farce.transaction { |tx| tx[tvar].value = 2 }
        raise "wrong value" unless tvar.value == 2
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
