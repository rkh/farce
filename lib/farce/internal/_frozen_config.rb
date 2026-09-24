# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Autoload runs on the main Ractor, where CONFIG can still be accessed before
    # freezing. Keep this lazy so requiring Farce leaves configuration mutable.
    FROZEN_CONFIG = CONFIG.freeze
  end
end
