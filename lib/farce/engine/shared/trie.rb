# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/internal/copyable"
require "farce/shareable"
require "farce/strict"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Portable immutable backend for {Farce::Strict::Trie}.
    class PortableTrie
      attr_reader :stats

      EMPTY_CAPTURES       = [].freeze
      EMPTY_NAMED_CAPTURES = {}.freeze

      class Node
        EMPTY_STATIC = {}.freeze

        attr_reader :dynamic, :dynamic_index, :fast_static, :static, :static_depth, :stride, :tokens

        def initialize
          @static        = {}
          @dynamic       = []
          @dynamic_index = {}
          @tokens        = []
          @fast_static   = nil
          @static_depth  = 0
          @stride        = 1
        end

        def measure_static_depth
          @static_depth =
            if @dynamic.empty? && @tokens.empty? && !@static.empty?
              1 + @static.each_value.map(&:static_depth).min
            else
              0
            end
        end

        def optimize
          return if @static_depth <= 1

          @stride  = @static_depth
          frontier = [[nil, self]]
          @stride.times do
            next_frontier = []
            frontier.each do |prefix, node|
              if node.static.length == 1
                character, child = node.static.first
                prefix = prefix ? prefix << character : String.new(character)
                next_frontier << [prefix, child]
              else
                node.static.each do |character, child|
                  next_prefix = prefix ? prefix + character : String.new(character)
                  next_frontier << [next_prefix, child]
                end
              end
            end
            frontier = next_frontier
          end
          @fast_static = frontier.to_h { |prefix, node| [prefix.freeze, node] }.freeze
          @static = EMPTY_STATIC
        end

        def freeze
          @static.freeze
          @dynamic.each(&:freeze)
          @dynamic.freeze
          @dynamic_index = nil
          @tokens.freeze
          super
        end
      end
      private_constant :Node

      def initialize(entries, tokens)
        validate_array!(entries, "entries")
        validate_array!(tokens, "tokens")
        validate_tokens!(tokens)

        @tokens      = Array.new(tokens).freeze
        @root        = Node.new
        nodes        = [@root]
        static_edges = 0
        regexp_edges = 0

        Array.new(entries).each do |entry|
          validate_array!(entry, "entry")
          raise ArgumentError, "entry must contain parts and a token ID" unless entry.length == 2

          parts, token_id = entry
          validate_array!(parts, "parts")
          unless token_id.is_a?(Integer) && token_id >= 0 && token_id < @tokens.length
            raise ArgumentError, "token ID is out of range: #{token_id.inspect}"
          end

          node = @root
          Array.new(parts).each do |part|
            case part
            when String
              literal = String.new(part)
              validate_encoding!(literal, "edge")
              literal.each_char do |character|
                child = node.static[character]
                unless child
                  child = Node.new
                  node.static[character.freeze] = child
                  nodes << child
                  static_edges += 1
                end
                node = child
              end
            when Regexp
              key = regexp_key(part)
              child = node.dynamic_index[key]
              unless child
                child = Node.new
                node.dynamic << [anchor(part), child]
                node.dynamic_index[key] = child
                nodes << child
                regexp_edges += 1
              end
              node = child
            else
              raise TypeError, "edge must be a String or Regexp, got #{part.class}"
            end
          end
          node.tokens << token_id
        end

        nodes.reverse_each(&:measure_static_depth)
        frontier = [@root]
        until frontier.empty?
          node = frontier.pop
          node.optimize
          (node.fast_static || node.static).each_value { |child| frontier << child }
          node.dynamic.each { |edge| frontier << edge.last }
        end
        nodes.each(&:freeze)
        @stats = {
          nodes:               nodes.length,
          static_edges:,
          regexp_edges:,
          native_regexp_edges: 0,
          ruby_regexp_edges:   regexp_edges,
        }.freeze
        freeze
      end

      def match(input) = find(input, all: false, peek: false)
      def match_all(input) = find(input, all: true, peek: false)
      def peek(input) = find(input, all: false, peek: true)
      def peek_all(input) = find(input, all: true, peek: true)

      def each_match(input, &block)
        return enum_for(__method__, input) unless block

        each_result(input, peek: false, deduplicate: true, &block)
        self
      end

      def each_peek(input, &block)
        return enum_for(__method__, input) unless block

        each_result(input, peek: true, deduplicate: true, &block)
        self
      end

      private

      def anchor(regexp)
        compile_regexp("\\G(?:#{regexp.source})", regexp)
      rescue RegexpError
        compile_regexp("\\G(?:#{regexp.source}\n)", regexp)
      end

      def compile_regexp(source, regexp)
        if regexp.respond_to?(:timeout)
          Regexp.new(source, regexp.options, timeout: regexp.timeout).freeze
        else
          Regexp.new(source, regexp.options).freeze
        end
      end

      def regexp_key(regexp)
        timeout = regexp.timeout if regexp.respond_to?(:timeout)
        [regexp.source, regexp.options, regexp.encoding, timeout].freeze
      end

      def validate_array!(value, name)
        raise TypeError, "#{name} must be an Array" unless value.is_a?(Array)
      end

      def validate_tokens!(tokens)
        seen = {}.compare_by_identity
        tokens.each do |token|
          raise Ractor::IsolationError, "token is not Ractor-shareable" unless Ractor.shareable?(token)
          raise ArgumentError, "tokens must be unique by identity" if seen.key?(token)

          seen[token] = true
        end
      end

      def validate_encoding!(string, label)
        return if string.valid_encoding?

        raise ArgumentError, "#{label} has an invalid #{string.encoding} byte sequence"
      end

      def find(input, all:, peek:)
        results = [] if all
        each_result(input, peek:, deduplicate: all) do |token, captures, named, suffix|
          tuple = [token, captures, named, suffix]
          return tuple unless all

          results << tuple
        end
        all ? results : nil
      end

      def each_result(input, peek:, deduplicate:)
        raise TypeError, "input must be a String" unless input.is_a?(String)
        input = String.new(input)
        validate_encoding!(input, "input")

        input_length = input.length
        seen = {} if deduplicate
        stack = [[@root, 0, EMPTY_CAPTURES, EMPTY_NAMED_CAPTURES, 0, 0]]

        until stack.empty?
          node, position, captures, named, phase, index = stack.pop
          case phase
          when 0
            stack << [node, position, captures, named, 1, 0]
            if node.fast_static
              key = input[position, node.stride]
              if key && (child = node.fast_static[key])
                stack << [child, position + node.stride, captures, named, 0, 0]
              end
            elsif position < input_length && (child = node.static[input[position]])
              stack << [child, position + 1, captures, named, 0, 0]
            end
          when 1
            if index < node.dynamic.length
              regexp, child = node.dynamic[index]
              stack << [node, position, captures, named, 1, index + 1]
              if (matched = regexp.match(input, position))
                stack << [
                  child,
                  matched.end(0),
                  captures + matched.captures,
                  merge_named_captures(named, matched.named_captures),
                  0,
                  0
                ]
              end
            elsif (peek || position == input_length) && !node.tokens.empty?
              node.tokens.each do |token_id|
                next if deduplicate && seen.key?(token_id)

                seen[token_id] = true if deduplicate
                yield(
                  @tokens.fetch(token_id),
                  captures.map { |value| value&.dup },
                  copy_named_captures(named),
                  input[position..] || +""
                )
              end
            end
          end
        end
      end

      def merge_named_captures(base, additions)
        return base if additions.empty?

        merged = base.dup
        additions.each do |name, value|
          unless merged.key?(name)
            merged[name] = value
            next
          end

          previous = merged[name]
          merged[name] = previous.is_a?(Array) ? previous + [value] : [previous, value]
        end
        merged
      end

      def copy_named_captures(named)
        named.to_h do |name, value|
          copied = if value.is_a?(Array)
                     value.map { |element| element&.dup }
                   else
                     value&.dup
                   end
          [name.dup, copied]
        end
      end
    end
  end

  module Strict
    unless const_defined?(:Trie, false)
      # Portable implementation used on JRuby and TruffleRuby.
      class Trie < Internal::PortableTrie
        include Internal::Copyable
        include Shareable::Immutable
      end
    end
  end
end

require "farce/engine/shared/trie_builder"
