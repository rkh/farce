# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Subscription
    Farce.on_main do
      ractors = Internal.native_ractors? ? [::Ractor] : [Internal::FakeRactor::Main, Internal::FakeRactor::NotMain]

      define(Internal::BasePort, *ractors)      { subscriber.send(it)      }
      define(Abstract::Publisher)               { subscriber.publish(it)   }
      define(Abstract::Queue)                   { subscriber.try_push(it)  }
      define(Internal::Counter, Local::Counter) { |_| subscriber.increment }
      define(Internal::Flag, Local::Flag)       { |_| subscriber.set       }
      define(Abstract::Atom)                    { subscriber.value = it    }
      define(Abstract::Set, Abstract::Vector)   { subscriber << it         }
      define(Signal)                            { |_| subscriber.broadcast }

      define(::Thread::Queue) { subscriber.push(it) }
      define(::Thread::SizedQueue) do |payload|
        subscriber.push(payload, true)
      rescue ThreadError
        false
      end
    end
  end
end
