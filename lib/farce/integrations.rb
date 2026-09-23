# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @api private
  module Integrations
    # Dependency entry points, ending with the feature that activates each integration.
    INTEGRATIONS = {
      active_support: %w[active_support active_support/core_ext].freeze,
      dry_types:      %w[dry/types].freeze,
      json:           %w[json].freeze,
      msgpack:        %w[msgpack].freeze,
      psych:          %w[psych].freeze,
    }.freeze

    PATHS = INTEGRATIONS.to_h { [_2.last, _1] }.freeze

    # Zeitwerk aliases Kernel#require. Prepending there can leave the aliased
    # wrapper without a valid super target on TruffleRuby. Define the instance
    # hook above Object so Kernel#require remains available for those aliases
    # and Ruby's Ractor-aware Object#require stays in the lookup chain.
    module RequireHook
      private

      # Load a feature and its integration while preserving require's result.
      # @param path [String, #to_path] The feature to load.
      # @return [Boolean] Whether the requested feature was newly loaded.
      def require(path, ...)
        path        = File.path(path)
        result      = super
        integration = PATHS[path.delete_suffix(".rb")]
        super("farce/integrations/#{integration}") if integration
        result
      end
    end

    Object.prepend(RequireHook)
    private_constant :RequireHook

    # A prepended singleton hook can recurse when Zeitwerk aliases it. Preserve
    # the original method explicitly instead of relying on super here.
    class << Kernel
      alias farce_original_require require
      private :farce_original_require

      # Load a feature and its integration through Kernel.require.
      # @api private
      # @param path [String, #to_path] The feature to load.
      # @return [Boolean] Whether the requested feature was newly loaded.
      def require(path, ...)
        path        = File.path(path)
        result      = farce_original_require(path, ...)
        integration = PATHS[path.delete_suffix(".rb")]
        farce_original_require("farce/integrations/#{integration}") if integration
        result
      end
    end

    private_constant :INTEGRATIONS, :PATHS

    extend self

    # Loads all integrations for gems that have already been loaded.
    # @return [Array<Symbol>] the list of integrations that were loaded
    # @!scope class
    def load_active
      result = []
      INTEGRATIONS.each do |integration, require_paths|
        next unless loaded?(require_paths.last)
        require "farce/integrations/#{integration}"
        result << integration
      end
      result
    end

    # Attempts to load all available integrations.
    # If the integration could be loaded, it will be included in the result.
    # @return [Array<Symbol>] the list of integrations that were loaded
    # @!scope class
    def load_available
      result = []
      INTEGRATIONS.each do |integration, require_paths|
        next unless try_require("farce/integrations/#{integration}", *require_paths)
        result << integration
      end
      result
    end

    private

    def loaded?(path)
      path  = "#{path}.rb" unless path.end_with?(".rb")
      paths = $LOAD_PATH.map { File.expand_path(path, it) }
      paths.any? { $LOADED_FEATURES.include?(it) }
    end

    def try_require(path, *ignore)
      require path
      true
    rescue LoadError => e
      raise e unless e.path == path || ignore.include?(e.path)
      false
    end
  end
end
