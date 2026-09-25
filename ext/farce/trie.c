#include "containers.h"

#include "ruby/atomic.h"
#include "ruby/encoding.h"
#include "ruby/internal/core/rregexp.h"
#include "ruby/re.h"

#include <limits.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define TRIE_INLINE_FRAMES 64
#define TRIE_INLINE_EVENTS 32
#define TRIE_INTERRUPT_INTERVAL 1024
#define TRIE_PROGRAM_INSTRUCTIONS 16
#define TRIE_PROGRAM_CAPTURES 8
#define TRIE_PROGRAM_SOURCE_BYTES 4096
#define TRIE_STATIC_INDEX_THRESHOLD 8

typedef struct trie_node trie_node_t;

typedef enum {
    TRIE_CAPTURE_DIGIT,
    TRIE_CAPTURE_WORD,
    TRIE_CAPTURE_NOT_SLASH,
    TRIE_CAPTURE_NOT_PATH_SEPARATOR,
    TRIE_LITERAL_ALTERNATIVES,
} trie_opcode_t;

typedef struct {
    unsigned char *bytes;
    size_t length;
} trie_literal_t;

typedef struct {
    trie_opcode_t opcode;
    VALUE name;
    trie_literal_t *alternatives;
    size_t alternative_count;
} trie_instruction_t;

typedef struct trie_program {
    unsigned char *key;
    size_t key_length;
    uint64_t key_hash;
    int key_encoding;
    int key_options;
    trie_instruction_t *instructions;
    size_t instruction_count;
    size_t instruction_capacity;
    size_t capture_count;
    bool end_anchor;
    bool requires_ascii_input;
} trie_program_t;

typedef struct {
    VALUE label;
    trie_node_t *child;
    int encoding;
    uint32_t next_same_byte;
} trie_static_edge_t;

typedef struct {
    uint16_t span;
    unsigned char minimum;
    unsigned char reserved;
    uint32_t slots[];
} trie_static_index_t;

_Static_assert(sizeof(trie_static_index_t) == sizeof(uint32_t),
               "static index header must occupy one slot");

typedef struct {
    VALUE source;
    VALUE anchored;
    VALUE timeout;
    int options;
    trie_program_t *program;
    trie_node_t *child;
} trie_regexp_edge_t;

struct trie_node {
    trie_static_edge_t *static_edges;
    size_t static_count;
    size_t static_capacity;
    trie_static_index_t *static_index;
    trie_regexp_edge_t *regexp_edges;
    size_t regexp_count;
    size_t regexp_capacity;
    uint32_t *tokens;
    size_t token_count;
    size_t token_capacity;
};

typedef struct {
    trie_node_t *root;
    trie_node_t **nodes;
    size_t node_count;
    size_t node_capacity;
    trie_program_t **programs;
    size_t program_count;
    size_t program_capacity;
    trie_program_t **program_cache;
    size_t program_cache_capacity;
    VALUE tokens;
    VALUE owner;
    size_t static_edge_count;
    size_t static_index_count;
    size_t static_index_bytes;
    size_t regexp_edge_count;
    bool initialized;
} trie_t;

typedef enum { TRIE_EVENT_NATIVE, TRIE_EVENT_RUBY } trie_event_kind_t;

typedef struct {
    trie_event_kind_t kind;
    long begin;
    long end;
    VALUE name;
    long match_index;
} trie_capture_event_t;

typedef struct {
    trie_node_t *node;
    long cursor;
    size_t restore_events;
    size_t static_index;
    size_t regexp_index;
    unsigned phase;
} trie_frame_t;

/* A suspended Enumerator or user Fiber can be collected without unwinding the
 * native stack. Keep every spilled search buffer behind a Ruby object so GC can
 * reclaim it even when trie_search_cleanup never runs. */
typedef struct {
    void *pointer;
    size_t bytes;
} trie_scratch_t;

typedef struct {
    VALUE self;
    VALUE input;
    VALUE results;
    VALUE matches;
    VALUE previous_backref;
    VALUE frame_scratch;
    VALUE event_scratch;
    VALUE seen_scratch;
    VALUE seen_building_scratch;
    trie_t *trie;
    long input_length;
    int input_encoding;
    trie_frame_t *frames;
    size_t frame_count;
    size_t frame_capacity;
    trie_capture_event_t *events;
    size_t event_count;
    size_t event_capacity;
    uint32_t *seen;
    uint32_t *seen_building;
    size_t seen_count;
    size_t seen_capacity;
    bool seen_hashed;
    size_t work;
    bool peek;
    bool first_only;
    bool stream;
    bool utf8_input;
    bool ascii_input;
    bool native_segment_input;
    bool regexp_timeout_checked;
    VALUE first;
    trie_frame_t inline_frames[TRIE_INLINE_FRAMES];
    trie_capture_event_t inline_events[TRIE_INLINE_EVENTS];
    uint32_t inline_seen[16];
} trie_search_t;

typedef struct {
    const unsigned char *bytes;
    size_t length;
    size_t position;
    trie_program_t *program;
} trie_parser_t;

static VALUE cTrie;
static ID id_captures;
static ID id_named_captures;
static ID id_timeout;
static bool regexp_timeout_supported;

#ifdef FARCE_TRIE_FAILURE_INJECTION
static _Thread_local long trie_failure_countdown = -1;
static VALUE trie_interrupt_queue = Qnil;
static rb_atomic_t trie_scratch_live_count;

static void
trie_failure_checkpoint(void)
{
    if (trie_failure_countdown < 0) return;
    if (trie_failure_countdown-- == 0) rb_memerror();
}
#else
# define trie_failure_checkpoint() ((void)0)
#endif

static void
trie_check_interrupts(void)
{
#ifdef FARCE_TRIE_FAILURE_INJECTION
    if (!NIL_P(trie_interrupt_queue)) {
        VALUE queues = trie_interrupt_queue;
        VALUE ready = RARRAY_AREF(queues, 0);
        VALUE release = RARRAY_AREF(queues, 1);
        trie_interrupt_queue = Qnil;
        rb_funcall(ready, rb_intern("<<"), 1, Qtrue);
        rb_funcall(release, rb_intern("pop"), 0);
        RB_GC_GUARD(queues);
        RB_GC_GUARD(ready);
        RB_GC_GUARD(release);
    }
#endif
    rb_thread_check_ints();
}

static void
trie_search_work_checkpoint(trie_search_t *search)
{
    if ((++search->work & (TRIE_INTERRUPT_INTERVAL - 1)) == 0) trie_check_interrupts();
}

static void *
trie_malloc(size_t count, size_t element)
{
    trie_failure_checkpoint();
    return ruby_xmalloc2(count, element);
}

static void *
trie_realloc(void *pointer, size_t count, size_t element)
{
    trie_failure_checkpoint();
    return ruby_xrealloc2(pointer, count, element);
}

static void
trie_scratch_free(void *opaque)
{
    trie_scratch_t *scratch = opaque;
    if (!scratch) return;
    if (scratch->pointer) {
        xfree(scratch->pointer);
#ifdef FARCE_TRIE_FAILURE_INJECTION
        RUBY_ATOMIC_DEC(trie_scratch_live_count);
#endif
    }
    xfree(scratch);
}

static size_t
trie_scratch_memsize(const void *opaque)
{
    const trie_scratch_t *scratch = opaque;
    return scratch ? sizeof(*scratch) + scratch->bytes : 0;
}

static const rb_data_type_t trie_scratch_type = {
    .wrap_struct_name = "Farce::Strict::Trie::SearchScratch",
    .function = {
        .dmark = NULL,
        .dfree = trie_scratch_free,
        .dsize = trie_scratch_memsize,
        .dcompact = NULL,
    },
    .parent = NULL,
    .data = NULL,
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static void *
trie_scratch_allocate(VALUE *owner, size_t count, size_t element)
{
    trie_scratch_t *scratch;
    VALUE wrapper = TypedData_Make_Struct(rb_cObject, trie_scratch_t,
                                          &trie_scratch_type, scratch);
    *owner = wrapper;
    scratch->pointer = NULL;
    scratch->bytes = 0;
    scratch->pointer = trie_malloc(count, element);
    scratch->bytes = count * element;
#ifdef FARCE_TRIE_FAILURE_INJECTION
    RUBY_ATOMIC_INC(trie_scratch_live_count);
#endif
    RB_GC_GUARD(wrapper);
    return scratch->pointer;
}

static void *
trie_scratch_resize(VALUE owner, size_t count, size_t element)
{
    trie_scratch_t *scratch = RTYPEDDATA_DATA(owner);
    void *pointer = trie_realloc(scratch->pointer, count, element);
    scratch->pointer = pointer;
    scratch->bytes = count * element;
    RB_GC_GUARD(owner);
    return pointer;
}

static void
trie_scratch_release(VALUE owner)
{
    trie_scratch_t *scratch;
    if (owner == 0) return;
    scratch = RTYPEDDATA_DATA(owner);
    if (!scratch->pointer) return;
    xfree(scratch->pointer);
    scratch->pointer = NULL;
    scratch->bytes = 0;
#ifdef FARCE_TRIE_FAILURE_INJECTION
    RUBY_ATOMIC_DEC(trie_scratch_live_count);
#endif
}

#define TRIE_ALLOC(type) ((type *)trie_malloc(1, sizeof(type)))
#define TRIE_ALLOC_N(type, count) ((type *)trie_malloc((count), sizeof(type)))
#define TRIE_REALLOC_N(pointer, type, count) \
    ((pointer) = (type *)trie_realloc((pointer), (count), sizeof(type)))

static bool
trie_size_grow(size_t current, size_t minimum, size_t element, size_t *result)
{
    size_t capacity = current ? current : 4;
    while (capacity < minimum) {
        if (capacity > SIZE_MAX / 2) return false;
        capacity *= 2;
    }
    if (capacity > SIZE_MAX / element) return false;
    *result = capacity;
    return true;
}

static void
trie_mark(void *pointer)
{
    trie_t *trie = pointer;
    size_t node_index;
    size_t program_index;
    if (!trie) return;
    if (!NIL_P(trie->owner)) {
        rb_gc_mark(trie->owner);
        return;
    }
    rb_gc_mark(trie->tokens);
    for (node_index = 0; node_index < trie->node_count; node_index++) {
        trie_node_t *node = trie->nodes[node_index];
        size_t index;
        for (index = 0; index < node->static_count; index++) {
            rb_gc_mark(node->static_edges[index].label);
        }
        for (index = 0; index < node->regexp_count; index++) {
            rb_gc_mark(node->regexp_edges[index].source);
            rb_gc_mark(node->regexp_edges[index].anchored);
            rb_gc_mark(node->regexp_edges[index].timeout);
        }
    }
    for (program_index = 0; program_index < trie->program_count; program_index++) {
        trie_program_t *program = trie->programs[program_index];
        size_t index;
        for (index = 0; index < program->instruction_count; index++) {
            if (program->instructions[index].opcode != TRIE_LITERAL_ALTERNATIVES) {
                rb_gc_mark(program->instructions[index].name);
            }
        }
    }
}

static void
trie_program_free(trie_program_t *program)
{
    size_t index;
    if (!program) return;
    for (index = 0; index < program->instruction_count; index++) {
        trie_instruction_t *instruction = &program->instructions[index];
        size_t alternative;
        for (alternative = 0; alternative < instruction->alternative_count; alternative++) {
            xfree(instruction->alternatives[alternative].bytes);
        }
        xfree(instruction->alternatives);
    }
    xfree(program->instructions);
    xfree(program->key);
    xfree(program);
}

static void
trie_release_contents(trie_t *trie)
{
    size_t index;
    for (index = 0; index < trie->node_count; index++) {
        trie_node_t *node = trie->nodes[index];
        xfree(node->static_edges);
        xfree(node->static_index);
        xfree(node->regexp_edges);
        xfree(node->tokens);
        xfree(node);
    }
    for (index = 0; index < trie->program_count; index++) {
        trie_program_free(trie->programs[index]);
    }
    xfree(trie->nodes);
    xfree(trie->programs);
    xfree(trie->program_cache);
    trie->root = NULL;
    trie->nodes = NULL;
    trie->node_count = trie->node_capacity = 0;
    trie->programs = NULL;
    trie->program_count = trie->program_capacity = 0;
    trie->program_cache = NULL;
    trie->program_cache_capacity = 0;
}

static void
trie_free(void *pointer)
{
    trie_t *trie = pointer;
    if (!trie) return;
    if (NIL_P(trie->owner)) trie_release_contents(trie);
    xfree(trie);
}

static size_t
trie_program_memsize(const trie_program_t *program)
{
    size_t size = sizeof(*program) + program->key_length;
    size_t index;
    size += program->instruction_capacity * sizeof(*program->instructions);
    for (index = 0; index < program->instruction_count; index++) {
        const trie_instruction_t *instruction = &program->instructions[index];
        size_t alternative;
        size += instruction->alternative_count * sizeof(*instruction->alternatives);
        for (alternative = 0; alternative < instruction->alternative_count; alternative++) {
            size += instruction->alternatives[alternative].length;
        }
    }
    return size;
}

static size_t
trie_memsize(const void *pointer)
{
    const trie_t *trie = pointer;
    size_t size;
    size_t index;
    if (!trie) return 0;
    if (!NIL_P(trie->owner)) return sizeof(*trie);
    size = sizeof(*trie);
    size += trie->node_capacity * sizeof(*trie->nodes);
    size += trie->program_capacity * sizeof(*trie->programs);
    size += trie->program_cache_capacity * sizeof(*trie->program_cache);
    for (index = 0; index < trie->node_count; index++) {
        const trie_node_t *node = trie->nodes[index];
        size += sizeof(*node);
        size += node->static_capacity * sizeof(*node->static_edges);
        size += node->regexp_capacity * sizeof(*node->regexp_edges);
        size += node->token_capacity * sizeof(*node->tokens);
    }
    for (index = 0; index < trie->program_count; index++) {
        size += trie_program_memsize(trie->programs[index]);
    }
    size += trie->static_index_bytes;
    return size;
}

static const rb_data_type_t trie_type = {
    .wrap_struct_name = "Farce::Internal::Trie",
    .function = {
        .dmark = trie_mark,
        .dfree = trie_free,
        .dsize = trie_memsize,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
trie_allocate(VALUE klass)
{
    trie_t *trie;
    VALUE object = TypedData_Make_Struct(klass, trie_t, &trie_type, trie);
    memset(trie, 0, sizeof(*trie));
    trie->tokens = Qnil;
    trie->owner = Qnil;
    return object;
}

static trie_t *
trie_get(VALUE self)
{
    trie_t *trie;
    TypedData_Get_Struct(self, trie_t, &trie_type, trie);
    if (!NIL_P(trie->owner)) {
        TypedData_Get_Struct(trie->owner, trie_t, &trie_type, trie);
    }
    if (!trie->initialized) rb_raise(rb_eRuntimeError, "uninitialized trie");
    return trie;
}

static void
trie_ensure_node_inventory(trie_t *trie, size_t minimum)
{
    size_t capacity;
    if (minimum <= trie->node_capacity) return;
    if (!trie_size_grow(trie->node_capacity, minimum, sizeof(*trie->nodes), &capacity)) rb_memerror();
    TRIE_REALLOC_N(trie->nodes, trie_node_t *, capacity);
    trie->node_capacity = capacity;
}

static trie_node_t *
trie_node_new(trie_t *trie)
{
    trie_node_t *node;
    trie_ensure_node_inventory(trie, trie->node_count + 1);
    node = TRIE_ALLOC(trie_node_t);
    memset(node, 0, sizeof(*node));
    trie->nodes[trie->node_count++] = node;
    return node;
}

static void
trie_ensure_static_edges(trie_node_t *node, size_t minimum)
{
    size_t capacity;
    if (minimum <= node->static_capacity) return;
    if (!trie_size_grow(node->static_capacity, minimum, sizeof(*node->static_edges), &capacity)) rb_memerror();
    TRIE_REALLOC_N(node->static_edges, trie_static_edge_t, capacity);
    node->static_capacity = capacity;
}

static void
trie_ensure_regexp_edges(trie_node_t *node, size_t minimum)
{
    size_t capacity;
    if (minimum <= node->regexp_capacity) return;
    if (!trie_size_grow(node->regexp_capacity, minimum, sizeof(*node->regexp_edges), &capacity)) rb_memerror();
    TRIE_REALLOC_N(node->regexp_edges, trie_regexp_edge_t, capacity);
    node->regexp_capacity = capacity;
}

static void
trie_ensure_tokens(trie_node_t *node, size_t minimum)
{
    size_t capacity;
    if (minimum <= node->token_capacity) return;
    if (!trie_size_grow(node->token_capacity, minimum, sizeof(*node->tokens), &capacity)) rb_memerror();
    TRIE_REALLOC_N(node->tokens, uint32_t, capacity);
    node->token_capacity = capacity;
}

static VALUE
trie_frozen_string(VALUE source, long offset, long length)
{
    VALUE string = rb_str_subseq(source, offset, length);
    rb_obj_freeze(string);
    return string;
}

static size_t
trie_common_prefix(VALUE left, VALUE right, size_t right_offset)
{
    size_t left_length = (size_t)RSTRING_LEN(left);
    size_t right_length = (size_t)RSTRING_LEN(right) - right_offset;
    size_t limit = left_length < right_length ? left_length : right_length;
    size_t index = 0;
    while (index < limit) {
        size_t length = limit - index;
        if (length > 16384) length = 16384;
        const unsigned char *left_bytes = (const unsigned char *)RSTRING_PTR(left) + index;
        const unsigned char *right_bytes = (const unsigned char *)RSTRING_PTR(right) + right_offset + index;
        if (memcmp(left_bytes, right_bytes, length) != 0) {
            size_t offset = 0;
            while (offset < length && left_bytes[offset] == right_bytes[offset]) offset++;
            return index + offset;
        }
        index += length;
        if (index < limit) trie_check_interrupts();
    }
    return index;
}

static size_t
trie_static_index_size(size_t span)
{
    return sizeof(trie_static_index_t) + span * sizeof(uint32_t);
}

static trie_static_index_t *
trie_static_index_new(unsigned char minimum, unsigned char maximum)
{
    size_t span = (size_t)maximum - minimum + 1;
    size_t bytes = trie_static_index_size(span);
    trie_static_index_t *table = (trie_static_index_t *)TRIE_ALLOC_N(unsigned char, bytes);
    table->span = (uint16_t)span;
    table->minimum = minimum;
    table->reserved = 0;
    memset(table->slots, 0, span * sizeof(*table->slots));
    return table;
}

static uint32_t *
trie_static_index_slot(trie_static_index_t *table, unsigned char first)
{
    if (first < table->minimum) return NULL;
    size_t offset = (size_t)first - table->minimum;
    if (offset >= table->span) return NULL;
    return &table->slots[offset];
}

static const uint32_t *
trie_static_index_slot_const(const trie_static_index_t *table, unsigned char first)
{
    if (first < table->minimum) return NULL;
    size_t offset = (size_t)first - table->minimum;
    if (offset >= table->span) return NULL;
    return &table->slots[offset];
}

static void
trie_enable_static_index(trie_t *trie, trie_node_t *node)
{
    unsigned char minimum = UCHAR_MAX;
    unsigned char maximum = 0;
    size_t index;
    for (index = 0; index < node->static_count; index++) {
        unsigned char first = (unsigned char)RSTRING_PTR(node->static_edges[index].label)[0];
        if (first < minimum) minimum = first;
        if (first > maximum) maximum = first;
    }
    trie_static_index_t *table = trie_static_index_new(minimum, maximum);
    for (index = node->static_count; index > 0; index--) {
        trie_static_edge_t *edge = &node->static_edges[index - 1];
        unsigned char first = (unsigned char)RSTRING_PTR(edge->label)[0];
        uint32_t *slot = trie_static_index_slot(table, first);
        edge->next_same_byte = *slot;
        *slot = (uint32_t)index;
    }
    node->static_index = table;
    trie->static_index_count++;
    trie->static_index_bytes += trie_static_index_size(table->span);
}

static void
trie_expand_static_index(trie_t *trie, trie_node_t *node, unsigned char first)
{
    trie_static_index_t *old = node->static_index;
    if (trie_static_index_slot(old, first)) return;
    unsigned char minimum = first < old->minimum ? first : old->minimum;
    unsigned char old_maximum = (unsigned char)(old->minimum + old->span - 1);
    unsigned char maximum = first > old_maximum ? first : old_maximum;
    trie_static_index_t *replacement = trie_static_index_new(minimum, maximum);
    size_t offset = (size_t)old->minimum - replacement->minimum;
    memcpy(replacement->slots + offset, old->slots, old->span * sizeof(*old->slots));
    node->static_index = replacement;
    trie->static_index_bytes += trie_static_index_size(replacement->span) -
                                trie_static_index_size(old->span);
    xfree(old);
}

static void
trie_index_static_edge(trie_t *trie, trie_node_t *node, size_t index)
{
    if (index >= UINT32_MAX) rb_raise(rb_eArgError, "too many static edges at one trie node");
    trie_static_edge_t *edge = &node->static_edges[index];
    unsigned char first = (unsigned char)RSTRING_PTR(edge->label)[0];
    size_t work = 0;
    edge->next_same_byte = 0;
    if (!node->static_index) {
        if (node->static_count >= TRIE_STATIC_INDEX_THRESHOLD) trie_enable_static_index(trie, node);
        return;
    }
    trie_expand_static_index(trie, node, first);
    uint32_t *next = trie_static_index_slot(node->static_index, first);
    while (*next) {
        next = &node->static_edges[*next - 1].next_same_byte;
        if ((++work & (TRIE_INTERRUPT_INTERVAL - 1)) == 0) trie_check_interrupts();
    }
    *next = (uint32_t)(index + 1);
}

static long
trie_find_static_edge(const trie_node_t *node, VALUE string, size_t offset)
{
    unsigned char first = (unsigned char)RSTRING_PTR(string)[offset];
    size_t index;
    if (node->static_index) {
        const uint32_t *slot = trie_static_index_slot_const(node->static_index, first);
        uint32_t current = slot ? *slot : 0;
        size_t work = 0;
        while (current) {
            const trie_static_edge_t *edge = &node->static_edges[current - 1];
            if (rb_enc_compatible(edge->label, string)) return (long)(current - 1);
            current = edge->next_same_byte;
            if ((++work & (TRIE_INTERRUPT_INTERVAL - 1)) == 0) trie_check_interrupts();
        }
        return -1;
    }
    for (index = 0; index < node->static_count; index++) {
        VALUE label = node->static_edges[index].label;
        if (RSTRING_LEN(label) > 0 && (unsigned char)RSTRING_PTR(label)[0] == first &&
            rb_enc_compatible(label, string)) return (long)index;
    }
    return -1;
}

static bool
trie_parser_starts_with(const trie_parser_t *parser, const char *text)
{
    size_t length = strlen(text);
    return parser->position <= parser->length &&
           length <= parser->length - parser->position &&
           memcmp(parser->bytes + parser->position, text, length) == 0;
}

static bool
trie_parser_consume(trie_parser_t *parser, const char *text)
{
    size_t length = strlen(text);
    if (!trie_parser_starts_with(parser, text)) return false;
    parser->position += length;
    return true;
}

static bool
trie_program_add_instruction(trie_program_t *program, trie_instruction_t instruction)
{
    size_t capacity;
    if (program->instruction_count >= TRIE_PROGRAM_INSTRUCTIONS) return false;
    if (program->instruction_count == program->instruction_capacity) {
        if (!trie_size_grow(program->instruction_capacity,
                            program->instruction_count + 1,
                            sizeof(*program->instructions), &capacity)) return false;
        TRIE_REALLOC_N(program->instructions, trie_instruction_t, capacity);
        program->instruction_capacity = capacity;
    }
    program->instructions[program->instruction_count++] = instruction;
    return true;
}

static bool
trie_capture_accepts(trie_opcode_t opcode, unsigned char byte)
{
    switch (opcode) {
      case TRIE_CAPTURE_DIGIT:
        return byte >= '0' && byte <= '9';
      case TRIE_CAPTURE_WORD:
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
               (byte >= '0' && byte <= '9') || byte == '_';
      case TRIE_CAPTURE_NOT_SLASH:
        return byte != '/';
      case TRIE_CAPTURE_NOT_PATH_SEPARATOR:
        return byte != '/' && byte != '?' && byte != '#';
      default:
        return false;
    }
}

static bool
trie_name_byte(unsigned char byte, bool first)
{
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
           (!first && ((byte >= '0' && byte <= '9') || byte == '_'));
}

static bool
trie_parse_negated_delimiters(trie_parser_t *parser, trie_opcode_t *opcode)
{
    size_t start = parser->position;
    unsigned int delimiters = 0;
    if (!trie_parser_consume(parser, "[^")) return false;
    while (parser->position < parser->length && parser->bytes[parser->position] != ']') {
        unsigned char byte = parser->bytes[parser->position++];
        unsigned int delimiter;
        if (byte == '\\') {
            if (parser->position >= parser->length) goto fail;
            byte = parser->bytes[parser->position++];
        }
        if (byte == '/') delimiter = 1;
        else if (byte == '?') delimiter = 2;
        else if (byte == '#') delimiter = 4;
        else goto fail;
        if (delimiters & delimiter) goto fail;
        delimiters |= delimiter;
    }
    if (parser->position >= parser->length || parser->bytes[parser->position++] != ']' ||
        parser->position >= parser->length || parser->bytes[parser->position++] != '+') goto fail;
    if (delimiters == 1) *opcode = TRIE_CAPTURE_NOT_SLASH;
    else if (delimiters == 7) *opcode = TRIE_CAPTURE_NOT_PATH_SEPARATOR;
    else goto fail;
    return true;

  fail:
    parser->position = start;
    return false;
}

static bool
trie_parse_capture(trie_parser_t *parser)
{
    size_t name_start;
    size_t name_length;
    trie_opcode_t opcode;
    trie_instruction_t instruction;
    VALUE name;
    size_t index;
    if (!trie_parser_consume(parser, "(?<")) return false;
    name_start = parser->position;
    while (parser->position < parser->length &&
           trie_name_byte(parser->bytes[parser->position], parser->position == name_start)) {
        parser->position++;
    }
    name_length = parser->position - name_start;
    if (name_length == 0 || parser->position >= parser->length ||
        parser->bytes[parser->position++] != '>') return false;

    if (trie_parser_consume(parser, "\\d+")) opcode = TRIE_CAPTURE_DIGIT;
    else if (trie_parser_consume(parser, "[0-9]+")) opcode = TRIE_CAPTURE_DIGIT;
    else if (trie_parser_consume(parser, "\\w+")) opcode = TRIE_CAPTURE_WORD;
    else if (trie_parser_starts_with(parser, "[^")) {
        if (!trie_parse_negated_delimiters(parser, &opcode)) return false;
    }
    else if (trie_parser_consume(parser, "(?-mix:\\d+)")) opcode = TRIE_CAPTURE_DIGIT;
    else if (trie_parser_consume(parser, "(?-mix:\\w+)")) opcode = TRIE_CAPTURE_WORD;
    else return false;
    if (parser->position >= parser->length || parser->bytes[parser->position++] != ')') return false;
    if (parser->program->capture_count >= TRIE_PROGRAM_CAPTURES) return false;
    for (index = 0; index < parser->program->instruction_count; index++) {
        trie_instruction_t *existing = &parser->program->instructions[index];
        if (existing->opcode == TRIE_LITERAL_ALTERNATIVES) continue;
        if ((size_t)RSTRING_LEN(existing->name) == name_length &&
            memcmp(RSTRING_PTR(existing->name), parser->bytes + name_start, name_length) == 0) return false;
    }

    memset(&instruction, 0, sizeof(instruction));
    instruction.opcode = opcode;
    instruction.name = Qnil;
    if (!trie_program_add_instruction(parser->program, instruction)) return false;
    name = rb_enc_str_new((const char *)parser->bytes + name_start, (long)name_length, rb_usascii_encoding());
    rb_obj_freeze(name);
    parser->program->instructions[parser->program->instruction_count - 1].name = name;
    parser->program->capture_count++;
    if (opcode == TRIE_CAPTURE_DIGIT || opcode == TRIE_CAPTURE_WORD) {
        parser->program->requires_ascii_input = true;
    }
    RB_GC_GUARD(name);
    return true;
}

static bool
trie_literal_meta(unsigned char byte)
{
    switch (byte) {
      case '.': case '^': case '$': case '*': case '+': case '?':
      case '{': case '}': case '[': case ']': case '(': case ')':
      case '|': case '\\':
        return true;
      default:
        return false;
    }
}

static bool
trie_add_literal_alternative(trie_instruction_t *instruction,
                             const unsigned char *bytes, size_t length)
{
    trie_literal_t *alternatives;
    unsigned char *copy;
    size_t count = instruction->alternative_count;
    if (count == SIZE_MAX || count + 1 > SIZE_MAX / sizeof(*alternatives)) return false;
    alternatives = instruction->alternatives;
    TRIE_REALLOC_N(alternatives, trie_literal_t, count + 1);
    instruction->alternatives = alternatives;
    alternatives[count].bytes = NULL;
    alternatives[count].length = 0;
    instruction->alternative_count++;
    copy = TRIE_ALLOC_N(unsigned char, length);
    memcpy(copy, bytes, length);
    alternatives[count].bytes = copy;
    alternatives[count].length = length;
    return true;
}

static void
trie_instruction_clear(trie_instruction_t *instruction)
{
    size_t index;
    for (index = 0; index < instruction->alternative_count; index++) {
        xfree(instruction->alternatives[index].bytes);
    }
    xfree(instruction->alternatives);
    memset(instruction, 0, sizeof(*instruction));
}

static bool
trie_parse_literal_alternatives(trie_parser_t *parser, trie_opcode_t preceding)
{
    trie_instruction_t empty;
    trie_instruction_t *instruction;
    bool closed = false;
    if (!trie_parser_consume(parser, "(?:")) return false;
    memset(&empty, 0, sizeof(empty));
    empty.opcode = TRIE_LITERAL_ALTERNATIVES;
    if (!trie_program_add_instruction(parser->program, empty)) return false;
    instruction = &parser->program->instructions[parser->program->instruction_count - 1];
    while (parser->position < parser->length) {
        unsigned char buffer[32];
        size_t length = 0;
        while (parser->position < parser->length) {
            unsigned char byte = parser->bytes[parser->position++];
            if (byte == '|' || byte == ')') {
                closed = byte == ')';
                break;
            }
            if (byte == '\\') {
                if (parser->position >= parser->length) goto fail;
                byte = parser->bytes[parser->position++];
                if (!trie_literal_meta(byte) && byte != '/' && byte != '-' && byte != '#') goto fail;
            }
            else if (trie_literal_meta(byte)) goto fail;
            if (length == sizeof(buffer)) goto fail;
            buffer[length++] = byte;
        }
        if (length == 0 || trie_capture_accepts(preceding, buffer[0]) ||
            !trie_add_literal_alternative(instruction, buffer, length)) goto fail;
        if (closed) break;
    }
    if (!closed || instruction->alternative_count < 2) goto fail;
    /* Alternatives must be prefix-free or the native first choice could hide
     * a longer Ruby choice. */
    for (size_t left = 0; left < instruction->alternative_count; left++) {
        for (size_t right = left + 1; right < instruction->alternative_count; right++) {
            trie_literal_t *a = &instruction->alternatives[left];
            trie_literal_t *b = &instruction->alternatives[right];
            size_t limit = a->length < b->length ? a->length : b->length;
            if (memcmp(a->bytes, b->bytes, limit) == 0) goto fail;
        }
    }
    return true;
  fail:
    return false;
}

static bool
trie_parse_literal(trie_parser_t *parser, trie_opcode_t preceding)
{
    trie_instruction_t empty;
    trie_instruction_t *instruction;
    unsigned char buffer[64];
    size_t length = 0;
    if (trie_parser_starts_with(parser, "(?:")) {
        return trie_parse_literal_alternatives(parser, preceding);
    }
    while (parser->position < parser->length && !trie_parser_starts_with(parser, "(?<")) {
        unsigned char byte = parser->bytes[parser->position++];
        if (byte == '\\') {
            if (parser->position >= parser->length) return false;
            byte = parser->bytes[parser->position++];
            if (!trie_literal_meta(byte) && byte != '/' && byte != '-' && byte != '#') return false;
        }
        else if (trie_literal_meta(byte)) return false;
        if (length == sizeof(buffer)) return false;
        buffer[length++] = byte;
    }
    if (length == 0 || trie_capture_accepts(preceding, buffer[0])) return false;
    memset(&empty, 0, sizeof(empty));
    empty.opcode = TRIE_LITERAL_ALTERNATIVES;
    if (!trie_program_add_instruction(parser->program, empty)) return false;
    instruction = &parser->program->instructions[parser->program->instruction_count - 1];
    if (!trie_add_literal_alternative(instruction, buffer, length)) return false;
    return true;
}

static uint64_t
trie_hash_source(VALUE source, size_t length, int encoding, int options)
{
    uint64_t hash = UINT64_C(1469598103934665603);
    size_t index = 0;
    while (index < length) {
        size_t limit = length - index > 16384 ? index + 16384 : length;
        const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(source);
        while (index < limit) {
            hash ^= bytes[index++];
            hash *= UINT64_C(1099511628211);
        }
        if (index < length) trie_check_interrupts();
    }
    hash ^= (uint32_t)encoding;
    hash *= UINT64_C(1099511628211);
    hash ^= (uint32_t)options;
    return hash ? hash : 1;
}

static void
trie_ensure_program_inventory(trie_t *trie, size_t minimum)
{
    size_t capacity;
    if (minimum <= trie->program_capacity) return;
    if (!trie_size_grow(trie->program_capacity, minimum, sizeof(*trie->programs), &capacity)) rb_memerror();
    TRIE_REALLOC_N(trie->programs, trie_program_t *, capacity);
    trie->program_capacity = capacity;
}

static void
trie_program_cache_rebuild(trie_t *trie, size_t capacity)
{
    trie_program_t **cache = TRIE_ALLOC_N(trie_program_t *, capacity);
    size_t index;
    memset(cache, 0, capacity * sizeof(*cache));
    for (index = 0; index < trie->program_count; index++) {
        trie_program_t *program = trie->programs[index];
        size_t slot = (size_t)program->key_hash & (capacity - 1);
        while (cache[slot]) slot = (slot + 1) & (capacity - 1);
        cache[slot] = program;
    }
    xfree(trie->program_cache);
    trie->program_cache = cache;
    trie->program_cache_capacity = capacity;
}

static trie_program_t *
trie_compile_program(trie_t *trie, VALUE source, int options, VALUE timeout)
{
    size_t length;
    int encoding;
    uint64_t hash;
    size_t slot;
    trie_program_t *program;
    trie_parser_t parser;
    bool success = false;

    if (options != 0) return NULL;
    if (!NIL_P(timeout)) return NULL;
    if (!rb_enc_asciicompat(rb_enc_get(source)) || !rb_enc_str_asciionly_p(source)) return NULL;
    length = (size_t)RSTRING_LEN(source);
    if (length == 0 || length > TRIE_PROGRAM_SOURCE_BYTES) return NULL;
    encoding = rb_enc_get_index(source);
    hash = trie_hash_source(source, length, encoding, options);

    if (trie->program_cache_capacity) {
        slot = (size_t)hash & (trie->program_cache_capacity - 1);
        while ((program = trie->program_cache[slot])) {
            if (program->key_hash == hash && program->key_length == length &&
                program->key_encoding == encoding && program->key_options == options &&
                memcmp(program->key, RSTRING_PTR(source), length) == 0) return program;
            slot = (slot + 1) & (trie->program_cache_capacity - 1);
        }
    }

    trie_ensure_program_inventory(trie, trie->program_count + 1);
    program = TRIE_ALLOC(trie_program_t);
    memset(program, 0, sizeof(*program));
    trie->programs[trie->program_count++] = program;
    program->key = TRIE_ALLOC_N(unsigned char, length);
    memcpy(program->key, RSTRING_PTR(source), length);
    program->key_length = length;
    program->key_hash = hash;
    program->key_encoding = encoding;
    program->key_options = options;

    memset(&parser, 0, sizeof(parser));
    parser.bytes = program->key;
    parser.length = length;
    parser.program = program;
    if (parser.length >= 6 && memcmp(parser.bytes, "(?:", 3) == 0 &&
        memcmp(parser.bytes + parser.length - 3, ")\\z", 3) == 0) {
        parser.position = 3;
        parser.length -= 3;
        program->end_anchor = true;
    }
    else if (parser.length >= 2 && memcmp(parser.bytes + parser.length - 2, "\\z", 2) == 0) {
        parser.length -= 2;
        program->end_anchor = true;
    }
    trie_parser_consume(&parser, "\\G");
    if (!trie_parse_capture(&parser)) goto finish;
    while (parser.position < parser.length) {
        trie_opcode_t preceding = program->instructions[program->instruction_count - 1].opcode;
        if (!trie_parse_literal(&parser, preceding)) goto finish;
        if (!trie_parse_capture(&parser)) goto finish;
    }
    success = program->instruction_count > 0 && program->capture_count > 0;

  finish:
    if (!success) {
        trie->program_count--;
        trie_program_free(program);
        return NULL;
    }
    if (!trie->program_cache_capacity ||
        trie->program_count * 10 >= trie->program_cache_capacity * 7) {
        size_t capacity = trie->program_cache_capacity ? trie->program_cache_capacity * 2 : 16;
        if (capacity < trie->program_cache_capacity) rb_memerror();
        trie_program_cache_rebuild(trie, capacity);
    }
    else {
        slot = (size_t)hash & (trie->program_cache_capacity - 1);
        while (trie->program_cache[slot]) slot = (slot + 1) & (trie->program_cache_capacity - 1);
        trie->program_cache[slot] = program;
    }
    RB_GC_GUARD(source);
    RB_GC_GUARD(timeout);
    return program;
}

typedef struct {
    VALUE source;
    VALUE timeout;
    int options;
} trie_regexp_build_t;

static VALUE
trie_build_regexp(VALUE opaque)
{
    trie_regexp_build_t *build = (trie_regexp_build_t *)(uintptr_t)opaque;
    if (NIL_P(build->timeout)) return rb_reg_new_str(build->source, build->options);
    VALUE keywords = rb_hash_new();
    VALUE arguments[3] = {build->source, INT2NUM(build->options), keywords};
    rb_hash_aset(keywords, ID2SYM(id_timeout), build->timeout);
    return rb_funcallv_kw(rb_cRegexp, rb_intern("new"), 3, arguments, RB_PASS_KEYWORDS);
}

static VALUE
trie_anchored_regexp(VALUE source, int options, VALUE timeout)
{
    VALUE wrapped = rb_str_new_cstr("\\G(?:");
    trie_regexp_build_t build;
    VALUE regexp;
    int state = 0;
    rb_enc_copy(wrapped, source);
    rb_str_concat(wrapped, source);
    rb_str_cat_cstr(wrapped, ")");
    build.source = wrapped;
    build.timeout = timeout;
    build.options = options;
    regexp = rb_protect(trie_build_regexp, (VALUE)(uintptr_t)&build, &state);
    if (state) {
        VALUE error = rb_errinfo();
        if (!rb_obj_is_kind_of(error, rb_eRegexpError)) rb_jump_tag(state);
        rb_set_errinfo(Qnil);
        wrapped = rb_str_new_cstr("\\G(?:");
        rb_enc_copy(wrapped, source);
        rb_str_concat(wrapped, source);
        /* A trailing extended-mode comment can consume our close. The newline
         * is ignored exactly when extended mode remains active at source end. */
        rb_str_cat_cstr(wrapped, "\n)");
        build.source = wrapped;
        regexp = trie_build_regexp((VALUE)(uintptr_t)&build);
        RB_GC_GUARD(error);
    }
    rb_obj_freeze(regexp);
    RB_GC_GUARD(source);
    RB_GC_GUARD(timeout);
    RB_GC_GUARD(wrapped);
    return regexp;
}

static bool
trie_string_bytes_equal(VALUE left, VALUE right)
{
    long length = RSTRING_LEN(left);
    long offset = 0;
    if (length != RSTRING_LEN(right)) return false;
    while (offset < length) {
        long count = length - offset;
        if (count > 16384) count = 16384;
        if (memcmp(RSTRING_PTR(left) + offset, RSTRING_PTR(right) + offset,
                   (size_t)count) != 0) return false;
        offset += count;
        if (offset < length) trie_check_interrupts();
    }
    return true;
}

static bool
trie_timeout_equal(VALUE left, VALUE right)
{
    if (left == right) return true;
    if (NIL_P(left) || NIL_P(right)) return false;
    return RTEST(rb_eql(left, right));
}

static bool
trie_regexp_edge_equal(const trie_regexp_edge_t *edge, VALUE source,
                       int options, VALUE timeout)
{
    return edge->options == options && rb_enc_get_index(edge->source) == rb_enc_get_index(source) &&
           trie_string_bytes_equal(edge->source, source) &&
           trie_timeout_equal(edge->timeout, timeout);
}

static trie_node_t *
trie_insert_string(trie_t *trie, trie_node_t *node, VALUE string)
{
    size_t offset = 0;
    size_t length = (size_t)RSTRING_LEN(string);
    while (offset < length) {
        long found = trie_find_static_edge(node, string, offset);
        if (found < 0) {
            trie_node_t *child = trie_node_new(trie);
            VALUE label = trie_frozen_string(string, (long)offset, (long)(length - offset));
            size_t edge_index = node->static_count;
            trie_ensure_static_edges(node, node->static_count + 1);
            node->static_edges[edge_index].label = label;
            node->static_edges[edge_index].child = child;
            node->static_edges[edge_index].encoding = rb_enc_get_index(label);
            node->static_count++;
            trie->static_edge_count++;
            trie_index_static_edge(trie, node, edge_index);
            RB_GC_GUARD(label);
            return child;
        }
        trie_static_edge_t *edge = &node->static_edges[found];
        size_t shared = trie_common_prefix(edge->label, string, offset);
        size_t edge_length = (size_t)RSTRING_LEN(edge->label);
        if (shared == edge_length) {
            node = edge->child;
            offset += shared;
            continue;
        }

        trie_node_t *middle = trie_node_new(trie);
        VALUE old_label = edge->label;
        VALUE prefix = trie_frozen_string(old_label, 0, (long)shared);
        VALUE old_suffix = trie_frozen_string(old_label, (long)shared, (long)(edge_length - shared));
        trie_ensure_static_edges(middle, shared == length - offset ? 1 : 2);
        middle->static_edges[0].label = old_suffix;
        middle->static_edges[0].child = edge->child;
        middle->static_edges[0].encoding = rb_enc_get_index(old_suffix);
        middle->static_count = 1;
        trie->static_edge_count++;
        trie_index_static_edge(trie, middle, 0);
        edge->label = prefix;
        edge->child = middle;
        edge->encoding = rb_enc_get_index(prefix);
        offset += shared;
        if (offset == length) {
            RB_GC_GUARD(old_label);
            RB_GC_GUARD(prefix);
            RB_GC_GUARD(old_suffix);
            return middle;
        }
        trie_node_t *child = trie_node_new(trie);
        VALUE new_suffix = trie_frozen_string(string, (long)offset, (long)(length - offset));
        middle->static_edges[1].label = new_suffix;
        middle->static_edges[1].child = child;
        middle->static_edges[1].encoding = rb_enc_get_index(new_suffix);
        middle->static_count = 2;
        trie->static_edge_count++;
        trie_index_static_edge(trie, middle, 1);
        RB_GC_GUARD(old_label);
        RB_GC_GUARD(prefix);
        RB_GC_GUARD(old_suffix);
        RB_GC_GUARD(new_suffix);
        return child;
    }
    return node;
}

static trie_node_t *
trie_insert_regexp(trie_t *trie, trie_node_t *node, VALUE regexp)
{
    VALUE source = RREGEXP_SRC(regexp);
    VALUE source_copy = rb_str_dup(source);
    VALUE timeout = regexp_timeout_supported ? rb_funcall(regexp, id_timeout, 0) : Qnil;
    int options = rb_reg_options(regexp);
    size_t index;
    if (!NIL_P(timeout) && !RB_FLOAT_TYPE_P(timeout) && !RB_INTEGER_TYPE_P(timeout)) {
        rb_raise(rb_eTypeError, "regexp timeout must be numeric or nil");
    }
    rb_obj_freeze(source_copy);
    for (index = 0; index < node->regexp_count; index++) {
        if (trie_regexp_edge_equal(&node->regexp_edges[index], source_copy, options, timeout)) {
            RB_GC_GUARD(source);
            RB_GC_GUARD(source_copy);
            RB_GC_GUARD(timeout);
            return node->regexp_edges[index].child;
        }
    }
    VALUE anchored = trie_anchored_regexp(source_copy, options, timeout);
    trie_program_t *program = trie_compile_program(trie, source_copy, options, timeout);
    trie_node_t *child = trie_node_new(trie);
    trie_ensure_regexp_edges(node, node->regexp_count + 1);
    trie_regexp_edge_t *edge = &node->regexp_edges[node->regexp_count++];
    edge->source = source_copy;
    edge->anchored = anchored;
    edge->timeout = timeout;
    edge->options = options;
    edge->program = program;
    edge->child = child;
    trie->regexp_edge_count++;
    RB_GC_GUARD(source);
    RB_GC_GUARD(source_copy);
    RB_GC_GUARD(timeout);
    RB_GC_GUARD(anchored);
    return child;
}

static void
trie_insert_entry(trie_t *trie, VALUE parts, uint32_t token)
{
    trie_node_t *node = trie->root;
    long index;
    Check_Type(parts, T_ARRAY);
    for (index = 0; index < RARRAY_LEN(parts); index++) {
        VALUE part = RARRAY_AREF(parts, index);
        if (RB_TYPE_P(part, T_STRING)) {
            VALUE stable_part = rb_str_new_frozen(part);
            if (rb_enc_str_coderange(stable_part) == ENC_CODERANGE_BROKEN) {
                rb_raise(rb_eArgError, "trie literal has invalid encoding");
            }
            node = trie_insert_string(trie, node, stable_part);
            RB_GC_GUARD(stable_part);
        }
        else if (rb_obj_is_kind_of(part, rb_cRegexp)) {
            node = trie_insert_regexp(trie, node, part);
        }
        else {
            rb_raise(rb_eTypeError, "trie parts must be strings or regular expressions");
        }
        if ((index & (TRIE_INTERRUPT_INTERVAL - 1)) == TRIE_INTERRUPT_INTERVAL - 1) trie_check_interrupts();
    }
    trie_ensure_tokens(node, node->token_count + 1);
    node->tokens[node->token_count++] = token;
}

static void
trie_validate_references(VALUE self)
{
    trie_t *trie;
    size_t node_index;
    size_t program_index;
    TypedData_Get_Struct(self, trie_t, &trie_type, trie);
    if (!NIL_P(trie->owner)) {
        containers_check_shareable(trie->owner);
        return;
    }
    containers_check_shareable(trie->tokens);
    for (node_index = 0; node_index < trie->node_count; node_index++) {
        trie_node_t *node = trie->nodes[node_index];
        size_t index;
        for (index = 0; index < node->static_count; index++) {
            containers_check_shareable(node->static_edges[index].label);
        }
        for (index = 0; index < node->regexp_count; index++) {
            containers_check_shareable(node->regexp_edges[index].source);
            containers_check_shareable(node->regexp_edges[index].anchored);
            containers_check_shareable(node->regexp_edges[index].timeout);
        }
    }
    for (program_index = 0; program_index < trie->program_count; program_index++) {
        trie_program_t *program = trie->programs[program_index];
        size_t index;
        for (index = 0; index < program->instruction_count; index++) {
            if (program->instructions[index].opcode != TRIE_LITERAL_ALTERNATIVES) {
                containers_check_shareable(program->instructions[index].name);
            }
        }
    }
}

static VALUE
trie_initialize(VALUE self, VALUE entries, VALUE tokens)
{
    trie_t *trie;
    VALUE token_copy;
    VALUE token_identities;
    long index;
    TypedData_Get_Struct(self, trie_t, &trie_type, trie);
    if (trie->initialized || trie->node_count || !NIL_P(trie->tokens)) {
        rb_raise(rb_eRuntimeError, "trie initialization already attempted");
    }
    Check_Type(entries, T_ARRAY);
    Check_Type(tokens, T_ARRAY);
    if ((unsigned long)RARRAY_LEN(tokens) > UINT32_MAX) rb_raise(rb_eArgError, "too many trie tokens");
    token_copy = rb_ary_new_capa(RARRAY_LEN(tokens));
    token_identities = rb_hash_new();
    rb_funcall(token_identities, rb_intern("compare_by_identity"), 0);
    for (index = 0; index < RARRAY_LEN(tokens); index++) {
        VALUE token = RARRAY_AREF(tokens, index);
        containers_check_shareable(token);
        if (rb_hash_lookup2(token_identities, token, Qundef) != Qundef) {
            rb_raise(rb_eArgError, "trie tokens must have unique identities");
        }
        rb_hash_aset(token_identities, token, Qtrue);
        rb_ary_push(token_copy, token);
        if ((index & (TRIE_INTERRUPT_INTERVAL - 1)) == TRIE_INTERRUPT_INTERVAL - 1) trie_check_interrupts();
    }
    rb_obj_freeze(token_copy);
    trie->tokens = token_copy;
    trie->root = trie_node_new(trie);

    for (index = 0; index < RARRAY_LEN(entries); index++) {
        VALUE entry = RARRAY_AREF(entries, index);
        VALUE parts;
        VALUE identifier;
        unsigned long id;
        Check_Type(entry, T_ARRAY);
        if (RARRAY_LEN(entry) != 2) rb_raise(rb_eArgError, "trie entry must contain parts and token id");
        parts = RARRAY_AREF(entry, 0);
        identifier = RARRAY_AREF(entry, 1);
        if (!RB_INTEGER_TYPE_P(identifier)) rb_raise(rb_eTypeError, "trie token id must be an integer");
        id = NUM2ULONG(identifier);
        if (id >= (unsigned long)RARRAY_LEN(token_copy) || id > UINT32_MAX) {
            rb_raise(rb_eArgError, "trie token id is out of range");
        }
        trie_insert_entry(trie, parts, (uint32_t)id);
        if ((index & (TRIE_INTERRUPT_INTERVAL - 1)) == TRIE_INTERRUPT_INTERVAL - 1) trie_check_interrupts();
    }
    trie->initialized = true;
    rb_obj_freeze(self);
    containers_publish_native_with_references(self, trie_validate_references);
    RB_GC_GUARD(entries);
    RB_GC_GUARD(tokens);
    RB_GC_GUARD(token_copy);
    RB_GC_GUARD(token_identities);
    return self;
}

static void
trie_search_ensure_frames(trie_search_t *search, size_t minimum)
{
    size_t capacity;
    trie_frame_t *frames;
    if (minimum <= search->frame_capacity) return;
    if (!trie_size_grow(search->frame_capacity, minimum, sizeof(*frames), &capacity)) rb_memerror();
    if (search->frame_scratch == 0) {
        frames = trie_scratch_allocate(&search->frame_scratch, capacity, sizeof(*frames));
        memcpy(frames, search->frames, search->frame_count * sizeof(*frames));
    }
    else frames = trie_scratch_resize(search->frame_scratch, capacity, sizeof(*frames));
    search->frames = frames;
    search->frame_capacity = capacity;
}

static void
trie_search_push_frame(trie_search_t *search, trie_node_t *node, long cursor,
                       size_t restore_events)
{
    trie_frame_t *frame;
    trie_search_ensure_frames(search, search->frame_count + 1);
    frame = &search->frames[search->frame_count++];
    memset(frame, 0, sizeof(*frame));
    frame->node = node;
    frame->cursor = cursor;
    frame->restore_events = restore_events;
    if (node->static_index && cursor < search->input_length) {
        unsigned char first = (unsigned char)RSTRING_PTR(search->input)[cursor];
        const uint32_t *slot = trie_static_index_slot_const(node->static_index, first);
        frame->static_index = slot ? *slot : 0;
    }
}

static void
trie_search_ensure_events(trie_search_t *search, size_t minimum)
{
    size_t capacity;
    trie_capture_event_t *events;
    if (minimum <= search->event_capacity) return;
    if (!trie_size_grow(search->event_capacity, minimum, sizeof(*events), &capacity)) rb_memerror();
    if (search->event_scratch == 0) {
        events = trie_scratch_allocate(&search->event_scratch, capacity, sizeof(*events));
        memcpy(events, search->events, search->event_count * sizeof(*events));
    }
    else events = trie_scratch_resize(search->event_scratch, capacity, sizeof(*events));
    search->events = events;
    search->event_capacity = capacity;
}

static void
trie_search_append_native(trie_search_t *search, long begin, long end, VALUE name)
{
    trie_capture_event_t *event;
    trie_search_ensure_events(search, search->event_count + 1);
    event = &search->events[search->event_count++];
    event->kind = TRIE_EVENT_NATIVE;
    event->begin = begin;
    event->end = end;
    event->name = name;
    event->match_index = -1;
}

static void
trie_search_append_ruby(trie_search_t *search, VALUE match)
{
    trie_capture_event_t *event;
    if (NIL_P(search->matches)) search->matches = rb_ary_new();
    long match_index = RARRAY_LEN(search->matches);
    rb_ary_push(search->matches, match);
    trie_search_ensure_events(search, search->event_count + 1);
    event = &search->events[search->event_count++];
    event->kind = TRIE_EVENT_RUBY;
    event->begin = event->end = 0;
    event->name = Qnil;
    event->match_index = match_index;
}

static bool
trie_program_match(const trie_program_t *program, VALUE input, long cursor,
                   trie_search_t *search, long *end_cursor)
{
    long length = RSTRING_LEN(input);
    size_t index;
    for (index = 0; index < program->instruction_count; index++) {
        const trie_instruction_t *instruction = &program->instructions[index];
        if (instruction->opcode == TRIE_LITERAL_ALTERNATIVES) {
            size_t alternative;
            bool matched = false;
            for (alternative = 0; alternative < instruction->alternative_count; alternative++) {
                const trie_literal_t *literal = &instruction->alternatives[alternative];
                const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(input);
                if (literal->length <= (size_t)(length - cursor) &&
                    memcmp(bytes + cursor, literal->bytes, literal->length) == 0) {
                    cursor += (long)literal->length;
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        else {
            long begin = cursor;
            while (cursor < length) {
                const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(input);
                if (!trie_capture_accepts(instruction->opcode, bytes[cursor])) break;
                cursor++;
                trie_search_work_checkpoint(search);
            }
            if (cursor == begin) return false;
            trie_search_append_native(search, begin, cursor, instruction->name);
        }
    }
    if (program->end_anchor && cursor != length) return false;
    *end_cursor = cursor;
    return true;
}

static bool
trie_native_program_allowed(const trie_program_t *program, trie_search_t *search, long cursor)
{
    if (!search->native_segment_input || (program->requires_ascii_input && !search->ascii_input)) return false;
    if (search->utf8_input && cursor < search->input_length) {
        const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(search->input);
        if ((bytes[cursor] & 0xc0) == 0x80) return false;
    }
    return true;
}

static bool
trie_static_match(VALUE input, long cursor, const trie_static_edge_t *edge,
                  long label_length, int input_encoding)
{
    VALUE label = edge->label;
    long offset = 0;
    if (label_length > RSTRING_LEN(input) - cursor) return false;
    if ((unsigned char)RSTRING_PTR(input)[cursor] != (unsigned char)RSTRING_PTR(label)[0]) return false;
    if (edge->encoding != input_encoding && !rb_enc_compatible(label, input)) return false;
    if (label_length <= 16384) {
        return memcmp(RSTRING_PTR(input) + cursor, RSTRING_PTR(label), (size_t)label_length) == 0;
    }
    while (offset < label_length) {
        long length = label_length - offset;
        if (length > 16384) length = 16384;
        if (memcmp(RSTRING_PTR(input) + cursor + offset,
                   RSTRING_PTR(label) + offset, (size_t)length) != 0) return false;
        offset += length;
        if (offset < label_length) trie_check_interrupts();
    }
    return true;
}

static bool
trie_regexp_match(const trie_regexp_edge_t *edge, trie_search_t *search,
                  long cursor, long *end_cursor)
{
    size_t restore = search->event_count;
    if (edge->program) {
        if (!search->regexp_timeout_checked) {
            search->regexp_timeout_checked = true;
            if (regexp_timeout_supported && !NIL_P(rb_funcall(rb_cRegexp, id_timeout, 0))) {
                search->native_segment_input = false;
            }
        }
        if (trie_native_program_allowed(edge->program, search, cursor)) {
            if (trie_program_match(edge->program, search->input, cursor, search, end_cursor)) return true;
            search->event_count = restore;
            return false;
        }
    }
    long position = rb_reg_search(edge->anchored, search->input, cursor, 0);
    if (position < 0) return false;
    VALUE match = rb_backref_get();
    struct re_registers *registers = RMATCH_REGS(match);
    if (!registers || registers->num_regs < 1 || registers->end[0] < cursor) return false;
    *end_cursor = registers->end[0];
    /* Subsequent regexp searches may otherwise recycle the current backref's
     * MatchData storage while this branch still retains it. */
    rb_match_busy(match);
    trie_search_append_ruby(search, match);
    RB_GC_GUARD(match);
    return true;
}

static void
trie_merge_named(VALUE named, VALUE key, VALUE value)
{
    VALUE previous = rb_hash_lookup2(named, key, Qundef);
    if (previous == Qundef) rb_hash_aset(named, key, value);
    else if (RB_TYPE_P(previous, T_ARRAY)) rb_ary_push(previous, value);
    else rb_hash_aset(named, key, rb_ary_new_from_args(2, previous, value));
}

typedef struct { VALUE destination; } trie_named_merge_t;

static int
trie_merge_named_i(VALUE key, VALUE value, VALUE opaque)
{
    trie_named_merge_t *merge = (trie_named_merge_t *)(uintptr_t)opaque;
    trie_merge_named(merge->destination, key, value);
    return ST_CONTINUE;
}

static void
trie_materialize_captures(trie_search_t *search, VALUE *captures, VALUE *named)
{
    size_t index;
    *captures = rb_ary_new();
    *named = rb_hash_new();
    for (index = 0; index < search->event_count; index++) {
        trie_capture_event_t *event = &search->events[index];
        if (event->kind == TRIE_EVENT_NATIVE) {
            VALUE value = rb_str_subseq(search->input, event->begin, event->end - event->begin);
            rb_ary_push(*captures, value);
            trie_merge_named(*named, event->name, value);
        }
        else {
            VALUE match = RARRAY_AREF(search->matches, event->match_index);
            VALUE edge_captures = rb_funcall(match, id_captures, 0);
            VALUE edge_named = rb_funcall(match, id_named_captures, 0);
            trie_named_merge_t merge = {.destination = *named};
            rb_ary_concat(*captures, edge_captures);
            rb_hash_foreach(edge_named, trie_merge_named_i, (VALUE)(uintptr_t)&merge);
            RB_GC_GUARD(edge_captures);
            RB_GC_GUARD(edge_named);
        }
    }
}

static void
trie_seen_rebuild(trie_search_t *search, size_t capacity)
{
    uint32_t *old = search->seen;
    VALUE old_scratch = search->seen_scratch;
    size_t old_capacity = search->seen_capacity;
    size_t source_length = search->seen_hashed ? old_capacity : search->seen_count;
    uint32_t *table = trie_scratch_allocate(&search->seen_building_scratch,
                                            capacity, sizeof(*table));
    size_t index;

    /* The ensure cleanup owns both tables until the replacement is complete. */
    search->seen_building = table;
    for (index = 0; index < capacity; index++) {
        table[index] = UINT32_MAX;
        trie_search_work_checkpoint(search);
    }
    for (index = 0; index < source_length; index++) {
        uint32_t existing = old[index];
        size_t slot;
        if (search->seen_hashed && existing == UINT32_MAX) {
            trie_search_work_checkpoint(search);
            continue;
        }
        slot = ((uint64_t)existing * UINT64_C(11400714819323198485)) & (capacity - 1);
        while (table[slot] != UINT32_MAX) {
            slot = (slot + 1) & (capacity - 1);
            trie_search_work_checkpoint(search);
        }
        table[slot] = existing;
        trie_search_work_checkpoint(search);
    }
    search->seen = table;
    search->seen_capacity = capacity;
    search->seen_hashed = true;
    search->seen_building = NULL;
    search->seen_scratch = search->seen_building_scratch;
    search->seen_building_scratch = 0;
    trie_scratch_release(old_scratch);
}

static bool
trie_seen(trie_search_t *search, uint32_t token)
{
    size_t index;
    if (search->first_only) return false;
    if (!search->seen_hashed) {
        for (index = 0; index < search->seen_count; index++) {
            if (search->seen[index] == token) return true;
        }
        if (search->seen_count < search->seen_capacity) {
            search->seen[search->seen_count++] = token;
            return false;
        }
        trie_seen_rebuild(search, 32);
    }
    if (search->seen_count + 1 >= search->seen_capacity - search->seen_capacity / 4) {
        size_t capacity = search->seen_capacity * 2;
        if (capacity < search->seen_capacity || capacity > SIZE_MAX / sizeof(*search->seen)) rb_memerror();
        trie_seen_rebuild(search, capacity);
    }
    size_t slot = ((uint64_t)token * UINT64_C(11400714819323198485)) & (search->seen_capacity - 1);
    while (search->seen[slot] != UINT32_MAX) {
        if (search->seen[slot] == token) return true;
        slot = (slot + 1) & (search->seen_capacity - 1);
        trie_search_work_checkpoint(search);
    }
    search->seen[slot] = token;
    search->seen_count++;
    return false;
}

static bool
trie_emit_terminal(trie_search_t *search, trie_frame_t *frame)
{
    trie_node_t *node = frame->node;
    size_t index;
    for (index = 0; index < node->token_count; index++) {
        uint32_t id = node->tokens[index];
        VALUE captures;
        VALUE named;
        VALUE suffix;
        VALUE token;
        VALUE result;
        trie_search_work_checkpoint(search);
        if (trie_seen(search, id)) continue;
        trie_materialize_captures(search, &captures, &named);
        suffix = rb_str_subseq(search->input, frame->cursor, search->input_length - frame->cursor);
        token = RARRAY_AREF(search->trie->tokens, (long)id);
        if (search->stream) {
            rb_yield_values(4, token, captures, named, suffix);
            continue;
        }
        result = rb_ary_new_from_args(4, token, captures, named, suffix);
        if (search->first_only) {
            search->first = result;
            return true;
        }
        rb_ary_push(search->results, result);
    }
    return false;
}

static VALUE
trie_search_body(VALUE opaque)
{
    trie_search_t *search = (trie_search_t *)(uintptr_t)opaque;
    trie_search_push_frame(search, search->trie->root, 0, 0);
    while (search->frame_count) {
        trie_frame_t *frame = &search->frames[search->frame_count - 1];
        trie_search_work_checkpoint(search);
        if (frame->phase == 0) {
            bool descended = false;
            if (frame->node->static_index) {
                while (frame->static_index) {
                    trie_static_edge_t *edge = &frame->node->static_edges[frame->static_index - 1];
                    long label_length = RSTRING_LEN(edge->label);
                    frame->static_index = edge->next_same_byte;
                    if (!trie_static_match(search->input, frame->cursor, edge,
                                           label_length, search->input_encoding)) continue;
                    trie_search_push_frame(search, edge->child, frame->cursor + label_length,
                                           search->event_count);
                    descended = true;
                    break;
                }
            }
            else {
                while (frame->static_index < frame->node->static_count) {
                    trie_static_edge_t *edge = &frame->node->static_edges[frame->static_index++];
                    long label_length = RSTRING_LEN(edge->label);
                    if (!trie_static_match(search->input, frame->cursor, edge,
                                           label_length, search->input_encoding)) continue;
                    trie_search_push_frame(search, edge->child, frame->cursor + label_length,
                                           search->event_count);
                    descended = true;
                    break;
                }
            }
            if (descended) continue;
            frame->phase = 1;
        }
        if (frame->phase == 1) {
            bool descended = false;
            while (frame->regexp_index < frame->node->regexp_count) {
                trie_regexp_edge_t *edge = &frame->node->regexp_edges[frame->regexp_index++];
                size_t restore = search->event_count;
                long end_cursor;
                if (!trie_regexp_match(edge, search, frame->cursor, &end_cursor)) {
                    search->event_count = restore;
                    continue;
                }
                trie_search_push_frame(search, edge->child, end_cursor, restore);
                descended = true;
                break;
            }
            if (descended) continue;
            frame->phase = 2;
        }
        if (frame->phase == 2) {
            frame->phase = 3;
            if ((search->peek || frame->cursor == search->input_length) &&
                trie_emit_terminal(search, frame)) break;
        }
        if (frame->phase == 3) {
            size_t restore = frame->restore_events;
            search->frame_count--;
            search->event_count = restore;
        }
    }
    if (search->stream) return search->self;
    return search->first_only ? search->first : search->results;
}

static VALUE
trie_search_cleanup(VALUE opaque)
{
    trie_search_t *search = (trie_search_t *)(uintptr_t)opaque;
    trie_scratch_release(search->frame_scratch);
    trie_scratch_release(search->event_scratch);
    trie_scratch_release(search->seen_scratch);
    trie_scratch_release(search->seen_building_scratch);
    if (search->previous_backref != Qundef) rb_backref_set(search->previous_backref);
    return Qnil;
}

static VALUE
trie_search(VALUE self, VALUE input, bool peek, bool first_only, bool stream)
{
    trie_search_t search;
    VALUE stable_input;
    int encoding;
    int coderange;
    if (!RB_TYPE_P(input, T_STRING)) rb_raise(rb_eTypeError, "trie input must be a string");
    stable_input = rb_str_new_frozen(input);
    coderange = rb_enc_str_coderange(stable_input);
    if (coderange == ENC_CODERANGE_BROKEN) rb_raise(rb_eArgError, "trie input has invalid encoding");
    memset(&search, 0, offsetof(trie_search_t, inline_frames));
    search.self = self;
    search.input = stable_input;
    search.trie = trie_get(self);
    search.input_length = RSTRING_LEN(stable_input);
    search.frames = search.inline_frames;
    search.frame_capacity = TRIE_INLINE_FRAMES;
    search.events = search.inline_events;
    search.event_capacity = TRIE_INLINE_EVENTS;
    search.seen = search.inline_seen;
    search.seen_capacity = sizeof(search.inline_seen) / sizeof(*search.inline_seen);
    search.results = first_only || stream ? Qnil : rb_ary_new();
    search.matches = Qnil;
    search.previous_backref = search.trie->regexp_edge_count ? rb_backref_get() : Qundef;
    search.first = Qnil;
    search.peek = peek;
    search.first_only = first_only;
    search.stream = stream;
    encoding = rb_enc_get_index(stable_input);
    search.input_encoding = encoding;
    if (search.trie->program_count) {
        search.utf8_input = encoding == rb_utf8_encindex();
        search.ascii_input = coderange == ENC_CODERANGE_7BIT;
        search.native_segment_input = encoding == rb_utf8_encindex() ||
                                      encoding == rb_usascii_encindex() ||
                                      encoding == rb_ascii8bit_encindex();
    }
    VALUE result = rb_ensure(trie_search_body, (VALUE)(uintptr_t)&search,
                             trie_search_cleanup, (VALUE)(uintptr_t)&search);
    RB_GC_GUARD(self);
    RB_GC_GUARD(input);
    RB_GC_GUARD(stable_input);
    RB_GC_GUARD(search.results);
    RB_GC_GUARD(search.matches);
    RB_GC_GUARD(search.previous_backref);
    RB_GC_GUARD(search.first);
    RB_GC_GUARD(search.frame_scratch);
    RB_GC_GUARD(search.event_scratch);
    RB_GC_GUARD(search.seen_scratch);
    RB_GC_GUARD(search.seen_building_scratch);
    return result;
}

static VALUE trie_match(VALUE self, VALUE input) { return trie_search(self, input, false, true, false); }
static VALUE trie_match_all(VALUE self, VALUE input) { return trie_search(self, input, false, false, false); }
static VALUE trie_peek(VALUE self, VALUE input) { return trie_search(self, input, true, true, false); }
static VALUE trie_peek_all(VALUE self, VALUE input) { return trie_search(self, input, true, false, false); }

static VALUE
trie_each_match(VALUE self, VALUE input)
{
    RETURN_ENUMERATOR(self, 1, &input);
    return trie_search(self, input, false, false, true);
}

static VALUE
trie_each_peek(VALUE self, VALUE input)
{
    RETURN_ENUMERATOR(self, 1, &input);
    return trie_search(self, input, true, false, true);
}

static VALUE
trie_initialize_copy(VALUE self, VALUE other)
{
    trie_t *destination;
    trie_t *source;
    VALUE owner;
    TypedData_Get_Struct(self, trie_t, &trie_type, destination);
    TypedData_Get_Struct(other, trie_t, &trie_type, source);
    if (!source->initialized) rb_raise(rb_eTypeError, "cannot copy an uninitialized trie");
    if (destination->initialized) rb_raise(rb_eRuntimeError, "cannot overwrite an initialized trie");
    rb_obj_init_copy(self, other);
    owner = NIL_P(source->owner) ? other : source->owner;
    /* A fresh allocation has no graph yet. Keep the root wrapper alive rather
     * than sharing ownership of raw pointers. */
    trie_release_contents(destination);
    memset(destination, 0, sizeof(*destination));
    destination->tokens = Qnil;
    destination->owner = owner;
    destination->initialized = true;
    rb_obj_freeze(self);
    containers_publish_native_with_references(self, trie_validate_references);
    RB_GC_GUARD(other);
    RB_GC_GUARD(owner);
    return self;
}

static VALUE
trie_stats(VALUE self)
{
    trie_t *trie = trie_get(self);
    VALUE stats = rb_hash_new();
    rb_hash_aset(stats, ID2SYM(rb_intern("nodes")), SIZET2NUM(trie->node_count));
    rb_hash_aset(stats, ID2SYM(rb_intern("static_edges")), SIZET2NUM(trie->static_edge_count));
    rb_hash_aset(stats, ID2SYM(rb_intern("static_index_nodes")), SIZET2NUM(trie->static_index_count));
    rb_hash_aset(stats, ID2SYM(rb_intern("static_index_bytes")),
                 SIZET2NUM(trie->static_index_bytes));
    rb_hash_aset(stats, ID2SYM(rb_intern("dynamic_edges")), SIZET2NUM(trie->regexp_edge_count));
    rb_hash_aset(stats, ID2SYM(rb_intern("native_programs")), SIZET2NUM(trie->program_count));
    rb_hash_aset(stats, ID2SYM(rb_intern("native_bytes")), SIZET2NUM(trie_memsize(trie)));
    return stats;
}

#ifdef FARCE_TRIE_FAILURE_INJECTION
static VALUE
trie_failure_after(VALUE klass, VALUE count)
{
    (void)klass;
    if (NIL_P(count)) trie_failure_countdown = -1;
    else {
        long value = NUM2LONG(count);
        if (value < 0) rb_raise(rb_eArgError, "failure countdown must be nonnegative or nil");
        trie_failure_countdown = value;
    }
    return count;
}

static VALUE
trie_interrupt_queue_set(VALUE klass, VALUE queue)
{
    (void)klass;
    if (!NIL_P(queue)) {
        Check_Type(queue, T_ARRAY);
        if (RARRAY_LEN(queue) != 2) rb_raise(rb_eArgError, "interrupt queues must contain ready and release");
    }
    trie_interrupt_queue = queue;
    return queue;
}

static VALUE
trie_search_scratch_count(VALUE klass)
{
    (void)klass;
    return UINT2NUM(RUBY_ATOMIC_LOAD(trie_scratch_live_count));
}
#endif

void
containers_init_trie(VALUE namespace)
{
    VALUE farce = rb_const_get(rb_cObject, rb_intern("Farce"));
    VALUE strict = rb_const_get(farce, rb_intern("Strict"));
    (void)namespace;
    cTrie = rb_define_class_under(strict, "Trie", rb_cObject);
    rb_define_alloc_func(cTrie, trie_allocate);
    rb_define_private_method(cTrie, "initialize", trie_initialize, 2);
    rb_define_private_method(cTrie, "initialize_copy", trie_initialize_copy, 1);
    rb_define_method(cTrie, "match", trie_match, 1);
    rb_define_method(cTrie, "match_all", trie_match_all, 1);
    rb_define_method(cTrie, "peek", trie_peek, 1);
    rb_define_method(cTrie, "peek_all", trie_peek_all, 1);
    rb_define_method(cTrie, "each_match", trie_each_match, 1);
    rb_define_method(cTrie, "each_peek", trie_each_peek, 1);
    rb_define_method(cTrie, "stats", trie_stats, 0);
#ifdef FARCE_TRIE_FAILURE_INJECTION
    rb_define_private_method(rb_singleton_class(cTrie), "__native_failure_after=", trie_failure_after, 1);
    rb_global_variable(&trie_interrupt_queue);
    rb_define_private_method(rb_singleton_class(cTrie), "__native_interrupt_queue=", trie_interrupt_queue_set, 1);
    rb_define_private_method(rb_singleton_class(cTrie), "__native_search_scratch_count", trie_search_scratch_count, 0);
#endif

    id_captures = rb_intern("captures");
    id_named_captures = rb_intern("named_captures");
    id_timeout = rb_intern("timeout");
    regexp_timeout_supported = rb_respond_to(rb_cRegexp, id_timeout);
}
