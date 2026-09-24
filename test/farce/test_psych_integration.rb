# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestPsychIntegration < Test
    def test_psych_and_yaml_activate_before_or_after_farce
      %w[psych yaml].product([true, false]).each do |feature, before|
        # SimpleCov loads Psych, so load-order probes need an uninstrumented runtime.
        output, error, status = ruby_isolated(<<~RUBY, timeout: 60, coverage: false)
          require #{feature.inspect} if #{before}
          require "farce"
          sources = [
            Farce::Map.new({ one: 1 }),
            Farce::Atom.new(7, mode: :make_shareable),
            Farce::Counter.new(3).increment(2),
            Farce::Flag.new(true),
            Farce::Set.new([1, 2]),
            Farce::Local::Map.new({ one: 1 }, scope: :fiber),
            Farce::Local::Atom.new(7, scope: :fiber),
            Farce::Local::Counter.new(3, scope: :fiber).increment(2),
            Farce::Local::Flag.new(true, scope: :fiber),
            Farce::Local::LRUMap.new({ one: 1 }, max_size: 2, scope: :fiber),
            Farce::Local::Set.new([1, 2], scope: :fiber),
          ]
          unless #{before}
            raise "Psych loaded by core" if $LOADED_FEATURES.any? { it.end_with?("/psych.rb") }
            sources.each do |source|
              raise "YAML hooks exposed by core" if source.respond_to?(:encode_with) || source.respond_to?(:init_with)
            end
            raise "YAML helper exposed by core" if Farce::Set.private_method_defined?(:restore_yaml_entry)
            raise "normalizer dumping exposed by core" if Farce.const_get(:Internal)::KeyNormalizer.respond_to?(:dump)
          end
          require #{feature.inspect}
          raise "Psych integration missing" unless Farce::Integrations.load_active.include?(:psych)
          codec = #{feature == "yaml" ? "YAML" : "Psych"}
          sources.each do |source|
            copy = codec.unsafe_load(codec.dump(source))
            raise "wrong class" unless copy.class == source.class
            reader = source.is_a?(Farce::Abstract::Map) ? :to_h : source.is_a?(Farce::Abstract::Set) ? :to_set : :value
            raise "wrong contents" unless copy.public_send(reader) == source.public_send(reader)
            raise "scope lost" if source.respond_to?(:scope) && copy.scope != :fiber
            raise "mode lost" if source.is_a?(Farce::Atom) && copy.mode != :make_shareable
            raise "capacity lost" if source.respond_to?(:max_size) && copy.max_size != 2
            if source.is_a?(Farce::Abstract::Counter)
              raise "initial value lost" unless copy.initial == 3
              copy.reset
              raise "reset failed" unless copy.value == 3
            end
          end
          # Load another Local class after activation as well.
          late = Farce::Local::LFUMap.new({ one: 1 }, max_size: 2, scope: :fiber)
          copy = codec.unsafe_load(codec.dump(late))
          raise "late-loaded scope lost" unless copy.scope == :fiber && copy.to_h == late.to_h
          raise "unrelated Local class gained YAML hooks" if Farce::Local::Queue.method_defined?(:encode_with)
          puts "ok"
        RUBY

        assert_predicate status, :success?, "#{feature}, before=#{before}: #{output}\n#{error}"
        assert_equal "ok\n", output
      end
    end

    def test_kernel_require_activates_psych_and_preserves_return_values
      output, error, status = ruby_isolated(<<~RUBY, timeout: 60, coverage: false)
        require "farce"
        raise "first require returned false" unless Kernel.require("psych")
        raise "second require returned true" if Kernel.require("psych")
        raise "integration missing" unless Farce::Flag.method_defined?(:encode_with)
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
    end

    def test_explicit_psych_integration_loads_its_dependency
      output, error, status = ruby_isolated(<<~RUBY, timeout: 60)
        require "farce/integrations/psych"
        counter = Psych.unsafe_load(Psych.dump(Farce::Counter.new(3)))
        raise "incorrect value" unless counter.value == 3
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
    end
  end
end
