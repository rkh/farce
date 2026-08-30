# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Module holding classes with instances which are not thread-safe and cannot be shared between Ractors.
  module Unsafe
    include Internal::Autoloads
  end
end
