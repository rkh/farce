# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Module holding classes which have instances that cannot be shared between Ractors.
  # Some instances may still be {Unshareable::Movable moved} or {Unshareable::Copyable copied} between Ractors.
  module Unshared
    include Internal::Autoloads
  end
end
