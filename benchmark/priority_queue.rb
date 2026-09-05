# frozen_string_literal: true
# Keep the same Ruby lambda dispatch overhead for every queue adapter.
# rubocop:disable Style/SymbolProc

if RUBY_ENGINE == "ruby"
  case ENV["JIT"].to_s.downcase
  when "", "yjit" then RubyVM::YJIT.enable
  when "zjit"     then RubyVM::ZJIT.enable
  when "false" # no-op
  else abort "Unknown JIT: #{ENV["JIT"].inspect}"
  end
end

require "bundler/setup"
require "benchmark/ips"
require "farce"

# Distinct, shareable values allow duplicate priorities even in queues that
# index values by equality. IO::Event compares the values themselves.
Entry = Data.define(:priority, :id) do
  include Comparable

  def <=>(other) = priority <=> other.priority

  # Comparable's == would otherwise equate distinct entries with tied priorities.
  def ==(other) = eql?(other)
end

Implementation = Data.define(:factory, :push, :pop)
implementations = {
  "Farce::TimerQueue (due)" => Implementation.new(
    -> { Farce::TimerQueue.new },
    ->(queue, entry) { queue.try_push(entry, at: entry.priority) },
    ->(queue) { queue.try_pop },
  ),
  "Farce::PriorityQueue"    => Implementation.new(
    -> { Farce::PriorityQueue.new },
    ->(queue, entry) { queue.try_push(entry, priority: entry.priority) },
    ->(queue) { queue.try_pop },
  ),
}

filter = Regexp.new(ENV.fetch("FILTER", "."))
competitors = {
  "IO::Event::PriorityHeap"               => ["io-event", "io/event/priority_heap", lambda do
    Implementation.new(
      -> { IO::Event::PriorityHeap.new },
      ->(queue, entry) { queue.push(entry) },
      ->(queue) { queue.pop },
    )
  end],
  "MinPriorityQueue"                      => ["lazy_priority_queue", "lazy_priority_queue", lambda do
    Implementation.new(
      -> { MinPriorityQueue.new },
      ->(queue, entry) { queue.push(entry, entry.priority) },
      ->(queue) { queue.pop },
    )
  end],
  "Philiprehberger::PriorityQueue::Queue" => [
    "philiprehberger-priority_queue", "philiprehberger/priority_queue", lambda do
      Implementation.new(
        -> { Philiprehberger::PriorityQueue::Queue.new(mode: :min) },
        ->(queue, entry) { queue.push(entry, priority: entry.priority) },
        ->(queue) { queue.pop },
      )
    end
  ],
  "FastContainers::PriorityQueue"         => ["priority_queue_cxx", "fc", lambda do
    Implementation.new(
      -> { FastContainers::PriorityQueue.new(:min) },
      ->(queue, entry) { queue.push(entry, entry.priority) },
      # This gem's pop returns the queue, so retrieving the value costs top too.
      lambda { |queue|
        value = queue.top
        queue.pop
        value
      },
    )
  end],
  "MultiRBTree"                           => ["rbtree", "rbtree", lambda do
    Implementation.new(
      -> { MultiRBTree.new },
      ->(queue, entry) { queue[entry.priority] = entry },
      ->(queue) { queue.shift&.last },
    )
  end],
  "PQueue"                                => ["pqueue", "pqueue", lambda do
    Implementation.new(
      -> { PQueue.new { |left, right| left < right } },
      ->(queue, entry) { queue.push(entry) },
      ->(queue) { queue.pop },
    )
  end],
}

# rubocop:enable Style/SymbolProc

puts RUBY_DESCRIPTION
competitors.each do |name, (gem_name, path, build)|
  next unless filter.match?(name)

  begin
    require path
    implementations[name] = build.call
    puts "#{name}: #{gem_name} #{Gem.loaded_specs.fetch(gem_name).version}"
  rescue LoadError => e
    warn "Skipping #{name}: #{e.message}. Install with BUNDLE_WITH=benchmark bundle install."
  end
end
implementations.select! { |name, _| filter.match?(name) }
abort "No implementations match FILTER or are available" if implementations.empty?
puts "Farce #{Farce::VERSION}" if implementations.keys.any? { it.start_with?("Farce::") }

size   = Integer(ENV.fetch("SIZE", "1000"))
seed   = Integer(ENV.fetch("SEED", "42"))
time   = Float(ENV.fetch("TIME", "5"))
warmup = Float(ENV.fetch("WARMUP", "2"))
raise ArgumentError, "SIZE and TIME must be positive; WARMUP must be nonnegative" unless
  size.positive? && time.positive? && time.finite? && warmup >= 0 && warmup.finite?

random = Random.new(seed)
priorities = {
  "random"     => Array.new(size) { random.rand },
  "ascending"  => Array.new(size, &:itself),
  "descending" => Array.new(size) { size - it },
  "duplicates" => Array.new(size) { random.rand(8) },
}

priorities.each do |workload, keys|
  # Negative timestamps are already due on Farce's relative monotonic clock.
  # Shift every queue's keys equally to retain the same ordering and ties.
  keys = keys.map { (it - size - 1).to_f }
  entries = keys.each_with_index.map { |priority, id| Entry.new(priority, id) }.freeze
  entries.each { Ractor.make_shareable(it) } if defined?(Ractor)

  # Verify the complete workload outside timing. Ties need not be FIFO, but
  # every value must survive and priorities must be removed in ascending order.
  implementations.each do |name, implementation|
    queue = implementation.factory.call
    entries.each { implementation.push.call(queue, it) }
    raise "#{name}: incorrect size after push" unless queue.size == size
    removed = Array.new(size) { implementation.pop.call(queue) }
    valid = removed.all? { Entry === it } &&
      removed.map(&:priority) == keys.sort &&
      removed.map(&:id).sort == (0...size).to_a && queue.empty?
    raise "#{name}: incorrect ordering or lost values (#{workload})" unless valid
  end

  puts "", "#{workload}: #{size} entries, seed #{seed} (iterations/s = complete fill-and-drain batches)"
  Benchmark.ips do |x|
    x.config(time:, warmup:)
    implementations.each do |name, implementation|
      factory, push, pop = implementation.factory, implementation.push, implementation.pop
      x.report(name) do
        queue = factory.call
        entries.each { push.call(queue, it) }
        size.times { pop.call(queue) }
      end
    end
    x.compare!
  end
end
