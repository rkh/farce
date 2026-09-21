# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Common interface for concurrent sets backed by Farce maps.
    # Membership changes are atomic per element. Operations involving several
    # elements are not atomic as a whole. Iteration streams without first copying
    # every element. Structural changes during traversal can invalidate it.
    # Identity comparison and normalization are fixed at construction, so this
    # class does not provide Set#compare_by_identity or Set#reset.
    class Set
      include Enumerable
      include Internal::Copyable

      # A shareable, immutable key used by mode-backed sets. Structural keys
      # contain an insertion-time snapshot. Identity keys contain either the
      # shareable element itself or an opaque token.
      class MembershipKey
        attr_reader :value

        def initialize(value, identity: false)
          @value = value
          @identity = identity
          @hash = identity ? value.__id__.hash : value.hash
          freeze
        end

        def eql?(other)
          return false unless other.instance_of?(self.class) && @identity == other.identity?
          @identity ? @value.equal?(other.value) : @value.eql?(other.value)
        end
        alias == eql?

        def hash = [self.class, @identity, @hash].hash
        def identity? = @identity
      end
      private_constant :MembershipKey

      # Keeps the manager that created a payload beside it. Derived sets can
      # retain the stored representation without opening move envelopes.
      class StoredEntry
        include Shareable::Immutable

        attr_reader :manager, :payload

        def initialize(manager, payload)
          @manager = manager
          @payload = payload
          super()
        end
      end
      private_constant :StoredEntry

      IDENTITY_TOKENS = Local::WeakKeyMap.new(compare_keys_by_identity: true)
      MISSING_KEY = Object.new.freeze
      private_constant :IDENTITY_TOKENS, :MISSING_KEY

      # Construct a set from the arguments.
      # @param elements [Array<BasicObject>] The initial elements.
      # @return [Farce::Abstract::Set] A new instance of the receiving class.
      def self.[](*elements) = new(elements)

      # Construct a set, optionally transforming each initial element before normalization.
      # @param enumerable [#each, nil] The initial elements, or nil for an empty set.
      # @param normalize [Symbol, Proc, Hash, Farce::Abstract::Map, nil] The element normalizer.
      # @param compare_by_identity [Boolean] Whether membership uses object identity.
      # @param mode [Symbol] The default transfer mode. Only Farce::Set and Farce::SortedSet
      #   accept this option. Defaults to :copy for those classes.
      # @param options [Hash] Additional options for the selected variant.
      # @option options [Symbol] scope (:ractor) The scope used by Farce::Local variants.
      # @yield [element] Optionally transform each initial element before storage.
      # @yieldparam element [BasicObject] An element from enumerable.
      # @yieldreturn [BasicObject] The element to normalize and store.
      # @return [Farce::Abstract::Set] The new set.
      def initialize(
        enumerable = nil, normalize: nil, compare_by_identity: false, mode: UNDEFINED, **options, &transform
      )
        unknown = options.keys - [:scope]

        unless unknown.empty?
          label = unknown.size == 1 ? "keyword" : "keywords"
          raise ArgumentError, "unknown #{label}: #{unknown.map(&:inspect).join(", ")}"
        end

        shareable = !is_a?(Unshareable)

        validate_boolean!(:compare_by_identity, compare_by_identity)

        @compare_by_identity = compare_by_identity
        @normalizer          = Internal::KeyNormalizer.build(normalize, shareable:)
        restoring            = Internal::KeyNormalizer.restoration?(normalize)

        initialize_value_mode(mode)
        elements = input_elements(enumerable) unless enumerable.nil?
        elements.map! { transform.call(it) } if transform && elements
        elements.map! { normalize_element(it) } if elements && @normalizer && !restoring

        if value_modes?
          @map = new_map(nil, compare_keys_by_identity: false, **options)
          elements&.each { add_normalized(it) }
        else
          entries = elements&.map { [it, true] }
          @map = new_map(entries, compare_keys_by_identity: compare_by_identity, **options)
        end

        super()
      end

      # Add an element and return self.
      # @param element [BasicObject] The element to normalize and store.
      # @param mode [Symbol, nil] Override the transfer mode for this insertion. Only
      #   Farce::Set and Farce::SortedSet accept this option. Nil uses the set's default.
      # @return [self] The set.
      def add(element, mode: UNDEFINED)
        check_frozen!
        add_normalized(normalize_element(element), mode:)
        self
      end
      alias << add

      # Add an absent element and return self, or nil if it was already present.
      # @param element [BasicObject] The element to normalize and store.
      # @param mode [Symbol, nil] Override the transfer mode for this insertion. Only
      #   Farce::Set and Farce::SortedSet accept this option. Nil uses the set's default.
      # @return [self, nil] The set if added, otherwise nil.
      def add?(element, mode: UNDEFINED) # rubocop:disable Naming/PredicateMethod
        check_frozen!
        added = add_normalized?(normalize_element(element), mode:)
        self if added
      end

      # Remove an element and return self.
      # @param element [BasicObject] The element to normalize and look up.
      # @return [self] The set.
      def delete(element)
        check_frozen!
        element = normalize_element(element)
        if value_modes?
          key = lookup_key(element)
          @map.delete(key) unless MISSING_KEY.equal?(key)
        else
          @map.delete(element)
        end
        self
      end

      # Remove an element and return self, or nil if it was absent.
      # @param element [BasicObject] The element to normalize and look up.
      # @return [self, nil] The set if removed, otherwise nil.
      def delete?(element) # rubocop:disable Naming/PredicateMethod
        check_frozen!
        element = normalize_element(element)
        removed = if value_modes?
                    key = lookup_key(element)
                    @map.delete(key) unless MISSING_KEY.equal?(key)
                  else
                    @map.delete(element)
                  end
        self if removed
      end

      # Return whether an element is present.
      # @param element [BasicObject] The element to normalize and look up.
      # @return [Boolean] Whether the normalized element is present.
      def include?(element)
        element = normalize_element(element)
        return @map.key?(element) unless value_modes?
        key = lookup_key(element)
        !MISSING_KEY.equal?(key) && @map.key?(key)
      end
      alias member? include?
      alias === include?

      # Iterate over the elements currently present without first copying all elements.
      # @yield [element] Visit each element. Returns an Enumerator without a block.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator] The set, or an Enumerator without a block.
      def each
        return enum_for(__method__) { size } unless block_given?
        each_element { yield it }
        self
      end

      # Return the number of elements currently present.
      # @return [Integer]
      def size = @map.size
      alias length size

      # Return whether no elements are present.
      # @return [Boolean]
      def empty? = @map.empty?

      # Remove all elements and return self.
      # @return [self]
      def clear
        check_frozen!
        @map.clear
        self
      end

      # Add all elements yielded by each enumerable.
      # @param enumerables [Array<#each>] The collections of elements to add.
      # @return [self] The set.
      def merge(*enumerables)
        check_frozen!
        enumerables.each do |enumerable|
          if canonical_compatible?(enumerable)
            enumerable.each_stored { |key, value| add_stored(key, value) }
          else
            each_input(enumerable) { add(it) }
          end
        end
        self
      end

      # Remove every element yielded by enumerable.
      # @param enumerable [#each] The elements to remove.
      # @return [self] The set.
      def subtract(enumerable)
        check_frozen!
        if canonical_compatible?(enumerable)
          retained = membership_index(enumerable)
          @map.delete_if { |element, _| retained.key?(element) }
        else
          each_input(enumerable) do |element|
            key = lookup_key(normalize_element(element))
            @map.delete(key) unless MISSING_KEY.equal?(key)
          end
        end
        self
      end

      # Remove elements accepted by the block.
      # @yield [element] Test each element. Returns an Enumerator without a block.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [BasicObject] A truthy value to remove the element.
      # @return [self, Enumerator] The set, or an Enumerator without a block.
      def delete_if
        return enum_for(__method__) { size } unless block_given?
        check_frozen!
        each_stored { |key, value| @map.delete(key) if yield(public_stored(key, value)) }
        self
      end

      # Keep elements accepted by the block.
      # @yield [element] Test each element. Returns an Enumerator without a block.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [BasicObject] A truthy value to keep the element.
      # @return [self, Enumerator] The set, or an Enumerator without a block.
      def keep_if
        return enum_for(__method__) { size } unless block_given?
        check_frozen!
        each_stored { |key, value| @map.delete(key) unless yield(public_stored(key, value)) }
        self
      end

      # Return a same-kind set containing elements accepted by the block.
      # @yield [element] Test each element. Returns an Enumerator without a block.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [BasicObject] A truthy value to keep the element.
      # @return [Farce::Abstract::Set, Enumerator] A new set, or an Enumerator without a block.
      def select
        return enum_for(__method__) { size } unless block_given?
        dup.filter_backend! { yield it }
      end
      alias filter select

      # Return a same-kind set without elements accepted by the block.
      # @yield [element] Test each element. Returns an Enumerator without a block.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [BasicObject] A truthy value to exclude the element.
      # @return [Farce::Abstract::Set, Enumerator] A new set, or an Enumerator without a block.
      def reject
        return enum_for(__method__) { size } unless block_given?
        dup.filter_backend! { !yield(it) }
      end

      # Remove elements accepted by the block, returning nil when unchanged.
      # @yield [element] Test each element. Returns an Enumerator without a block.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [BasicObject] A truthy value to remove the element.
      # @return [self, nil, Enumerator] The changed set, nil if unchanged, or an Enumerator without a block.
      def reject!
        return enum_for(__method__) { size } unless block_given?
        check_frozen!
        changed = false
        each_stored do |key, value|
          changed = true if yield(public_stored(key, value)) && @map.delete(key)
        end
        self if changed
      end

      # Keep elements accepted by the block, returning nil when unchanged.
      # @yield [element] Test each element. Returns an Enumerator without a block.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [BasicObject] A truthy value to keep the element.
      # @return [self, nil, Enumerator] The changed set, nil if unchanged, or an Enumerator without a block.
      def select!
        return enum_for(__method__) { size } unless block_given?
        check_frozen!
        changed = false
        each_stored do |key, value|
          changed = true if !yield(public_stored(key, value)) && @map.delete(key)
        end
        self if changed
      end
      alias filter! select!

      # Return the elements in an Array.
      # @return [Array<BasicObject>] The observed elements.
      def to_a = each.to_a

      # Convert to a Ruby Set, or to an explicitly requested set class.
      # @param klass [Class] The target set class. Defaults to Ruby's ::Set.
      # @param arguments [Array<BasicObject>] Additional positional arguments for its constructor.
      # @param options [Hash] Keyword arguments for its constructor.
      # @yield [element] Optionally transform elements through the target constructor.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [BasicObject] The element to store in the target set.
      # @return [::Set, Farce::Abstract::Set] A new Ruby Set by default. An explicit
      #   target class matching self returns self when no arguments, options, or block
      #   are supplied. Otherwise, returns a new instance of klass.
      def to_set(klass = ::Set, *arguments, **options, &)
        return self if klass == self.class && arguments.empty? && options.empty? && !block_given?
        klass.new(self, *arguments, **options, &)
      end

      # Return a same-kind set containing elements from either operand.
      # @param enumerables [Array<#each>] The collections of elements to include.
      # @return [Farce::Abstract::Set] A new set of the same class with the same settings.
      def union(*enumerables) = dup.merge(*enumerables)
      alias | union
      alias + union

      # Return a same-kind set without elements from the enumerable.
      # @param enumerable [#each] The elements to exclude.
      # @return [Farce::Abstract::Set] A new set of the same class with the same settings.
      def difference(enumerable) = dup.subtract(enumerable)
      alias - difference

      # Return a same-kind set containing elements also present in every enumerable.
      # @param enumerables [Array<#each>] The collections whose members must be present.
      # @return [Farce::Abstract::Set] A new set of the same class with the same settings.
      def intersection(*enumerables)
        copy = dup
        indexes = enumerables.map { membership_index(it) }
        copy.filter_stored! { |key, _| indexes.all? { it.key?(key) } }
        copy
      end
      alias & intersection

      # Return a same-kind set containing elements present in exactly one operand.
      # @param other [#each] The other collection of elements.
      # @return [Farce::Abstract::Set] A new set of the same class with the same settings.
      def ^(other)
        other = empty_copy.merge(other)
        (self - other).merge(other - self)
      end

      # Return whether every element is present in the other set-like object.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def subset?(other)
        validate_set_like(other)
        left  = equality_index
        right = relation_index(other)
        left.size <= right.size && left.each_key.all? { right.key?(it) }
      end
      alias <= subset?

      # Return whether this is a proper subset of the other set-like object.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def proper_subset?(other)
        validate_set_like(other)
        left  = equality_index
        right = relation_index(other)
        left.size < right.size && left.each_key.all? { right.key?(it) }
      end
      alias < proper_subset?

      # Return whether all elements of the other set-like object are present.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def superset?(other)
        validate_set_like(other)
        left  = equality_index
        right = relation_index(other)
        left.size >= right.size && right.each_key.all? { left.key?(it) }
      end
      alias >= superset?

      # Return whether this is a proper superset of the other set-like object.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def proper_superset?(other)
        validate_set_like(other)
        left  = equality_index
        right = relation_index(other)
        left.size > right.size && right.each_key.all? { left.key?(it) }
      end
      alias > proper_superset?

      # Return whether this set and another set-like object share an element.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def intersect?(other)
        validate_set_like(other)
        left  = equality_index
        right = relation_index(other)
        left, right = right, left if right.size < left.size
        left.each_key.any? { right.key?(it) }
      end

      # Return whether this set and another set-like object share no elements.
      # @param other [Farce::Abstract::Set, ::Set] The set to compare against.
      # @return [Boolean] Whether the relation holds.
      # @raise [ArgumentError] If other is not a Farce or Ruby set.
      def disjoint?(other) = !intersect?(other)

      # Compare sets by the subset relation.
      # @param other [BasicObject] The object to compare against.
      # @return [Integer, nil] -1 for a proper subset, 0 for equal sets, 1 for a proper
      #   superset, or nil when neither relation holds or other is not a set.
      def <=>(other)
        return unless set_like?(other)
        return 0  if self == other
        return -1 if proper_subset?(other)
        1 if proper_superset?(other)
      end

      # Group elements by the block result.
      # @yield [element] Choose a group for each element. Returns an Enumerator without a block.
      # @yieldparam element [BasicObject] The current element.
      # @yieldreturn [BasicObject] The group key.
      # @return [Hash{BasicObject => Farce::Abstract::Set}, Enumerator] Group keys mapped
      #   to same-kind subsets, or an Enumerator without a block.
      def classify
        return enum_for(__method__) { size } unless block_given?
        groups = {}
        each_stored do |stored_key, stored_value|
          element = public_stored(stored_key, stored_value)
          key = yield element
          (groups[key] ||= empty_copy).add_stored(stored_key, stored_value)
        end
        groups
      end

      # Divide elements into same-kind subsets.
      # The outer result is an Unshared::Set that holds the subsets strongly.
      #
      # @overload divide { |element| ... }
      #   Group elements that produce the same block result.
      #   @yield [element] Choose a group for each element.
      #   @yieldparam element [BasicObject] The current element.
      #   @yieldreturn [BasicObject] The group key.
      #   @return [Farce::Unshared::Set] A set containing the same-kind subsets.
      # @overload divide { |left, right| ... }
      #   Compute strongly connected components using a two-argument block.
      #   @yield [left, right] Test the directed relation between two elements.
      #   @yieldparam left [BasicObject] The source element.
      #   @yieldparam right [BasicObject] The candidate related element.
      #   @yieldreturn [BasicObject] A truthy value when left is related to right.
      #   @return [Farce::Unshared::Set] A set containing the same-kind components.
      # @overload divide
      #   @return [Enumerator] An Enumerator that divides the set when given a block.
      def divide(&block)
        return enum_for(__method__) { size } unless block
        groups = if block.arity == 2
                   # Ruby 3.4 also requires TSort here, inside Set#divide.
                   require "tsort"
                   divide_by_relation(&block)
                 else
                   classify(&block).values
                 end
        Farce::Unshared::Set.new(groups)
      end

      # Return a flattened same-kind set.
      # @return [Farce::Abstract::Set] A new set containing the recursively expanded members.
      # @raise [ArgumentError] If a nested set contains itself recursively.
      def flatten
        copy = empty_copy
        flatten_into(self, copy, ::Set.new.compare_by_identity)
        copy
      end

      # Return whether membership uses object identity.
      # @return [Boolean] Whether identity comparison is enabled.
      def compare_by_identity? = @compare_by_identity

      # Return whether elements are held weakly.
      # @return [Boolean] Whether the set retains elements weakly.
      def weak? = @map.weak_keys?

      # Compatibility method for ActiveSupport.
      # @return [Boolean] Always true.
      def duplicable? = true

      # Return whether this set has the same members as another set.
      # @param other [BasicObject] The object to compare against.
      # @return [Boolean] Whether other is a Farce set with compatible comparison settings and equal members.
      def ==(other)
        return true if equal?(other)
        return false unless other.is_a?(Abstract::Set) && size == other.size
        return false unless comparison_compatible?(other)
        index = other.equality_index
        equality_index.each_key.all? { index.key?(it) }
      end

      # Compare membership using eql?.
      # @param other [BasicObject] The object to compare against.
      # @return [Boolean] Whether other is a Farce set with compatible comparison settings and equal members.
      def eql?(other)
        return true if equal?(other)
        return false unless other.is_a?(Abstract::Set) && size == other.size
        return false unless comparison_compatible?(other)
        index = other.equality_index
        equality_index.each_key.all? { index.key?(it) }
      end

      # Return an order-independent hash derived from the members.
      # @return [Integer] The hash code.
      def hash
        guard = recursion_guard(:farce_set_hash_guard)
        return 0 if guard.key?(self)
        guard[self] = true
        entered     = true
        set         = ::Set.new
        set.merge(equality_index.keys).hash
      ensure
        guard&.delete(self) if entered
      end

      # Return a debugging representation.
      # @return [String] The class name and observed members.
      def inspect
        guard = recursion_guard(:farce_set_inspect_guard)
        return "#<#{self.class.name}: {...}>" if guard.key?(self)
        guard[self] = true
        entered = true
        "#<#{self.class.name}: {#{map(&:inspect).join(", ")}}>"
      ensure
        guard&.delete(self) if entered
      end
      alias to_s inspect

      # Join the members through Array#join.
      # @param separator [String, nil] The separator. Nil uses Array's default separator.
      # @return [String] The joined elements.
      def join(separator = nil) = to_a.join(separator)

      # Serialize the members as a JSON Array.
      # @overload to_json(*arguments)
      #   @param arguments [Array<BasicObject>] Serialization arguments forwarded to Array#to_json.
      #   @return [String] The generated JSON.
      def to_json(...) = to_a.to_json(...)

      # @api private
      # Called by Psych for generating YAML.
      # @param coder [Psych::Coder] The YAML representation.
      # @return [Psych::Coder] The coder containing the set representation.
      def encode_with(coder)
        coder["entries"] = each_stored.map do |key, stored|
          element        = public_stored(key, stored)
          entry          = {
            "value"     => element,
            "shareable" => Ractor.shareable?(element),
          }
          if value_modes?
            entry["identity"] = identity_storage_key?(key)
            entry["snapshot"] = key unless entry["identity"]
            entry["mode"]     = stored_mode(stored)
          end
          entry
        end
        coder["compare_by_identity"] = compare_by_identity?
        coder["frozen"]              = frozen?
        coder["mode"]                = @manager.mode if value_modes?
        coder["scope"]               = scope if respond_to?(:scope)
        coder["normalize"]           = Internal::KeyNormalizer.dump(@normalizer) if @normalizer
        coder
      end

      # @api private
      # Called by Psych when parsing YAML.
      # @param coder [Psych::Coder] The YAML representation.
      # @return [self] The restored set.
      def init_with(coder)
        options             = { compare_by_identity: coder["compare_by_identity"] }
        options[:mode]      = coder["mode"].to_sym                                if coder["mode"]
        options[:scope]     = coder["scope"].to_sym                               if coder["scope"]
        options[:normalize] = Internal::KeyNormalizer.restore(coder["normalize"]) if coder.map.key?("normalize")
        entries             = coder["entries"]

        if coder["mode"]
          initialize(nil, **options)
          entries.each { restore_yaml_entry(it) }
        else
          values = entries.map { restore_yaml_value(it) }
          initialize(values, **options)
        end

        freeze if coder["frozen"]
        self
      end

      protected

      def initialize_empty_copy(other)
        initialize_copy(other, empty: true)
        publish_shareable if is_a?(Shareable)
        self
      end

      def each_stored(&block)
        return enum_for(__method__) { size } unless block
        @map.each_live(&block)
      end

      def filter_backend!(&keep)
        check_frozen!
        filter_stored! { |key, value| keep.call(public_stored(key, value)) }
      end

      def filter_stored!
        check_frozen!
        each_stored { |key, value| @map.delete(key) unless yield(key, value) }
        self
      end

      def equality_index
        each_stored.with_object({}) do |(key, _), index|
          key = comparison_key_for_canonical(key) unless value_modes?
          index[key] = true
        end
      end

      def add_stored(key, value)
        @map.store_if_absent(key) { value }
        self
      end

      def public_stored(key, value) = value_modes? ? unwrap_entry(key, value) : key

      def canonical_compatible?(other)
        return false unless other.is_a?(Abstract::Set)
        @normalizer.equal?(other.instance_variable_get(:@normalizer)) &&
          compare_by_identity? == other.compare_by_identity? &&
          value_modes? == other.value_modes? &&
          ordered? == other.ordered?
      end

      def add_normalized(element, mode: UNDEFINED)
        add_normalized?(element, mode:)
        self
      end

      def value_modes? = false
      def map_backend  = @map
      def ordered?     = false

      private

      def check_frozen! = Internal::Freeze.check(self)
      def freeze_backend = @map

      def initialize_copy(other, empty: false)
        super(other)
        @map = if empty
                 new_map(
                   nil,
                   compare_keys_by_identity: value_modes? ? false : other.compare_by_identity?,
                   **copy_map_options(other),
                 )
               else
                 other.map_backend.dup
               end
      end

      def recursion_guard(key)
        Internal::Storage.fiber.store_if_absent(key) { {}.compare_by_identity }
      end

      def each_element
        each_stored { |key, value| yield public_stored(key, value) }
      end

      def each_input(enumerable)
        raise ArgumentError, "value must be enumerable" unless enumerable.respond_to?(:each)
        enumerable.each { yield it }
      end

      def input_elements(enumerable)
        raise ArgumentError, "value must be enumerable" unless enumerable.respond_to?(:each)
        elements = []
        enumerable.each { elements << it } # rubocop:disable Style/MapIntoArray
        elements
      end

      def empty_copy
        copy = self.class.allocate
        instance_variables.each { |name| copy.instance_variable_set(name, instance_variable_get(name)) }
        copy.initialize_empty_copy(self)
      end

      def map_canonical
        copy = empty_copy
        each { copy.add_normalized(yield(it)) }
        copy
      end

      def membership_index(enumerable)
        raise ArgumentError, "value must be enumerable" unless enumerable.respond_to?(:each)
        index = {}
        index.compare_by_identity if compare_by_identity? && !value_modes?
        if canonical_compatible?(enumerable)
          enumerable.each_stored { |key, _| index[key] = true }
        else
          enumerable.each do |element|
            element = normalize_element(element)
            if value_modes?
              key = lookup_key(element)
              index[key] = true unless MISSING_KEY.equal?(key)
            else
              index[element] = true
            end
          end
        end
        index
      end

      def normalize_element(element) = @normalizer ? @normalizer.call(element) : element

      def initialize_value_mode(mode)
        raise ArgumentError, "unknown keyword: :mode" unless UNDEFINED.equal?(mode)
      end

      def validate_boolean!(name, value)
        return if value.equal?(true) || value.equal?(false)
        raise ArgumentError, "#{name} must be a boolean"
      end

      def add_normalized?(element, mode: UNDEFINED)
        raise ArgumentError, "unknown keyword: :mode" unless value_modes? || UNDEFINED.equal?(mode)
        if value_modes?
          add_mode_value?(element, mode:)
        else
          added = false
          @map.store_if_absent(element) do
            added = true
            true
          end
          added
        end
      end

      def add_mode_value?(element, mode:)
        requested_mode = UNDEFINED.equal?(mode) || mode.nil? ? @manager.mode : mode
        existing_key   = lookup_key(element)
        return false unless MISSING_KEY.equal?(existing_key) || !@map.key?(existing_key)

        key, payload = prepare_mode_entry(element, requested_mode)
        added        = false

        @map.store_if_absent(key) do
          added   = true
          payload = @manager.wrap(element, mode: requested_mode) if UNDEFINED.equal?(payload)
          StoredEntry.new(@manager, payload)
        end
        added
      end

      def prepare_mode_entry(element, requested_mode)
        if identity_membership?(element) && !Ractor.shareable?(element)
          case requested_mode
          when :copy
            raise ArgumentError, "identity comparison cannot copy a non-shareable element"
          when :shareable_copy, :make_shareable
            payload = @manager.wrap(element, mode: requested_mode)
            return [insertion_key(payload), payload]
          end
        end

        key = insertion_key(element)
        [key, UNDEFINED]
      end

      def insertion_key(element)
        return structural_key(element) unless identity_membership?(element)
        token = IDENTITY_TOKENS[element]
        return MembershipKey.new(token, identity: true) if token
        return MembershipKey.new(element, identity: true) if Ractor.shareable?(element)

        token = IDENTITY_TOKENS.store_if_absent(element) { Object.new.freeze }
        MembershipKey.new(token, identity: true)
      end

      def lookup_key(element)
        return element unless value_modes?
        return structural_key(element) unless identity_membership?(element)
        token = IDENTITY_TOKENS[element]
        return MembershipKey.new(token, identity: true) if token
        return MembershipKey.new(element, identity: true) if Ractor.shareable?(element)

        MISSING_KEY
      end

      def structural_key(element)
        return element if Ractor.shareable?(element)

        snapshot = Ractor.make_shareable(element, copy: true)
        unless snapshot.eql?(element) && element.eql?(snapshot) && snapshot.hash == element.hash
          raise ArgumentError, "element cannot be represented by a stable equality snapshot"
        end
        snapshot
      end

      def identity_membership?(element)
        compare_by_identity? || element.method(:eql?).owner == Kernel
      rescue NameError
        true
      end

      def unwrap_entry(key, entry)
        element = entry.manager.unwrap(entry.payload)
        if identity_storage_key?(key) && !Ractor.shareable?(element)
          token = key.value
          IDENTITY_TOKENS.store_if_absent(element) { token }
        end
        element
      end

      def stored_mode(entry)
        case entry.payload
        when Envelope::Copy  then :copy
        when Envelope::Local then :local
        when Envelope::Move  then :move
        else @manager.mode
        end
      end

      def restore_yaml_entry(entry)
        value   = restore_yaml_value(entry)
        key     = entry["identity"] ? comparison_key_for_canonical(value) : Ractor.make_shareable(entry["snapshot"])
        mode    = entry["mode"]&.to_sym
        payload = @manager.wrap(value, mode:)
        add_stored(key, StoredEntry.new(@manager, payload))
      end

      def restore_yaml_value(entry)
        value = entry["value"]
        entry["shareable"] ? Ractor.make_shareable(value) : value
      end

      def identity_storage_key?(key)
        key.instance_of?(MembershipKey) && key.identity?
      end

      def copy_map_options(other)
        other.respond_to?(:scope) ? { scope: other.scope } : {}
      end

      def validate_set_like(other)
        return if set_like?(other)
        raise ArgumentError, "value must be a set"
      end

      def set_like?(object) = object.is_a?(Abstract::Set) || object.is_a?(::Set)

      def comparison_compatible?(other)
        (!other.respond_to?(:compare_by_identity?) || compare_by_identity? == other.compare_by_identity?) &&
          ordered? == other.is_a?(Abstract::SortedSet)
      end

      def relation_index(other)
        return other.equality_index if other.is_a?(Abstract::Set)
        membership_index(other)
      end

      def comparison_key_for_canonical(element)
        return element unless identity_membership?(element)
        token = IDENTITY_TOKENS[element]
        return MembershipKey.new(token, identity: true) if token
        return MembershipKey.new(element, identity: true) if Ractor.shareable?(element)

        token = IDENTITY_TOKENS.store_if_absent(element) { Object.new.freeze }
        MembershipKey.new(token, identity: true)
      end

      def flatten_into(source, target, seen)
        raise ArgumentError, "tried to flatten recursive set" if seen.include?(source)
        seen.add(source)
        entered = true
        if source.is_a?(Abstract::Set)
          source.each_stored do |key, value|
            element = source.public_stored(key, value)
            if set_like?(element)
              flatten_into(element, target, seen)
            elsif target.canonical_compatible?(source)
              target.add_stored(key, value)
            else
              target.add(element)
            end
          end
        else
          source.each do |element|
            set_like?(element) ? flatten_into(element, target, seen) : target.add(element)
          end
        end
      ensure
        seen.delete(source) if entered
      end

      def divide_by_relation(&relation)
        entries = @map.to_a
        graph   = {}
        graph.compare_by_identity if compare_by_identity? && !value_modes?
        entries.each do |key, value|
          element     = public_stored(key, value)
          graph[key]  = entries.filter_map do |candidate_key, candidate_value|
            candidate = public_stored(candidate_key, candidate_value)
            candidate_key if relation.call(element, candidate)
          end
        end
        graph.extend(TSort)
        graph.define_singleton_method(:tsort_each_node) { |&yield_node| each_key(&yield_node) }
        graph.define_singleton_method(:tsort_each_child) { |node, &yield_child| fetch(node).each(&yield_child) }
        graph.strongly_connected_components.map do |component|
          empty_copy.tap do |group|
            component.each { |key| group.add_stored(key, @map.fetch(key)) }
          end
        end
      end

      # simplecov:disable
      def new_map(...)
        raise "subclass failed to implement #new_map" unless instance_of?(Set)
        raise NoMethodError, "Farce::Abstract::Set should not be instantiated directly. Use a subclass instead."
      end
      # simplecov:enable
    end
  end
end
