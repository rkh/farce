#include <ruby.h>
#include <ruby/version.h>

#include <stddef.h>

/*
 * Private CRuby layout mirrored from vm_core.h.
 *
 * Ruby 4.1 split Proc's storage into separate representations sharing a
 * header. Older supported CRuby versions store the captured block first.
 * We deliberately mirror only the prefix we need.
 */

union farce_block_code
{
    const void *iseq;
    const void *ifunc;
    VALUE val;
};

struct farce_captured_block
{
    VALUE self;
    const VALUE *ep;
    union farce_block_code code;
};

enum farce_block_type
{
    FARCE_BLOCK_ISEQ   = 0,
    FARCE_BLOCK_IFUNC  = 1,
    FARCE_BLOCK_SYMBOL = 2,
    FARCE_BLOCK_PROC   = 3
};

struct farce_block
{
    union
    {
        struct farce_captured_block captured;
        VALUE symbol;
        VALUE proc;
    } as;

    enum farce_block_type type;
};

#if RUBY_API_VERSION_MAJOR == 4 && RUBY_API_VERSION_MINOR >= 1
struct farce_proc_header
{
    enum farce_block_type type : 8;
    unsigned int is_from_method : 1;
    unsigned int is_lambda      : 1;
    unsigned int is_isolated    : 1;
    unsigned int is_refined     : 1;
};

struct farce_proc_captured
{
    struct farce_proc_header header;
    struct farce_captured_block captured;
};

union farce_proc
{
    struct farce_block block;
    struct farce_proc_header header;
    struct farce_proc_captured captured;
};

typedef union farce_proc farce_proc_t;

#define FARCE_PROC_TYPE(proc) ((proc)->header.type)
#define FARCE_PROC_SELF(proc) (&(proc)->captured.captured.self)
#define FARCE_PROC_LAMBDA(proc) ((proc)->header.is_lambda)

#else
struct farce_proc
{
    struct farce_block block;

    unsigned int is_from_method : 1;
    unsigned int is_lambda      : 1;
    unsigned int is_isolated    : 1;
};

typedef struct farce_proc farce_proc_t;

#define FARCE_PROC_TYPE(proc) ((proc)->block.type)
#define FARCE_PROC_SELF(proc) (&(proc)->block.as.captured.self)
#define FARCE_PROC_LAMBDA(proc) ((proc)->is_lambda)
#endif

#define FARCE_STATIC_ASSERT(name, expr) \
    typedef char farce_static_assert_##name[(expr) ? 1 : -1]

FARCE_STATIC_ASSERT(
    captured_block_is_three_words,
    sizeof(struct farce_captured_block) == 3 * sizeof(VALUE));

FARCE_STATIC_ASSERT(
    captured_self_is_first,
    offsetof(struct farce_captured_block, self) == 0);

FARCE_STATIC_ASSERT(
    block_is_four_words,
    sizeof(struct farce_block) == 4 * sizeof(VALUE));

#if RUBY_API_VERSION_MAJOR == 4 && RUBY_API_VERSION_MINOR >= 1
FARCE_STATIC_ASSERT(
    captured_self_offset,
    offsetof(union farce_proc, captured.captured.self) == sizeof(VALUE));
#else
FARCE_STATIC_ASSERT(
    proc_starts_with_block,
    offsetof(struct farce_proc, block) == 0);
#endif

#if !((RUBY_API_VERSION_MAJOR == 3 && RUBY_API_VERSION_MINOR == 4) || \
      (RUBY_API_VERSION_MAJOR == 4 && RUBY_API_VERSION_MINOR <= 1))
#error "Farce's Proc layout needs verification for this CRuby version"
#endif

static farce_proc_t *
farce_proc_ptr(VALUE proc)
{
    return (farce_proc_t *)RTYPEDDATA_GET_DATA(proc);
}

static int
farce_proc_rebindable_p(farce_proc_t *proc)
{
    return (FARCE_PROC_TYPE(proc) == FARCE_BLOCK_ISEQ || FARCE_PROC_TYPE(proc) == FARCE_BLOCK_IFUNC);
}

static VALUE
proc_rebindable_p(VALUE module, VALUE proc_val)
{
    farce_proc_t *proc;

    (void)module;

    if (!rb_obj_is_proc(proc_val)) return Qfalse;
    proc = farce_proc_ptr(proc_val);
    return farce_proc_rebindable_p(proc) ? Qtrue : Qfalse;
}

static VALUE
rebind_proc_self(VALUE module, VALUE proc_val, VALUE new_self, VALUE lambda_mode)
{
    VALUE new_proc;
    farce_proc_t *proc;

    (void)module;

    if (!rb_obj_is_proc(proc_val))
        rb_raise(rb_eTypeError, "expected a Proc");

    if (lambda_mode != Qnil && lambda_mode != Qtrue && lambda_mode != Qfalse)
        rb_raise(rb_eArgError, "lambda mode must be true, false, or nil");

    new_proc = rb_funcall(proc_val, rb_intern("dup"), 0);
    proc = farce_proc_ptr(new_proc);

    if (!farce_proc_rebindable_p(proc))
        rb_raise(rb_eTypeError, "cannot rebind this Proc representation");

    RB_OBJ_WRITE(new_proc, FARCE_PROC_SELF(proc), new_self);

    if (lambda_mode != Qnil)
        FARCE_PROC_LAMBDA(proc) = lambda_mode == Qtrue;

    return new_proc;
}

void Init_rebind(void)
{
#ifdef HAVE_RB_EXT_RACTOR_SAFE
    rb_ext_ractor_safe(true);
#endif

    VALUE mFarce = rb_const_get(rb_cObject, rb_intern("Farce"));
    VALUE mInternal = rb_const_get(mFarce, rb_intern("Internal"));
    rb_define_module_function(mInternal, "rebind", rebind_proc_self, 3);
    rb_define_module_function(mInternal, "rebindable?", proc_rebindable_p, 1);
}
