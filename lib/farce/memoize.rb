# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Ractor-friendly memoization module.
  #
  # Replaces the following pattern:
  #
  # ```ruby
  # class MyClass
  #   def time
  #     @time ||= Time.now
  #   end
  # end
  # ```
  #
  # Using `Farce::Memoize` instead gives you:
  #
  # * Allows memoization after freezing
  # * Is Ractor-safe (with optional scoping or transfer modes) and thread-safe
  # * Adds one instance variable per memoized method (avoids hash lookup and doesn't bust Ruby's data structures)
  # * Is Marshal-dump/load friendly
  # * Allows weak memoization, where the memoized value is kept until it is garbage collected
  # * Does not need to run code on the main Ractor for memoization
  #
  # Methods with arguments cannot be memoized. Explicitly use a {Farce::Abstract::Map map} instead.
  #
  # @example Using `memoize` method
  #   class MyClass
  #     include Farce::Memoize
  #     memoize def time = Time.now
  #   end
  #
  #   instance    = MyClass.new
  #   first_time  = instance.time
  #   second_time = instance.time
  #
  #   first_time == second_time      # => true
  #   first_time == MyClass.new.time # => false
  #
  # @example Scope-specific memoization
  #   class MyClass
  #     include Farce::Memoize
  #
  #     def first = expensive_computation(0)
  #     def last  = expensive_computation(-1)
  #
  #     # Memoize separately per Ractor
  #     memoize :first, :last, scope: :ractor
  #   end
  #
  # @example Setting a mode
  #   class MyClass
  #     include Farce::Memoize
  #     memoize :expensive, mode: :make_shareable
  #     def expensive = expensive_computation
  #   end
  #
  # @example Without `memoize` extension
  #   class MyClass
  #     include Farce::Memoize[:time]
  #     def time = Time.now
  #   end
  #
  # @see Farce::Lazy
  # @see Farce::LazyRef
  #
  # @!macro memoize_params
  #   @overload $0(*methods, scope: :global, mode: :smart, weak: false, visibility: nil)
  #     @param methods [Array<Symbol>]
  #       The methods to memoize
  #
  #     @param scope [Symbol]
  #       The scope of the memoization.
  #       In addition to the {Farce::SCOPES normal scopes} it may also be set to `:global` or `:unshared`.
  #
  #     @param mode [Symbol]
  #       The mode of the memoization. Ignored for any scope other than `:global`.
  #       Defaults to `:raise` with `weak: true`, which supports only `:raise`, `:make_shareable`, and `:dedup`.
  #
  #     @param weak [Boolean]
  #       Whether to use weak memoization.
  #       If enabled, memoized values may be garbage collected when no longer referenced.
  #       In this case, next access to the memoized method may recompute the value.
  #
  #     @param visibility [Symbol, nil]
  #       The visibility of the memoized methods.
  #       May be one of `:public`, `:protected`, or `:private`.
  #       If set to `nil`, {Farce::Memoize#memoize} will attempt to infer the visibility based on the context.
  #       Other methods will default to `:public`.
  module Memoize
    # A named module preserves the nil marker's identity across Marshal round trips.
    NIL_VALUE = Module.new.freeze
    private_constant :NIL_VALUE

    # Mixins used to implement memoization for different methods, scopes, and modes
    # @see Farce::Memoize
    class Mixin < Module
      KNOWN = Strict::Map.new
      private_constant :KNOWN

      # @!macro memoize_params
      # @return [Mixin] the memoization mixin
      # @see #initialize
      def self.new(*methods, **options)
        return super unless self == Mixin
        methods = Farce.dedup(methods.map(&:to_sym).uniq.sort)
        options = Farce.dedup(normalize_options(options))
        map     = KNOWN.store_if_absent(options) { Strict::Map.new }
        map.store_if_absent(methods) { super(methods, **options) }
      end

      # @api private
      def self.normalize_options(options)
        options[:visibility] &&= options[:visibility].to_sym

        options[:scope]      ||= :global
        options[:visibility] ||= :public
        options[:weak]       ||= false

        if options[:scope] == :global
          options[:mode] ||= options[:weak] ? :raise : :smart
        else
          options.delete(:mode)
        end

        options
      end
      private_class_method :normalize_options

      # @return [Array<Symbol>] the memoized methods
      attr_reader :memoized_methods

      # @return [Symbol] the scope of the memoization
      attr_reader :scope

      # @return [Symbol, nil] the transfer mode, or nil for a scoped cache
      attr_reader :mode

      # @return [Symbol] the visibility of the memoized methods
      attr_reader :visibility

      def initialize(methods, scope:, weak:, mode: nil, visibility: :public)
        @memoized_methods = methods
        @scope            = scope
        @mode             = mode
        @weak             = !!weak # rubocop:disable Style/DoubleNegation
        @visibility       = visibility

        super()

        unless %i[public protected private].include?(visibility)
          raise ArgumentError, "unsupported visibility: #{visibility.inspect}"
        end

        atom_class = weak ? "WeakAtom" : "Atom"

        case scope
        when :global
          modes = weak ? Internal::WeakModeManager::MODES : MODES
          raise ArgumentError, "unsupported mode: #{mode.inspect}" unless modes.include?(mode)
          init = "::Farce::#{atom_class}.new(mode: #{mode.inspect})"
          args = methods.join(", ")
          args += ", mode: #{mode.inspect}" unless mode == :smart
        when :unshared
          init = "::Farce::Unshared::#{atom_class}.new"
          args = "#{methods.join(", ")}, scope: :unshared"
        when *SCOPES
          init = "::Farce::Local::#{atom_class}.new(scope: #{scope.inspect})"
          args = "#{methods.join(", ")}, scope: #{scope.inspect}"
        else
          raise ArgumentError, "unsupported scope: #{scope.inspect}"
        end

        set_temporary_name(-"Farce::Memoize[#{args}]") if instance_of?(Mixin)
        initializer = +""
        # Overlapping mixins need separate slots. Stable names also survive Marshal across processes.
        slot = "#{methods.join(",").unpack1("H*")}_#{scope}_#{mode}_#{@weak}_#{visibility}"

        methods.each do |method|
          unless method =~ /\A[a-z_]\w*[!?]?\z/i && method != :initialize
            raise ArgumentError, "unsuitable method name: #{method.inspect}"
          end
          ivar = "@_#{method.to_s.unpack1("H*")}_memoize_#{slot}_atom"
          initializer << "  #{ivar} = #{init}\n"
          module_eval <<~RUBY, __FILE__, __LINE__ + 1
            #{visibility} def #{method}
              value = #{ivar}.store_if_absent do
                result = super()
                nil.equal?(result) ? NIL_VALUE : result
              end
              value unless NIL_VALUE.equal?(value)
            end
          RUBY
        end

        # Explicit forwarding preserves nested constructor keywords on JRuby.
        module_eval <<~RUBY, __FILE__, __LINE__ + 1
          def initialize(*, **, &)
            #{initializer}
            super
          end
        RUBY
      end

      # @return [Boolean] whether the memoization is weak
      def weak? = @weak

      # allow `include Farce::Memoize[...]` to work like `prepend`
      private def append_features(base) = base.prepend(self)
    end

    # @api private
    def self.append_features(base) = base.extend(self)
    private_class_method :append_features

    # Creates or retrieves the memoization mixin for the given methods, scope, and mode
    # @!macro memoize_params
    # @return [Mixin] memoization mixin for the given methods, scope, and mode
    def self.[](...) = Mixin.new(...)

    # @!macro memoize_params
    # Creates a memoization mixin for the given arguments and adds it to the current class.
    #
    # Can be used as a prefix to `def`:
    #
    # ```ruby
    # memoize def some_method = expensive_computation
    # ```
    #
    # Or called separately with the method names, useful for passing additional options:
    #
    # ```ruby
    # def some_method = expensive_computation
    #
    # # memoize some_method per thread
    # memoize :some_method, scope: :thread
    # ```
    #
    # ## Visibility of Memoized Methods
    #
    # If no visibility is provided, it will determine the visibility based on the existing method definitions.
    # If none exist, it will default to public. This happens when `memoize` is called.
    # Make sure you set the visibility before calling this method.
    #
    # This works:
    #
    # ```ruby
    # memoize private def some_method = expensive_computation
    # ```
    #
    # As does this:
    #
    # ```ruby
    # private
    # memoize def some_method = expensive_computation
    # ```
    #
    # Or this:
    #
    # ```ruby
    # private def some_method = expensive_computation
    # memoize :some_method
    # ```
    #
    # But this doesn't, as the mixin's method will end up public:
    #
    # ```ruby
    # private memoize def some_method = expensive_computation
    # ```
    #
    # Same for this one, as the mixin's method will also end up public:
    #
    # ```ruby
    # memoize :some_method
    # private def some_method = expensive_computation
    # ```
    #
    # You can of course set visibility explicitly when calling `memoize`:
    #
    # ```ruby
    # memoize :some_method, visibility: :private
    # ```
    #
    # @return [Array<Symbol>] the list of memoized methods
    def memoize(*methods, visibility: nil, warn: true, **)
      if visibility.nil?
        groups = methods.group_by do |method|
          next :protected if protected_method_defined?(method)
          next :private   if private_method_defined?(method)
          :public
        end
        return groups.flat_map { memoize(*_2, visibility: _1, warn:, **) }
      end

      if warn
        methods.each do |name|
          method = instance_method(name)
          next if method.parameters.empty?
          warn "#{method.owner}##{name} expects parameters and may be unsuitable for memoization"
        rescue NameError => e
          raise e unless e.name == name.to_sym
        end
      end

      mixin = Farce::Memoize[*methods, visibility:, **]
      prepend mixin

      mixin.memoized_methods
    end
  end
end
