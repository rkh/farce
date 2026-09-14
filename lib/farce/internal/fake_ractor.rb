# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module FakeRactor
      State = Struct.new(:id, :name, :main_thread, :default_port, :status, :mutex, :monitors, :source_location)

      GROUPS         = {}.compare_by_identity
      RACTOR_MAPPING = ObjectSpace::WeakKeyMap.new
      STATES         = ObjectSpace::WeakKeyMap.new

      class Main
        include Farce::Ractor
        extend RactorMethods

        private_class_method :new
        INSTANCE     = new.freeze
        DEFAULT_PORT = BasePort.new

        def default_port = DEFAULT_PORT
        def inspect      = "#<Farce::Ractor#1 running>"
        def join         = sleep
        def main?        = true
        def monitor(_)   = true # rubocop:disable Naming/PredicateMethod
        def name         = nil
        def receive(...) = DEFAULT_PORT.receive(...)
        def send(...)    = DEFAULT_PORT.send(...)
        def unmonitor(_) = self
        def value        = sleep

        alias << send
        alias recv receive
      end

      class NotMain
        include Farce::Ractor
        extend RactorMethods

        @@ractor_counter = 1
        @@ractor_counter_mutex = Mutex.new

        def initialize(*, name: nil, &block)
          raise ArgumentError, "must be called with a block" unless block_given?
          group = ThreadGroup.new
          state = State.new(
            default_port:    BasePort.new,
            id:              @@ractor_counter_mutex.synchronize { @@ractor_counter += 1 },
            monitors:        Set.new,
            mutex:           Mutex.new,
            name:            name,
            source_location: -(block.source_location&.join(":") || "(unknown)"),
            status:          :running,
          )

          STATES[self] = state
          GROUPS[group] = self

          state.main_thread = Thread.new do # rubocop:disable Lint/UselessSetterCall
            current = Thread.current
            group.add(current)
            current.freeze

            RACTOR_MAPPING[current] = self
            result = instance_exec(*, &block)

            # this will trigger a fiber scheduler main loop if one is set
            Fiber.set_scheduler(nil) if Fiber.respond_to?(:set_scheduler)
            state.status = :exited
            result
          rescue Exception => e # rubocop:disable Lint/RescueException
            state.status = :aborted
            raise e
          ensure
            state.mutex.synchronize do
              state.monitors.each do |monitor|
                monitor << state.status
              end
              state.monitors = nil
            end
            group.list.each { it.kill unless it == current }
            GROUPS.delete(group)
          end
        end

        def [](key)
          raise "Cannot get ractor local storage for non-current ractor" unless self == FakeRactor.current
          Farce::Ractor[key]
        end

        def []=(key, value)
          raise "Cannot set ractor local storage for non-current ractor" unless self == FakeRactor.current
          Farce::Ractor[key] = value
        end

        def monitor(port) # rubocop:disable Naming/PredicateMethod
          state = STATES[self]

          if state.status == :running
            state.mutex.synchronize do
              next if state.status != :running
              state.monitors << port
              return true
            end
          end

          port << state.status
          false
        end

        def unmonitor(port)
          state = STATES[self]
          state.mutex.synchronize { state.monitors&.delete(port) }
          self
        end

        def inspect
          return super unless state = STATES[self]
          status = state.status == :running ? "running" : "terminated"
          "#<Farce::Ractor##{state.id}#{" #{state.name}" if state.name} #{state.source_location} #{status}>"
        end

        def join
          STATES[self].main_thread.join
          self
        end

        def send(...)
          default_port.send(...)
          self
        end

        def default_port = STATES[self].default_port
        def main?        = false
        def name         = STATES[self].name
        def receive(...) = default_port.receive(...)
        def value        = STATES[self].main_thread.value

        alias << send
        alias recv receive
        alias to_s inspect

        undef dup
        undef clone
      end

      def self.current     = GROUPS.fetch(Thread.current.group) { Main::INSTANCE }
      def self.main_thread = STATES[current]&.main_thread || Thread.main

      def self.threads
        group = Thread.current.group
        return group.list if GROUPS.key?(group)
        list = ThreadGroup::Default.list
        list += group.list if group != ThreadGroup::Default
        list
      end
    end
  end
end
