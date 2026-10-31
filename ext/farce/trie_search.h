/* Included twice to specialize static matching without a mode branch in the
 * traversal loop. Keep both modes on the same capture and backtracking logic. */

static VALUE
TRIE_SEARCH_BODY(VALUE opaque)
{
    trie_search_t *search = (trie_search_t *)(uintptr_t)opaque;
#if TRIE_IGNORE_CASE
    trie_case_mapping_t mapping = { .encoding = rb_enc_from_index(search->input_encoding) };
    mapping.ascii_compatible = rb_enc_asciicompat(mapping.encoding);
    trie_search_push_frame_ignore_case(search, search->trie->root, 0, 0, 0, &mapping);
#else
    trie_search_push_frame(search, search->trie->root, 0, 0);
#endif
    while (search->frame_count) {
        trie_frame_t *frame = &search->frames[search->frame_count - 1];
        trie_search_work_checkpoint(search);
        if (frame->phase == 0) {
            bool descended = false;
            if (frame->node->static_index) {
                while (frame->static_index) {
                    trie_static_edge_t *edge = &frame->node->static_edges[frame->static_index - 1];
#if TRIE_IGNORE_CASE
                    long end_cursor;
                    unsigned end_offset;
#else
                    long label_length = RSTRING_LEN(edge->label);
#endif
                    frame->static_index = edge->next_same_byte;
#if TRIE_IGNORE_CASE
                    if (!trie_static_match_ignore_case(search, frame, edge, &mapping,
                                                       &end_cursor, &end_offset)) continue;
                    trie_search_push_frame_ignore_case(search, edge->child, end_cursor,
                                                        search->event_count, end_offset, &mapping);
#else
                    if (!trie_static_match(search->input, frame->cursor, edge,
                                           label_length, search->input_encoding)) continue;
                    trie_search_push_frame(search, edge->child, frame->cursor + label_length,
                                           search->event_count);
#endif
                    descended = true;
                    break;
                }
            }
            else {
                while (frame->static_index < frame->node->static_count) {
                    trie_static_edge_t *edge = &frame->node->static_edges[frame->static_index++];
#if TRIE_IGNORE_CASE
                    long end_cursor;
                    unsigned end_offset;
#else
                    long label_length = RSTRING_LEN(edge->label);
#endif
#if TRIE_IGNORE_CASE
                    if (!trie_static_match_ignore_case(search, frame, edge, &mapping,
                                                       &end_cursor, &end_offset)) continue;
                    trie_search_push_frame_ignore_case(search, edge->child, end_cursor,
                                                        search->event_count, end_offset, &mapping);
#else
                    if (!trie_static_match(search->input, frame->cursor, edge,
                                           label_length, search->input_encoding)) continue;
                    trie_search_push_frame(search, edge->child, frame->cursor + label_length,
                                           search->event_count);
#endif
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
#if TRIE_IGNORE_CASE
                if (frame->lowercase_offset) break;
#endif
                trie_regexp_edge_t *edge = &frame->node->regexp_edges[frame->regexp_index++];
                size_t restore = search->event_count;
                long end_cursor;
                if (!trie_regexp_match(edge, search, frame->cursor, &end_cursor)) {
                    search->event_count = restore;
                    continue;
                }
#if TRIE_IGNORE_CASE
                trie_search_push_frame_ignore_case(search, edge->child, end_cursor, restore, 0, &mapping);
#else
                trie_search_push_frame(search, edge->child, end_cursor, restore);
#endif
                descended = true;
                break;
            }
            if (descended) continue;
            frame->phase = 2;
        }
        if (frame->phase == 2) {
            frame->phase = 3;
            if (
#if TRIE_IGNORE_CASE
                !frame->lowercase_offset &&
#endif
                (search->peek || frame->cursor == search->input_length) &&
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

