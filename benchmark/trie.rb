# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# ruby -Ilib benchmark/trie.rb > results.json
# COUNTS=10,1000 TIME=1 WARMUP=1 ROUNDS=5 QUERIES=256 FRESH=0 FROZEN=0
# FILTER=digits IMPLEMENTATIONS=Farce,Portable SPIKE=/path/to/trie-matcher-spike
# QUERIES=all visits the entire tree. FRESH=1 duplicates inputs in the timed loop.
require "bundler/setup"
require "json"
require "time"
require "rbconfig"
require "objspace" if RUBY_ENGINE == "ruby"
require "farce"
require "farce/engine/shared/trie"
require File.join(ENV.fetch("SPIKE"), "load_matchers") if ENV["SPIKE"]

module TrieBenchmark
  module_function

  def tuple(token, captures = [], names = {}, suffix = "")
    [token, captures, names, suffix]
  end

  def workloads(count, query_limit)
    ids = (0...count).to_a.shuffle(random: Random.new(250925)).take(query_limit || count)
    static = count.times.map { |i| [["/api/r#{i}/edit"], i] }
    digits = count.times.map { |i| [["/api/r#{i}/", /(?<id>\d+)/, "/edit"], i] }
    segments = count.times.map { |i| [["/api/r#{i}/", %r{(?<id>[^/]+)}, "/edit"], i] }
    words = count.times.map { |i| [["/api/r#{i}/", /(?<slug>\w+)/], i] }
    compound = count.times.map { |i| [["/api/r#{i}/", /(?<id>\d+)(?:-|%2D|%2d)(?<slug>\w+)/], i] }
    four = count.times.map do |i|
      [["/api/r#{i}/", %r{(?<a>[^/]+)}, "/", %r{(?<b>[^/]+)}, "/",
        %r{(?<c>[^/]+)}, "/", %r{(?<d>[^/]+)}], i]
    end
    fallback = count.times.map { |i| [["/api/r#{i}/", /(?<word>\p{L}+)/, "/edit"], i] }
    long = count.times.map { |i| [["/#{"common/" * 32}r#{i}/edit"], i] }
    overlap = count.times.flat_map do |i|
      [[["/api/r#{i}/new"], i * 3], [["/api/r#{i}/", %r{(?<id>[^/]+)}], (i * 3) + 1],
        [["/api/r#{i}/", %r{(?<other>[^/]+)}], (i * 3) + 1], [["/api/r#{i}/"], (i * 3) + 2]]
    end
    [
      ["static", static, :match, ids.map { |i| ["/api/r#{i}/edit", tuple(i)] }],
      ["static_miss", static, :match, ids.map { |i| ["/api/r#{i}/wrong", nil] }],
      ["digits", digits, :match, ids.map { |i| ["/api/r#{i}/1234/edit", tuple(i, ["1234"], { "id" => "1234" })] }],
      ["digits_miss", digits, :match, ids.map { |i| ["/api/r#{i}/wrong/edit", nil] }],
      ["segment", segments, :match, ids.map { |i| ["/api/r#{i}/name/edit", tuple(i, ["name"], { "id" => "name" })] }],
      ["word", words, :match, ids.map { |i| ["/api/r#{i}/word_42", tuple(i, ["word_42"], { "slug" => "word_42" })] }],
      ["id_slug", compound, :match, ids.map { |i| ["/api/r#{i}/123-word_42", tuple(i, %w[123 word_42], { "id" => "123", "slug" => "word_42" })] }],
      ["four_segments", four, :match, ids.map { |i| ["/api/r#{i}/one/two/three/four", tuple(i, %w[one two three four], { "a" => "one", "b" => "two", "c" => "three", "d" => "four" })] }],
      ["unicode_segment", segments, :match, ids.map { |i| ["/api/r#{i}/日本/edit", tuple(i, ["日本"], { "id" => "日本" })] }],
      ["unicode_fallback", fallback, :match, ids.map { |i| ["/api/r#{i}/日本/edit", tuple(i, ["日本"], { "word" => "日本" })] }],
      ["long_static", long, :match, ids.map { |i| ["/#{"common/" * 32}r#{i}/edit", tuple(i)] }],
      ["peek", digits, :peek, ids.map { |i| ["/api/r#{i}/1234/edit/tail", tuple(i, ["1234"], { "id" => "1234" }, "/tail")] }],
      ["match_all", overlap, :match_all, ids.map { |i| ["/api/r#{i}/new", [tuple(i * 3), tuple((i * 3) + 1, ["new"], { "id" => "new" })]] }],
      ["peek_all", overlap, :peek_all, ids.map { |i| ["/api/r#{i}/new/tail", [tuple(i * 3, [], {}, "/tail"), tuple((i * 3) + 1, ["new"], { "id" => "new" }, "/tail"), tuple((i * 3) + 2, [], {}, "new/tail")]] }]
    ]
  end

  class Portable
    def self.new(entries)
      registry = {}.compare_by_identity
      tokens = []
      rows = entries.map do |parts, token|
        id = registry.fetch(token) do
          registry[token] = tokens.length
          tokens << token
          tokens.length - 1
        end
        [parts, id]
      end
      Farce.const_get(:Internal)::PortableTrie.new(rows, tokens)
    end
  end

  # This includes reachable token payloads but excludes class/module graphs.
  # Native TypedData reports its owned allocations through ObjectSpace's hook.
  def retained_memory(root)
    return unless ObjectSpace.respond_to?(:reachable_objects_from) && ObjectSpace.respond_to?(:memsize_of)

    seen = {}.compare_by_identity
    stack = [root]
    bytes = 0
    until stack.empty?
      object = stack.pop
      next if object.is_a?(Module) || seen.key?(object)

      seen[object] = true
      bytes += ObjectSpace.memsize_of(object)
      ObjectSpace.reachable_objects_from(object)&.each do |child|
        stack << child unless child.is_a?(Module) || seen.key?(child)
      end
    end
    { bytes: bytes, objects: seen.length }
  end

  def factories
    candidates = {
      "Farce" => lambda do |entries|
        Farce::Strict::Trie.build { |builder| entries.each { |parts, token| builder.add(parts, token) } }
      end,
      "Portable" => ->(entries) { Portable.new(entries) },
    }
    if defined?(TrieSpike::FastRadixC)
      candidates["FastRadixC-spike"] = lambda do |entries|
        tree = TrieSpike::FastRadixC.new
        entries.each { |parts, token| tree.add(parts, token) }
        tree.optimize!
        Ractor.make_shareable(tree.freeze)
      end
    end
    selection = ENV.fetch("IMPLEMENTATIONS", "").split(",")
    candidates.select { |name, _| selection.empty? || selection.include?(name) }
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def allocated
    GC.stat(:total_allocated_objects)
  rescue ArgumentError, NotImplementedError
    nil
  end

  def sample(tree, operation, queries, seconds, fresh)
    started = clock
    calls = 0
    loop do
      queries.each { |query| tree.public_send(operation, fresh ? query.dup : query) }
      calls += queries.length
      elapsed = clock - started
      return calls / elapsed if elapsed >= seconds
    end
  end

  def median(samples)
    sorted = samples.sort
    middle = sorted.length / 2
    sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
  end

  def run
    counts = ENV.fetch("COUNTS", "10,1000").split(",").map { Integer(it) }
    seconds = Float(ENV.fetch("TIME", "1"))
    warmup = Float(ENV.fetch("WARMUP", "1"))
    rounds = Integer(ENV.fetch("ROUNDS", "5"))
    query_limit = ENV.fetch("QUERIES", "256")
    query_limit = query_limit == "all" ? nil : Integer(query_limit)
    fresh = ENV["FRESH"] == "1"
    frozen_queries = ENV["FROZEN"] == "1"
    filter = Regexp.new(ENV.fetch("FILTER", "."))
    raise ArgumentError, "positive counts, TIME, ROUNDS, QUERIES and nonnegative WARMUP required" unless
      counts.all?(&:positive?) && seconds.positive? && rounds.positive? && warmup >= 0 && (!query_limit || query_limit.positive?)
    candidates = factories
    raise ArgumentError, "No implementations selected" if candidates.empty?
    rows = []
    counts.each do |count|
      workloads(count, query_limit).each do |name, entries, operation, cases|
        next unless filter.match?(name)
        queries = cases.map(&:first)
        queries.each(&:freeze) if frozen_queries
        active = candidates.map do |label, factory|
          build_samples = []
          build_allocations = []
          tree = nil
          3.times do
            GC.start
            before = allocated
            started = clock
            tree = factory.call(entries)
            build_samples << (clock - started) * 1000
            after = allocated
            build_allocations << after - before if before && after
          end
          cases.each do |query, expected|
            actual = tree.public_send(operation, query)
            raise "#{label} #{name} #{query.inspect}: #{actual.inspect} != #{expected.inspect}" unless actual == expected
          end
          sample(tree, operation, queries, warmup, fresh) if warmup.positive?
          record = { implementation: label, workload: name, count: count, entries: entries.length,
            operation: operation, queries: queries.length, build_ms: build_samples,
            build_allocations: build_allocations, samples_ips: [],
            stats: tree.respond_to?(:stats) ? tree.stats : nil, retained_memory: retained_memory(tree) }
          [tree, record]
        end
        rounds.times do |round|
          (round.odd? ? active.reverse : active).each do |tree, record|
            GC.start
            record[:samples_ips] << sample(tree, operation, queries, seconds, fresh)
          end
        end
        active.each do |tree, record|
          GC.start
          before = allocated
          20.times { queries.each { |query| tree.public_send(operation, fresh ? query.dup : query) } }
          after = allocated
          record[:objects_per_lookup] = (after - before).fdiv(20 * queries.length) if before && after
          record[:median_ips] = median(record[:samples_ips])
          record[:median_build_ms] = median(record[:build_ms])
          rows << record
          warn format("%-18s %-18s %6d %10.0f calls/s %s objects/call", record[:implementation], name, count,
            record[:median_ips], record[:objects_per_lookup]&.round(2) || "unavailable")
        end
      end
    end
    { metadata: { ruby: RUBY_DESCRIPTION, yjit: defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?,
      platform: RUBY_PLATFORM, cflags: RbConfig::CONFIG["CFLAGS"], timestamp: Time.now.iso8601,
      seconds: seconds, warmup: warmup, rounds: rounds, fresh: fresh, frozen_queries: frozen_queries, seed: 250925,
      scope: "Complete generic lookup tuples, GC enabled, expected results checked before timing. Alternating candidate order. Fresh input includes duplication. Portable construction bypasses public validation, so build costs are not equivalent. Native stats exclude Ruby/regexp memory. ObjectSpace reachable memory includes tokens and reported native allocations, excluding class/module graphs and allocator overhead. This is not a Mustermann::Set benchmark." }, results: rows }
  end
end

puts JSON.pretty_generate(TrieBenchmark.run) if $PROGRAM_NAME == __FILE__
