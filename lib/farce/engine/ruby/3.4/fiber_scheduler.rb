# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    class FiberScheduler
      # Ruby 3.4 can strand a control Ractor started alongside scheduled workers.
      # Start it before admitting fibers. Ruby 4.x creates the selector lazily.
      module RactorSelectorSetup
        def initialize(...)
          RactorSelector.current
          super
        end
      end
      private_constant :RactorSelectorSetup
      prepend RactorSelectorSetup
    end
  end
end
