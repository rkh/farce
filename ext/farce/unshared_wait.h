#ifndef FARCE_UNSHARED_WAIT_H
#define FARCE_UNSHARED_WAIT_H

/* Build default only. Unshared queues and signal subclasses can select either
 * fiber waiting protocol at runtime. No scheduler backend is detected here. */
#ifndef FARCE_UNSHARED_FIBER_IO
# define FARCE_UNSHARED_FIBER_IO 0
#endif

#include "containers.h"
#include "ruby/fiber/scheduler.h"

#include <math.h>
#include <stdint.h>
#include <time.h>

/* A wait list confined to one Ractor. All list access retains that Ractor's
 * GVL. Parked C stacks own the waiter nodes, just like CRuby's Thread::Queue.
 * No IO wrapper, pipe, descriptor duplicate, or native lock is required. */
typedef struct farce_unshared_waiter farce_unshared_waiter_t;

typedef struct {
    farce_unshared_waiter_t *first;
    farce_unshared_waiter_t *last;
    size_t count;
    uint64_t sequence;
} farce_unshared_wait_list_t;

struct farce_unshared_waiter {
    farce_unshared_wait_list_t *list;
    farce_unshared_waiter_t *previous;
    farce_unshared_waiter_t *next;
    VALUE blocker;
    VALUE thread;
    VALUE scheduler;
    VALUE fiber;
    uint64_t sequence;
    double deadline;
    bool finite;
    bool linked;
    bool notified;
};

static double
farce_unshared_wait_now(void)
{
    struct timespec now;
#ifdef CLOCK_MONOTONIC
    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
        return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
    }
#endif
    struct timeval fallback;
    gettimeofday(&fallback, NULL);
    return (double)fallback.tv_sec + (double)fallback.tv_usec / 1000000.0;
}

static void
farce_unshared_wait_mark(farce_unshared_wait_list_t *list)
{
    for (farce_unshared_waiter_t *waiter = list->first; waiter; waiter = waiter->next) {
        /* These same VALUEs live in suspended C frames and must stay pinned. */
        rb_gc_mark(waiter->blocker);
        rb_gc_mark(waiter->thread);
        rb_gc_mark(waiter->scheduler);
        rb_gc_mark(waiter->fiber);
    }
}

static void
farce_unshared_wait_unlink(farce_unshared_waiter_t *waiter)
{
    if (!waiter->linked) return;
    if (waiter->previous) waiter->previous->next = waiter->next;
    else waiter->list->first = waiter->next;
    if (waiter->next) waiter->next->previous = waiter->previous;
    else waiter->list->last = waiter->previous;
    waiter->linked = false;
}

static VALUE
farce_unshared_wait_cleanup(VALUE opaque)
{
    farce_unshared_waiter_t *waiter = (farce_unshared_waiter_t *)opaque;
    farce_unshared_wait_unlink(waiter);
    waiter->list->count--;
    return Qnil;
}

static VALUE
farce_unshared_wait_body(VALUE opaque)
{
    farce_unshared_waiter_t *waiter = (farce_unshared_waiter_t *)opaque;
    double remaining = waiter->finite ? waiter->deadline - farce_unshared_wait_now() : 0;
    if (waiter->finite && remaining <= 0) return Qfalse;

    if (!NIL_P(waiter->scheduler)) {
        rb_fiber_scheduler_block(
            waiter->scheduler, waiter->blocker, waiter->finite ? DBL2NUM(remaining) : Qnil
        );
    }
    else if (waiter->finite) {
        /* Bounded chunks avoid overflowing time_t for huge valid timeouts. */
        if (remaining > 86400) remaining = 86400;
        struct timeval interval = {
            .tv_sec = (time_t)remaining,
            .tv_usec = (int)ceil((remaining - floor(remaining)) * 1000000),
        };
        if (interval.tv_usec == 1000000) {
            interval.tv_sec++;
            interval.tv_usec = 0;
        }
        rb_thread_wait_for(interval);
    }
    else {
        rb_thread_sleep_deadly();
    }
    return waiter->notified || !waiter->finite || farce_unshared_wait_now() < waiter->deadline ? Qtrue : Qfalse;
}

/* The caller checks its condition immediately before this call, under the
 * GVL. Do not run Ruby or release the GVL between that check and registration.
 * Scheduler block/unblock implementations must support early notifications,
 * as they do for Ruby's own Mutex and Queue. */
static bool
farce_unshared_wait(farce_unshared_wait_list_t *list, VALUE blocker, bool finite, double deadline)
{
    farce_unshared_waiter_t waiter = {
        .list = list,
        .previous = list->last,
        .next = NULL,
        .blocker = blocker,
        .thread = rb_thread_current(),
        .scheduler = rb_fiber_scheduler_current(),
        .fiber = rb_fiber_current(),
        .sequence = ++list->sequence,
        .deadline = deadline,
        .finite = finite,
        .linked = true,
        .notified = false,
    };
    if (list->last) list->last->next = &waiter;
    else list->first = &waiter;
    list->last = &waiter;
    list->count++;
    return RTEST(rb_ensure(farce_unshared_wait_body, (VALUE)&waiter, farce_unshared_wait_cleanup, (VALUE)&waiter));
}

static VALUE
farce_unshared_wait_wake(VALUE opaque)
{
    farce_unshared_waiter_t *waiter = (farce_unshared_waiter_t *)opaque;
    if (NIL_P(waiter->scheduler)) return rb_thread_wakeup_alive(waiter->thread);
    return rb_fiber_scheduler_unblock(waiter->scheduler, waiter->blocker, waiter->fiber);
}

static void
farce_unshared_wait_notify_all_body(farce_unshared_wait_list_t *list)
{
    uint64_t sequence = list->sequence;
    VALUE error = Qnil;
    int error_state = 0;
    while (list->first && list->first->sequence <= sequence) {
        farce_unshared_waiter_t *waiter = list->first;
        farce_unshared_wait_unlink(waiter);
        waiter->notified = true;
        /* Unblock may run Ruby, resume the waiter, yield, or raise. Never keep
         * a waiter pointer across it. Finish the original notification batch
         * before propagating an error, and leave newly registered waits alone. */
        int state = 0;
        rb_protect(farce_unshared_wait_wake, (VALUE)waiter, &state);
        if (state) {
            if (!error_state) {
                error = rb_errinfo();
                error_state = state;
            }
            rb_set_errinfo(Qnil);
        }
    }
    if (error_state) {
        rb_set_errinfo(error);
        rb_jump_tag(error_state);
    }
    RB_GC_GUARD(error);
}

static inline void
farce_unshared_wait_notify_all(farce_unshared_wait_list_t *list)
{
    if (list->first) farce_unshared_wait_notify_all_body(list);
}

#endif
