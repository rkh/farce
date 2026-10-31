# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    class PortableTrie
      # @api private
      module IgnoreCase
        private

        def each_result(input, peek:, deduplicate:, &)
          raise TypeError, "input must be a String" unless input.is_a?(String)
          input = String.new(input)
          validate_encoding!(input, "input")

          input_length = input.length
          static_input = input.downcase
          if static_input.length != input_length
            return each_expanding_result(input, static_input, peek:, deduplicate:, &)
          end
          seen = {} if deduplicate
          stack = [[@root, 0, EMPTY_CAPTURES, EMPTY_NAMED_CAPTURES, 0, 0]]

          until stack.empty?
            node, position, captures, named, phase, index = stack.pop
            if phase.zero?
              child = nil
              stride = node.stride
              if node.fast_static
                key = static_input[position, stride]
                child = node.fast_static[key] if key
              elsif position < input_length && !node.static.empty?
                child = node.static[static_input[position]]
              end
              if child
                # Retain only frames with alternatives or a terminal result.
                stack << [node, position, captures, named, 1, 0] unless node.dynamic.empty? && node.tokens.empty?
                stack << [child, position + stride, captures, named, 0, 0]
                next
              end
            end
            if index < node.dynamic.length
              regexp, child = node.dynamic[index]
              if index + 1 < node.dynamic.length || !node.tokens.empty?
                stack << [node, position, captures, named, 1, index + 1]
              end
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

        def each_expanding_result(input, static_input, peek:, deduplicate:)
          to_original = [0]
          from_original = [0]
          input.each_char.with_index do |character, index|
            count = character.downcase.length
            # An internal lowercase boundary cannot start a regexp or end a result.
            (count - 1).times { to_original << nil }
            to_original << (index + 1)
            from_original << (to_original.length - 1)
          end
          input_length = static_input.length
          seen = {} if deduplicate
          stack = [[@root, 0, EMPTY_CAPTURES, EMPTY_NAMED_CAPTURES, 0, 0]]

          until stack.empty?
            node, position, captures, named, phase, index = stack.pop
            original_position = to_original[position]
            case phase
            when 0
              stack << [node, position, captures, named, 1, 0]
              if node.fast_static
                key = static_input[position, node.stride]
                if key && (child = node.fast_static[key])
                  stack << [child, position + node.stride, captures, named, 0, 0]
                end
              elsif position < input_length && (child = node.static[static_input[position]])
                stack << [child, position + 1, captures, named, 0, 0]
              end
            when 1
              if index < node.dynamic.length
                regexp, child = node.dynamic[index]
                stack << [node, position, captures, named, 1, index + 1]
                if original_position && (matched = regexp.match(input, original_position))
                  stack << [
                    child,
                    from_original[matched.end(0)],
                    captures + matched.captures,
                    merge_named_captures(named, matched.named_captures),
                    0,
                    0
                  ]
                end
              elsif original_position && (peek || position == input_length) && !node.tokens.empty?
                node.tokens.each do |token_id|
                  next if deduplicate && seen.key?(token_id)

                  seen[token_id] = true if deduplicate
                  yield(
                    @tokens.fetch(token_id),
                    captures.map { |value| value&.dup },
                    copy_named_captures(named),
                    input[original_position..] || +""
                  )
                end
              end
            end
          end
        end
      end
      private_constant :IgnoreCase
    end
  end
end
