# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestFiberSchedulerTruffleruby < Test
      def test_preloading_succeeds_but_instantiation_is_unsupported
        return unless RUBY_ENGINE == "truffleruby"
        scheduler = Internal.const_get(:FiberScheduler, false)

        assert_kind_of Class, scheduler
        error = assert_raises(NotImplementedError) { scheduler.new }
        assert_equal "TruffleRuby does not support fiber schedulers", error.message
        assert_raises(NotImplementedError) { scheduler.new(backend: :select) }
      end
    end
  end
end
