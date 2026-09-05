# frozen_string_literal: true

if RUBY_ENGINE == "ruby"
  case ENV["JIT"].to_s.downcase
  when "", "yjit" then RubyVM::YJIT.enable
  when "zjit"     then RubyVM::ZJIT.enable
  when "false" # no-op
  else abort "Unknown JIT: #{ENV["JIT"].inspect}"
  end
end

require "bundler/setup"
require "benchmark"
require "benchmark/ips"
require "farce"

class PortQueue
  def initialize
    @ractor  = Ractor.new do
      values = Thread::Queue.new
      ports  = Thread::Queue.new

      Thread.new do
        loop do
          port  = ports.pop
          value = values.pop
          port.send(value)
        end
      end

      while payload = Ractor.receive
        action, value = payload
        case action
        when :push then values.push(value)
        when :pop  then ports.push(value)
        else warn "unknown action: #{action.inspect}"
        end
      end
    end

    Ractor.make_shareable(self)
  end

  def push(value) = @ractor.send([:push, value].freeze)

  def pop
    port = Thread.current[:multi_port] ||= Ractor::Port.new
    @ractor.send([:pop, port].freeze)
    port.receive
  end
end

queues = {
  "Thread::Queue"          => -> { Thread::Queue.new },
  "Thread::SizedQueue"     => -> { Thread::SizedQueue.new(1024) },
  "Farce::Internal::Queue" => -> { Farce.const_get(:Internal, false)::Queue.new },
  "Farce::Queue"           => -> { Farce::Queue.new },
  "Farce::StrictQueue"     => -> { Farce::StrictQueue.new },
}

if defined?(Ractor)
  queues["Ractor::Port multiplexing"] = -> { PortQueue.new }

  begin
    require "ratomic"
    queues["Ratomic::Queue"] = -> { Ratomic::Queue.new(1024) }
  rescue LoadError => e
    warn "#{e.class}: #{e.message}"
  end

  begin
    require "ractor_queue"
    queues["RactorQueue"] = -> { RactorQueue.new(capacity: 1024) }
  rescue LoadError => e
    warn "#{e.class}: #{e.message}"
  end
end

Benchmark.ips do |x|
  x.config(time: Float(ENV.fetch("TIME", "5")), warmup: Float(ENV.fetch("WARMUP", "2")))
  queues.each do |queue_name, queue_factory|
    next if ENV["FILTER"] && !Regexp.new(ENV["FILTER"]).match?(queue_name)
    queue = queue_factory.call
    x.report(queue_name) do |times|
      reader = Thread.new { times.times { queue.pop } }
      writer = Thread.new { times.times { queue.push(Object.new.freeze) } }
      reader.join
      writer.join
    end
  end

  x.compare!
end
