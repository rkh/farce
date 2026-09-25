# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"
require "farce/engine/shared/trie"

module Farce
  class TestPortableTrie < Test
    def test_all_lookup_modes_and_traversal_order
      trie = portable_trie([
                             [["/a"], :short],
                             [["/abc"], :long],
                             [["/", /(?<value>.+)/], :dynamic]
                           ])

      assert_equal [:long, [], {}, ""], trie.match("/abc")
      assert_equal [:dynamic, ["abcdef"], { "value" => "abcdef" }, ""], trie.match("/abcdef")
      assert_equal [:long, [], {}, "def"], trie.peek("/abcdef")
      assert_equal [
        [:long, [], {}, "def"],
        [:short, [], {}, "bcdef"],
        [:dynamic, ["abcdef"], { "value" => "abcdef" }, ""]
      ], trie.peek_all("/abcdef")
      assert_equal [], trie.match_all("missing")
    end

    def test_shared_regexp_prefix_keeps_static_descendant_precedence
      segment = %r{(?<segment>[^/]+)}
      trie = portable_trie([
                             [["/", segment, "/", %r{(?<tail>[^/]+)}], :generic],
                             [["/", segment, "/new"], :static]
                           ])

      assert_equal [:static, ["a"], { "segment" => "a" }, ""], trie.match("/a/new")
      assert_equal 2, trie.stats.fetch(:regexp_edges)
    end

    def test_capture_rollback_duplicate_names_and_result_isolation
      trie = portable_trie([
                             [["/", /(?<lost>\d+)/, "/wrong"], :wrong],
                             [["/", %r{(?<id>[^/]+)}, "/", /(?<id>\d+)/], :first],
                             [["/", %r{(?<id>[^/]+)}, "/", /(?<id>\d+)/], :second]
                           ])

      results = trie.match_all("/12/34")

      assert_equal [
        [:first, %w[12 34], { "id" => %w[12 34] }, ""],
        [:second, %w[12 34], { "id" => %w[12 34] }, ""]
      ], results
      results[0][1][0].replace("changed")
      results[0][2]["id"][0].replace("changed")
      results[0][3].replace("changed")

      assert_equal [:second, %w[12 34], { "id" => %w[12 34] }, ""], results[1]
      assert_equal [:first, %w[12 34], { "id" => %w[12 34] }, ""], trie.match("/12/34")
    end

    def test_streaming_traversal_is_lazy_and_matches_collected_results
      shared = Object.new.freeze
      trie = portable_trie([
                             [["/same"], shared],
                             [["/", /(?<id>same)/], shared],
                             [["/", /(?<id>.+)/], :dynamic]
                           ])

      exact = trie.each_match("/same")
      lazy_input = +"/same"
      lazy = trie.each_match(lazy_input)
      lazy_input.replace("missing")
      peek = []
      returned = trie.each_peek("/same/tail") do |token, captures, named, suffix|
        peek << [token, captures, named, suffix]
      end
      exact_results = exact.to_a

      assert_instance_of Enumerator, exact
      assert_empty lazy.to_a
      assert_same trie, returned
      assert_equal trie.match_all("/same"), exact_results
      assert_equal trie.peek_all("/same/tail"), peek
      assert_equal(1, exact_results.count { |token,| token.equal?(shared) })

      yielded = 0
      # rubocop:disable-next Lint/UnreachableLoop
      stopped = trie.each_match("/same") do
        yielded += 1
        break :stopped
      end

      assert_equal :stopped, stopped
      assert_equal 1, yielded
    end

    def test_zero_width_atomic_edges_and_regexp_context
      trie = portable_trie([
                             [[""], :empty],
                             [[/(?<empty>)/], :zero],
                             [["prefix", /(?<=prefix)(?<id>\d+)/], :lookbehind],
                             [[/a+/, "a"], :atomic],
                             [[/a\Kb/], :keep]
                           ])

      assert_equal [
        [:zero, [""], { "empty" => "" }, ""],
        [:empty, [], {}, ""]
      ], trie.match_all("")
      assert_equal [:lookbehind, ["12"], { "id" => "12" }, ""], trie.match("prefix12")
      assert_nil trie.match("aa")
      assert_equal [:keep, [], {}, ""], trie.match("ab")
    end

    def test_regexp_options_and_extended_trailing_comment
      trie = portable_trie([
                             [[/a|b/i], :options],
                             [[/(?x)# trailing comment/], :comment]
                           ])

      assert_equal [:options, [], {}, ""], trie.match("B")
      assert_equal [:comment, [], {}, "tail"], trie.peek("tail")
    end

    def test_literal_and_input_encodings
      binary = "\xFF".b
      utf8 = "é".encode(Encoding::UTF_8)
      trie = portable_trie([
                             [[binary], :binary],
                             [[utf8], :utf8],
                             [["plain".encode(Encoding::UTF_16LE)], :utf16]
                           ])

      assert_equal [:binary, [], {}, ""], trie.match(binary)
      assert_equal [:utf8, [], {}, ""], trie.match(utf8)
      assert_nil trie.match("plain")

      invalid = "\xFF".dup.force_encoding(Encoding::UTF_8)
      error = assert_raises(ArgumentError) { trie.match(invalid) }
      assert_match(/input has an invalid UTF-8 byte sequence/, error.message)
      assert_raises(ArgumentError) { portable_trie([[[invalid], :invalid]]) }
    end

    def test_constructor_validation_and_regexp_semantic_keys
      assert_raises(TypeError) { Internal::PortableTrie.new(nil, []) }
      assert_raises(TypeError) { Internal::PortableTrie.new([], nil) }
      assert_raises(ArgumentError) { Internal::PortableTrie.new([[[], 1]], [:only]) }
      assert_raises(TypeError) { Internal::PortableTrie.new([[[Object.new], 0]], [:token]) }
      assert_raises(ArgumentError) { Internal::PortableTrie.new([], %i[same same]) }

      return unless Regexp.method_defined?(:timeout)

      first = Regexp.new("a", timeout: 0.1)
      second = Regexp.new("a", timeout: 0.2)
      trie = portable_trie([[[first], :first], [[second], :second]])

      assert_equal 2, trie.stats.fetch(:regexp_edges)
    end

    def test_static_compression_prunes_covered_nodes
      literal = "segment" * 32
      trie = portable_trie([[[literal], :route]])
      root = trie.instance_variable_get(:@root)

      assert_equal literal.length, root.stride
      assert_empty root.static
      assert_equal [literal], root.fast_static.keys

      terminal = root.fast_static.fetch(literal)

      assert_nil terminal.fast_static
      assert_equal [0], terminal.tokens
      assert_equal [:route, [], {}, ""], trie.match(literal)
    end

    def test_deep_match_does_not_use_the_ruby_stack
      parts = Array.new(2_000) { /(?=a)/ }
      trie = portable_trie([[parts, :deep]])

      assert_equal [:deep, [], {}, "a"], trie.peek("a")
    end

    private

    def portable_trie(routes)
      tokens = []
      ids = {}.compare_by_identity
      entries = routes.map do |parts, token|
        ids[token] ||= tokens.length.tap { tokens << token }
        [parts, ids.fetch(token)]
      end
      Internal::PortableTrie.new(entries, tokens)
    end
  end
end
