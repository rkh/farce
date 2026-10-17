#include "containers.h"

typedef struct {
    VALUE owner_class;
} containers_marker_t;

static ID pin_marker_id;
static ID copy_marker_id;
static ID move_marker_id;
static ID share_marker_id;
static ID owner_class_id;
static ID new_id;
static ID pipe_id;
static ID close_id;
static VALUE cPinMarker;
static VALUE cNoncopyableMarker;
static VALUE cNonmovableMarker;
static VALUE cUnshareableMarker;
static VALUE eRactorError;
static VALUE eIsolationError;

static void
containers_marker_mark(void *pointer)
{
    containers_marker_t *marker = pointer;
    rb_gc_mark_movable(marker->owner_class);
}

static void
containers_marker_compact(void *pointer)
{
    containers_marker_t *marker = pointer;
    containers_gc_update(&marker->owner_class);
}

static size_t
containers_marker_size(const void *pointer)
{
    return pointer == NULL ? 0 : sizeof(containers_marker_t);
}

static const rb_data_type_t containers_pin_marker_type = {
    .wrap_struct_name = "Farce pin marker",
    .function = {
        .dmark = containers_marker_mark,
        .dfree = RUBY_TYPED_DEFAULT_FREE,
        .dsize = containers_marker_size,
        .dcompact = containers_marker_compact,
    },
    .parent = NULL,
    .data = NULL,
    .flags = RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FREE_IMMEDIATELY | FARCE_TYPED_THREAD_SAFE_FREE,
};

/* Native class metadata avoids the unshareable generic ivar storage of T_DATA. */
static const rb_data_type_t containers_nonmovable_marker_type = {
    .wrap_struct_name = "Farce nonmovable marker",
    .function = {
        .dmark = containers_marker_mark,
        .dfree = RUBY_TYPED_DEFAULT_FREE,
        .dsize = containers_marker_size,
        .dcompact = containers_marker_compact,
    },
    .parent = NULL,
    .data = NULL,
    .flags = RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FREE_IMMEDIATELY | FARCE_TYPED_THREAD_SAFE_FREE,
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
containers_marker_initialize(VALUE marker, VALUE owner_class)
{
    Check_Type(owner_class, T_CLASS);
    rb_ivar_set(marker, owner_class_id, owner_class);
    return marker;
}

static VALUE
containers_marker_owner_class(VALUE marker)
{
    if (containers_pin_marker_p(marker) || rb_typeddata_is_kind_of(marker, &containers_nonmovable_marker_type)) {
        return ((containers_marker_t *)RTYPEDDATA_DATA(marker))->owner_class;
    }
    return rb_ivar_get(marker, owner_class_id);
}

static VALUE
containers_marker_inspect(VALUE marker)
{
    return rb_sprintf("#<unshareable marker for %"PRIsVALUE">", containers_marker_owner_class(marker));
}

static VALUE
containers_new_pin_marker(VALUE owner_class)
{
    containers_marker_t *marker_data;
    VALUE marker = TypedData_Make_Struct(
        cPinMarker,
        containers_marker_t,
        &containers_pin_marker_type,
        marker_data
    );
    marker_data->owner_class = Qnil;
    RB_OBJ_WRITE(marker, &marker_data->owner_class, owner_class);
    rb_obj_freeze(marker);
    return marker;
}

static VALUE
containers_marker_reject_freeze(VALUE marker)
{
    rb_raise(eRactorError, "%"PRIsVALUE" cannot be made Ractor-shareable", containers_marker_owner_class(marker));
}

static VALUE
containers_noncopyable_marker_new(VALUE klass, VALUE owner_class)
{
    VALUE pair = rb_funcall(klass, pipe_id, 0);
    VALUE reader = rb_ary_entry(pair, 0);
    VALUE writer = rb_ary_entry(pair, 1);

    rb_funcall(reader, close_id, 0);
    rb_funcall(writer, close_id, 0);
    return containers_marker_initialize(reader, owner_class);
}

static VALUE
containers_nonmovable_marker_allocate(VALUE klass)
{
    containers_marker_t *marker_data;
    VALUE marker = TypedData_Make_Struct(
        klass,
        containers_marker_t,
        &containers_nonmovable_marker_type,
        marker_data
    );
    marker_data->owner_class = Qnil;
    return marker;
}

static VALUE
containers_nonmovable_marker_initialize(VALUE marker, VALUE owner_class)
{
    containers_marker_t *marker_data;
    Check_Type(owner_class, T_CLASS);
    TypedData_Get_Struct(marker, containers_marker_t, &containers_nonmovable_marker_type, marker_data);
    RB_OBJ_WRITE(marker, &marker_data->owner_class, owner_class);
    return marker;
}

static VALUE
containers_nonmovable_marker_initialize_copy(VALUE marker, VALUE original)
{
    containers_marker_t *original_data;
    TypedData_Get_Struct(original, containers_marker_t, &containers_nonmovable_marker_type, original_data);
    return containers_nonmovable_marker_initialize(marker, original_data->owner_class);
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
    rb_ivar_set(object, pin_marker_id, containers_new_pin_marker(rb_obj_class(object)));
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
    rb_ivar_set(object, copy_marker_id, rb_funcall(cNoncopyableMarker, new_id, 1, rb_obj_class(object)));
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
    if (rb_typeddata_is_kind_of(marker, &containers_nonmovable_marker_type)) return object;

    containers_check_guard_target(object);
    rb_ivar_set(object, move_marker_id, rb_funcall(cNonmovableMarker, new_id, 1, rb_obj_class(object)));
    return object;
}

static VALUE
containers_unshareable_prevent_shareable(VALUE module, VALUE object)
{
    VALUE marker;
    (void)module;

    if (RB_SPECIAL_CONST_P(object)) {
        rb_raise(rb_eTypeError, "cannot guard an immediate value");
    }

    if (containers_pin_marker_p(rb_ivar_get(object, pin_marker_id))) return object;
    marker = rb_ivar_get(object, share_marker_id);
    if (rb_obj_is_kind_of(marker, cUnshareableMarker)) return object;

    containers_check_guard_target(object);
    VALUE owner_class = rb_obj_class(object);
    rb_ivar_set(object, share_marker_id, rb_class_new_instance(1, &owner_class, cUnshareableMarker));
    return object;
}

void
containers_init_unshareable(VALUE namespace)
{
    VALUE module = rb_define_module_under(namespace, "Unshareable");

    pin_marker_id = rb_intern("__ractor_containers_pin__");
    copy_marker_id = rb_intern("__ractor_containers_prevent_copy__");
    move_marker_id = rb_intern("__ractor_containers_prevent_move__");
    share_marker_id = rb_intern("__ractor_containers_prevent_share__");
    owner_class_id = rb_intern("@owner_class");
    new_id = rb_intern("new");
    pipe_id = rb_intern("pipe");
    close_id = rb_intern("close");
    eRactorError = rb_const_get(rb_cRactor, rb_intern("Error"));
    eIsolationError = rb_const_get(rb_cRactor, rb_intern("IsolationError"));

    cPinMarker = rb_class_new(rb_cObject);
    rb_undef_alloc_func(cPinMarker);
    rb_define_method(cPinMarker, "inspect", containers_marker_inspect, 0);
    rb_define_method(cPinMarker, "to_s", containers_marker_inspect, 0);
    rb_global_variable(&cPinMarker);

    /* Keep the native transfer restrictions while rejecting recursive freezing. */
    cNoncopyableMarker = rb_define_class_under(module, "NoncopyableMarker", rb_cIO);
    rb_define_singleton_method(cNoncopyableMarker, "new", containers_noncopyable_marker_new, 1);
    rb_define_method(cNoncopyableMarker, "freeze", containers_marker_reject_freeze, 0);
    rb_define_method(cNoncopyableMarker, "inspect", containers_marker_inspect, 0);
    rb_define_method(cNoncopyableMarker, "to_s", containers_marker_inspect, 0);
    cNonmovableMarker = rb_define_class_under(module, "NonmovableMarker", rb_cObject);
    rb_define_alloc_func(cNonmovableMarker, containers_nonmovable_marker_allocate);
    rb_define_method(cNonmovableMarker, "initialize", containers_nonmovable_marker_initialize, 1);
    rb_define_method(cNonmovableMarker, "initialize_copy", containers_nonmovable_marker_initialize_copy, 1);
    rb_define_method(cNonmovableMarker, "inspect", containers_marker_inspect, 0);
    rb_define_method(cNonmovableMarker, "to_s", containers_marker_inspect, 0);
    rb_define_method(cNonmovableMarker, "freeze", containers_marker_reject_freeze, 0);

    /* Ruby 4.1's Ractor copier falls back to Marshal for extension data. */
    rb_define_method(cNonmovableMarker, "marshal_dump", containers_marker_owner_class, 0);
    rb_define_method(cNonmovableMarker, "marshal_load", containers_nonmovable_marker_initialize, 1);
    cUnshareableMarker = rb_define_class_under(module, "UnshareableMarker", rb_cObject);
    rb_define_method(cUnshareableMarker, "initialize", containers_marker_initialize, 1);
    rb_define_method(cUnshareableMarker, "freeze", containers_marker_reject_freeze, 0);
    rb_funcall(module, rb_intern("private_constant"), 3,
               ID2SYM(rb_intern("NoncopyableMarker")),
               ID2SYM(rb_intern("NonmovableMarker")),
               ID2SYM(rb_intern("UnshareableMarker")));

    rb_define_singleton_method(module, "pin_to_current_ractor", containers_unshareable_pin, 1);
    rb_define_singleton_method(module, "prevent_copyable", containers_unshareable_prevent_copyable, 1);
    rb_define_singleton_method(module, "prevent_movable", containers_unshareable_prevent_movable, 1);
    rb_define_singleton_method(module, "prevent_shareable", containers_unshareable_prevent_shareable, 1);
}
