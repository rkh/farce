# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Special, write-only port that discards all messages.
  # If the Ruby environment supports ports, this will be a real Port object.
  # It can therefore be passed to any API expecting a `Ractor::Port`, including C code.
  # Cannot be read from, but does not accumulate messages in memory.
  # @return [Ractor::Port] Write-only port
  NULL_PORT = Internal::NullPort.new
end
