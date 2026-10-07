# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/internal/copyable"
require "farce/shareable"

module Farce
  module Strict
    # An immutable Ractor-shareable trie for String and Regexp chains.
    #
    # Build a trie with {.build} or {Builder}. Published tries do not change.
    # A reusable builder can publish additional independent snapshots.
    #
    # Static edges take precedence over regexp edges. Regexp edges retain their
    # insertion order. `peek` searches descendants before returning a shorter
    # terminal match. A regexp edge is atomic. Later edges cannot make a regexp
    # choose a different endpoint.
    #
    # Tokens must already be Ractor-shareable. They are stored and returned
    # unchanged. Equal but different token objects remain separate. Reusing the
    # same token object produces at most one result per lookup.
    #
    # Each result is `[token, positional_captures, named_captures, suffix]`.
    # Exact matches have an empty suffix. Capture arrays, hashes, strings, and
    # suffixes are new mutable objects for each result. A capture string may
    # be shared between the positional and named views within one result.
    #
    # Input and literal edges retain Ruby String encoding behavior. Invalid byte
    # sequences are rejected. ASCII-8BIT strings provide binary matching.
    # Incompatible literal encodings do not match. Regexp encoding errors retain
    # Ruby's ordinary behavior.
    #
    # `dup` and `clone` return frozen, Ractor-shareable matchers with the same
    # immutable graph and token objects. This also applies to
    # `clone(freeze: false)`.
    #
    # @example Build and match a trie
    #   routes = Farce::Strict::Trie.build do |builder|
    #     builder.add(["/users/", /(?<id>\d+)/], :user)
    #   end
    #
    #   routes.match("/users/12")
    #   # => [:user, ["12"], { "id" => "12" }, ""]
    #
    # @!method match(input)
    #   Return the first exact match.
    #   @param input [String]
    #   @return [Array(Object, Array<String, nil>, Hash{String => Object}, String), nil]
    #
    # @!method match_all(input)
    #   Return every exact match in traversal order.
    #   @param input [String]
    #   @return [Array<Array>]
    #
    # @!method peek(input)
    #   Return the first prefix match.
    #   @param input [String]
    #   @return [Array(Object, Array<String, nil>, Hash{String => Object}, String), nil]
    #
    # @!method peek_all(input)
    #   Return every prefix match in traversal order.
    #   @param input [String]
    #   @return [Array<Array>]
    #
    # @!method each_match(input)
    #   Yield each exact match without first collecting every result.
    #   Each yield has four arguments: token, positional captures, named
    #   captures, and suffix.
    #   @param input [String]
    #   @yieldparam token [Object]
    #   @yieldparam positional_captures [Array<String, nil>]
    #   @yieldparam named_captures [Hash{String => Object}]
    #   @yieldparam suffix [String]
    #   @return [Trie, Enumerator] self after normal exhaustion, or an Enumerator
    #     when no block is given
    #
    # @!method each_peek(input)
    #   Yield each prefix match without first collecting every result.
    #   Each yield has four arguments: token, positional captures, named
    #   captures, and suffix.
    #   @param input [String]
    #   @yieldparam token [Object]
    #   @yieldparam positional_captures [Array<String, nil>]
    #   @yieldparam named_captures [Hash{String => Object}]
    #   @yieldparam suffix [String]
    #   @return [Trie, Enumerator] self after normal exhaustion, or an Enumerator
    #     when no block is given
    class Trie
      include Internal::MarshalSupport::Reject
      include Internal::Copyable unless ancestors.include?(Internal::Copyable)
      include Shareable::Immutable unless ancestors.include?(Shareable::Immutable)

      # Collects entries and publishes immutable {Trie} snapshots.
      class Builder
        # Create an empty builder.
        def initialize
          @entries = []
        end

        # @api private
        def marshal_dump
          entries = @entries.map { |parts, token| [parts, Internal::MarshalSupport.value(token)] }
          [1, entries, frozen?]
        end

        # @api private
        def marshal_load(data)
          entries, frozen = Internal::MarshalSupport.payload(data, 2)
          initialize
          entries.each { |parts, token| add(parts, Internal::MarshalSupport.restore_value(token)) }
          freeze if frozen
        end

        # Add a String and Regexp chain.
        #
        # Literal strings are copied immediately. The token is not copied or
        # frozen and must already be Ractor-shareable. A published trie retains
        # a plain semantic copy of each regexp, not caller-owned regexp state.
        #
        # @param parts [Array<String, Regexp>] ordered matcher edges
        # @param token [Object] the object returned for a match
        # @return [Builder] self
        # @raise [TypeError] if parts or one of its elements has the wrong type
        # @raise [ArgumentError] if a literal has an invalid byte sequence
        # @raise [Ractor::IsolationError] if token is not Ractor-shareable
        def add(parts, token)
          raise TypeError, "parts must be an Array" unless parts.is_a?(Array)
          raise Ractor::IsolationError, "token is not Ractor-shareable" unless Ractor.shareable?(token)

          snapshot = Array.new(parts).map do |part|
            case part
            when String
              snapshot_literal(part)
            when Regexp
              part
            else
              raise TypeError, "edge must be a String or Regexp, got #{part.class}"
            end
          end.freeze

          @entries << [snapshot, token].freeze
          self
        end

        # Publish an immutable snapshot of the current entries.
        #
        # Subsequent changes to the builder do not affect the returned trie.
        #
        # @return [Trie]
        def build
          tokens = []
          token_ids = {}.compare_by_identity
          entries = @entries.map do |parts, token|
            unless token_ids.key?(token)
              token_ids[token] = tokens.length
              tokens << token
            end
            [parts.dup.freeze, token_ids.fetch(token)].freeze
          end.freeze

          Trie.send(:build_entries, entries, tokens.freeze)
        end

        private

        def snapshot_literal(part)
          literal = String.new(part)
          raise ArgumentError, "edge has an invalid #{literal.encoding} byte sequence" unless literal.valid_encoding?

          literal.freeze
        end

        def initialize_copy(other)
          super
          @entries = other.instance_variable_get(:@entries).dup
        end
      end

      class << self
        # Build an immutable trie.
        #
        # @yieldparam builder [Builder]
        # @return [Trie]
        def build
          builder = Builder.new
          yield builder if block_given?
          builder.build
        end

        private

        def build_entries(entries, tokens) = new(entries, tokens)

        private :new
      end
    end
  end
end
