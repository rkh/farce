# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "English"

module Farce
  class TestTrie < Test
    class HostileToken
      def ==(*) = raise "== called"
      def eql?(*) = raise "eql? called"
      def hash = raise "hash called"
    end

    class UnshareableToken
      include Unshareable
    end

    class HostileString < String
      def [](*) = raise "[] called"
      def dup = raise "dup called"
      def length = raise "length called"
      def valid_encoding? = raise "valid_encoding? called"
    end

    class RegexpWithState < Regexp
    end

    def test_build_and_reusable_builder_snapshots
      source = +"/first"
      builder = Strict::Trie::Builder.new

      assert_same builder, builder.add([source], :first)
      first = builder.build

      source.replace("/changed")
      builder.add(["/second"], :second)
      second = builder.build

      assert_equal [:first, [], {}, ""], first.match("/first")
      assert_nil first.match("/second")
      assert_equal [:first, [], {}, ""], second.match("/first")
      assert_equal [:second, [], {}, ""], second.match("/second")
      assert_predicate first, :frozen?
      assert Ractor.shareable?(first)
    end

    def test_class_build_and_argument_validation
      trie = Strict::Trie.build { it.add(["/", /(?<id>\d+)/], :route) }

      assert_equal [:route, ["12"], { "id" => "12" }, ""], trie.match("/12")
      assert_raises(NoMethodError) { Strict::Trie.new([], []) }
      assert_raises(TypeError) { Strict::Trie::Builder.new.add(nil, :token) }
      assert_raises(TypeError) { Strict::Trie::Builder.new.add([Object.new], :token) }
      assert_raises(TypeError) { trie.match(Object.new) }
    end

    def test_failed_add_leaves_builder_usable
      builder = Strict::Trie::Builder.new
      source = +"valid"
      invalid = "\xFF".dup.force_encoding(Encoding::UTF_8)

      assert_raises(ArgumentError) { builder.add([source, invalid], :invalid) }
      builder.add([source], :valid)
      source.replace("changed")

      assert_equal [:valid, [], {}, ""], builder.build.match("valid")
    end

    def test_string_subclasses_are_snapshotted_without_callbacks
      literal = HostileString.new("/safe")
      input = HostileString.new("/safe")
      trie = Strict::Trie.build { it.add([literal], :safe) }

      literal.replace("changed")

      assert_equal [:safe, [], {}, ""], trie.match(input)
    end

    def test_published_trie_does_not_retain_caller_regexp_state
      regexp = RegexpWithState.new("(?<value>safe)")
      state = Object.new unless regexp.frozen?
      regexp.instance_variable_set(:@state, state) if state

      trie = Strict::Trie.build { it.add([regexp], :safe) }

      assert_equal [:safe, ["safe"], { "value" => "safe" }, ""], trie.match("safe")
      assert Ractor.shareable?(trie)
      return unless state

      refute_predicate regexp, :frozen?
      refute_predicate state, :frozen?
    end

    def test_tokens_use_identity_without_callbacks
      first = HostileToken.new.freeze
      second = HostileToken.new.freeze
      builder = Strict::Trie::Builder.new
      builder.add(["/same"], first)
      builder.add(["/", /same/], second)
      builder.add(["/", /(?=same)/, "same"], first)
      trie = builder.build

      results = trie.match_all("/same")

      assert_equal 2, results.length
      assert_same first, results[0][0]
      assert_same second, results[1][0]
    end

    def test_rejects_unshareable_token_without_freezing_it
      token = UnshareableToken.new
      builder = Strict::Trie::Builder.new

      error = assert_raises(Ractor::IsolationError) { builder.add(["/x"], token) }

      assert_match(/token is not Ractor-shareable/, error.message)
      refute_predicate token, :frozen?
      assert_equal [], builder.build.match_all("/x")
    end

    def test_nil_and_false_tokens
      trie = Strict::Trie.build do |builder|
        builder.add(["nil"], nil)
        builder.add(["false"], false)
      end

      assert_equal [nil, [], {}, ""], trie.match("nil")
      assert_equal [false, [], {}, ""], trie.match("false")
    end

    def test_lookup_does_not_replace_callers_regexp_backreference
      trie = Strict::Trie.build { it.add([/(?<route>matched)/], :route) }
      /before/ =~ "before"
      previous = $LAST_MATCH_INFO

      assert_equal [:route, ["matched"], { "route" => "matched" }, ""], trie.match("matched")
      assert_same previous, $LAST_MATCH_INFO
    end

    def test_results_in_one_all_lookup_do_not_alias
      trie = Strict::Trie.build do |builder|
        builder.add([/(?<id>\d+)/], :first)
        builder.add([/(?<id>\d+)/], :second)
      end
      results = trie.match_all("12")

      results[0][1][0].replace("changed")
      results[0][2]["id"].replace("changed")
      results[0][3].replace("changed")

      assert_equal [:second, ["12"], { "id" => "12" }, ""], results[1]
    end

    def test_streaming_lookup_parity_enumerator_and_early_termination
      shared = Object.new.freeze
      trie = Strict::Trie.build do |builder|
        builder.add(["/same"], shared)
        builder.add(["/", /(?<id>same)/], shared)
        builder.add(["/", /(?<id>.+)/], :dynamic)
      end

      exact = []
      returned = trie.each_match("/same") { |token, captures, named, suffix| exact << [token, captures, named, suffix] }
      peek = trie.each_peek("/same/tail")
      lazy_input = +"/same"
      lazy = trie.each_match(lazy_input)
      lazy_input.replace("missing")

      assert_same trie, returned
      assert_instance_of Enumerator, peek
      assert_equal trie.match_all("/same"), exact
      assert_equal trie.peek_all("/same/tail"), peek.to_a
      assert_empty lazy.to_a
      assert_equal(1, exact.count { |token,| token.equal?(shared) })

      yielded = 0
      # rubocop:disable Lint/UnreachableLoop
      stopped = trie.each_match("/same") do
        yielded += 1
        break :stopped
      end

      assert_equal :stopped, stopped
      assert_equal 1, yielded
      error = assert_raises(RuntimeError) { trie.each_match("/same") { raise "stop" } }
      # rubocop:enable Lint/UnreachableLoop
      assert_equal "stop", error.message
    end

    def test_copies_share_the_immutable_match_behavior
      trie = Strict::Trie.build { it.add(["/copy"], :copy) }

      [trie.dup, trie.clone, trie.clone(freeze: false)].each do |copy|
        assert_predicate copy, :frozen?
        assert Ractor.shareable?(copy)
        assert_equal [:copy, [], {}, ""], copy.match("/copy")
      end
    end

    def test_native_ractor_lookup
      skip "native Ractors are unavailable" unless Internal.native_ractors?

      trie = Strict::Trie.build { it.add(["/", /(?<id>\d+)/], :route) }
      worker = Ractor.new(trie) { it.match("/42") }
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal [:route, ["42"], { "id" => "42" }, ""], result
    end

    def test_native_ractor_first_build
      skip "native Ractors are unavailable" unless Internal.native_ractors?

      worker = Ractor.new do
        trie = Farce::Strict::Trie.build { it.add(["/remote"], :remote) }
        trie.match("/remote")
      end
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal [:remote, [], {}, ""], result
    end

    def test_fresh_require_and_first_build
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        trie = Farce::Strict::Trie.build { it.add(["/fresh"], :fresh) }
        p trie.match("/fresh")
      RUBY

      assert_predicate status, :success?, error
      assert_equal "[:fresh, [], {}, \"\"]\n", output
      assert_empty error
    end
  end
end
