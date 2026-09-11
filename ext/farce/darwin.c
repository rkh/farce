#include "containers.h"

#if defined(HAVE_PTHREAD_QOS_H) && \
    defined(HAVE_PTHREAD_SET_QOS_CLASS_SELF_NP) && \
    defined(HAVE_PTHREAD_GET_QOS_CLASS_NP)
#include <pthread/qos.h>
#if defined(HAVE_SYS_SYSCTL_H) && defined(HAVE_SYSCTLBYNAME)
#include <errno.h>
#include <sys/sysctl.h>
#endif

static VALUE
darwin_set_qos_class(VALUE self, VALUE qos_class, VALUE relative_priority)
{
    int error = pthread_set_qos_class_self_np(
        (qos_class_t)NUM2UINT(qos_class),
        NUM2INT(relative_priority)
    );
    if (error) rb_syserr_fail(error, "pthread_set_qos_class_self_np");
    return Qnil;
}

static VALUE
darwin_get_qos_class(VALUE self)
{
    qos_class_t qos_class;
    int relative_priority;
    int error = pthread_get_qos_class_np(pthread_self(), &qos_class, &relative_priority);
    if (error) rb_syserr_fail(error, "pthread_get_qos_class_np");
    return rb_assoc_new(UINT2NUM(qos_class), INT2NUM(relative_priority));
}

#ifdef HAVE_QOS_CLASS_MAIN
static VALUE
darwin_main_qos_class(VALUE self)
{
    return UINT2NUM(qos_class_main());
}
#endif

#if defined(HAVE_SYS_SYSCTL_H) && defined(HAVE_SYSCTLBYNAME)
static VALUE
darwin_read_cpu_count(const char *name, bool optional)
{
    int count;
    size_t size = sizeof(count);
    if (sysctlbyname(name, &count, &size, NULL, 0) == -1) {
        if (optional && errno == ENOENT) return Qnil;
        rb_sys_fail(name);
    }
    return INT2NUM(count);
}

static VALUE
darwin_performance_cpu_count(VALUE self)
{
    return darwin_read_cpu_count("hw.perflevel0.logicalcpu", true);
}

static VALUE
darwin_efficiency_cpu_count(VALUE self)
{
    return darwin_read_cpu_count("hw.perflevel1.logicalcpu", true);
}

static VALUE
darwin_cpu_count(VALUE self)
{
    return darwin_read_cpu_count("hw.logicalcpu", false);
}
#endif
#endif

void
containers_init_darwin(VALUE namespace)
{
#if defined(HAVE_PTHREAD_QOS_H) && \
    defined(HAVE_PTHREAD_SET_QOS_CLASS_SELF_NP) && \
    defined(HAVE_PTHREAD_GET_QOS_CLASS_NP)
    VALUE darwin = rb_define_module_under(namespace, "Darwin");
    rb_define_singleton_method(darwin, "set_qos_class", darwin_set_qos_class, 2);
    rb_define_singleton_method(darwin, "get_qos_class", darwin_get_qos_class, 0);
#ifdef HAVE_QOS_CLASS_MAIN
    rb_define_singleton_method(darwin, "main_qos_class", darwin_main_qos_class, 0);
#endif
#if defined(HAVE_SYS_SYSCTL_H) && defined(HAVE_SYSCTLBYNAME)
    rb_define_singleton_method(darwin, "performance_cpu_count", darwin_performance_cpu_count, 0);
    rb_define_singleton_method(darwin, "efficiency_cpu_count", darwin_efficiency_cpu_count, 0);
    rb_define_singleton_method(darwin, "cpu_count", darwin_cpu_count, 0);
#endif

    rb_define_const(darwin, "MIN_RELATIVE_PRIORITY", INT2NUM(QOS_MIN_RELATIVE_PRIORITY));
    rb_define_const(darwin, "USER_INTERACTIVE", UINT2NUM(QOS_CLASS_USER_INTERACTIVE));
    rb_define_const(darwin, "USER_INITIATED", UINT2NUM(QOS_CLASS_USER_INITIATED));
    rb_define_const(darwin, "DEFAULT", UINT2NUM(QOS_CLASS_DEFAULT));
    rb_define_const(darwin, "UTILITY", UINT2NUM(QOS_CLASS_UTILITY));
    rb_define_const(darwin, "BACKGROUND", UINT2NUM(QOS_CLASS_BACKGROUND));
    rb_define_const(darwin, "UNSPECIFIED", UINT2NUM(QOS_CLASS_UNSPECIFIED));
#endif
}
