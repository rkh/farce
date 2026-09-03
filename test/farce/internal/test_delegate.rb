# frozen_string_literal: true

require_relative "../../setup"

module Helpers
  module DelegateModuleTarget
    def self.combine(value, keyword:, **kwargs, &block)
      [self, value, keyword, kwargs, block.call]
    end

    def self.first = :module_first
    def self.second = :module_second
  end

  module DelegateStringTarget
    def self.combine(value, keyword:, **kwargs, &block)
      [self, value, keyword, kwargs, block.call]
    end
  end
end

module Farce
  module Internal
    class TestDelegate < Test
      ModuleTarget = Helpers::DelegateModuleTarget
      StringTarget = Helpers::DelegateStringTarget

      def test_delegates_to_module_constant
        receiver = receiver_for(ModuleTarget, :combine)

        assert_equal [ModuleTarget, 1, 2, { three: 3 }, 4], receiver.combine(1, keyword: 2, three: 3) { 4 }
      end

      def test_delegates_multiple_methods_to_module_constant
        receiver = receiver_for(ModuleTarget, :first, :second)

        assert_equal :module_first, receiver.first
        assert_equal :module_second, receiver.second
      end

      def test_delegates_to_string_target
        receiver = receiver_for("Helpers::DelegateStringTarget", :combine)

        assert_equal [StringTarget, 1, 2, { three: 3 }, 4], receiver.combine(1, keyword: 2, three: 3) { 4 }
      end

      def test_delegates_to_symbol_target
        receiver = receiver_for(:"Helpers::DelegateStringTarget", :combine)

        assert_equal [StringTarget, 1, 2, { three: 3 }, 4], receiver.combine(1, keyword: 2, three: 3) { 4 }
      end

      def test_delegates_to_object_target
        target = Object.new
        target.define_singleton_method(:combine) do |value, keyword:, **kwargs, &block|
          [self, value, keyword, kwargs, block.call]
        end

        receiver = receiver_for(target, :combine)

        assert_equal [target, 1, 2, { three: 3 }, 4], receiver.combine(1, keyword: 2, three: 3) { 4 }
      end

      def test_delegates_multiple_methods_to_object_target
        target = Object.new
        target.define_singleton_method(:first) { :object_first }
        target.define_singleton_method(:second) { :object_second }
        receiver = receiver_for(target, :first, :second)

        assert_equal :object_first, receiver.first
        assert_equal :object_second, receiver.second
      end

      private

      def receiver_for(target, *methods)
        delegated = Module.new
        Internal.delegate(delegated, target, *methods)
        Class.new { include delegated }.new
      end
    end
  end
end
