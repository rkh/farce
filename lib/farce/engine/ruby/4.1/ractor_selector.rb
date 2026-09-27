# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/4.0/ractor_selector"

module Farce
  module Internal
    class RactorSelector
      # Ruby 4.1 can crash while formatting a dying helper's exception after
      # Ractor teardown has freed its ports. Callers and close observe failures.
      # See https://bugs.ruby-lang.org/issues/22386
      module ExplicitFailureReporting
        private

        def run
          Thread.current.report_on_exception = false
          super
        end
      end
      private_constant :ExplicitFailureReporting
      prepend ExplicitFailureReporting
    end
  end
end
