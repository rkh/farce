# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestExecutor < Test
    def test_dedicated_schedulers_inherit_the_scheduler_contract
      assert_operator Abstract::Scheduler, :<, Abstract::Executor
      [Scheduler, Unshared::Scheduler, Local::Scheduler].each do |type|
        assert_operator type, :<, Abstract::Scheduler
      end
    end

    def test_close_all_rejects_new_tasks_for_unscoped_executors
      [Scheduler, Unshared::Scheduler, Pool, Unshared::Pool].each do |type|
        executor = type.new
        error = type <= Abstract::Pool ? PoolClosedError : SchedulerClosedError

        assert_same executor, executor.close_all
        assert_same executor, executor.close_all
        assert_predicate executor, :closed?
        assert_raises(error) { executor.schedule { nil } }
        assert_raises(SchedulerClosedError) { executor.execute { nil } }
      ensure
        executor&.close
      end
    end

    def test_pools_and_thread_executor_inherit_the_executor_contract
      [Abstract::Pool, Pool, Unshared::Pool, Local::Pool, ThreadExecutor].each do |type|
        assert_operator type, :<, Abstract::Executor
        refute_operator type, :<, Abstract::Scheduler
      end
    end
  end
end
