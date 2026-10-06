# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"

require_relative "setup"

class TestInternalTestHelpers < Test
  include Helpers::InternalTestHelpers

  def test_interrupted_publication_stops_the_worker
    worker = nil
    error = assert_raises(Timeout::Error) do
      assert_atomic_ractor_publication(Internal::PriorityQueue, iterations: 1) do |_, publisher|
        worker = publisher
        raise Timeout::Error, "interrupted before publication"
      end
    end

    assert_equal "interrupted before publication", error.message
    assert_raises(Ractor::ClosedError) { worker.send(:probe) }
  end

  def test_interrupted_observation_stops_the_worker
    worker = nil
    error = assert_raises(Timeout::Error) do
      assert_atomic_ractor_publication(Internal::PriorityQueue, iterations: 1) do |target, publisher|
        worker = publisher
        target.send(:initialize, capacity: nil)
        raise Timeout::Error, "interrupted after publication"
      end
    end

    assert_equal "interrupted after publication", error.message
    assert_raises(Ractor::ClosedError) { worker.send(:probe) }
  end
end
