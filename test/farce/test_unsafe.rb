# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestUnsafe < Test
    def test_fallback_and_precedence_with_unloaded_constants
      assert_namespace_lookup
    end

    def test_fallback_and_precedence_after_loading_unshared_variants
      assert_namespace_lookup(:Unshared)
    end

    def test_fallback_and_precedence_after_loading_unsafe_variants
      assert_namespace_lookup(:Unsafe)
    end

    private

    def assert_namespace_lookup(preload = nil)
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        overrides = %i[TreeMap LRUMap LFUMap]
        if #{!preload.nil?}
          namespace = Farce.const_get(#{preload.inspect})
          overrides.each { |name| namespace.const_get(name) }
        end
        unsafe = Farce::Unsafe
        unshared = Farce::Unshared
        overrides.each do |name|
          own = unsafe.const_get(name, false)
          inherited = unshared.const_get(name, false)
          raise "Unsafe used Unshared::\#{name}" if own.equal?(inherited)
          raise "wrong Unsafe::\#{name} class" unless own.name == "Farce::Unsafe::\#{name}"
          raise "Unsafe lookup skipped its own \#{name}" unless unsafe.const_get(name).equal?(own)
        end
        (unshared.constants(false) - overrides).each do |name|
          raise "missing fallback for \#{name}" unless unsafe.const_get(name).equal?(unshared.const_get(name, false))
        end
        queue = unsafe::Queue.new
        queue.push(:value)
        raise "Queue fallback is not usable" unless queue.pop == :value
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
