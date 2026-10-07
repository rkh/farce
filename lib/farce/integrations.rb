# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @api private
  module Integrations
    # Dependency entry points, ending with the feature that activates each integration.
    INTEGRATIONS = {
      active_support: %w[active_support active_support/core_ext].freeze,
      bson:           %w[bson].freeze,
      dry_types:      %w[dry/types].freeze,
      concurrent:     %w[concurrent/map concurrent/tvar concurrent].freeze,
      json:           %w[json].freeze,
      msgpack:        %w[msgpack].freeze,
      psych:          %w[psych].freeze,
      oj:             %w[oj].freeze,
      sorted_set:     %w[sorted_set].freeze,
      weakref:        %w[weakref].freeze,
      yajl:           %w[yajl].freeze,
      ractor_tmvar:   %w[ractor/tvar ractor/tmvar].freeze,
      ractor_sharing: %w[
        ractor/tvar
        ractor/lockvar
        ractor/lockhash
        ractor/keylockhash
        ractor/active_object
        ractor/actor_hash
        ractor/sharing
      ].freeze,
    }.freeze

    PATHS = INTEGRATIONS.to_h { [_2.last, _1] }.merge(
      "concurrent/tvar" => :concurrent,
      "ractor/tvar"     => :ractor_sharing,
      "oj/json"         => :oj,
      "yajl/json_gem"   => :yajl,
    ).freeze

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
        result      = Integrations.loading(path) { super }
        integration = PATHS[path.delete_suffix(".rb")]
        if integration && !Integrations.loading?(integration) && Farce.config.autoload_integrations
          integration_path = "farce/integrations/#{integration}"
          Integrations.loading(integration_path) { super(integration_path) }
        end
        result
      end
    end
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
        result      = Integrations.loading(path) { farce_original_require(path, ...) }
        integration = PATHS[path.delete_suffix(".rb")]
        if integration && !Integrations.loading?(integration) && Farce.config.autoload_integrations
          integration_path = "farce/integrations/#{integration}"
          Integrations.loading(integration_path) { farce_original_require(integration_path) }
        end
        result
      end
    end

    private_constant :INTEGRATIONS, :PATHS

    extend self

    # Avoid requiring an integration again while it loads its own dependencies.
    # @api private
    def loading(path)
      return yield unless path.start_with?("farce/integrations/")
      previous = Thread.current[:farce_loading_integration]
      Thread.current[:farce_loading_integration] = path.delete_prefix("farce/integrations/").delete_suffix(".rb").to_sym
      begin
        yield
      ensure
        Thread.current[:farce_loading_integration] = previous
      end
    end

    # @api private
    def loading?(integration) = Thread.current[:farce_loading_integration] == integration

    # Activate integrations at startup when automatic loading is enabled.
    # @api private
    def setup
      Object.prepend(RequireHook)
      load_active if Farce.config.autoload_integrations
    end

    # Loads all integrations for gems that have already been loaded.
    # @return [Array<Symbol>] the list of integrations that were loaded
    # @!scope class
    def load_active
      result = []
      INTEGRATIONS.each_key do |integration|
        next unless loaded?("farce/integrations/#{integration}") ||
          PATHS.any? { |path, target| target == integration && loaded?(path) }
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
