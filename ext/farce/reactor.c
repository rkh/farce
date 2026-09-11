#include "reactor.h"
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>
#include <poll.h>
#include <ruby/fiber/scheduler.h>

// Tell Ruby's garbage collector which Ruby objects one fiber's wait still needs.
static int mark_wait(st_data_t key, st_data_t value, st_data_t arg) {
    fs_wait *w = (fs_wait *)value;
    rb_gc_mark(w->fiber); rb_gc_mark(w->token); rb_gc_mark(w->value);
    rb_gc_mark(w->error); rb_gc_mark(w->groups); rb_gc_mark(w->ios);
    return ST_CONTINUE;
}

// Keep the scheduler's Ruby objects alive, including fibers that are starting or waiting.
static void mark(void *data) {
    fs_state *s = data;
    rb_gc_mark(s->root); rb_gc_mark(s->active);
    for (fs_admission *a = s->admission; a; a = a->previous) { rb_gc_mark(a->parent); rb_gc_mark(a->child); }
    rb_gc_mark(s->owner);
    rb_gc_mark(s->backend); rb_gc_mark(s->fallback);
    if (s->fibers) st_foreach(s->fibers, mark_wait, 0);
}

// Free a fiber's wait record and any extra IO watches it owns.
// The first watch is stored inside the record and needs no separate free.
static int free_wait(st_data_t key, st_data_t value, st_data_t arg) {
    fs_wait *w = (fs_wait *)value;
    fs_watch *watch = w->watches;
    while (watch) { fs_watch *next = watch->next_wait; if (watch != &w->first_watch) xfree(watch); watch = next; }
    xfree(w); return ST_CONTINUE;
}

// Free one descriptor registration while walking a registration table.
static int free_reg(st_data_t key, st_data_t value, st_data_t arg) {
    xfree((fs_reg *)value); return ST_CONTINUE;
}

// Close the driver and wake pipe, then discard all waits and registrations.
// The mutex prevents another thread from writing to the pipe while it closes.
// Keep the empty tables and slot storage for the final object cleanup.
static void release(fs_state *s) {
    pthread_mutex_lock(&s->wake_mutex);
    s->closed = 1;
    fs_driver_close(s);
    for (int i = 0; i < 2; i++) if (s->wake[i] >= 0) { close(s->wake[i]); s->wake[i] = -1; }
    pthread_mutex_unlock(&s->wake_mutex);
    s->pending = 0;
    s->slot_count = 0; s->first_free = UINT32_MAX;
    if (s->fibers) { st_foreach(s->fibers, free_wait, 0); st_clear(s->fibers); }
    if (s->regs) { st_foreach(s->regs, free_reg, 0); st_clear(s->regs); }
    if (s->generations) st_clear(s->generations);
    if (s->retired_regs) { st_foreach(s->retired_regs, free_reg, 0); st_clear(s->retired_regs); }
    s->polling_regs = 0;
    s->ready_head = s->ready_tail = NULL;
}

// Release native resources and free the scheduler's remaining storage
// when Ruby's garbage collector destroys the object.
static void free_state(void *data) {
    fs_state *s = data;
    release(s);
    xfree(s->slots);
    if (s->fibers) st_free_table(s->fibers);
    if (s->regs) st_free_table(s->regs);
    if (s->generations) st_free_table(s->generations);
    if (s->retired_regs) st_free_table(s->retired_regs);
    pthread_mutex_destroy(&s->wake_mutex);
    xfree(s);
}

// Add the space used by watches allocated outside their wait record.
static int count_watch_memory(st_data_t key, st_data_t value, st_data_t arg) {
    fs_wait *wait = (fs_wait *)value;
    size_t *size = (size_t *)arg;
    for (fs_watch *watch = wait->watches; watch; watch = watch->next_wait) if (watch != &wait->first_watch) *size += sizeof(*watch);
    return ST_CONTINUE;
}

// Report the scheduler's native memory use to Ruby's garbage collector.
static size_t memsize(const void *data) {
    const fs_state *s = data;
    size_t size = sizeof(*s) + (s->fibers ? st_memsize(s->fibers) + s->fibers->num_entries * sizeof(fs_wait) : 0) +
        s->slot_capacity * sizeof(fs_slot) +
        (s->regs ? st_memsize(s->regs) + s->regs->num_entries * sizeof(fs_reg) : 0) +
        (s->generations ? st_memsize(s->generations) : 0) +
        (s->retired_regs ? st_memsize(s->retired_regs) + s->retired_regs->num_entries * sizeof(fs_reg) : 0);
#ifdef HAVE_SYS_EVENT_H
    size += s->change_capacity * sizeof(struct kevent);
#endif
    if (s->fibers) st_foreach(s->fibers, count_watch_memory, (st_data_t)&size);
    return size;
}

// Describe how Ruby should mark, free, and measure the native scheduler object.
const rb_data_type_t fs_type = {
    .wrap_struct_name = "Farce::Internal::FiberScheduler",
    .function = {.dmark = mark, .dfree = free_state, .dsize = memsize},
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

// Create an empty scheduler in a closed state.
// Set safe defaults so cleanup also works if initialization fails.
static VALUE allocate(VALUE klass) {
    fs_state *s;
    VALUE self = TypedData_Make_Struct(klass, fs_state, &fs_type, s);
    s->active = s->root = s->owner = s->backend = s->fallback = Qnil;
    s->descriptor = s->wake[0] = s->wake[1] = -1;
    s->closed = 1;
    pthread_mutex_init(&s->wake_mutex, NULL);
    s->retired_regs = st_init_numtable();
    s->first_free = UINT32_MAX;
    s->regs = st_init_numtable(); s->generations = st_init_numtable();
    return self;
}

// Bind the scheduler to its thread and root fiber, then open the chosen driver.
// Register a nonblocking wake pipe so another thread can interrupt a driver wait.
static VALUE initialize(int argc, VALUE *argv, VALUE self) {
    VALUE options, backend = ID2SYM(rb_intern("auto"));
    rb_scan_args(argc, argv, "0:", &options);
    if (!NIL_P(options)) {
        ID keys[] = {rb_intern("backend")}; VALUE values[1];
        rb_get_kwargs(options, keys, 0, 1, values);
        if (values[0] != Qundef) backend = values[0];
    }
    fs_state *s = fs_get(self);
    if (!NIL_P(s->owner)) rb_raise(rb_eRuntimeError, "scheduler already initialized");
    s->owner = rb_thread_current();
    s->root = rb_fiber_current();
    s->fibers = st_init_numtable();
    int driver = 0;
    if (backend == ID2SYM(rb_intern("auto"))) {
#ifdef HAVE_SYS_EPOLL_H
        driver = FS_EPOLL; backend = ID2SYM(rb_intern("epoll"));
#elif defined(HAVE_SYS_EVENT_H)
        driver = FS_KQUEUE; backend = ID2SYM(rb_intern("kqueue"));
#endif
    } else if (backend == ID2SYM(rb_intern("epoll"))) driver = FS_EPOLL;
    else if (backend == ID2SYM(rb_intern("kqueue"))) driver = FS_KQUEUE;
    else if (backend == ID2SYM(rb_intern("io_uring"))) driver = FS_URING_DRIVER;
    else rb_raise(rb_eArgError, "unknown native scheduler backend");
    int error = fs_driver_init(s, driver);
    if (error) rb_syserr_fail(error, "requested fiber scheduler backend is unavailable");
    s->backend = backend;
    if (s->descriptor >= 0) fcntl(s->descriptor, F_SETFD, FD_CLOEXEC);
    if (pipe(s->wake) < 0) rb_sys_fail("scheduler wake pipe");
    for (int i = 0; i < 2; i++) {
        if (fcntl(s->wake[i], F_SETFD, FD_CLOEXEC) < 0 || fcntl(s->wake[i], F_SETFL, O_NONBLOCK) < 0)
            rb_sys_fail("scheduler wake flags");
    }
    fs_reg *reg = ZALLOC(fs_reg); reg->fd = s->wake[0];
    st_insert(s->regs, reg->fd, (st_data_t)reg);
    error = fs_driver_update(s, reg, FS_READ);
    if (error) rb_syserr_fail(error, "scheduler wake registration");
    s->closed = 0;
    return self;
}

// Find the live wait named by a token.
// Check both its slot and generation so an old token cannot name a reused wait.
fs_wait *fs_lookup(fs_state *s, VALUE token) {
    uint64_t identity;
#if SIZEOF_VALUE >= 8
    if (!FIXNUM_P(token) || FIX2LONG(token) < 0) return NULL;
    identity = FIX2ULONG(token);
#else
    // Keep the same generation lifetime on 32-bit Ruby. Tokens may be Bignums.
    if (!RB_INTEGER_TYPE_P(token)) return NULL;
    int sign = rb_integer_pack(token, &identity, 1, sizeof(identity), 0,
        INTEGER_PACK_NATIVE_BYTE_ORDER | INTEGER_PACK_LSWORD_FIRST);
    if (sign < 0 || sign > 1) return NULL;
#endif
    uint32_t index = (uint32_t)identity & FS_SLOT_MASK;
    if (index >= s->slot_count) return NULL;
    fs_wait *w = s->slots[index].wait;
#if SIZEOF_VALUE >= 8
    return w && w->token == token ? w : NULL;
#else
    return w && !NIL_P(w->token) && NUM2ULL(w->token) == identity ? w : NULL;
#endif
}

// Reject calls from the wrong thread or fiber, or after shutdown has begun.
// Normally this scheduler must also be installed on the thread.
void fs_check_fiber(VALUE self) {
    fs_state *s = fs_get(self);
    if (s->owner != rb_thread_current()) rb_raise(rb_eThreadError, "scheduler belongs to another thread");
    if (s->closed || s->stopping) rb_raise(rb_eIOError, "scheduler is closed");
    if (rb_fiber_current() != s->active)
        rb_raise(rb_const_get(rb_cObject, rb_intern("FiberError")), "operation requires an admitted fiber");
    if (!s->closing && rb_fiber_scheduler_get() != self)
        rb_raise(rb_const_get(rb_cObject, rb_intern("FiberError")), "scheduler must be installed");
}

// Check the current fiber, then create a token for its next wait.
VALUE fs_arm(VALUE self) {
    fs_check_fiber(self);
    return fs_arm_checked(self);
}

// Start a wait for a fiber the caller has already checked.
// Reuse its slot with a new generation and clear the previous result.
VALUE fs_arm_checked(VALUE self) {
    fs_state *s = fs_get(self);
    st_data_t entry;
    if (!st_lookup(s->fibers, (st_data_t)s->active, &entry)) rb_raise(rb_eRuntimeError, "missing native fiber state");
    fs_wait *w = (fs_wait *)entry;
    if (!NIL_P(w->token)) rb_raise(rb_eRuntimeError, "fiber already has a suspension");
    fs_slot *slot = &s->slots[w->slot];
    if (slot->generation == (UINT64_MAX >> (FS_SLOT_BITS + 2))) rb_raise(rb_eRangeError, "scheduler generation exhausted");
    VALUE token = ULL2NUM((++slot->generation << FS_SLOT_BITS) | w->slot);
    w->token = token; w->status = w->events = w->selected = w->native_error = 0;
    w->value = w->error = w->groups = w->ios = Qnil;
    s->pending++;
    return token;
}

// Return a fiber's active wait token, or nil if it has no wait.
static VALUE current_wait(VALUE self, VALUE fiber) {
    fs_state *s = fs_get(self);
    st_data_t entry;
    return s->fibers && st_lookup(s->fibers, (st_data_t)fiber, &entry) ? ((fs_wait *)entry)->token : Qnil;
}

// Add a wait to the end of the ready queue unless it is already queued.
// This preserves the order in which waits become ready.
static void ready_push(fs_state *s, fs_wait *w) {
    if (w->queued) return;
    w->queued = 1; w->ready_prev = s->ready_tail; w->ready_next = NULL;
    if (s->ready_tail) s->ready_tail->ready_next = w;
    else s->ready_head = w;
    s->ready_tail = w;
}

// Unlink a wait from the ready queue. Do nothing if it is not queued.
static void ready_remove(fs_state *s, fs_wait *w) {
    if (!w->queued) return;
    if (w->ready_prev) w->ready_prev->ready_next = w->ready_next;
    else s->ready_head = w->ready_next;
    if (w->ready_next) w->ready_next->ready_prev = w->ready_prev;
    else s->ready_tail = w->ready_prev;
    w->queued = 0; w->ready_prev = w->ready_next = NULL;
}

// Take the oldest ready wait from the queue, or return NULL if it is empty.
static fs_wait *ready_pop(fs_state *s) {
    fs_wait *w = s->ready_head;
    if (w) ready_remove(s, w);
    return w;
}

// Store a pending wait's result and queue its fiber to run.
// Ignore old tokens and waits that already have a result.
VALUE fs_resume(VALUE self, VALUE token, VALUE value, VALUE error) {
    fs_state *s = fs_get(self); fs_wait *w = fs_lookup(s, token);
    if (!w || w->status != 0) return Qfalse;
    w->status = 1; w->value = value; w->error = error;
    ready_push(s, w); return Qtrue;
}

// Accept Ruby arguments for resuming a wait, including an optional exception.
static VALUE resume_method(int argc, VALUE *argv, VALUE self) {
    VALUE token, value, error; rb_scan_args(argc, argv, "21", &token, &value, &error);
    return fs_resume(self, token, value, error);
}

// Give a wait an exception and make its fiber ready to run.
// An exception can replace a queued result until that result has been dispatched.
static VALUE interrupt(VALUE self, VALUE token, VALUE error) {
    fs_state *s = fs_get(self); fs_wait *w = fs_lookup(s, token);
    if (!w || w->status == 2) return Qfalse;
    if (!w->status) ready_push(s, w);
    w->status = 1; w->error = error; return Qtrue;
}

// Declare the closed-IO check used below to detect descriptor reuse.
static int closed_io(VALUE io);

// Attach an IO watch to both its wait and its descriptor registration.
// If the descriptor number was reused after a close, fail the old waits
// and create a separate registration for the new IO.
void fs_watch_io(fs_state *s, fs_wait *w, int fd, int events, int group, long index) {
    st_data_t entry;
    fs_reg *reg;
    reg = st_lookup(s->regs, fd, &entry) ? (fs_reg *)entry : NULL;
    if (reg) {
        for (fs_watch *old = reg->watches; old; old = old->next_reg) {
            if (!closed_io(old->wait->ios)) continue;
            // Ruby 3.4 has no io_close hook. A closed IO still identifies the
            // previous fd generation even if a newly opened IO reused its number.
            fs_driver_update(s, reg, 0);
            st_data_t key = fd; st_delete(s->regs, &key, NULL);
            st_insert(s->retired_regs, (st_data_t)reg, (st_data_t)reg);
            reg->fd = -1;
            for (fs_watch *item = reg->watches; item; item = item->next_reg) {
                fs_wait *wait = item->wait;
                if (!wait->status) {
                    wait->error = rb_exc_new_cstr(rb_eIOError, "IO descriptor was closed and reused");
                    wait->status = 1; ready_push(s, wait);
                }
            }
            reg = NULL;
            break;
        }
    }
    if (!reg) {
        reg = ZALLOC(fs_reg); reg->fd = fd;
        st_insert(s->regs, fd, (st_data_t)reg);
    }
    fs_watch *watch = w->watches ? ZALLOC(fs_watch) : &w->first_watch;
    watch->wait = w; watch->reg = reg; watch->events = events; watch->group = group; watch->index = index;
    watch->next_wait = w->watches; w->watches = watch;
    watch->next_reg = reg->watches; reg->watches = watch;
    if ((reg->events | events) != reg->events) {
        int error = fs_driver_update(s, reg, reg->events | events);
        if (error) rb_syserr_fail(error, "scheduler registration");
    }
}

// Finish a wait and remove its watches and ready-queue entry.
// A pending receive must stop using the buffer before cleanup can continue.
// Clear Ruby references and keep the fiber's slot available for its next wait.
VALUE fs_retire(VALUE self, VALUE token) {
    fs_state *s = fs_get(self); fs_wait *w = fs_lookup(s, token);
    if (!w) return Qnil;
    if (w->receive_pending) fs_cancel_receive(self, w);
    ready_remove(s, w);
    fs_watch *watch = w->watches;
    while (watch) {
        fs_watch *next = watch->next_wait;
        fs_reg *reg = watch->reg;
        fs_watch **cursor = &reg->watches;
        while (*cursor && *cursor != watch) cursor = &(*cursor)->next_reg;
        if (*cursor) *cursor = watch->next_reg;
        int events = 0;
        for (fs_watch *item = reg->watches; item; item = item->next_reg) events |= item->events;
        if (events != reg->events && !s->closed) fs_driver_update(s, reg, events);
        if (!events && reg->poll_events) { s->polling_regs--; reg->poll_events = 0; }
        if (!events && (reg->fd < 0 || s->regs->num_entries > 4096)) {
            st_data_t key = reg->fd; st_delete(s->regs, &key, NULL);
            key = reg->generation; st_delete(s->generations, &key, NULL);
            key = (st_data_t)reg; st_delete(s->retired_regs, &key, NULL);
            if (reg->poll_events) s->polling_regs--;
            xfree(reg);
        }
        if (watch != &w->first_watch) xfree(watch);
        watch = next;
    }
    s->pending--;
    w->token = w->value = w->error = w->groups = w->ios = Qnil;
    w->watches = NULL;
    memset(&w->first_watch, 0, sizeof(w->first_watch));
    return Qnil;
}

// Switch from the root to a ready fiber.
// If a newly started child finishes, return control to its waiting parent
// before returning to the root dispatcher.
static VALUE transfer_to(fs_state *s, VALUE fiber) {
    s->active = fiber;
    VALUE result = rb_fiber_transfer(fiber, 0, NULL);
    s->active = Qnil;
    // A transferred fiber returns to the thread root when its block finishes.
    // Complete nested immediate admissions before returning to the driver.
    while (s->admission && s->admission->parent != s->root) {
        s->active = s->admission->parent;
        result = rb_fiber_transfer(s->admission->parent, 0, NULL);
        s->active = Qnil;
    }
    return result;
}

// Switch into a newly admitted fiber from the root or from its parent fiber.
static VALUE start_body(VALUE data) {
    VALUE *args = (VALUE *)data;
    fs_state *s = fs_get(args[0]);
    if (rb_fiber_current() == s->root) return transfer_to(s, args[1]);
    s->active = args[1];
    return rb_fiber_transfer(args[1], 0, NULL);
}

// Restore the parent fiber and remove the admission record after starting a child,
// including when the child raises.
static VALUE start_cleanup(VALUE data) {
    VALUE *args = (VALUE *)data;
    fs_state *s = fs_get(args[0]);
    s->active = s->admission->parent == s->root ? Qnil : s->admission->parent;
    s->admission = s->admission->previous;
    return Qnil;
}

// Give a new fiber a reusable wait slot and run it immediately.
// Track its parent so a nested start returns to the right fiber.
static VALUE start_fiber(VALUE self, VALUE fiber) {
    fs_state *s = fs_get(self);
    uint32_t index;
    if (s->first_free != UINT32_MAX) {
        index = s->first_free; s->first_free = s->slots[index].next_free;
    } else {
        if (s->slot_count > FS_SLOT_MASK) rb_raise(rb_eRangeError, "too many admitted scheduler fibers");
        if (s->slot_count == s->slot_capacity) {
            uint32_t capacity = s->slot_capacity ? s->slot_capacity * 2 : 64;
            REALLOC_N(s->slots, fs_slot, capacity);
            memset(s->slots + s->slot_capacity, 0, (capacity - s->slot_capacity) * sizeof(fs_slot));
            s->slot_capacity = capacity;
        }
        index = s->slot_count++;
    }
    fs_wait *w = ZALLOC(fs_wait); w->slot = index; s->slots[index].wait = w;
    w->fiber = fiber; w->token = w->value = w->error = w->groups = w->ios = Qnil;
    st_insert(s->fibers, (st_data_t)fiber, (st_data_t)w);
    fs_admission admission = {rb_fiber_current(), fiber, s->admission};
    s->admission = &admission;
    VALUE args[] = {self, fiber};
    return rb_ensure(start_body, (VALUE)args, start_cleanup, (VALUE)args);
}

// Declare the nonblocking poll used when switching between ready fibers.
static void poll_ready(VALUE self);

// Suspend the current fiber and choose where control goes next.
// Return to its parent during startup, or run another ready fiber within the budget.
// When this fiber resumes, return its wait result or raise its recorded error.
static VALUE park_body(VALUE data) {
    VALUE *args = (VALUE *)data;
    fs_state *s = fs_get(args[0]);
    VALUE current = rb_fiber_current(), next = s->root;
    if (s->admission && s->admission->child == current) next = s->admission->parent;
    else if (s->dispatch_left > 0 && !s->policy_pending) {
        if (!s->ready_head && s->allow_poll) poll_ready(args[0]);
        while (s->ready_head && !s->policy_pending) {
            fs_wait *ready = s->ready_head;
            if (ready->fiber == current) break;
            ready_pop(s);
            if (ready->status != 1) continue;
            ready->status = 2; s->dispatch_left--;
            next = ready->fiber;
            break;
        }
    }
    s->active = next == s->root ? Qnil : next;
    rb_fiber_transfer(next, 0, NULL);
    s->active = current;
    fs_wait *w = fs_lookup(fs_get(args[0]), args[1]);
    if (!w) rb_raise(rb_eRuntimeError, "retired scheduler suspension");
    if (!NIL_P(w->error)) rb_exc_raise(w->error);
    if (w->native_error) rb_syserr_fail(w->native_error, "scheduler completion");
    return w->value;
}

// Retire the wait after a parked fiber resumes or raises.
static VALUE park_ensure(VALUE data) {
    VALUE *args = (VALUE *)data; return fs_retire(args[0], args[1]);
}

// Suspend a fiber while leaving wait cleanup to the caller.
// Buffer transfers use this to keep cleanup in their outer protected scope.
VALUE fs_suspend(VALUE self, VALUE token) {
    fs_get(self)->suspensions++;
    VALUE args[] = {self, token}; return park_body((VALUE)args);
}

// Suspend a fiber and always retire its wait when control returns or raises.
VALUE fs_park(VALUE self, VALUE token) {
    fs_get(self)->suspensions++;
    VALUE args[] = {self, token}; return rb_ensure(park_body, (VALUE)args, park_ensure, (VALUE)args);
}

// Give other fibers a turn after 64 operations complete without waiting.
// Return the original value once this fiber runs again.
VALUE fs_checkpoint(VALUE self, VALUE value) {
    fs_state *s = fs_get(self);
    if (++s->immediate >= 64) {
        s->immediate = 0;
        VALUE token = fs_arm(self);
        fs_resume(self, token, Qnil, Qnil);
        fs_park(self, token);
    }
    return value;
}

// Watch each IO in the read, write, and priority groups for an IO.select call.
// Keep the original groups so the result can return the caller's objects.
static VALUE register_select(VALUE self, VALUE token, VALUE groups, VALUE ios) {
    fs_state *s = fs_get(self); fs_wait *w = fs_lookup(s, token);
    w->groups = groups; w->ios = ios;
    for (int i = 0; i < 3; i++) {
        VALUE list = rb_ary_entry(ios, i);
        for (long j = 0; j < RARRAY_LEN(list); j++)
            fs_watch_io(s, w, rb_io_descriptor(rb_ary_entry(list, j)), i == 0 ? FS_READ : i == 1 ? FS_WRITE : FS_PRI, i, j);
    }
    return Qnil;
}

// Report whether any wait is queued to run.
static VALUE ready(VALUE self) { return fs_get(self)->ready_head ? Qtrue : Qfalse; }

// Report whether any wait is still active, including waits already queued to run.
static VALUE pending(VALUE self) { return fs_get(self)->pending ? Qtrue : Qfalse; }

// Return the number of waits that have not yet been retired.
static VALUE pending_count(VALUE self) { return SIZET2NUM(fs_get(self)->pending); }

// Ask the dispatcher to return to Ruby policy code and wake a blocked driver.
// Guard the pipe write so another thread can safely call this during shutdown.
static VALUE wakeup(VALUE self) {
    fs_state *s = fs_get(self); char byte = 0;
    s->policy_pending = 1;
    pthread_mutex_lock(&s->wake_mutex);
    if (!s->closed) { ssize_t result = write(s->wake[1], &byte, 1); (void)result; }
    pthread_mutex_unlock(&s->wake_mutex);
    return Qtrue;
}

// Turn recorded readiness into a wait result.
// IO.select needs a fresh grouped snapshot to preserve Ruby's result format.
static int settle(st_data_t key, st_data_t value, st_data_t arg) {
    fs_wait *w = (fs_wait *)value;
    if (!w->selected || w->status) return ST_CONTINUE;
    VALUE self = (VALUE)arg;
    if (NIL_P(w->groups)) fs_resume(self, w->token, INT2NUM(w->events), Qnil);
    else {
        VALUE found = rb_funcall(self, rb_intern("select_result"), 3, w->groups, w->ios, INT2NUM(0));
        if (!NIL_P(found)) fs_resume(self, w->token, found, Qnil);
    }
    w->events = w->selected = 0;
    return ST_CONTINUE;
}

// Check whether an IO is closed.
// Also accept nested arrays so the same check works for IO.select groups.
static int closed_io(VALUE io) {
    if (RB_TYPE_P(io, T_ARRAY)) {
        for (long i = 0; i < RARRAY_LEN(io); i++) if (closed_io(rb_ary_entry(io, i))) return 1;
        return 0;
    }
    return RB_TYPE_P(io, T_FILE) && (!RFILE(io)->fptr || RTEST(rb_io_closed_p(io)));
}

// Give a pending wait an IOError if any of its IO objects has closed.
static int cancel_closed(st_data_t key, st_data_t value, st_data_t arg) {
    fs_wait *w = (fs_wait *)value;
    if (!w->status && !NIL_P(w->ios) && closed_io(w->ios))
        interrupt((VALUE)arg, w->token, rb_exc_new_cstr(rb_eIOError, "stream closed while waiting"));
    return ST_CONTINUE;
}

// Check priority events with poll when the driver cannot report them directly.
// Record readiness or interrupt waits whose descriptor has become invalid.
static int snapshot_fallback(st_data_t key, st_data_t value, st_data_t arg) {
    fs_reg *reg = (fs_reg *)value;
    if (!(reg->poll_events & reg->events)) return ST_CONTINUE;
    struct pollfd fd = {.fd = reg->fd, .events = POLLPRI};
    int result = poll(&fd, 1, 0);
    if (result < 0 && errno != EINTR) rb_sys_fail("scheduler compatibility snapshot");
    for (fs_watch *watch = reg->watches; watch; watch = watch->next_reg) {
        fs_wait *w = watch->wait;
        if (w->status) continue;
        if (fd.revents & POLLNVAL)
            interrupt((VALUE)arg, w->token, rb_exc_new_cstr(rb_eIOError, "stream closed while waiting"));
        else if ((fd.revents & POLLPRI) && (watch->events & FS_PRI)) {
            w->selected = 1; w->events |= FS_PRI;
        }
    }
    return ST_CONTINUE;
}

// Match a driver event to its live wait or descriptor registration.
// Ignore old generations, queue ready fibers, and record grouped IO.select events.
// Wake-pipe events ask the dispatcher to return to Ruby policy code.
static void accept_event(VALUE self, fs_event *e) {
    fs_state *s = fs_get(self);
    if (e->generation & FS_RECEIVE) {
        fs_wait *w = fs_lookup(s, ULL2NUM(e->generation & ~FS_RECEIVE));
        if (!w) return;
        w->receive_pending = 0;
        if (!w->status) fs_resume(self, w->token, INT2NUM(e->error), Qnil);
        return;
    }
    st_data_t entry;
    if (!st_lookup(s->generations, e->generation, &entry)) return;
    fs_reg *reg = (fs_reg *)entry;
    if (reg->fd == s->wake[0]) {
        char buffer[4096]; while (read(s->wake[0], buffer, sizeof(buffer)) > 0) {}
        s->policy_pending = 1;
    } else {
        for (fs_watch *watch = reg->watches; watch; watch = watch->next_reg) {
            fs_wait *w = watch->wait;
            if (w->status) continue;
            if (e->error) {
                w->native_error = e->error;
                fs_resume(self, w->token, Qnil, Qnil);
            } else if (watch->events & e->events) {
                if (NIL_P(w->groups)) fs_resume(self, w->token, INT2FIX(watch->events & e->events), Qnil);
                else { w->selected = 1; w->events |= watch->events & e->events; s->selected_pending = 1; }
            }
        }
    }
    if (s->driver == FS_URING_DRIVER) reg->events = 0;
}

// Restore io_uring readiness watches after their one-time notifications fire.
// Only keep watching events that still have pending waiters.
static void rearm_events(fs_state *s) {
#ifdef FARCE_URING
    if (s->driver != FS_URING_DRIVER) return;
    for (int i = 0; i < s->event_count; i++) {
        st_data_t entry;
        if (!st_lookup(s->generations, s->events[i].generation, &entry)) continue;
        fs_reg *reg = (fs_reg *)entry;
        if (reg->events) continue;
        int events = reg->fd == s->wake[0] ? FS_READ : 0;
        for (fs_watch *watch = reg->watches; watch; watch = watch->next_reg)
            if (!watch->wait->status) events |= watch->events;
        if (!events) continue;
        int error = fs_driver_update(s, reg, events);
        if (error) { s->poll_error = error; s->policy_pending = 1; return; }
    }
#endif
}

// Collect driver events without waiting and restore any io_uring watches.
// Ask Ruby policy code to run if there is an error or an IO.select result to build.
static void poll_ready(VALUE self) {
    fs_state *s = fs_get(self);
    s->timeout = 0;
    fs_driver_poll(s);
    for (int i = 0; i < s->event_count; i++) accept_event(self, &s->events[i]);
    rearm_events(s);
    if (s->poll_error || s->selected_pending) s->policy_pending = 1;
}

// Cancel an io_uring receive and wait until the original operation has finished.
// Keep the caller's buffer locked throughout, because a cancellation reply alone
// does not prove the kernel has stopped writing to it.
void fs_cancel_receive(VALUE self, fs_wait *w) {
#ifdef FARCE_URING
    fs_state *s = fs_get(self);
    struct io_uring_sqe *entry = io_uring_get_sqe(&s->ring);
    if (!entry) {
        int result;
        do { result = io_uring_submit(&s->ring); } while (result == -EINTR);
        if (result < 0) rb_bug("cannot submit pending scheduler receive");
        entry = io_uring_get_sqe(&s->ring);
        if (!entry) rb_bug("cannot reserve scheduler cancellation");
    }
    io_uring_prep_cancel64(entry, FS_RECEIVE | NUM2ULL(w->token), 0);
    entry->user_data = 0;
    // Wait for the original receive CQE, not just the cancellation CQE. No Ruby
    // fiber runs here, and the caller's buffer remains locked throughout.
    while (w->receive_pending) {
        int result = io_uring_submit_and_wait(&s->ring, 1);
        if (result < 0 && result != -EINTR) rb_bug("cannot acknowledge scheduler receive cancellation");
        s->timeout = 0;
        fs_driver_poll(s);
        if (s->poll_error && s->poll_error != EINTR) rb_bug("cannot drain scheduler receive cancellation");
        for (int i = 0; i < s->event_count; i++) accept_event(self, &s->events[i]);
        rearm_events(s);
    }
#endif
}

// Call a helper for every active wait, skipping empty slots and idle fibers.
static void each_wait(fs_state *s, int (*callback)(st_data_t, st_data_t, st_data_t), st_data_t arg) {
    for (uint32_t i = 0; i < s->slot_count; i++) {
        fs_wait *w = s->slots[i].wait;
        if (w && !NIL_P(w->token)) callback((st_data_t)w->token, (st_data_t)w, arg);
    }
}

// Collect IO events and run ready fibers up to the requested budget.
// Release Ruby's VM lock if the driver needs to wait.
// Return to Ruby policy code for timers, notifications, or shutdown work.
static VALUE dispatch(VALUE self, VALUE timeout, VALUE budget) {
    rb_funcall(self, rb_intern("check_root"), 0);
    fs_state *s = fs_get(self);
    if (s->closed) rb_raise(rb_eIOError, "scheduler is closed");
    int limit = NUM2INT(budget), polled = 0;
    s->policy_pending = 0;
    s->allow_poll = NIL_P(timeout);
    if (s->selected_pending) {
        s->selected_pending = 0;
        each_wait(s, settle, (st_data_t)self);
    }
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double seconds = now.tv_sec + now.tv_nsec * 1e-9;
    if (seconds >= s->close_check_at) {
        each_wait(s, cancel_closed, (st_data_t)self);
        s->close_check_at = seconds + 0.05;
    }
    if (s->ready_head && ++s->ready_batches < 4) goto drain_ready;
    s->ready_batches = 0;
    s->timeout = s->ready_head ? 0 : NIL_P(timeout) ? -1 : NUM2DBL(timeout);
    // Closing an IO in another thread can remove its OS registration without
    // delivering an event. Bound the interval before checking Ruby IO ownership.
    if (s->pending && (s->timeout < 0 || s->timeout > 0.05)) s->timeout = 0.05;
    polled = 1;
    double blocking_timeout = s->timeout;
    s->timeout = 0;
    fs_driver_poll(s);
    if (!s->event_count && !s->poll_error && blocking_timeout != 0) {
        s->timeout = blocking_timeout;
        rb_thread_call_without_gvl(fs_driver_poll, s, RUBY_UBF_IO, NULL);
    }
    if (s->poll_error && s->poll_error != EINTR) rb_syserr_fail(s->poll_error, "scheduler poll");
    for (int i = 0; i < s->event_count; i++) accept_event(self, &s->events[i]);
    if (s->polling_regs) st_foreach(s->regs, snapshot_fallback, (st_data_t)self);
    // Only IO.select needs a grouped snapshot. Ordinary readiness is settled
    // directly from the event above instead of scanning all pending waits.
    if (s->polling_regs || s->selected_pending) {
        s->selected_pending = 0;
        each_wait(s, settle, (st_data_t)self);
    }
drain_ready:;
    if (polled) rearm_events(s);
    s->dispatch_left = limit;
    while (s->dispatch_left > 0 && !s->policy_pending) {
        fs_wait *w = ready_pop(s);
        if (!w && s->allow_poll && s->pending) {
            poll_ready(self);
            if (!s->policy_pending) w = ready_pop(s);
        }
        if (!w) break;
        if (w->status != 1) continue;
        w->status = 2;
        s->dispatch_left--;
        transfer_to(s, w->fiber);
    }
    int count = limit - s->dispatch_left;
    s->dispatch_left = 0;
    if (s->poll_error && s->poll_error != EINTR) rb_syserr_fail(s->poll_error, "scheduler poll");
    return INT2NUM(count);
}

// Release the scheduler's native resources and clear its active fiber.
// The Ruby object remains available for the rest of shutdown.
static VALUE destroy(VALUE self) {
    fs_state *s = fs_get(self); release(s); s->active = Qnil;
    if (s->fibers) st_clear(s->fibers);
    s->ready_head = s->ready_tail = NULL;
    return Qnil;
}

// Remove a finished fiber's wait record and return its slot to the free list.
// Retire any remaining wait before freeing the record.
static VALUE finish_fiber(VALUE self) {
    fs_state *s = fs_get(self);
    st_data_t key = rb_fiber_current(), entry;
    if (st_lookup(s->fibers, key, &entry)) {
        fs_wait *w = (fs_wait *)entry;
        if (!NIL_P(w->token)) fs_retire(self, w->token);
        st_delete(s->fibers, &key, NULL);
        s->slots[w->slot].wait = NULL;
        s->slots[w->slot].next_free = s->first_free;
        s->first_free = w->slot;
        xfree(w);
    }
    s->active = Qnil;
    return Qnil;
}

// Allow up to 4096 fiber dispatches before returning to Ruby policy code.
static VALUE dispatch_budget(VALUE self) { return INT2FIX(4096); }

// End the current dispatch batch so Ruby can process a policy change.
static VALUE policy_changed(VALUE self) { fs_get(self)->policy_pending = 1; return Qnil; }

// Allow admitted fibers to finish while Ruby removes this scheduler from the thread.
static VALUE begin_close(VALUE self) { fs_get(self)->closing = 1; return Qnil; }

// Reject new waits and stop the current dispatch batch for shutdown.
static VALUE begin_shutdown(VALUE self) {
    fs_state *s = fs_get(self); s->stopping = 1; s->dispatch_left = 0; return Qnil;
}

// Return the name of the driver selected during initialization.
static VALUE backend(VALUE self) { return fs_get(self)->backend; }

// Return the recorded fallback reason, or nil when there is none.
static VALUE fallback(VALUE self) { return fs_get(self)->fallback; }

// Reject dup and clone because native scheduler resources have a single owner.
static VALUE no_copy(int argc, VALUE *argv, VALUE self) { rb_raise(rb_eTypeError, "scheduler ownership cannot be copied"); }

// Define the native scheduler class and connect its Ruby methods to these C functions.
// Include the shared Ruby IO helpers and install the native IO hooks.
void farce_init_fiber_scheduler(VALUE internal) {
    // Each scheduler owns its mutable driver and wait state.
    VALUE klass = rb_define_class_under(internal, "FiberScheduler", rb_cObject);
    rb_include_module(klass, rb_const_get(internal, rb_intern("SchedulerIO")));
    rb_define_alloc_func(klass, allocate);
    rb_define_private_method(klass, "initialize", initialize, -1);
    rb_define_private_method(klass, "initialize_copy", no_copy, -1);
    rb_define_private_method(klass, "policy_changed", policy_changed, 0);
    rb_define_private_method(klass, "dispatch_budget", dispatch_budget, 0);
    rb_define_private_method(klass, "finish_fiber", finish_fiber, 0);
    rb_define_private_method(klass, "begin_close", begin_close, 0);
    rb_define_private_method(klass, "begin_shutdown", begin_shutdown, 0);
    rb_define_private_method(klass, "start_fiber", start_fiber, 1);
    rb_define_private_method(klass, "arm_wait", fs_arm, 0);
    rb_define_private_method(klass, "current_wait", current_wait, 1);
    rb_define_private_method(klass, "park_current", fs_park, 1);
    rb_define_private_method(klass, "resume_wait", resume_method, -1);
    rb_define_private_method(klass, "interrupt_wait", interrupt, 2);
    rb_define_private_method(klass, "retire_wait", fs_retire, 1);
    rb_define_private_method(klass, "register_select", register_select, 3);
    rb_define_private_method(klass, "ready?", ready, 0);
    rb_define_private_method(klass, "pending?", pending, 0);
    rb_define_private_method(klass, "pending_count", pending_count, 0);
    rb_define_private_method(klass, "wakeup", wakeup, 0);
    rb_define_private_method(klass, "dispatch", dispatch, 2);
    rb_define_private_method(klass, "destroy", destroy, 0);
    rb_define_method(klass, "backend", backend, 0);
    rb_define_method(klass, "fallback_reason", fallback, 0);
    fs_init_io(klass);
}
