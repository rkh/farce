# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "English"

module Farce
  class TestTrieNative < Test
    def setup
      skip "CRuby native trie only" unless RUBY_ENGINE == "ruby"
    end

    def test_native_programs_are_shared_within_graph
      first = /(?<id>\d+)/
      second = Regexp.new(first.source)
      trie = Strict::Trie.build do |builder|
        builder.add(["/first/", first], :first)
        builder.add(["/second/", second], :second)
      end

      assert_equal [:first, ["12"], { "id" => "12" }, ""], trie.match("/first/12")
      assert_equal [:second, ["34"], { "id" => "34" }, ""], trie.match("/second/34")
      assert_equal 2, trie.stats.fetch(:dynamic_edges)
      assert_equal 1, trie.stats.fetch(:native_programs)
      assert_operator trie.stats.fetch(:native_bytes), :>, 0
      assert_equal Encoding::US_ASCII, trie.match("/first/12").fetch(2).keys.first.encoding
    end

    def test_changed_global_regexp_timeout_disables_native_program
      skip "Regexp.timeout is unavailable" unless Regexp.respond_to?(:timeout=) && defined?(Regexp::TimeoutError)

      previous_timeout = Regexp.timeout
      begin
        Regexp.timeout = nil
        trie = Strict::Trie.build { it.add([%r{(?<segment>[^/]+)\z}], :segment) }

        assert_equal 1, trie.stats.fetch(:native_programs)

        Regexp.timeout = 0.000001
        input = (("x" * 2_000_000) << "/").freeze

        assert_raises(Regexp::TimeoutError) { trie.match(input) }
      ensure
        Regexp.timeout = previous_timeout
      end
    end

    def test_native_negated_delimiter_classes_accept_equivalent_escapes
      path_sources = [
        '(?:\G(?<id>[^/?#]+))\z',
        '(?:\G(?<id>[^/\?#]+))\z',
        '(?:\G(?<id>[^\/\?\#]+))\z',
        '(?:\G(?<id>[^#?\/]+))\z'
      ]
      slash_sources = ['(?:\G(?<id>[^/]+))\z', '(?:\G(?<id>[^\/]+))\z']
      trie = Strict::Trie.build do |builder|
        path_sources.each_with_index do |source, index|
          builder.add(["/path/#{index}/", Regexp.new(source)], [:path, index].freeze)
        end
        slash_sources.each_with_index do |source, index|
          builder.add(["/slash/#{index}/", Regexp.new(source)], [:slash, index].freeze)
        end
      end

      assert_equal path_sources.length + slash_sources.length, trie.stats.fetch(:native_programs)
      path_sources.each_index do |index|
        token = [:path, index]

        assert_equal [token, ["123"], { "id" => "123" }, ""], trie.match("/path/#{index}/123")
        assert_equal [token, ["日本"], { "id" => "日本" }, ""], trie.match("/path/#{index}/日本")
        assert_nil trie.match("/path/#{index}/a/b")
        assert_nil trie.match("/path/#{index}/a?b")
        assert_nil trie.match("/path/#{index}/a#b")
      end
      slash_sources.each_index do |index|
        token = [:slash, index]

        assert_equal [token, ["a?#"], { "id" => "a?#" }, ""], trie.match("/slash/#{index}/a?#")
        assert_nil trie.match("/slash/#{index}/a/b")
      end

      fallback = without_warnings do
        Strict::Trie.build do |builder|
          builder.add([Regexp.new("(?<id>[^/?]+)")], :missing_delimiter)
          builder.add([Regexp.new("(?<id>[^//]+)")], :duplicate_delimiter)
          builder.add([Regexp.new("(?<id>[^/a-z]+)")], :range)
        end
      end

      assert_equal 0, fallback.stats.fetch(:native_programs)
      assert_equal [:missing_delimiter, ["abc#"], { "id" => "abc#" }, ""], fallback.match("abc#")
      assert_equal [:duplicate_delimiter, ["abc"], { "id" => "abc" }, ""], fallback.match_all("abc").last
      assert_equal [:range, ["123"], { "id" => "123" }, ""], fallback.match_all("123").last
    end

    def test_static_index_preserves_same_byte_encoding_alternatives
      latin = "\xC3".b.force_encoding(Encoding::ISO_8859_1)
      utf8 = "\xC3\xA9".b.force_encoding(Encoding::UTF_8)

      [[[latin, :latin], [utf8, :utf8]], [[utf8, :utf8], [latin, :latin]]].each do |alternatives|
        trie = Strict::Trie.build do |builder|
          alternatives.each { |literal, token| builder.add([literal], token) }
          %w[a b c d e f].each { |literal| builder.add([literal], literal.to_sym) }
        end

        assert_equal 1, trie.stats.fetch(:static_index_nodes)
        assert_equal 4 + ((0xC3 - "a".ord + 1) * 4), trie.stats.fetch(:static_index_bytes)
        assert_equal [:latin, [], {}, ""], trie.match(latin)
        assert_equal [:utf8, [], {}, ""], trie.match(utf8)
        assert_nil trie.match("z")
      end
    end

    def test_compact_static_index_grows_around_existing_range
      trie = Strict::Trie.build do |builder|
        ("a".."h").each { |literal| builder.add([literal], literal.to_sym) }
        builder.add(["z"], :last)
        builder.add(["0"], :first)
      end

      assert_equal 1, trie.stats.fetch(:static_index_nodes)
      assert_equal 4 + (("z".ord - "0".ord + 1) * 4), trie.stats.fetch(:static_index_bytes)
      assert_equal [:a, [], {}, ""], trie.match("a")
      assert_equal [:last, [], {}, ""], trie.match("z")
      assert_equal [:first, [], {}, ""], trie.match("0")
      assert_nil trie.match("/")

      binary = Strict::Trie.build do |builder|
        256.times { |byte| builder.add([byte.chr(Encoding::BINARY)], byte) }
      end

      assert_equal 1, binary.stats.fetch(:static_index_nodes)
      assert_equal 4 + (256 * 4), binary.stats.fetch(:static_index_bytes)
      assert_equal [0, [], {}, ""], binary.match("\x00".b)
      assert_equal [255, [], {}, ""], binary.match("\xFF".b)
    end

    def test_streamed_matches_preserve_order_identity_dedup_and_fresh_fields
      repeated = Object.new.freeze
      trie = Strict::Trie.build do |builder|
        builder.add([/(?<id>\d+)/], nil)
        builder.add([/(?<id>\d+)/], false)
        builder.add([/(?<id>\d+)/], repeated)
        builder.add([/(?<id>\d+)/], repeated)
      end
      expected = trie.match_all("12")
      enumerator = trie.each_match("12")

      assert_instance_of Enumerator, enumerator
      assert_equal expected, enumerator.to_a
      assert_equal [nil, false, repeated], expected.map(&:first)

      streamed = []
      returned = trie.each_match("12") do |token, captures, named, suffix|
        streamed << [token, captures, named, suffix]
        next unless streamed.one?

        captures.first.replace("changed")
        suffix << "changed"
      end

      assert_same trie, returned
      assert_equal [false, ["12"], { "id" => "12" }, ""], streamed.fetch(1)
      assert_equal [repeated, ["12"], { "id" => "12" }, ""], streamed.fetch(2)
      refute_same streamed.fetch(0).fetch(1), streamed.fetch(1).fetch(1)
      refute_same streamed.fetch(0).fetch(2), streamed.fetch(1).fetch(2)

      yielded = false

      assert_same trie, trie.each_match("missing") { yielded = true }
      refute yielded
      assert_empty trie.each_match("missing").to_a
    end

    def test_streamed_peek_supports_early_exit_reentrancy_and_stable_input
      trie = Strict::Trie.build do |builder|
        builder.add([/(?<id>\p{L}+)/], :first)
        builder.add([/(?<id>\p{L}+)/], :second)
      end
      input = +"alpha-tail"
      /seed/ =~ "seed"
      previous_backref = $LAST_MATCH_INFO
      nested = nil
      streamed = []

      returned = trie.each_peek(input) do |token, captures, named, suffix|
        streamed << [token, captures, named, suffix]
        next unless streamed.one?

        input.replace("mutated")
        GC.start
        GC.compact if GC.respond_to?(:compact)
        nested = trie.peek("beta-rest")
        /callback/ =~ "callback"
      end

      assert_same trie, returned
      assert_equal [
        [:first, ["alpha"], { "id" => "alpha" }, "-tail"],
        [:second, ["alpha"], { "id" => "alpha" }, "-tail"]
      ], streamed
      assert_equal [:first, ["beta"], { "id" => "beta" }, "-rest"], nested
      assert_same previous_backref, $LAST_MATCH_INFO

      count = 0
      stream_method = :each_peek
      stopped = trie.public_send(stream_method, "alpha-tail") do
        count += 1
        break :stopped
      end

      assert_equal :stopped, stopped
      assert_equal 1, count
      assert_same previous_backref, $LAST_MATCH_INFO

      error = assert_raises(RuntimeError) do
        trie.public_send(stream_method, "alpha-tail") { raise "stream stopped" }
      end
      assert_equal "stream stopped", error.message
      assert_same previous_backref, $LAST_MATCH_INFO
      assert_equal [:first, ["gamma"], { "id" => "gamma" }, "-rest"], trie.peek("gamma-rest")
    end

    def test_streamed_callback_compaction_with_heap_capture_events
      capture_count = 48
      parts = capture_count.times.flat_map do |index|
        capture = Regexp.new("(?<capture#{index}>\\d+)")
        index.zero? ? [capture] : ["-", capture]
      end
      input = Array.new(capture_count, "1").join("-").freeze
      trie = Strict::Trie.build do |builder|
        builder.add(parts, :first)
        builder.add(parts, :second)
      end
      streamed = []

      trie.each_match(input) do |token, captures, named, suffix|
        streamed << [token, captures, named, suffix]
        next unless streamed.one?

        GC.start
        GC.compact if GC.respond_to?(:compact)
      end

      assert_equal capture_count, trie.stats.fetch(:native_programs)
      assert_equal %i[first second], streamed.map(&:first)
      assert_equal Array.new(capture_count, "1"), streamed.last.fetch(1)
      assert_equal "1", streamed.last.fetch(2).fetch("capture47")
      assert_equal "", streamed.last.fetch(3)
    end

    def test_unsafe_escape_and_duplicate_name_programs_fall_back
      trie = Strict::Trie.build do |builder|
        builder.add([/(?<id>\d+)(?:\n|-)(?<slug>\w+)/], :escape)
        builder.add([/(?<id>\d+)-(?<id>\w+)/], :duplicate)
      end

      assert_equal 0, trie.stats.fetch(:native_programs)
      assert_equal [:escape, %w[12 word], { "id" => "12", "slug" => "word" }, ""], trie.match("12-word")
      assert_equal [:escape, %w[12 word], { "id" => "12", "slug" => "word" }, ""], trie.match("12\nword")
      assert_equal [:duplicate, %w[12 word], { "id" => "word" }, ""], trie.match_all("12-word").last
    end

    def test_internal_constructor_defensively_validates_shape_and_ids
      constructor = ->(entries, tokens) { Strict::Trie.send(:new, entries, tokens) }

      assert_raises(TypeError) { constructor.call(nil, []) }
      assert_raises(TypeError) { constructor.call([], nil) }
      assert_raises(ArgumentError) { constructor.call([[[], 0, :extra]], [:token]) }
      assert_raises(TypeError) { constructor.call([[:not_parts, 0]], [:token]) }
      assert_raises(TypeError) { constructor.call([[[Object.new], 0]], [:token]) }
      assert_raises(TypeError) { constructor.call([[[], :zero]], [:token]) }
      assert_raises(ArgumentError) { constructor.call([[[], 1]], [:token]) }

      token = Object.new.freeze
      assert_raises(ArgumentError) { constructor.call([], [token, token]) }

      mutable_token = +"mutable"
      assert_raises(Ractor::IsolationError) { constructor.call([[[], 0]], [mutable_token]) }
      refute_predicate mutable_token, :frozen?

      uninitialized = Strict::Trie.allocate
      assert_raises(TypeError) { uninitialized.dup }
    end

    def test_deep_static_graph_does_not_use_the_c_stack
      depth = 12_000
      parts = Array.new(depth, "x")
      input = "x" * depth
      trie = Strict::Trie.build { it.add(parts, :deep) }

      assert_equal [:deep, [], {}, ""], trie.match(input.freeze)
      assert_operator trie.stats.fetch(:nodes), :>=, depth
      assert_nil trie.match("#{input}y".freeze)
    end

    def test_deferred_native_captures_grow_safely
      depth = 256
      parts = Array.new(depth) { /(?<id>\d+)/ }.flat_map.with_index { |part, index| index.zero? ? [part] : ["-", part] }
      input = Array.new(depth, "1").join("-")
      trie = Strict::Trie.build { it.add(parts, :deep) }
      result = trie.match(input.freeze)

      assert_equal :deep, result.fetch(0)
      assert_equal Array.new(depth, "1"), result.fetch(1)
      assert_equal Array.new(depth, "1"), result.fetch(2).fetch("id")
    end

    def test_gc_stress_compaction_and_copy_lifetime
      previous = GC.stress
      begin
        GC.stress = true
        copy = Strict::Trie.build do |builder|
          40.times do |index|
            builder.add(["/route/#{index}/", /(?<id>\d+)/, "/end"], index)
          end
        end.dup
      ensure
        GC.stress = previous
      end

      GC.start
      GC.compact if GC.respond_to?(:compact)

      assert_equal [17, ["42"], { "id" => "42" }, ""], copy.match("/route/17/42/end")
      assert_predicate copy, :frozen?
      assert Ractor.shareable?(copy)
    end

    def test_fallback_lookup_from_ractor
      trie = Strict::Trie.build do |builder|
        builder.add(["prefix", /(?<=prefix)(?<id>\p{L}+)/], :fallback)
      end
      worker = Ractor.new(trie) { it.match("prefix日本") }
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal [:fallback, ["日本"], { "id" => "日本" }, ""], result
    end

    def test_native_allocation_failure_cleanup
      return unless native_test_hook?(:__native_failure_after=)

      begin
        entries = ("a".."h").each_with_index.map { |literal, id| [[literal], id] }
        entries.push(
          [["z"], 8],
          [["0"], 9],
          [["/first/", /(?<id>\d+)-(?<slug>\w+)/], 10],
          [["/second/", %r{(?<value>[^/?#]+)}], 11],
          [["/fallback/", /(?<word>\p{L}+)/], 12],
        ).freeze
        tokens = %i[a b c d e f g h z zero first second fallback].freeze
        built = nil
        256.times do |count|
          Strict::Trie.send(:__native_failure_after=, count)
          begin
            built = Strict::Trie.send(:new, entries, tokens)
          rescue NoMemoryError
            # Every partially initialized owner must remain safe to collect.
          ensure
            Strict::Trie.send(:__native_failure_after=, nil)
          end
          GC.start
          control = Strict::Trie.build { it.add(["/control"], :control) }

          assert_equal [:control, [], {}, ""], control.match("/control")

          break if built
        end

        refute_nil built
        assert_equal [:first, %w[12 word], { "id" => "12", "slug" => "word" }, ""],
          built.match("/first/12-word")

        parts = Array.new(80) { /(?<id>\d+)/ }.flat_map.with_index do |part, index|
          index.zero? ? [part] : ["-", part]
        end
        matcher = Strict::Trie.build do |builder|
          40.times { |token| builder.add(parts, token) }
        end
        input = Array.new(80, "1").join("-").freeze

        assert_equal 0, native_search_scratch_count
        abandon_native_enumerator(matcher, input)
        GC.start
        GC.compact if GC.respond_to?(:compact)

        assert_equal 0, native_search_scratch_count

        abandon_native_fiber(matcher, input)
        GC.start
        GC.compact if GC.respond_to?(:compact)

        assert_equal 0, native_search_scratch_count

        completed = false
        32.times do |count|
          Strict::Trie.send(:__native_failure_after=, count)
          begin
            results = matcher.match_all(input)

            assert_equal 40, results.length

            completed = true
          rescue NoMemoryError
            # rb_ensure must release any grown frame, event, or seen buffer.
          ensure
            Strict::Trie.send(:__native_failure_after=, nil)
          end

          assert_equal 0, matcher.match(input).first
          assert_equal 0, native_search_scratch_count

          break if completed
        end

        assert completed

        completed = false
        32.times do |count|
          Strict::Trie.send(:__native_failure_after=, count)
          begin
            tokens = []
            matcher.each_match(input) { |token,| tokens << token }

            assert_equal (0...40).to_a, tokens

            completed = true
          rescue NoMemoryError
            # Streaming owns the same grown frame, event, and seen buffers.
          ensure
            Strict::Trie.send(:__native_failure_after=, nil)
          end

          assert_equal 0, matcher.match(input).first
          assert_equal 0, native_search_scratch_count

          break if completed
        end

        assert completed
      ensure
        Strict::Trie.send(:__native_failure_after=, nil)
      end
    end

    def test_interrupted_native_construction_and_lookup_cleanup
      return unless native_test_hook?(:__native_interrupt_queue=)

      begin
        ready = Queue.new
        release = Queue.new
        parts = Array.new(100_000, "").freeze
        worker = Thread.new do
          Strict::Trie.send(:__native_interrupt_queue=, [ready, release])
          begin
            Strict::Trie.send(:new, [[parts, 0]], [:large])
            :completed
          rescue RuntimeError => e
            e.message
          ensure
            Strict::Trie.send(:__native_interrupt_queue=, nil)
          end
        end
        ready.pop
        worker.raise(RuntimeError, "construction interrupted")

        assert_equal "construction interrupted", worker.value

        matcher = Strict::Trie.build { it.add([/(?<id>\d+)/], :large) }
        input = ("1" * 2_000_000).freeze
        ready = Queue.new
        release = Queue.new
        worker = Thread.new do
          Strict::Trie.send(:__native_interrupt_queue=, [ready, release])
          begin
            matcher.match(input)
            :completed
          rescue RuntimeError => e
            e.message
          ensure
            Strict::Trie.send(:__native_interrupt_queue=, nil)
          end
        end
        ready.pop
        worker.raise(RuntimeError, "lookup interrupted")

        assert_equal "lookup interrupted", worker.value
        assert_equal [:large, ["42"], { "id" => "42" }, ""], matcher.match("42")
        assert_equal [:control, [], {}, ""], Strict::Trie.build { it.add(["x"], :control) }.match("x")
      ensure
        Strict::Trie.send(:__native_interrupt_queue=, nil)
      end
    end

    private

    def without_warnings
      verbose = $VERBOSE
      $VERBOSE = nil
      yield
    ensure
      $VERBOSE = verbose
    end

    def abandon_native_enumerator(matcher, input)
      enumerator = matcher.each_match(input)

      20.times { |token| assert_equal token, enumerator.next.first }
      assert_operator native_search_scratch_count, :>=, 3
    end

    def abandon_native_fiber(matcher, input)
      yielded = 0
      fiber = Fiber.new do
        matcher.each_match(input) do |token,|
          yielded += 1
          Fiber.yield(token) if yielded == 20
        end
      end

      assert_equal 19, fiber.resume
      assert_operator native_search_scratch_count, :>=, 3
    end

    def native_search_scratch_count
      Strict::Trie.send(:__native_search_scratch_count)
    end

    def native_test_hook?(name)
      Strict::Trie.singleton_class.private_method_defined?(name)
    end
  end
end
