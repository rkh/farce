# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce"
require "active_support"
require "active_support/core_ext"

Dir.glob("active_support/*.rb", base: __dir__) { require_relative it }
