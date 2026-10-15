# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

Warning[:experimental] = false
require "benchmark/ips"

module Checks
  NULL_PORT = Ractor.new { receive while true }.default_port
  extend self

  def with_inspect(ractor) = !ractor.inspect.end_with?("terminated>")

  def with_monitor(ractor)
    ractor.monitor(port = Ractor::Port.new)
  ensure
    ractor.unmonitor(port)
    port.close
  end

  def with_retained_monitor(ractor)
    ractor.monitor(NULL_PORT)
  ensure
    ractor.unmonitor(NULL_PORT)
  end
end

Benchmark.ips do |x|
  x.report("with_inspect (dead)") do |times|
    ractor = Ractor.new { }
    count  = 0
    while count < times
      Checks.with_inspect(ractor)
      count += 1
    end
  end

  x.report("with_inspect (alive)") do |times|
    ractor = Ractor.new { receive }
    count  = 0
    while count < times
      Checks.with_inspect(ractor)
      count += 1
    end
    ractor.send(nil)
  end

  x.report("with_monitor (dead)") do |times|
    ractor = Ractor.new { }
    count  = 0
    while count < times
      Checks.with_monitor(ractor)
      count += 1
    end
  end

  x.report("with_monitor (alive)") do |times|
    ractor = Ractor.new { receive }
    count  = 0
    while count < times
      Checks.with_monitor(ractor)
      count += 1
    end
    ractor.send(nil)
  end

  x.report("with_retained_monitor (dead)") do |times|
    ractor = Ractor.new { }
    count  = 0
    while count < times
      Checks.with_retained_monitor(ractor)
      count += 1
    end
  end

  x.report("with_retained_monitor (alive)") do |times|
    ractor = Ractor.new { receive }
    count  = 0
    while count < times
      Checks.with_retained_monitor(ractor)
      count += 1
    end
    ractor.send(nil)
  end

  x.compare!
end
