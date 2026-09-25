# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestTrieDifferential < Test
    def test_generated_routes_against_whole_regexp_oracle
      random = Random.new(250925)
      bodies = [/(?<a>\d+)/, /(?<a>\w+)/, %r{(?<a>[^/]+)}, /(?<a>\p{L}+)/]
      entries = 80.times.flat_map do |i|
        prefix = "/r#{i}/"
        dynamic = bodies.each_with_index.map do |body, kind|
          [[prefix, body, "/", /(?<b>\d+)/, "/end"], (i * 5) + kind]
        end
        dynamic << [["#{prefix}new/42/end"], (i * 5) + 4]
      end.shuffle(random: random)
      tree = Strict::Trie.build { |builder| entries.each { |parts, token| builder.add(parts, token) } }
      oracles = entries.map do |parts, token|
        source = parts.map { |part| part.is_a?(String) ? Regexp.escape(part) : part.to_s }.join
        [token, Regexp.new("\\A(?:#{source})\\z"), Regexp.new("\\A(?:#{source})")]
      end
      queries = 100.times.flat_map do
        id = random.rand(85)
        value = ["123", "new", "word_42", "日本", "", "x-y"].sample(random: random)
        ["/r#{id}/#{value}/42/end", "/r#{id}/#{value}/42/end/tail", "/r#{id}/#{value}/bad/end"]
      end
      queries.each do |input|
        [false, true].each do |peek|
          expected = oracles.filter_map do |token, exact_regexp, prefix_regexp|
            matched = (peek ? prefix_regexp : exact_regexp).match(input)
            [token, matched.captures, matched.named_captures, matched.post_match] if matched
          end.sort_by(&:first)
          all = peek ? tree.peek_all(input) : tree.match_all(input)

          assert_equal expected, all.sort_by(&:first), "seed=250925 peek=#{peek} input=#{input.inspect}"
          single = peek ? tree.peek(input) : tree.match(input)
          if all.empty?
            assert_nil single
          else
            assert_equal all.first, single
          end
        end
      end
    end

    def test_static_descendant_precedence_after_shared_dynamic_prefix
      prefix = %r{(?<id>[^/]+)}
      tree = Strict::Trie.build do |builder|
        builder.add(["/", prefix, "/", %r{(?<action>[^/]+)}], :dynamic)
        builder.add(["/", prefix, "/new"], :static)
      end

      assert_equal %i[static dynamic], tree.match_all("/users/new").map(&:first)
      assert_equal :static, tree.match("/users/new").first
    end

    def test_repeated_names_accumulate_and_results_do_not_alias_across_calls
      tree = Strict::Trie.build do |builder|
        builder.add([/(?<id>\d+)/, "-", /(?<id>\w+)/], :route)
      end
      first = tree.match("12-word")

      assert_equal [:route, %w[12 word], { "id" => %w[12 word] }, ""], first
      first[1][0].replace("changed")
      first[2]["id"] << "extra"
      first[3] << "suffix"

      assert_equal [:route, %w[12 word], { "id" => %w[12 word] }, ""], tree.match("12-word")
    end

    def test_specialization_matches_original_regexp_for_escape_and_name_boundaries
      expressions = [
        /(?<id>\d+)(?:\n|-)(?<slug>\w+)/,
        /(?<id>\d+)\t(?<slug>\w+)/,
        /(?<id>\d+)(?:\D|_)(?<slug>\w+)/,
        /(?<id>\d+)(?:\x2D|_)(?<slug>\w+)/,
        /(?<id>\d+)-(?<id>\w+)/,
        /(?<id>\d+)(?:-|--)(?<slug>\w+)/,
        %r{(?<id>[^/]+)-(?<slug>\w+)}
      ]
      expressions << Regexp.new("(?<id>abc)", Regexp::IGNORECASE, timeout: 1) if /a/.respond_to?(:timeout)
      inputs = ["12-word", "12--word", "12nword", "12\nword", "12tword", "12\tword", "12Dword", "12/word", "12_word",
                "ABC", "12-word/tail"]
      expressions.each do |regexp|
        tree = Strict::Trie.build { |builder| builder.add([regexp], :route) }
        inputs.each do |input|
          matched = regexp.match(input)
          matched = nil if matched && matched.begin(0) != 0
          prefix = [:route, matched.captures, matched.named_captures, matched.post_match] if matched
          exact = prefix if matched && matched.end(0) == input.length
          if prefix
            assert_equal prefix, tree.peek(input), "#{regexp.inspect} #{input.inspect}"
          else
            assert_nil tree.peek(input), "#{regexp.inspect} #{input.inspect}"
          end
          if exact
            assert_equal exact, tree.match(input), "#{regexp.inspect} #{input.inspect}"
          else
            assert_nil tree.match(input), "#{regexp.inspect} #{input.inspect}"
          end
          nil
        end
      end
    end

    def test_anchored_fallback_preserves_options_context_and_reset_match_start
      cases = [
        [["a", /(?<=a)(?<b>b)/], "ab", [:lookbehind, ["b"], { "b" => "b" }, ""]],
        [[/a\K(?<b>b)/], "ab", [:reset, ["b"], { "b" => "b" }, ""]],
        [[Regexp.new("(?<b>b) # trailing", Regexp::EXTENDED)], "b", [:extended, ["b"], { "b" => "b" }, ""]],
        [[Regexp.new("(?<b>b)(?x)# trailing")], "b", [:inline, ["b"], { "b" => "b" }, ""]]
      ]
      cases.each do |parts, input, expected|
        tree = Strict::Trie.build { |builder| builder.add(parts, expected.first) }

        assert_equal expected, tree.match(input), parts.inspect
        assert_nil tree.match("x#{input}"), parts.inspect
      end
    end
  end
end
