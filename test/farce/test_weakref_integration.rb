# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/weakref"

module Farce
  class TestWeakrefIntegration < Test
    include Helpers::WeakReferenceHelpers

    def test_explicit_loading_and_autoload_configuration
      [false, true].each do |disabled|
        output, error, status = ruby_isolated(<<~RUBY, coverage: false)
          ENV["FARCE_AUTOLOAD_INTEGRATIONS"] = "#{!disabled}"
          require "farce/integrations/weakref"
          raise "require result changed" if require("farce/integrations/weakref")
          reference = Farce.enfarce(::WeakRef.new(:value))
          raise "wrong reference class" unless reference.instance_of?(Farce::WeakRef)
          raise "wrong referent" unless reference.__getobj__ == :value
          raise "configuration frozen" if Farce.config.frozen?
        RUBY

        assert_predicate status, :success?, "#{output}\n#{error}"
      end
    end

    def test_disabling_autoload_leaves_conversion_unregistered
      output, error, status = ruby_isolated(<<~RUBY, coverage: false)
        ENV["FARCE_AUTOLOAD_INTEGRATIONS"] = "false"
        require "farce"
        reference = ::WeakRef.new(:value)
        raise "converted without integration" unless Farce.enfarce(reference).equal?(reference)
        require "farce/integrations/weakref"
        raise "explicit integration missing" unless Farce.enfarce(reference).instance_of?(Farce::WeakRef)
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_conversion_of_unchanged_referents
      [Farce, Local, Strict, Unshared, Unsafe].each do |namespace|
        [nil, false, :value, Object.new].each do |value|
          result = namespace.enfarce(::WeakRef.new(value))

          assert_instance_of Farce::WeakRef, result
          value.nil? ? assert_nil(result.__getobj__) : assert_same(value, result.__getobj__)

          assert_predicate result, :weakref_alive?
        end
      end
    end

    def test_conversion_returns_the_converted_referent
      [Farce, Local, Strict, Unshared, Unsafe].each do |namespace|
        value = [1]
        result = namespace.enfarce(::WeakRef.new(value))

        assert_instance_of namespace::Vector, result
        assert_equal [1], result.to_a
        assert_equal [1], value
        assert_equal :replacement, namespace.enfarce(::WeakRef.new(:value)) { :replacement }
      end
    end

    def test_conversion_of_collected_references
      source = collected_reference(::WeakRef)
      result = Farce.enfarce(source)

      assert_same Farce::WeakRef::RECYCLED, result
      refute_predicate result, :weakref_alive?
      assert_raises(Farce::WeakRefError) { result.__getobj__ }
    end

    def test_conversion_preserves_cycles_through_the_referent
      value = [1]
      reference = ::WeakRef.new(value)
      value << reference
      result = Unshared.enfarce(reference)

      assert_instance_of Unshared::Vector, result
      assert_equal 1, result[0]
      assert_same result, result[1]
      assert_same reference, value.last
    end

    def test_conversion_preserves_repeated_references
      value = Object.new
      reference = ::WeakRef.new(value)
      result = Unshared.enfarce([reference, reference])

      assert_same result[0], result[1]
      assert_same value, result[0].__getobj__
    end

    def test_conversion_does_not_swallow_callback_errors
      error = assert_raises(::WeakRef::RefError) do
        Farce.enfarce(::WeakRef.new(:value)) { raise ::WeakRef::RefError, "callback failed" }
      end

      assert_equal "callback failed", error.message
    end

    def test_conversion_does_not_retain_the_unchanged_referent
      reference = Thread.new do
        value = Object.new
        Farce.enfarce(::WeakRef.new(value))
      end.value
      50.times do
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        break unless reference.weakref_alive?
        sleep 0.01
      end

      refute_predicate reference, :weakref_alive?
      assert_raises(Farce::WeakRefError) { reference.__getobj__ }
    end

    def test_walker_visits_live_referents_once
      value = [:value]
      reference = ::WeakRef.new(value)
      visited = Walker.each([reference, reference]).to_a

      assert_equal(1, visited.count { it.equal?(reference) })
      assert_equal(1, visited.count { it.equal?(value) })
      assert_includes visited, :value
      assert_same value, reference.__getobj__
    end

    def test_walker_handles_nil_false_and_collected_references
      [nil, false].each do |value|
        reference = ::WeakRef.new(value)

        assert_equal [value, reference], Walker.each(reference).to_a
      end
      reference = collected_reference(::WeakRef)

      assert_equal [reference], Walker.each(reference).to_a
      assert_same reference, Walker.modify(reference, copy: true) { |_, walker| walker.traverse }
    end

    def test_walker_reuses_unchanged_references
      [false, true, :clone].each do |copy|
        value = [:value]
        reference = ::WeakRef.new(value)
        result = Walker.modify(reference, copy:) { |_, walker| walker.traverse }

        assert_same reference, result
        assert_same value, result.__getobj__
      end
    end

    def test_walker_replaces_changed_referents
      [false, true, :clone].each do |copy|
        original = +"original"
        replacement = +"replacement"
        reference = ::WeakRef.new(original)
        result = Walker.modify(reference, copy:) do |value, walker|
          value.equal?(original) ? replacement : walker.traverse
        end

        assert_instance_of ::WeakRef, result
        assert_same replacement, result.__getobj__
        assert_same original, reference.__getobj__
      end
    end

    def test_walker_preserves_copied_cycles
      value = [1]
      reference = ::WeakRef.new(value)
      value << reference
      result = Walker.modify(reference, copy: true) do |object, walker|
        Integer === object ? object + 1 : walker.traverse
      end
      converted = result.__getobj__

      refute_same reference, result
      refute_same value, converted
      assert_equal 2, converted.first
      assert_same result, converted.last
      assert_equal 1, value.first
      assert_same reference, value.last
    end
  end
end
