#include "containers.h"

typedef struct {
    unsigned char reserved;
} containers_pin_marker_t;

static ID pin_marker_id;
static ID copy_marker_id;
static ID move_marker_id;
static ID pipe_id;
static ID close_id;
static VALUE cPinMarker;
static VALUE eIsolationError;

static size_t
containers_pin_marker_size(const void *pointer)
{
    return pointer == NULL ? 0 : sizeof(containers_pin_marker_t);
}

static const rb_data_type_t containers_pin_marker_type = {
    .wrap_struct_name = "Ractor::Containers pin marker",
    .function = {
        .dmark = NULL,
        .dfree = RUBY_TYPED_DEFAULT_FREE,
        .dsize = containers_pin_marker_size,
        .dcompact = NULL,
    },
    .parent = NULL,
    .data = NULL,
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static bool
containers_pin_marker_p(VALUE value)
{
    return !NIL_P(value) && rb_typeddata_is_kind_of(value, &containers_pin_marker_type);
}

static void
containers_check_guard_target(VALUE object)
{
    if (RB_SPECIAL_CONST_P(object)) {
        rb_raise(rb_eTypeError, "cannot guard an immediate value");
    }

    rb_check_frozen(object);
    if (rb_ractor_shareable_p(object)) {
        rb_raise(eIsolationError, "cannot guard an object that is already shareable");
    }
}

static VALUE
containers_new_pin_marker(void)
{
    containers_pin_marker_t *marker_data;
    VALUE marker = TypedData_Make_Struct(
        cPinMarker,
        containers_pin_marker_t,
        &containers_pin_marker_type,
        marker_data
    );
    marker_data->reserved = 0;
    rb_obj_freeze(marker);
    return marker;
}

static VALUE
containers_new_copy_marker(void)
{
    VALUE pair = rb_funcall(rb_cIO, pipe_id, 0);
    VALUE reader = rb_ary_entry(pair, 0);
    VALUE writer = rb_ary_entry(pair, 1);

    rb_funcall(reader, close_id, 0);
    rb_funcall(writer, close_id, 0);
    return reader;
}

static VALUE
containers_unshareable_pin(VALUE module, VALUE object)
{
    VALUE marker;
    (void)module;

    if (RB_SPECIAL_CONST_P(object)) {
        rb_raise(rb_eTypeError, "cannot guard an immediate value");
    }

    marker = rb_ivar_get(object, pin_marker_id);
    if (containers_pin_marker_p(marker)) return object;

    containers_check_guard_target(object);
    rb_ivar_set(object, pin_marker_id, containers_new_pin_marker());
    return object;
}

static VALUE
containers_unshareable_prevent_copyable(VALUE module, VALUE object)
{
    VALUE marker;
    (void)module;

    if (RB_SPECIAL_CONST_P(object)) {
        rb_raise(rb_eTypeError, "cannot guard an immediate value");
    }

    if (containers_pin_marker_p(rb_ivar_get(object, pin_marker_id))) return object;
    marker = rb_ivar_get(object, copy_marker_id);
    if (rb_obj_is_kind_of(marker, rb_cIO)) return object;

    containers_check_guard_target(object);
    rb_ivar_set(object, copy_marker_id, containers_new_copy_marker());
    return object;
}

static VALUE
containers_unshareable_prevent_movable(VALUE module, VALUE object)
{
    VALUE marker;
    (void)module;

    if (RB_SPECIAL_CONST_P(object)) {
        rb_raise(rb_eTypeError, "cannot guard an immediate value");
    }

    if (containers_pin_marker_p(rb_ivar_get(object, pin_marker_id))) return object;
    marker = rb_ivar_get(object, move_marker_id);
    if (rb_obj_is_kind_of(marker, rb_cTime)) return object;

    containers_check_guard_target(object);
    rb_ivar_set(object, move_marker_id, rb_time_new(0, 0));
    return object;
}

void
containers_init_unshareable(VALUE namespace)
{
    VALUE module = rb_define_module_under(namespace, "Unshareable");

    pin_marker_id = rb_intern("__ractor_containers_pin__");
    copy_marker_id = rb_intern("__ractor_containers_prevent_copy__");
    move_marker_id = rb_intern("__ractor_containers_prevent_move__");
    pipe_id = rb_intern("pipe");
    close_id = rb_intern("close");
    eIsolationError = rb_const_get(rb_cRactor, rb_intern("IsolationError"));

    cPinMarker = rb_class_new(rb_cObject);
    rb_undef_alloc_func(cPinMarker);
    rb_global_variable(&cPinMarker);

    rb_define_singleton_method(module, "pin_to_current_ractor", containers_unshareable_pin, 1);
    rb_define_singleton_method(module, "prevent_copyable", containers_unshareable_prevent_copyable, 1);
    rb_define_singleton_method(module, "prevent_movable", containers_unshareable_prevent_movable, 1);
}
