# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable concurrent set whose elements support transfer modes.
  # Membership uses a stable insertion-time hash and eql? snapshot. Later
  # mutation of a local element does not change its membership key. Elements
  # whose equality cannot be preserved by a shareable snapshot are rejected.
  # Identity comparison supports shareable elements and the `:local`, `:move`,
  # `:make_shareable`, and `:shareable_copy` modes. Copying a non-shareable
  # identity element is unsupported. On runtimes without native Ractors,
  # elements follow ordinary hash-key mutation rules.
  #
  # @example Track unique job identifiers
  #   jobs = Farce::Set[:compile, :test]
  #   jobs.add?(:publish) # => jobs
  #   jobs.add?(:test)    # => nil
  class Set < Farce::Abstract::Set
    include Shareable::Delegated

    # The default transfer mode for elements.
    # @return [Symbol] The configured transfer mode.
    def mode = @manager.mode

    protected

    def value_modes? = true

    private

    def initialize_value_mode(mode)
      mode = :copy if UNDEFINED.equal?(mode)
      @manager = ModeManager.new(mode:)
    end

    def new_map(...) = Farce::Strict::Map.new(...)
  end
end
