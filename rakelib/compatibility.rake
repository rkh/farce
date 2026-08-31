# frozen_string_literal: true

desc "Check various classes for Ractor and Fiber compatibility"
task :compatibility do
  require "timeout"
  require "farce"
  require "yaml"

  require_relative "../test/helpers/queue_test_scheduler"

  names = { Thread => "Thread.join" }

  classes = [
    [Thread, lambda(&:wakeup), lambda(&:value), -> { Thread.new { Thread.pass } }],
    [Thread::Queue, -> { it.push(:item) }, lambda(&:pop)],
    [Thread::SizedQueue, -> { it.push(:item) }, lambda(&:pop), -> { Thread::SizedQueue.new(1) }],
    [ConditionVariable, lambda(&:signal), ->(c) { m = Mutex.new and m.synchronize { c.wait(m) } }]
  ]

  if defined?(Ractor)
    names[Ractor] = "Ractor.join / Ractor.take"
    if Ractor.method_defined?(:join)
      classes << [Ractor, -> { it.send(:item) }, lambda(&:join), -> { Ractor.new { receive } }]
    elsif Ractor.method_defined?(:take)
      classes << [Ractor, -> { it.send(:item) }, lambda(&:take), -> { Ractor.new { receive } }]
    end
  end

  classes << [Ractor::Port, -> { it.send(:item) }, lambda(&:receive)] if defined?(Ractor::Port)

  begin
    require "concurrent"
    classes << [Concurrent::IVar, -> { it.set(:item) }, lambda(&:value)]
    classes << [Concurrent::Exchanger, -> { it.exchange(:item) }, -> { it.exchange(:item) }]
    classes << [
      Concurrent::Promises::ResolvableFuture,
      -> { it.fulfill(:item) }, lambda(&:value),
      -> { Concurrent::Promises.resolvable_future }
    ]
  rescue LoadError
  end

  begin
    require "async"
    require "async/priority_queue"
    classes << [Async::Promise, -> { it.fulfill { :item } }, lambda(&:wait)]
    classes << [Async::Condition, lambda(&:signal), lambda(&:wait)]
    classes << [Async::PriorityQueue, -> { it.push(:item) }, lambda(&:pop)]
  rescue LoadError
  end

  begin
    require "ratomic"
    classes << [Ratomic::Queue, -> { it.push(:item) }, lambda(&:pop), -> { Ratomic::Queue.new(2) }, lambda(&:close)]
  rescue LoadError
  end

  begin
    require "ractor_queue"
    classes << [RactorQueue, -> { it.push(:item) }, lambda(&:pop), -> { RactorQueue.new(capacity: 2) }]
  rescue LoadError => e
  end

  Internal = Farce.const_get(:Internal) # rubocop:disable Lint/ConstantDefinitionInBlock
  classes << [Internal::Queue, -> { it.push(:item) }, lambda(&:pop), -> { Internal::Queue.new(capacity: 2) }]
  classes << [
    Internal::PriorityQueue,
    -> { it.push(0, :item) },
    lambda(&:pop),
    -> { Internal::PriorityQueue.new(capacity: 2) },
    lambda(&:close)
  ]

  results = []
  width = 0

  attempt = lambda do |&block|
    Timeout.timeout(1, &block)
  rescue Timeout::Error, Farce::Ractor::Error, Timeout::ExitException, ThreadError, Farce::Ractor::ClosedError
  rescue StandardError => e
    warn "#{e.class}: #{e.message}"
  end

  classes.each do |line|
    klass, set, get, init, cleanup = line
    init ||= -> { klass.new }
    init.call # make sure it works

    thread_compatible = false
    fiber_compatible = false
    ractor_compatible = false

    attempt.call do
      done = false
      instance = init.call

      getter = Thread.new do
        get.call(instance)
        thread_compatible = true unless done
      end

      sleep 0.1
      setter = Thread.new { set.call(instance) }
      getter.join(1)

      done = true
      set.call(instance) unless thread_compatible
    ensure
      begin
        setter.kill
      rescue StandardError
        nil
      end
      begin
        getter.kill
      rescue StandardError
        nil
      end
    end

    unless defined?(Ratomic::Queue) && klass == Ratomic::Queue # stalls the entire process
      attempt.call do
        done = false
        instance = init.call
        thread = Thread.new do
          scheduler = Helpers::QueueTestScheduler.new
          Fiber.set_scheduler(scheduler)
          Fiber.schedule do
            attempt.call do
              get.call(instance)
              fiber_compatible = true unless done
            end
          end
          Fiber.schedule do
            sleep 0.1
            attempt.call { set.call(instance) }
          end
          Fiber.set_scheduler(nil)
        rescue StandardError, Timeout::ExitException
        end
        thread.join(1)
        done = true
        set.call(instance) unless fiber_compatible
        cleanup&.call(instance)
      end
    end

    if Internal.native_ractors?
      set = Farce::Ractor.shareable_proc(&set)
      get = Farce::Ractor.shareable_proc(&get)
      attempt.call do
        instance = Ractor.make_shareable(init.call)
        Ractor.new(instance, set) do |instance, set|
          sleep 0.1
          set.call(instance)
        end
        get.call(instance)
        ractor_compatible = true
      end
    else
      ractor_compatible = nil
    end

    name = names.fetch(klass, klass.name)
    width = name.length if name.length > width
    results << [name, thread_compatible, fiber_compatible, ractor_compatible]
  end

  puts "# #{RUBY_ENGINE.capitalize.sub("ruby", "Ruby")} #{RUBY_ENGINE_VERSION}"
  puts

  puts "| #{"Class".ljust(width)} | Thread | Fiber  | Ractor |"
  puts "|-#{"-" * width}-|--------|--------|--------|"

  icons = { true => "✅", false => "❌", nil => "❓" }

  results.each do |klass, thread, fiber, ractor|
    puts "| #{klass.ljust(width)} |   #{icons[thread]}   |   #{icons[fiber]}   |   #{icons[ractor]}   |"
  end

  exit
end
