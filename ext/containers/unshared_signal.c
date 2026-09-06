#include "unshared_io_pool.h"

static VALUE cUnsharedSignal;
static VALUE cUnsharedIOSignal;
static VALUE cUnsharedBlockSignal;

struct containers_unshared_signal {
    farce_unshared_wait_list_t waiters;
    uint64_t generation;
    farce_io_pool_t fiber_pool;
    size_t fiber_waiters;
    bool initialized;
    bool fiber_io;
};

static void
unshared_signal_mark(void *pointer)
{
    containers_unshared_signal_t *signal = pointer;
    farce_unshared_wait_mark(&signal->waiters);
    farce_io_pool_mark(&signal->fiber_pool);
}

static void
unshared_signal_free(void *pointer)
{
    containers_unshared_signal_t *signal = pointer;
    farce_io_pool_free(&signal->fiber_pool);
    ruby_xfree(signal);
}

static size_t
unshared_signal_memsize(const void *pointer)
{
    const containers_unshared_signal_t *signal = pointer;
    return signal ? sizeof(*signal) + signal->fiber_pool.size * sizeof(farce_io_slot_t) : 0;
}

static const rb_data_type_t unshared_signal_type = {
    .wrap_struct_name = "Farce::Internal::UnsharedSignal",
    .function = {
        .dmark = unshared_signal_mark,
        .dfree = unshared_signal_free,
        .dsize = unshared_signal_memsize,
    },
};

static VALUE
unshared_signal_allocate_mode(VALUE klass, bool fiber_io)
{
    containers_unshared_signal_t *signal;
    VALUE self = TypedData_Make_Struct(klass, containers_unshared_signal_t, &unshared_signal_type, signal);
    signal->fiber_io = fiber_io;
    return self;
}

static VALUE unshared_signal_allocate(VALUE klass) { return unshared_signal_allocate_mode(klass, FARCE_UNSHARED_FIBER_IO); }
static VALUE unshared_io_signal_allocate(VALUE klass) { return unshared_signal_allocate_mode(klass, true); }
static VALUE unshared_block_signal_allocate(VALUE klass) { return unshared_signal_allocate_mode(klass, false); }

static containers_unshared_signal_t *
unshared_signal_get(VALUE self)
{
    containers_unshared_signal_t *signal;
    TypedData_Get_Struct(self, containers_unshared_signal_t, &unshared_signal_type, signal);
    if (!signal->initialized) rb_raise(rb_eRuntimeError, "uninitialized Signal");
    return signal;
}

/* Only the built-in classes bypass Ruby dispatch. Further subclasses retain
 * ordinary protocol dispatch, including overrides. */
containers_unshared_signal_t *
containers_unshared_signal_get_if_exact(VALUE self)
{
    VALUE klass = CLASS_OF(self);
    return klass == cUnsharedSignal || klass == cUnsharedIOSignal || klass == cUnsharedBlockSignal ?
        unshared_signal_get(self) : NULL;
}

bool
containers_unshared_fiber_io(VALUE mode)
{
    if (mode == Qundef || mode == ID2SYM(rb_intern("auto"))) return FARCE_UNSHARED_FIBER_IO;
    if (mode == ID2SYM(rb_intern("io"))) return true;
    if (mode == ID2SYM(rb_intern("block"))) return false;
    rb_raise(rb_eArgError, "fiber_wait must be :auto, :io, or :block");
}

/* Comparison-lock contention follows even a user subclass's native waiting
 * policy. Inspecting it here never calls Ruby during queue publication. */
bool
containers_unshared_signal_uses_fiber_io(VALUE self)
{
    if (!rb_typeddata_is_kind_of(self, &unshared_signal_type)) return FARCE_UNSHARED_FIBER_IO;
    return unshared_signal_get(self)->fiber_io;
}

static VALUE
unshared_signal_for(VALUE klass, VALUE mode)
{
    (void)klass;
    bool fiber_io = containers_unshared_fiber_io(mode);
    VALUE selected = mode == ID2SYM(rb_intern("auto")) ? cUnsharedSignal :
        (fiber_io ? cUnsharedIOSignal : cUnsharedBlockSignal);
    return rb_class_new_instance(0, NULL, selected);
}

static VALUE
unshared_signal_fiber_wait(VALUE self)
{
    return ID2SYM(rb_intern(unshared_signal_get(self)->fiber_io ? "io" : "block"));
}

bool
containers_unshared_signal_has_waiters(containers_unshared_signal_t *signal)
{
    return signal->waiters.count != 0 || signal->fiber_waiters != 0;
}

void
containers_unshared_signal_notify(containers_unshared_signal_t *signal)
{
    signal->generation++;
    /* Pipe notification does not call Ruby. Notify fibers before direct
     * scheduler callbacks, which may yield or raise. */
    if (signal->fiber_waiters) farce_io_pool_notify(&signal->fiber_pool);
    farce_unshared_wait_notify_all(&signal->waiters);
}

static VALUE
unshared_signal_initialize(VALUE self)
{
    containers_unshared_signal_t *signal;
    TypedData_Get_Struct(self, containers_unshared_signal_t, &unshared_signal_type, signal);
    if (signal->initialized) rb_raise(rb_eRuntimeError, "Signal is already initialized");
    rb_check_frozen(self);
    signal->initialized = true;
    rb_obj_freeze(self);
    return self;
}

static VALUE
unshared_signal_initialize_copy(VALUE self, VALUE other)
{
    (void)self;
    (void)other;
    rb_raise(rb_eTypeError, "cannot copy Signal");
}

static VALUE
unshared_signal_generation(VALUE self)
{
    return ULL2NUM(unshared_signal_get(self)->generation);
}

static VALUE
unshared_signal_num_waiting(VALUE self)
{
    containers_unshared_signal_t *signal = unshared_signal_get(self);
    return SIZET2NUM(signal->waiters.count + signal->fiber_waiters);
}

static VALUE
unshared_signal_broadcast(VALUE self)
{
    containers_unshared_signal_t *signal = unshared_signal_get(self);
    uint64_t generation = signal->generation + 1;
    containers_unshared_signal_notify(signal);
    return ULL2NUM(generation);
}

typedef struct {
    containers_unshared_signal_t *signal;
    uint64_t observed;
    double deadline;
    bool finite;
} unshared_signal_fiber_wait_t;

static bool
unshared_signal_fiber_ready(void *opaque)
{
    unshared_signal_fiber_wait_t *wait = opaque;
    return wait->signal->generation != wait->observed;
}

static VALUE
unshared_signal_fiber_wait_body(VALUE opaque)
{
    unshared_signal_fiber_wait_t *wait = (unshared_signal_fiber_wait_t *)opaque;
    return farce_io_pool_wait(&wait->signal->fiber_pool, wait->finite, wait->deadline,
                              unshared_signal_fiber_ready, wait) ? Qtrue : Qfalse;
}

static VALUE
unshared_signal_fiber_wait_cleanup(VALUE opaque)
{
    unshared_signal_fiber_wait_t *wait = (unshared_signal_fiber_wait_t *)opaque;
    wait->signal->fiber_waiters--;
    return Qnil;
}

static VALUE
unshared_signal_wait(int argc, VALUE *argv, VALUE self)
{
    VALUE observed_value = Qnil;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "01:", &observed_value, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    bool snapshot_at_entry = NIL_P(observed_value);
    uint64_t observed = snapshot_at_entry ? 0 : NUM2ULL(observed_value);
    VALUE timeout = keyword_values[0] == Qundef ? Qnil : keyword_values[0];
    bool finite = !NIL_P(timeout);
    double deadline = 0;
    if (finite) {
        double seconds = NUM2DBL(timeout);
        if (!isfinite(seconds) || seconds < 0) {
            rb_raise(rb_eArgError, "timeout must be a finite, non-negative number or nil");
        }
        deadline = farce_unshared_wait_now() + seconds;
    }
    containers_unshared_signal_t *signal = unshared_signal_get(self);
    if (snapshot_at_entry) observed = signal->generation;

    /* Coercion above may run Ruby. The generation check and registration below
     * run together under the GVL, so a broadcast cannot slip between them. */
    while (signal->generation == observed) {
        if (finite && farce_unshared_wait_now() >= deadline) {
            return rb_block_given_p() ? rb_yield_values(0) : Qnil;
        }
        if (signal->fiber_io && !NIL_P(rb_fiber_scheduler_current())) {
            /* Reuse owned pipe objects after each scheduler wait unwinds. */
            unshared_signal_fiber_wait_t wait = {signal, observed, deadline, finite};
            signal->fiber_waiters++;
            rb_ensure(unshared_signal_fiber_wait_body, (VALUE)&wait,
                      unshared_signal_fiber_wait_cleanup, (VALUE)&wait);
        }
        else farce_unshared_wait(&signal->waiters, self, finite, deadline);
    }
    return ULL2NUM(signal->generation);
}

void
containers_init_unshared_signal(VALUE namespace)
{
    rb_define_const(namespace, "UNSHARED_FIBER_IO", FARCE_UNSHARED_FIBER_IO ? Qtrue : Qfalse);
    cUnsharedSignal = rb_define_class_under(namespace, "UnsharedSignal", rb_cObject);
    rb_define_alloc_func(cUnsharedSignal, unshared_signal_allocate);
    cUnsharedIOSignal = rb_define_class_under(namespace, "UnsharedIOSignal", cUnsharedSignal);
    rb_define_alloc_func(cUnsharedIOSignal, unshared_io_signal_allocate);
    cUnsharedBlockSignal = rb_define_class_under(namespace, "UnsharedBlockSignal", cUnsharedSignal);
    rb_define_alloc_func(cUnsharedBlockSignal, unshared_block_signal_allocate);
    rb_define_singleton_method(cUnsharedSignal, "for", unshared_signal_for, 1);
    rb_define_method(cUnsharedSignal, "fiber_wait", unshared_signal_fiber_wait, 0);
    rb_define_private_method(cUnsharedSignal, "initialize", unshared_signal_initialize, 0);
    rb_define_private_method(cUnsharedSignal, "initialize_copy", unshared_signal_initialize_copy, 1);
    rb_define_method(cUnsharedSignal, "generation", unshared_signal_generation, 0);
    rb_define_method(cUnsharedSignal, "num_waiting", unshared_signal_num_waiting, 0);
    rb_define_method(cUnsharedSignal, "broadcast", unshared_signal_broadcast, 0);
    rb_define_method(cUnsharedSignal, "wait", unshared_signal_wait, -1);
}
