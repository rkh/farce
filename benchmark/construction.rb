# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# ruby -Ilib benchmark/construction.rb
# SIZES=0,1,16 OPERATIONS=25000 SAMPLES=3 WARMUP=1000 FILTER='Array|Vector'
# WORKERS=1,4,8 additionally measures concurrent construction with Farce::Ractor.
# COMPARE_FIX=1 compares previous and current publication in separate Ruby 4.1 processes.
# Inputs and the bounded retention buffer are prepared outside measurements.
# Allocation counts cover the main Ractor only. Native allocation bytes are not counted.
# Warmup includes Ruby learning instance-variable capacity. First-instance layouts are not measured.
require "farce"
require "concurrent/map"
require "json"
require "open3"
require "rbconfig"

module ConstructionBenchmark
  module_function

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def median(values)
    ordered = values.sort
    middle = ordered.length / 2
    ordered.length.odd? ? ordered[middle] : (ordered[middle - 1] + ordered[middle]) / 2.0
  end

  def concurrent_map_factory(mapping)
    return -> { ::Concurrent::Map.new } if mapping.empty?
    lambda do
      map = ::Concurrent::Map.new
      mapping.each_pair { |key, value| map[key] = value }
      map
    end
  end

  def factories(size)
    elements = Array.new(size) { it }.freeze
    mapping = elements.to_h { [it, nil] }.freeze
    unshared_map = size.zero? ? -> { Farce::Unshared::Map.new } : -> { Farce::Unshared::Map.new(mapping) }
    {
      "Array"                    => -> { Array.new(size) },
      "Farce::Vector"            => -> { Farce::Vector.new(size) },
      "Farce::Unshared::Vector"  => -> { Farce::Unshared::Vector.new(size) },
      "Farce::Concurrent::Tuple" => -> { Farce::Concurrent::Tuple.new(size) },
      "Hash"                     => size.zero? ? -> { {} } : -> { mapping.dup },
      "Concurrent::Map"          => concurrent_map_factory(mapping),
      "Farce::Map"               => size.zero? ? -> { Farce::Map.new } : -> { Farce::Map.new(mapping) },
      "Farce::Unshared::Map"     => unshared_map,
      "Set"                      => -> { Set.new(elements) },
      "Farce::Set"               => -> { Farce::Set.new(elements) },
      "Farce::Unshared::Set"     => -> { Farce::Unshared::Set.new(elements) },
    }
  end

  def construct(factory, operations, retained)
    index = 0
    while index < operations
      # Retaining recent results prevents a JIT from eliminating unused constructors.
      retained[index & 255] = factory.call
      index += 1
    end
  end

  def allocation_counter_available?
    before = GC.stat[:total_allocated_objects]
    return false unless before.is_a?(Integer)
    retained = Array.new(256)
    construct(-> { Object.new }, retained.length, retained)
    # Some engines expose a placeholder counter that always returns zero.
    GC.stat(:total_allocated_objects) > before
  end

  def verify_results(retained, size)
    raise "Incorrect constructor result" unless retained.all? { it.nil? || it.size == size }
  end

  def parallel_seconds(name, size, workers, operations, warmup)
    native_port = Farce::Ractor.builtin? && ::Ractor.const_defined?(:Port, false)
    ready = native_port ? ::Ractor::Port.new : Farce::Strict::Queue.new
    release = Farce::Strict::Queue.new unless native_port
    tasks = Array.new(workers) do
      Farce::Ractor.new(name, size, operations, warmup, ready, release) do |label, length, count, warming, signal, gate|
        factory = ConstructionBenchmark.factories(length).fetch(label)
        retained = Array.new(256)
        ConstructionBenchmark.construct(factory, warming, retained)
        signal << true
        gate ? gate.pop : Farce::Ractor.receive
        ConstructionBenchmark.construct(factory, count, retained)
        ConstructionBenchmark.verify_results(retained, length)
        nil
      end
    end
    workers.times { native_port ? ready.receive : ready.pop }
    started = clock
    tasks.each { native_port ? it.send(:start) : release << true }
    tasks.each(&:value)
    clock - started
  ensure
    ready&.close if native_port
  end

  def baseline(name)
    return "Array" if name.match?(/Array|Vector|Tuple/)
    name.match?(/Hash|Map/) ? "Hash" : "Set"
  end

  def key(row, name = row.fetch("implementation"))
    row.values_at("kind", "workers", "size") + [name]
  end

  def index_results(rows) = rows.to_h { [key(it), it] }

  def number(value, precision = 4) = value ? format("%.#{precision}f", value) : "unavailable"

  def print_results(rows)
    indexed = index_results(rows)
    puts "kind,workers,size,implementation,ns_per_construction,allocations_per_construction," \
         "baseline,time_vs_baseline,allocations_vs_baseline"
    rows.each do |row|
      name = row.fetch("implementation")
      reference = indexed.fetch(key(row, baseline(name)))
      allocations_ratio = row["allocations"] && reference["allocations"] &&
        (row["allocations"] / reference["allocations"])
      puts [*key(row), number(row.fetch("ns"), 1), number(row["allocations"]), baseline(name),
            number(row.fetch("ns") / reference.fetch("ns")), number(allocations_ratio)].join(",")
    end
  end

  def comparison_child(previous:)
    # This old implementation runs only in a disposable benchmark child process.
    # Objects created by its workers remain local and are never read by peers.
    previous_source = <<~RUBY
      previous_setup_ran = false
      TracePoint.new(:class) do |event|
        next unless event.self.name == "Farce::Shareable"
        event.disable
        Farce.const_get(:Internal).module_eval("def self.prepare_shareable_class(_base) = nil")
        previous_setup_ran = true
      end.enable
      require "farce"
      abort "Previous baseline invalid: Farce::Shareable was already loaded" unless previous_setup_ran
      module Farce
        module Internal
          module Freeze
            def self.publish(object)
              Object.instance_method(:freeze).bind_call(object)
              ::Ractor.make_shareable(object) if Internal.native_ractors?
              object
            end
          end
        end
      end
    RUBY
    source = previous ? previous_source : "require \"farce\"\n"
    source += "\nload ARGV.fetch(0)"
    environment = { "COMPARE_FIX" => "0", "CONSTRUCTION_JSON" => "1" }
    options = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? ["--yjit"] : []
    output, errors, status = Open3.capture3(environment, RbConfig.ruby, *options,
      "-I", File.expand_path("../lib", __dir__), "-e", source, File.expand_path(__FILE__))
    abort "#{previous ? "Previous" : "Current"} publication child failed:\n#{errors}\n#{output}" unless status.success?
    warn errors unless errors.empty?
    JSON.parse(output)
  end

  def compare_fix
    native_hooks = %i[prepare_shareable_class publish_shareable].all? do |name|
      Farce.const_get(:Internal).method(name).source_location.nil?
    end
    abort "COMPARE_FIX=1 requires CRuby 4.1 with the compiled publication fix" unless
      RUBY_ENGINE == "ruby" && RUBY_VERSION.start_with?("4.1.") && native_hooks
    previous_rows = comparison_child(previous: true)
    current_rows = comparison_child(previous: false)
    previous = index_results(previous_rows)
    current = index_results(current_rows)
    puts RUBY_DESCRIPTION
    puts "concurrent-ruby #{Gem.loaded_specs.fetch("concurrent-ruby").version}"
    puts "Farce #{Farce::VERSION}; SIZES=#{ENV.fetch("SIZES", "0,1,16")}; " \
         "OPERATIONS=#{ENV.fetch("OPERATIONS", "25000")}; SAMPLES=#{ENV.fetch("SAMPLES", "3")}"
    puts "WARMUP=#{ENV.fetch("WARMUP", "1000")}; WORKERS=#{ENV.fetch("WORKERS", "")}; " \
         "FILTER=#{ENV.fetch("FILTER", ".")}"
    puts "Full publication fix comparison in separate fresh processes. Each process warms up independently."
    puts "Warmup includes Ruby learning instance-variable capacity. First-instance layouts are not measured."
    puts "Previous disables class identity preparation before Shareable first loads."
    puts "Previous uses Object.instance_method(:freeze).bind_call and Ractor.make_shareable."
    puts "Current uses class identity preparation and native publication. This compares the complete fix."
    puts "Time ratios above 1 mean slower. Allocation deltas are current minus previous."
    puts "Family time ratios use Array, Hash or Set measured in the same process and worker configuration."
    puts "Empty Hash uses {}. Other empty maps use default constructors."
    puts "Populated Concurrent::Map uses new followed by individual inserts."
    puts "GC remains enabled. Each worker retains its latest 256 results. Inputs and retention buffers are prebuilt."
    puts "Concurrent timing excludes startup and warmup and includes barrier release, result checks and collection."
    puts "Allocations cover main-Ractor construction only and exclude native allocation bytes."
    puts "kind,workers,size,implementation,previous_ns,current_ns,current_vs_previous_time," \
         "time_change_percent,previous_allocations,current_allocations,allocation_delta," \
         "baseline,previous_time_vs_baseline,current_time_vs_baseline"
    current_rows.each do |row|
      old = previous.fetch(key(row))
      reference = baseline(row.fetch("implementation"))
      old_base = previous.fetch(key(row, reference))
      new_base = current.fetch(key(row, reference))
      ratio = row.fetch("ns") / old.fetch("ns")
      delta = row["allocations"] && old["allocations"] ? row["allocations"] - old["allocations"] : nil
      puts [*key(row), number(old.fetch("ns"), 1), number(row.fetch("ns"), 1), number(ratio),
            number((ratio - 1) * 100, 2), number(old["allocations"]), number(row["allocations"]), number(delta),
            reference, number(old.fetch("ns") / old_base.fetch("ns")),
            number(row.fetch("ns") / new_base.fetch("ns"))].join(",")
    end
  end

  def run
    return compare_fix if ENV["COMPARE_FIX"] == "1"
    sizes = ENV.fetch("SIZES", "0,1,16").split(",").map { Integer(it) }
    operations = Integer(ENV.fetch("OPERATIONS", "25000"))
    samples = Integer(ENV.fetch("SAMPLES", "3"))
    warmup = Integer(ENV.fetch("WARMUP", "1000"))
    workers = ENV.fetch("WORKERS", "").split(",").map { Integer(it) }
    filter = Regexp.new(ENV.fetch("FILTER", "."))
    raise ArgumentError, "nonnegative SIZES and WARMUP, positive OPERATIONS, SAMPLES and WORKERS required" unless
      !sizes.empty? && sizes.all? { it >= 0 } && warmup >= 0 && [operations, samples, *workers].all?(&:positive?)
    names = factories(0).keys.grep(filter)
    abort "No matching implementations" if names.empty?
    names = (names + names.map { baseline(it) }).uniq
    names = factories(0).keys.select { names.include?(it) }
    allocation_counts_available = allocation_counter_available?
    rows = []

    unless ENV["CONSTRUCTION_JSON"] == "1"
      puts RUBY_DESCRIPTION
      puts "concurrent-ruby #{Gem.loaded_specs.fetch("concurrent-ruby").version}"
      puts "Farce #{Farce::VERSION}; #{operations} constructions per worker; " \
           "#{samples} samples; #{warmup} warmup constructions"
      puts "Medians of elapsed ns/construction and allocated Ruby objects/construction. GC remains enabled."
      puts "Warmup includes Ruby learning instance-variable capacity. First-instance layouts are not measured."
      puts "Array, Vector and Tuple contain nil slots. Hash and Map copy integer keys with nil values."
      puts "Empty Hash uses {}. Other empty maps use default constructors."
      puts "Populated Concurrent::Map uses new followed by individual inserts."
      puts "Set contains integers. There is no Unshared Tuple variant."
      puts "Inputs are reused. Each worker retains its latest 256 results. Timing includes the retention loop."
      puts "Allocation counts are measured only in the main Ractor and exclude native allocation bytes."
      puts "Unavailable counters are reported as unavailable. Concurrent rows measure timing only."
      worker_kind = Farce::Ractor.builtin? ? "native Ractors" : "the thread-based Ractor polyfill"
      puts "Ractor timing uses #{worker_kind} and excludes worker startup and warmup."
      puts "Concurrent timing includes barrier release, result checks and result collection."
      puts "Concurrent ns/construction divides by all workers' operations."
      puts "Family ratios above 1 mean more time or allocations than Array, Hash or Set. Baselines are always included."
    end

    sizes.each do |size|
      selected = factories(size).slice(*names)
      selected.each do |name, factory|
        raise "Incorrect constructor result: #{name}" unless factory.call.size == size
        retained = Array.new(256)
        construct(factory, warmup, retained)
        elapsed = []
        allocated = []
        samples.times do
          GC.start
          before_allocations = GC.stat(:total_allocated_objects) if allocation_counts_available
          started = clock
          construct(factory, operations, retained)
          seconds = clock - started
          allocation_count = GC.stat(:total_allocated_objects) - before_allocations if allocation_counts_available
          elapsed << (seconds * 1_000_000_000 / operations)
          allocated << allocation_count.fdiv(operations) if allocation_count
          verify_results(retained, size)
        end
        rows << { "kind" => "main", "workers" => 1, "size" => size, "implementation" => name,
                  "ns" => median(elapsed), "allocations" => allocated.empty? ? nil : median(allocated) }
      end
    end

    sizes.product(names, workers).each do |size, name, worker_count|
      elapsed = Array.new(samples) do
        GC.start
        parallel_seconds(name, size, worker_count, operations, warmup) * 1_000_000_000 / (operations * worker_count)
      end
      rows << { "kind" => "Ractor", "workers" => worker_count, "size" => size, "implementation" => name,
                "ns" => median(elapsed), "allocations" => nil }
    end
    ENV["CONSTRUCTION_JSON"] == "1" ? puts(JSON.generate(rows)) : print_results(rows)
  end
end

ConstructionBenchmark.run
