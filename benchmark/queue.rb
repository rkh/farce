# frozen_string_literal: true

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
  "Farce::Queue"       => -> { Farce::Queue.new },
  "Farce::StrictQueue" => -> { Farce::StrictQueue.new },
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

queues["Thread::Queue"] = -> { Thread::SizedQueue.new(1024) }

Benchmark.ips do |x|
  queues.each do |queue_name, queue_factory|
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
