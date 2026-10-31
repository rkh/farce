# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/engine/shared/trie"

module Farce
  class TestTrieIgnoreCase < Test
    def test_builder_option_applies_to_every_static_segment
      builder = Strict::Trie::Builder.new(ignore_case: true)
      builder.add(["/Projects/", /(?<account>[A-Z][a-z]+)/, "/Items/", /(?<record>[A-Z][a-z]+)/], :record)
      builder.add(["/Health"], :health)
      trie = builder.build

      assert_equal [:record, %w[Alice Record], { "account" => "Alice", "record" => "Record" }, ""],
        trie.match("/PROJECTS/Alice/items/Record")
      assert_equal [:health, [], {}, ""], trie.match("/HEALTH")
      assert_nil trie.match("/projects/alice/items/Record")
    end

    def test_class_build_option_and_case_sensitive_default
      insensitive = Strict::Trie.build(ignore_case: true) { |builder| builder.add(["/Health"], :health) }
      sensitive = Strict::Trie.build { |builder| builder.add(["/Health"], :health) }
      disabled = Strict::Trie.build(ignore_case: false) { |builder| builder.add(["/Health"], :health) }

      assert_equal [:health, [], {}, ""], insensitive.match("/HEALTH")
      [sensitive, disabled].each do |trie|
        assert_nil trie.match("/HEALTH")
        assert_equal [:health, [], {}, ""], trie.match("/Health")
      end
    end

    def test_builder_snapshots_and_copies_preserve_the_option
      literal = +"/First"
      builder = Strict::Trie::Builder.new(ignore_case: true)
      builder.add([literal], :first)
      first = builder.build
      literal.replace("/changed")
      builder.add(["/Second"], :second)
      copy = builder.dup
      copy.add(["/Third"], :third)

      assert_equal [:first, [], {}, ""], first.match("/FIRST")
      assert_nil first.match("/SECOND")
      assert_equal [:second, [], {}, ""], builder.build.match("/SECOND")
      assert_nil builder.build.match("/THIRD")
      assert_equal [:third, [], {}, ""], copy.build.match("/THIRD")
    end

    def test_marshal_preserves_builder_option_tokens_and_frozen_state
      [false, true].each do |ignore_case|
        token = Ractor.make_shareable([:route])
        builder = Strict::Trie::Builder.new(ignore_case:)
        builder.add(["/Route"], token).add(["/Alias"], token)
        restored, restored_token = Marshal.load(Marshal.dump([builder.freeze, token]))
        trie = restored.build

        assert_predicate restored, :frozen?
        assert_same restored_token, trie.match("/Route").first
        assert_same restored_token, trie.match("/Alias").first
        assert_equal ignore_case, !trie.match("/ROUTE").nil?
        assert_raises(TypeError) { Marshal.dump(trie) }
      end
    end

    def test_old_builder_marshal_payload_remains_case_sensitive
      builder = Strict::Trie::Builder.allocate
      entries = [[["/Route"], Internal::MarshalSupport.value(:route)]]
      builder.marshal_load([1, entries, false])

      assert_equal [:route, [], {}, ""], builder.build.match("/Route")
      assert_nil builder.build.match("/ROUTE")
    end

    def test_captures_suffixes_and_regexp_context_retain_input_case
      each_trie([["/abc/", %r{(?<=ABC/)(?<value>[A-Z][a-z]+)}]]) do |trie|
        expected = [0, ["Mixed"], { "value" => "Mixed" }, "/TaIl"]

        assert_equal expected, trie.peek("/ABC/Mixed/TaIl")
        assert_equal [expected], trie.peek_all("/ABC/Mixed/TaIl")
        assert_equal [expected], trie.each_peek("/ABC/Mixed/TaIl").to_a
        assert_nil trie.match("/abc/Mixed")
        assert_nil trie.match("/ABC/mixed")
      end
      each_trie([["/prefix/", /(?<value>mixed)/i]]) do |trie|
        assert_equal [0, ["MiXeD"], { "value" => "MiXeD" }, ""], trie.match("/PREFIX/MiXeD")
      end
    end

    def test_case_collisions_static_precedence_and_token_deduplication
      trie = Strict::Trie.build(ignore_case: true) do |builder|
        builder.add(["/", /(?<value>.+)/], :dynamic)
        builder.add(["/Foo"], :first)
        builder.add(["/foo"], :second)
        builder.add(["/FOO"], :first)
      end

      assert_equal %i[first second dynamic], trie.match_all("/fOo").map(&:first)
      assert_equal [:first, [], {}, ""], trie.match("/fOo")
      assert_equal trie.match_all("/fOo"), trie.each_match("/fOo").to_a
    end

    def test_unicode_lowercase_mapping_and_original_positions
      [%w[Ä ä], %w[K k], %W[İ i\u0307], %w[Σ σ], %w[ẞ ß]].each do |upper, lower|
        each_trie([["/#{upper}/", /(?<value>.+)/], ["/#{upper}x/"]]) do |trie|
          [upper, lower].each do |input|
            assert_equal [0, ["MiXeD"], { "value" => "MiXeD" }, ""], trie.match("/#{input}/MiXeD")
          end
        end
      end
    end

    def test_static_and_regexp_alternatives_retain_prefix_results
      each_trie([["/"], ["/Foo"], ["/foo/bar"], ["/FOO/", /(?<tail>.+)/]]) do |trie|
        assert_equal [2, 3, 1, 0], trie.peek_all("/FOO/bar/BaZ").map(&:first)
        assert_equal [3, ["bar/BaZ"], { "tail" => "bar/BaZ" }, ""], trie.match("/FOO/bar/BaZ")
      end
      each_trie([["/root/", /(?<value>[A-Z]+)/, "/end"],
                 ["/ROOT/", /(?<value>[A-Za-z]+)/, "/END"]]) do |trie|
        assert_equal [1, ["Ab"], { "value" => "Ab" }, ""], trie.match("/ROOT/Ab/END")
      end
    end

    def test_lowercasing_does_not_use_regexp_case_folding
      each_trie([["/ss/"], ["/s/"], ["/σ/"], ["/ffi/"]]) do |trie|
        %w[/ß/ /ſ/ /ς/ /ﬃ/].each { |input| assert_nil trie.match(input) }
        assert_equal [0, [], {}, ""], trie.match("/SS/")
      end
    end

    def test_expanding_characters_in_dynamic_segments_preserve_later_offsets
      each_trie([["/start/", %r{(?<first>[^/]+)}, "/İ/", %r{(?<second>[^/]+)}]]) do |trie|
        expected = [0, %w[İ MiXeD], { "first" => "İ", "second" => "MiXeD" }, "/TaIl"]

        assert_equal expected, trie.peek("/START/İ/İ/MiXeD/TaIl")
        assert_equal expected, trie.peek("/START/İ/i\u0307/MiXeD/TaIl")
        assert_equal [expected], trie.each_peek("/START/İ/İ/MiXeD/TaIl").to_a
      end
    end

    def test_lowercase_expansion_across_static_branches
      each_trie([["/i"], ["/i\u0307/", /(?<value>.+)/], ["/ix/"], ["/i", /(?<value>.+)/]]) do |trie|
        expected = [1, ["MiXeD"], { "value" => "MiXeD" }, ""]

        assert_nil trie.match("/İ")
        assert_equal expected, trie.match("/İ/MiXeD")
        assert_equal [expected], trie.peek_all("/İ/MiXeD")
      end
    end

    def test_indexed_branches_use_case_insensitive_keys
      literals = 100.times.map { |i| format("/%<letter>s%<id>02d/Thing/", letter: (65 + (i % 26)).chr, id: i) }
      each_trie(literals.map { |literal| [literal] }) do |trie|
        literals.each_with_index do |literal, id|
          [literal.upcase, literal.downcase, literal.swapcase].each do |input|
            assert_equal [id, [], {}, ""], trie.match(input)
          end
        end
      end
    end

    def test_encoding_validation_and_long_static_edges
      %w[UTF-8 US-ASCII ASCII-8BIT ISO-8859-1 UTF-16LE UTF-32LE].each do |encoding|
        literal = "/AbCd/".encode(encoding)

        each_trie([[literal]]) { |trie| assert_equal 0, trie.match(literal.upcase)&.first, encoding }
      end
      each_trie([["/#{"AbCd" * 5000}"]]) do |trie|
        assert_equal 0, trie.match("/#{"ABCD" * 5000}")&.first
        assert_raises(ArgumentError) { trie.match("\xff".dup.force_encoding("UTF-8")) }
        assert_raises(TypeError) { trie.match(Object.new) }
      end
    end

    def test_generated_unicode_literals_against_downcase_oracle
      random = Random.new(301026)
      alphabet = %w[A Z a z Ä ä é É Σ σ ς ẞ ß İ i K k ﬃ F f / 1]
      literals = 100.times.map { Array.new(8) { alphabet.sample(random:) }.join }.uniq(&:downcase)
      each_trie(literals.map { |literal| [literal] }) do |trie|
        literals.each do |literal|
          [literal, literal.downcase, literal.upcase, literal.swapcase].each do |input|
            token = literals.index { |entry| entry.downcase == input.downcase }
            actual = trie.match(input)
            if token
              assert_equal [token, [], {}, ""], actual, "seed=301026 input=#{input.inspect}"
            else
              assert_nil actual, "seed=301026 input=#{input.inspect}"
            end
          end
        end
      end
    end

    def test_trie_copies_remain_frozen_shareable_and_case_insensitive
      trie = Strict::Trie.build(ignore_case: true) { |builder| builder.add(["/Copy"], :copy) }
      [trie.dup, trie.clone, trie.clone(freeze: false)].each do |copy|
        assert_instance_of Strict::Trie, copy
        assert_predicate copy, :frozen?
        assert Ractor.shareable?(copy)
        assert_equal [:copy, [], {}, ""], copy.match("/COPY")
      end
    end

    def test_streaming_uses_a_stable_input_snapshot_and_can_stop_early
      trie = Strict::Trie.build(ignore_case: true) do |builder|
        builder.add(["/Route/", /(?<value>.+)/], :first)
        builder.add(["/route/", /(?<value>.+)/], :second)
      end
      input = +"/ROUTE/MiXeD"
      results = []
      trie.each_match(input) do |token, captures, named, suffix|
        input.replace("changed")
        results << [token, captures, named, suffix]
      end
      expected = [:first, ["MiXeD"], { "value" => "MiXeD" }, ""]

      assert_equal [expected, [:second, *expected.drop(1)]], results
      # rubocop:disable-next Lint/UnreachableLoop -- Verify a caller can stop streaming early.
      assert_equal :stopped, trie.each_match("/ROUTE/MiXeD") { break :stopped }
    end

    def test_deep_graph_and_capture_spills_preserve_case
      parts = Array.new(100) { ["/Step/", /(?<value>[A-Z][a-z]+)/] }.flatten
      trie = Strict::Trie.build(ignore_case: true) { |builder| builder.add(parts, :deep) }
      input = "/STEP/Mixed" * 100

      assert_equal [:deep, Array.new(100, "Mixed"), { "value" => Array.new(100, "Mixed") }, ""], trie.match(input)
      GC.compact if GC.respond_to?(:compact)

      assert_equal :deep, trie.dup.match(input).first
    end

    def test_native_ractor_lookup
      skip "native Ractors are unavailable" unless Internal.native_ractors?

      trie = Strict::Trie.build(ignore_case: true) { |builder| builder.add(["/Route/", /(?<value>.+)/], :route) }
      worker = Ractor.new(trie) { it.match("/ROUTE/MiXeD") }
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal [:route, ["MiXeD"], { "value" => "MiXeD" }, ""], result
    end

    private

    def each_trie(entries)
      trie = Strict::Trie.build(ignore_case: true) do |builder|
        entries.each_with_index { |parts, token| builder.add(parts, token) }
      end
      yield trie
      return unless Internal.native_ractors?

      rows = entries.map.with_index { |parts, token| [parts, token] }
      yield Internal::PortableTrie.new(rows, (0...entries.length).to_a, ignore_case: true)
    end
  end
end
