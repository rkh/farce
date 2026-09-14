# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Shareable containers whose mutable contents belong to the current scope.
  # Scopes may be :ractor, :thread_group, :thread, :fiber_storage, or :fiber.
  # Initial contents are copied between Ractors. Within a Ractor, each scope has
  # its own container, but objects supplied as initial contents may be shared.
  module Local
    include Internal::Autoloads
  end
end
