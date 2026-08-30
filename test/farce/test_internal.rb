# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestInternal < Test
    def test_garbage_collectable
      refute Internal.garbage_collectable?(1)
      refute Internal.garbage_collectable?(1.0)
      refute Internal.garbage_collectable?(Complex(1, 2))
      refute Internal.garbage_collectable?(Rational(1, 2))
      refute Internal.garbage_collectable?(:symbol)
      refute Internal.garbage_collectable?(true)
      refute Internal.garbage_collectable?(false)
      refute Internal.garbage_collectable?(nil)

      assert Internal.garbage_collectable?("string")
      assert Internal.garbage_collectable?([])
      assert Internal.garbage_collectable?({})
    end
  end
end
