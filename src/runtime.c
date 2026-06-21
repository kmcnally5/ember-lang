// src/runtime.c — the Ember object runtime (M2a).
//
// Extracted from src/vm.c so ONE implementation of allocation, reference counting,
// and ownership-driven drop serves both backends: the bytecode VM (Ember's reference
// semantics) and the native C backend (`emberc -o`). The VM embeds an EmberRt and
// passes `&vm->rt`; a compiled program declares a global EmberRt and passes `&g_em`.
//
// Nothing here touches dispatch state, the CompiledProgram, or the verification
// machinery — the EmberRt context carries everything needed (the object list, the
// recycle pool, and the struct-layout table) — so this object file links cleanly
// into a bare standalone binary with no compiler front-end attached.
//
// Keep this in lockstep with the VM's behaviour: tests/native/ runs every program on
// both backends and diffs stdout. value_box / value_unbox / array_box / elem_size_for
// (the pure marshalling edge) live in include/ember_rt.h and are shared by both.

#include "ember_rt.h"
#include "builtin.h"   // WITNESS_NATIVE_BASE + the Hash/Eq native-witness ids
#include "cextern.h"   // the in-tree C FFI registry (em_ffi → cextern_call)

#if EMBER_DROP_TRACE
#include <execinfo.h>  // backtrace() for the opt-in double-drop detector (memory tape)
#endif


#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>


// register_object threads a freshly allocated object onto the context's private,
// doubly-linked object list (so unlink_object can splice it out in O(1) at drop
// time) and stamps its home for reclaim's cross-thread-free deferral check.
void register_object(EmberRt *ctx, Obj *o) {
    o->prev = NULL;
    o->refcount = 1;   // the value's first owner is whatever consumes this result
    o->home = ctx;     // reclaimed only by this context (a cross-thread free defers)
    o->next = ctx->objects;
    if (ctx->objects != NULL) {
        ctx->objects->prev = o;
    }
    ctx->objects = o;  // private arena → no lock
}





// pooled_alloc returns a block of at least `size` bytes for a heap object —
// recycled from the matching size-class pool when one is waiting, malloc'd
// otherwise. Pooled blocks are allocated at their class's rounded size so any
// later same-class request fits. Oversized objects fall through to exact malloc
// (size_class -1) and are free()d on death.
void *pooled_alloc(EmberRt *ctx, size_t size) {
    size_t cls = (size + 15) >> 4;
    if (cls < POOL_CLASSES) {
        Obj *o = ctx->pool[cls];        // private arena → no lock
        if (o != NULL) {
            ctx->pool[cls] = o->next;
            o->size_class = (int)cls;
            return o;
        }
        Obj *fresh = malloc(cls << 4);
        if (fresh == NULL) {
            fprintf(stderr, "emberc: out of memory allocating an object\n");
            exit(70);
        }
        fresh->size_class = (int)cls;
        return fresh;
    }
    Obj *big = malloc(size);
    if (big == NULL) {
        fprintf(stderr, "emberc: out of memory allocating an object\n");
        exit(70);
    }
    big->size_class = -1;
    return big;
}





// pooled_free retires a dead, already-unlinked object: small blocks go back to
// their size-class pool for the next allocation, oversized ones to free().
void pooled_free(EmberRt *ctx, Obj *o) {
    if (o->size_class >= 0) {
        o->next = ctx->pool[o->size_class];   // private arena → no lock
        ctx->pool[o->size_class] = o;
        return;
    }
    free(o);
}





// unlink_object removes an object from the context's list (it is about to be freed by
// a scope-exit drop). O(1) thanks to the prev link; updates the head if needed.
void unlink_object(EmberRt *ctx, Obj *o) {
    // Splice `o` out of its home context's private object list (no lock — only the
    // home thread calls this, via reclaim()).
    if (o->prev != NULL) {
        o->prev->next = o->next;
    } else {
        ctx->objects = o->next;
    }
    if (o->next != NULL) {
        o->next->prev = o->prev;
    }
}





// reclaim physically retires a dead object — but only if this context is its home,
// since a context's arena (list + pool) is lock-free and must not be touched by
// another thread. An object freed on a non-home worker (a value moved here through a
// channel and then dropped) is left linked on its home list; the exit sweep frees it.
// The cost is that such cross-thread objects are not recycled mid-run (a bounded,
// exit-reclaimed growth), in exchange for a fully lock-free same-thread hot path.
void reclaim(EmberRt *ctx, Obj *o) {
    if (o->home != ctx) {
        return;
    }
#if EMBER_DROP_TRACE
    // A "memory tape": opt-in double-drop detector (build with -DEMBER_DROP_TRACE). After a reclaim
    // we stamp `refcount` with a sentinel; the pool never touches refcount, and a real re-allocation
    // clears it (register_object). So seeing the sentinel here = a SECOND reclaim before reuse = a
    // double-drop (invisible to plain ASan because the pool recycles, not frees). Print both drop
    // sites (the first is stashed in `prev`) + abort. Used to find OFI-058; see [[trust-the-tape]].
    if (o->refcount == 0x5EAD5EAD) {
        void *bt[24];
        fprintf(stderr, "\n*** EMBER DOUBLE-DROP obj=%p type=%d ***\n", (void *)o, (int)o->type);
        if (o->type == OBJ_STRUCT) {
            fprintf(stderr, "STRUCT type_id=%d field_count=%d\n",
                    ((ObjStruct *)o)->type_id, ((ObjStruct *)o)->field_count);
        }
        fprintf(stderr, "first drop site: %p\n", (void *)o->prev);
        backtrace_symbols_fd(bt, backtrace(bt, 24), 2);
        abort();
    }
#endif
    unlink_object(ctx, o);
    pooled_free(ctx, o);
#if EMBER_DROP_TRACE
    {
        void *bt2[4];
        o->refcount = 0x5EAD5EAD;
        o->prev = (backtrace(bt2, 4) > 2) ? (Obj *)bt2[2] : NULL;   // stash this drop's site
    }
#endif
}





// drop_value releases a value going out of scope. Structs and arrays are unique
// owners (the move checker guarantees no aliasing / partial moves), freed directly
// after recursively releasing their owned children; strings, enums, closures and
// interfaces are reference-counted and freed only at the last owner; channels are
// nursery-scoped and reclaimed by the exit sweep. A non-heap value is a no-op, so
// this is safe to call on any slot the checker hands us.
void drop_value(EmberRt *ctx, Value v) {
    if (!IS_OBJ(v)) {
        return;
    }
    Obj *o = AS_OBJ(v);
    switch (o->type) {
        case OBJ_STRING:
            // A string carries no heap children: release one owner, free at zero.
            if (OBJ_RELEASE(o) <= 0) {
                reclaim(ctx, o);
            }
            return;

        case OBJ_ARRAY: {
            // A unique owner (like a struct): free it directly, first releasing each
            // element (a nested struct/array recursively, a string/enum by dropping a
            // reference) and then the element buffer. Recursion runs regardless of
            // home (each child self-gates); only the home context frees this array's
            // side buffer and reclaims its header.
            ObjArray *a = (ObjArray *)o;
            if (a->borrowed) {
                // A slice view owns neither its elements nor its buffer (it points into the
                // source array). Free only the header — never touch the borrowed elements/buffer.
                if (o->home == ctx) {
                    unlink_object(ctx, o);
                    pooled_free(ctx, o);
                }
                return;
            }
            if (a->elem_kind == AEK_BOXED) {     // packed scalars own nothing
                for (size_t i = 0; i < a->length; i++) {
                    drop_value(ctx, ((Value *)a->data)[i]);
                }
            } else if (a->elem_kind == AEK_INLINE_STRUCT) {
                // Inline struct elements: release each element's boxed sub-fields (a
                // no-op for an all-scalar struct); the packed bytes go with the buffer.
                for (size_t i = 0; i < a->length; i++) {
                    struct_elem_release(ctx, a->elem_struct_id,
                                        (unsigned char *)a->data + i * a->elem_size);
                }
            }
            if (o->home == ctx) {
                free(a->data);
                unlink_object(ctx, o);
                pooled_free(ctx, o);
            }
            return;
        }

        case OBJ_STRUCT: {
            ObjStruct *s = (ObjStruct *)o;
            if (s->is_enum) {
                // An enum is shared + reference-counted; at the last owner, release
                // its payload fields (all boxed 16-byte slots) before freeing it.
                if (OBJ_RELEASE(o) <= 0) {
                    for (int i = 0; i < s->field_count; i++) {
                        int k;
                        unsigned char *p = field_loc(ctx, s, i, &k);
                        drop_value(ctx, value_box(p, k));
                    }
                    reclaim(ctx, o);
                }
                return;
            }
            // A struct is a unique owner: free it, first releasing each BOXED field
            // (a nested struct recursively, a refcounted field by dropping a ref).
            // Packed scalar fields own nothing, so the descriptor's kinds drive it.
            const StructType *st = &ctx->structs[s->type_id];
            for (int i = 0; i < st->field_count; i++) {
                if (st->kind[i] == AEK_BOXED) {
                    drop_value(ctx, value_box(s->data + st->offset[i], AEK_BOXED));
                }
            }
            reclaim(ctx, o);
            return;
        }

        case OBJ_CHANNEL: {
            // A refcounted shareable handle (the creating scope plus each spawned task that
            // borrows it hold a counted reference): retire it at the LAST owner, like a string
            // or closure, but with two channel-specific obligations.
            ObjChannel *ch = (ObjChannel *)o;
            if (OBJ_RELEASE(o) <= 0) {
                // (1) Drain undrained buffered values. send MOVES a value in with no retain
                // (the buffer owns it) and recv moves it out, so any value still queued at the
                // last drop must be dropped here or it — and its heap children — leak. Recurse;
                // each child self-gates on its own home. Done regardless of who fires the last
                // release (a value's home is independent of the channel's).
                for (int i = 0; i < ch->count; i++) {
                    drop_value(ctx, ch->buffer[(ch->head + i) % ch->capacity]);
                }
                // (2) Only the HOME arena may physically retire the shell + its OS primitives:
                // its object list and pool are lock-free and must not be touched cross-thread
                // (the reclaim contract). A non-home last release leaves the (now value-drained)
                // shell linked on its home list for the exit sweep — the documented bounded
                // cross-thread deferral (OFI-018), not a leak of owned values.
                if (o->home == ctx) {
#if EMBER_PARALLEL
                    pthread_mutex_destroy(&ch->lock);
#if !EMBER_MN
                    pthread_cond_destroy(&ch->not_empty);   // M:N uses fiber FIFOs, not condvars
                    pthread_cond_destroy(&ch->not_full);
#endif
#endif
                    free(ch->buffer);
                    ch->buffer = NULL;     // sentinel: tells free_list teardown already ran
                    reclaim(ctx, o);       // unlink + pool the shell (home-only)
                }
            }
            return;
        }

        case OBJ_CLOSURE: {
            // Shared + reference-counted like a string; at the last owner, release
            // each captured value before freeing the closure itself.
            ObjClosure *cl = (ObjClosure *)o;
            if (OBJ_RELEASE(o) <= 0) {
                for (int i = 0; i < cl->capture_count; i++) {
                    drop_value(ctx, cl->captures[i]);
                }
                reclaim(ctx, o);
            }
            return;
        }

        case OBJ_INTERFACE: {
            // A unique owner (a move type) like a struct: free it directly, first
            // releasing the boxed receiver it owns and its vtable (a witness enum of
            // plain ints — dropping it just reclaims that record).
            ObjInterface *it = (ObjInterface *)o;
            drop_value(ctx, it->receiver);
            drop_value(ctx, it->vtable);
            reclaim(ctx, o);
            return;
        }
    }
}





// field_loc returns a pointer to field `index` within instance `s`, and sets `*kind`
// to its storage kind. A struct's layout (offset + kind per field) comes from its
// StructType; an enum's fields are all 16-byte boxed Values at index*16.
unsigned char *field_loc(EmberRt *ctx, ObjStruct *s, int index, int *kind) {
    if (s->is_enum) {
        *kind = AEK_BOXED;
        return s->data + (size_t)index * sizeof(Value);
    }
    const StructType *st = &ctx->structs[s->type_id];
    *kind = st->kind[index];
    return s->data + st->offset[index];
}





// field_inline_sid returns the nested struct's type id for a field stored INLINE
// (kind AEK_INLINE_STRUCT — its packed bytes embed in the parent's buffer); -1 otherwise.
// Used to size the inline bytes and materialise a value COPY on read (value-types 3b.5).
int field_inline_sid(EmberRt *ctx, const ObjStruct *s, int index) {
    if (s->is_enum) {
        return -1;
    }
    const StructType *st = &ctx->structs[s->type_id];
    if (st->kind[index] != AEK_INLINE_STRUCT) {
        return -1;
    }
    return st->field_struct[index];
}





// For an INLINE struct array element at `p` (the packed bytes of struct `struct_id`),
// retain / release its BOXED sub-fields (string/enum/nested struct/array). Scalar
// fields own nothing, so an all-scalar struct makes both a no-op. retain on COPY
// (index); release on DROP or overwrite.
void struct_elem_retain(EmberRt *ctx, int struct_id, unsigned char *p) {
    const StructType *st = &ctx->structs[struct_id];
    for (int f = 0; f < st->field_count; f++) {
        if (st->kind[f] == AEK_BOXED) {
            Value v;
            memcpy(&v, p + st->offset[f], sizeof(Value));
            if (IS_OBJ(v)) {
                OBJ_RETAIN(AS_OBJ(v));
            }
        }
    }
}


// ---- giving a value to a NEW owner: clone unique-owner aggregates, retain refcounted ones --------
// A value STRUCT and an ARRAY are UNIQUE owners (not reference-counted; their drop reclaims them
// unconditionally). So when one is shared into a second owner — built into / read out of an erased
// generic aggregate ([T], Map<_,T>, Option<T>, …) — the two owners must NOT share the object, or each
// reclaims it and it is double-freed (OFI-062 for structs, OFI-063 for arrays). Instead the new owner
// gets a DEEP CLONE (value semantics). Refcounted shareables (string/enum/closure/channel) just take
// an extra reference. own_into_slot retains a refcounted value; clone_owned_else_borrow leaves it a
// borrow (for a read whose non-aggregate result the source still owns). Both deep-clone aggregates,
// recursing through nested aggregate fields/elements.

static void own_inline_leaves(EmberRt *ctx, int struct_id, unsigned char *p);   // fwd

static Value clone_struct_value(EmberRt *ctx, ObjStruct *s) {
    const StructType *st = &ctx->structs[s->type_id];
    Value copy = alloc_instance(ctx, s->type_id, s->tag, 0, s->field_count);
    memcpy(AS_STRUCT(copy)->data, s->data, (size_t)st->total_size);
    own_inline_leaves(ctx, s->type_id, AS_STRUCT(copy)->data);   // own the copy's boxed/inline leaves
    return copy;
}


static Value clone_array_value(EmberRt *ctx, ObjArray *a) {
    Value copy = (a->elem_kind == AEK_INLINE_STRUCT)
                     ? alloc_struct_array(ctx, a->length, a->elem_struct_id)
                     : alloc_array(ctx, a->length, a->elem_kind);
    ObjArray *c = AS_ARRAY(copy);
    if (a->length > 0) {
        memcpy(c->data, a->data, a->length * (size_t)a->elem_size);
    }
    if (a->elem_kind == AEK_BOXED) {
        for (size_t i = 0; i < a->length; i++) {
            ((Value *)c->data)[i] = own_into_slot(ctx, ((Value *)c->data)[i]);
        }
    } else if (a->elem_kind == AEK_INLINE_STRUCT) {
        for (size_t i = 0; i < a->length; i++) {
            own_inline_leaves(ctx, a->elem_struct_id, (unsigned char *)c->data + i * (size_t)a->elem_size);
        }
    }
    return copy;
}


// own_inline_leaves: a packed struct at `p` was byte-copied into a new owner; give that copy
// independent ownership of each owned leaf — clone an aggregate field, retain a refcounted field,
// recurse into an inline nested struct.
static void own_inline_leaves(EmberRt *ctx, int struct_id, unsigned char *p) {
    const StructType *st = &ctx->structs[struct_id];
    for (int f = 0; f < st->field_count; f++) {
        if (st->kind[f] == AEK_BOXED) {
            Value *fp = (Value *)(p + st->offset[f]);
            *fp = own_into_slot(ctx, *fp);
        } else if (st->kind[f] == AEK_INLINE_STRUCT) {
            own_inline_leaves(ctx, st->field_struct[f], p + st->offset[f]);
        }
    }
}


Value own_into_slot(EmberRt *ctx, Value v) {
    if (!IS_OBJ(v)) {
        return v;
    }
    Obj *o = AS_OBJ(v);
    if (o->type == OBJ_STRUCT && !((ObjStruct *)o)->is_enum) {
        return clone_struct_value(ctx, (ObjStruct *)o);
    }
    if (o->type == OBJ_ARRAY && !((ObjArray *)o)->borrowed) {
        return clone_array_value(ctx, (ObjArray *)o);
    }
    OBJ_RETAIN(o);
    return v;
}


Value clone_owned_else_borrow(EmberRt *ctx, Value v) {
    if (!IS_OBJ(v)) {
        return v;
    }
    Obj *o = AS_OBJ(v);
    if (o->type == OBJ_STRUCT && !((ObjStruct *)o)->is_enum) {
        return clone_struct_value(ctx, (ObjStruct *)o);
    }
    if (o->type == OBJ_ARRAY && !((ObjArray *)o)->borrowed) {
        return clone_array_value(ctx, (ObjArray *)o);
    }
    return v;
}





void struct_elem_release(EmberRt *ctx, int struct_id, unsigned char *p) {
    const StructType *st = &ctx->structs[struct_id];
    for (int f = 0; f < st->field_count; f++) {
        if (st->kind[f] == AEK_BOXED) {
            drop_value(ctx, value_box(p + st->offset[f], AEK_BOXED));
        }
    }
}





// alloc_instance allocates a struct or enum instance with a PACKED field buffer,
// threads it onto the object list for later cleanup, and returns it. A struct's
// buffer size comes from its StructType; an enum's is field_count 16-byte boxed slots.
Value alloc_instance(EmberRt *ctx, int type_id, int tag, int is_enum, int field_count) {
    size_t size = is_enum ? (size_t)field_count * sizeof(Value)
                          : (size_t)ctx->structs[type_id].total_size;
    ObjStruct *s = pooled_alloc(ctx, sizeof(ObjStruct) + size);
    s->obj.type    = OBJ_STRUCT;
    register_object(ctx, (Obj *)s);
    s->type_id     = type_id;
    s->tag         = tag;            // variant index for enums; 0 for structs
    s->is_enum     = is_enum;        // structs drop at scope exit; enums are shared
    s->field_count = field_count;
    return OBJ_VAL(s);
}





// make_string allocates an ObjString with room for `length` bytes (plus the NUL
// terminator), threads it onto the object list, and returns it. The caller fills chars.
ObjString *make_string(EmberRt *ctx, size_t length) {
    ObjString *s = pooled_alloc(ctx, sizeof(ObjString) + length + 1);
    s->obj.type      = OBJ_STRING;
    register_object(ctx, (Obj *)s);
    s->length        = length;
    s->chars[length] = '\0';
    return s;
}





// alloc_array allocates an ObjArray of `length` elements of `elem_kind` and threads
// it onto the object list. The caller fills in the elements.
Value alloc_array(EmberRt *ctx, size_t length, uint8_t elem_kind) {
    ObjArray *a    = pooled_alloc(ctx, sizeof(ObjArray));
    uint8_t   esz  = elem_size_for(elem_kind);
    void     *buf  = length > 0 ? malloc(length * esz) : NULL;
    if (a == NULL || (length > 0 && buf == NULL)) {
        fprintf(stderr, "emberc: out of memory allocating an array\n");
        exit(70);
    }
    a->obj.type   = OBJ_ARRAY;
    register_object(ctx, (Obj *)a);
    a->length     = length;
    a->capacity   = length;
    a->elem_kind  = elem_kind;
    a->elem_size  = esz;
    a->borrowed   = 0;            // an owning array; a view sets this via alloc_slice
    a->elem_struct_id = -1;
    a->data       = buf;
    return OBJ_VAL(a);
}





// alloc_slice builds a borrowed VIEW (Slice<T>) over `src`'s buffer: a fresh ObjArray
// header whose `data` points into src->data at element `lo`, length `hi-lo`. It owns no
// buffer and no elements (borrowed = 1), so drop frees only the header. Bounds:
// 0 <= lo <= hi <= src->length.
Value alloc_slice(EmberRt *ctx, ObjArray *src, size_t lo, size_t hi) {
    ObjArray *a = pooled_alloc(ctx, sizeof(ObjArray));
    if (a == NULL) {
        fprintf(stderr, "emberc: out of memory allocating a slice\n");
        exit(70);
    }
    a->obj.type       = OBJ_ARRAY;
    register_object(ctx, (Obj *)a);
    a->length         = hi - lo;
    a->capacity       = hi - lo;
    a->elem_kind      = src->elem_kind;
    a->elem_size      = src->elem_size;
    a->borrowed       = 1;
    a->elem_struct_id = src->elem_struct_id;
    a->data           = (unsigned char *)src->data + lo * src->elem_size;
    return OBJ_VAL(a);
}





// alloc_struct_array allocates an array that stores all-scalar structs INLINE: the
// element stride is the struct's packed total_size, so a [Pixel] is N*3 bytes with no
// per-element heap object (value-types campaign). The caller fills the elements.
Value alloc_struct_array(EmberRt *ctx, size_t length, int struct_id) {
    ObjArray *a   = pooled_alloc(ctx, sizeof(ObjArray));
    size_t    esz = (size_t)ctx->structs[struct_id].total_size;
    void     *buf = length > 0 ? malloc(length * esz) : NULL;
    if (a == NULL || (length > 0 && buf == NULL)) {
        fprintf(stderr, "emberc: out of memory allocating a struct array\n");
        exit(70);
    }
    a->obj.type       = OBJ_ARRAY;
    register_object(ctx, (Obj *)a);
    a->length         = length;
    a->capacity       = length;
    a->elem_kind      = AEK_INLINE_STRUCT;
    a->elem_size      = (uint8_t)esz;
    a->borrowed       = 0;            // an OWNING array — must init (pooled_alloc returns dirty memory)
    a->elem_struct_id = struct_id;
    a->data           = buf;
    return OBJ_VAL(a);
}





// alloc_interface boxes a receiver + its vtable into an interface value (dynamic
// dispatch). The interface value uniquely OWNS the receiver and vtable already sitting
// on the stack — no extra retain — so drop_value releases them exactly once.
Value alloc_interface(EmberRt *ctx, Value receiver, Value vtable) {
    ObjInterface *it = pooled_alloc(ctx, sizeof(ObjInterface));
    it->obj.type  = OBJ_INTERFACE;
    register_object(ctx, (Obj *)it);
    it->receiver  = receiver;
    it->vtable    = vtable;
    return OBJ_VAL(it);
}





// free_list frees one intrusive object list (releasing each object's side buffer).
// The single source of truth for the exit sweep, shared by the VM (which also sweeps
// its parallel graveyard) and a generated binary (via rt_free_objects).
void free_list(Obj *o) {
    while (o != NULL) {
        Obj *next = o->next;
        if (o->type == OBJ_CHANNEL) {
            ObjChannel *ch = (ObjChannel *)o;
            // buffer == NULL ⇒ drop_value already tore this channel down at its last drop
            // (the sentinel); only tear down a channel that outlived the run (refcount never
            // hit zero, or a non-home last release left it for this sweep). free_list runs
            // single-threaded after every worker has joined, so the sentinel needs no lock.
            if (ch->buffer != NULL) {
#if EMBER_PARALLEL
                pthread_mutex_destroy(&ch->lock);
#if !EMBER_MN
                pthread_cond_destroy(&ch->not_empty);   // M:N uses fiber FIFOs, not condvars
                pthread_cond_destroy(&ch->not_full);
#endif
#endif
                free(ch->buffer);              // the channel's separate buffer
            }
        } else if (o->type == OBJ_ARRAY) {
            if (!((ObjArray *)o)->borrowed) {  // a slice view borrows its buffer — don't free it
                free(((ObjArray *)o)->data);   // the array's separate buffer
            }
        }
        free(o);
        o = next;
    }
}





// drain_pool frees one set of size-classed recycling freelists.
void drain_pool(Obj *pool[POOL_CLASSES]) {
    for (int c = 0; c < POOL_CLASSES; c++) {
        Obj *p = pool[c];
        while (p != NULL) {
            Obj *next = p->next;
            free(p);
            p = next;
        }
        pool[c] = NULL;
    }
}





// rt_free_objects is a context's exit sweep: free its private object list and drain
// its recycle pool. A generated binary calls this at exit; the VM's free_objects
// wraps it and additionally sweeps the shared parallel graveyard (src/vm.c).
void rt_free_objects(EmberRt *ctx) {
    free_list(ctx->objects);
    ctx->objects = NULL;
    drain_pool(ctx->pool);
}






// (The boxed struct helpers em_struct / em_get_field / em_get_field_owned / em_set_field
// were removed: value-type structs now lower to real C structs in the C backend, so they
// have no heap construction or field indirection. The boxed object runtime above —
// alloc_instance, drop_value, field_loc — stays for the VM and the boxed aggregates below.)


// em_enum constructs a heap enum value (the VM's OP_NEW_ENUM): a refcounted instance
// tagged with its variant index, its `n` payload fields (varargs, all boxed 16-byte
// slots) packed in. Construction MOVES the fields in (no retain), like the VM. The C
// backend emits one call per variant construction (`Circle(2.0)`, a bare `Red`).
Value em_enum(EmberRt *ctx, int enum_id, int variant, int n, ...) {
    Value v = alloc_instance(ctx, enum_id, variant, 1, n);
    ObjStruct *s = AS_STRUCT(v);
    va_list ap;
    va_start(ap, n);
    for (int i = 0; i < n; i++) {
        int k;
        unsigned char *p = field_loc(ctx, s, i, &k);   // is_enum => AEK_BOXED at i*sizeof(Value)
        value_unbox(p, k, va_arg(ap, Value));
    }
    va_end(ap);
    return v;
}






// em_enum_field reads payload/struct field `index` of a boxed value as a Value (the VM's
// OP_GET_FIELD). A scalar/heap field is a BORROW (the box still owns it); a NESTED INLINE-STRUCT
// field materialises a fresh OWNED boxed COPY (value_box can't represent inline bytes). The
// inline case is reached in ERASED code — a generic struct's type-param field read (`self.k`)
// where the concrete instance happens to store the field inline; the caller drops the copy.
Value em_enum_field(EmberRt *ctx, Value v, int index) {
    int k;
    unsigned char *p = field_loc(ctx, AS_STRUCT(v), index, &k);
    if (k == AEK_INLINE_STRUCT) {
        return em_struct_field_inline(ctx, v, index);
    }
    // A BORROW of the field (the enum still owns it). Cloning a unique-owner aggregate payload here
    // is WRONG — em_enum_field also reads the Map's internal Option<MapEntry> payloads, so a clone
    // recursively explodes (OOM). The native Map-of-aggregate fix belongs in the codegen choosing an
    // OWNED read where the payload is consumed (deferred — OFI-062/063 native, OFI-051 umbrella).
    return value_box(p, k);
}






// em_field_owned reads field `index` of a boxed struct as an OWNED value the caller MUST drop —
// uniformly, regardless of the field's runtime kind: a nested inline-struct field materialises a
// boxed copy, a heap field is read + RETAINED, a scalar is copied. Used for an ERASED bound-method
// operand (the receiver/args of `self.k.eq(other)` where the type parameter's concrete kind —
// value struct vs scalar vs string — is unknown to the emitter), so the operand can be dropped
// after the indirect call without a use-after-free on a borrowed field or a leak on a materialised
// one (OFI-054 — closes the bounded-dispatch-of-value-struct-key leak).
Value em_field_owned(EmberRt *ctx, Value v, int index) {
    int k;
    unsigned char *p = field_loc(ctx, AS_STRUCT(v), index, &k);
    if (k == AEK_INLINE_STRUCT) {
        return em_struct_field_inline(ctx, v, index);
    }
    Value f = value_box(p, k);
    if (k == AEK_BOXED) {
        // Owned read: clone a unique-owner aggregate (struct/array) for the new owner, retain a
        // refcounted field — never a retained alias of a unique owner (OFI-062/063).
        return own_into_slot(ctx, f);
    }
    return f;
}






// em_struct_field_inline reads a NESTED INLINE-STRUCT field (kind AEK_INLINE_STRUCT) of a boxed
// struct by MATERIALISING a fresh OWNED boxed COPY of it — value semantics, independent of the
// parent (the VM's OP_GET_FIELD inline branch). `value_box` can't represent an inline-struct
// field (it's packed bytes, not one Value), so a struct-typed field read off a boxed receiver
// routes here. The caller DROPS the copy after use (an owning temp). All-scalar nested structs
// (the only kind a field can be inline — see nested_inline_sid) make struct_elem_retain a no-op.
Value em_struct_field_inline(EmberRt *ctx, Value v, int index) {
    ObjStruct *s = AS_STRUCT(v);
    int k;
    unsigned char *p = field_loc(ctx, s, index, &k);   // k == AEK_INLINE_STRUCT
    int nsid = field_inline_sid(ctx, s, index);
    int fc   = ctx->structs[nsid].field_count;
    Value copy = alloc_instance(ctx, nsid, 0, 0, fc);
    memcpy(AS_STRUCT(copy)->data, p, (size_t)ctx->structs[nsid].total_size);
    struct_elem_retain(ctx, nsid, AS_STRUCT(copy)->data);   // no-op for an all-scalar nested struct
    return copy;
}






// em_array builds a heap array literal `[e0, e1, …]` of `n` elements of storage kind
// `elem_kind` (the checker's ArrayElemKind — a packed scalar width or AEK_BOXED). The
// elements (varargs) MOVE in. A unique-owner (move) value, freed by drop_value.
Value em_array(EmberRt *ctx, int n, int elem_kind, ...) {
    Value arr = alloc_array(ctx, (size_t)n, (uint8_t)elem_kind);
    ObjArray *a = AS_ARRAY(arr);
    va_list ap;
    va_start(ap, elem_kind);
    for (int i = 0; i < n; i++) {
        array_unbox(a, (size_t)i, va_arg(ap, Value));
    }
    va_end(ap);
    return arr;
}






// em_struct_array builds an inline-struct array literal `[s0, s1, …]` (the VM's OP_NEW_STRUCT_ARRAY).
// Each vararg is a boxed ObjStruct of `struct_id`; its packed bytes are copied into the array's
// buffer and its shell reclaimed (the value MOVES in, transferring any boxed sub-fields). All-scalar
// and heap-bearing element structs are uniform here — struct_elem_release at drop handles sub-fields.
Value em_struct_array(EmberRt *ctx, int n, int struct_id, ...) {
    Value arr   = alloc_struct_array(ctx, (size_t)n, struct_id);
    ObjArray *a = AS_ARRAY(arr);
    va_list ap;
    va_start(ap, struct_id);
    for (int i = 0; i < n; i++) {
        Value v = va_arg(ap, Value);
        memcpy((unsigned char *)a->data + (size_t)i * a->elem_size,
               AS_STRUCT(v)->data, a->elem_size);
        reclaim(ctx, AS_OBJ(v));
    }
    va_end(ap);
    return arr;
}






// em_index reads element `i` of an array (the VM's OP_INDEX), bounds-checked. A scalar/boxed
// element is a BORROW (the array keeps ownership). An INLINE-STRUCT element materialises a fresh
// OWNED struct COPY, increfing its boxed sub-fields (a no-op for an all-scalar struct) — value
// semantics; the caller drops it after transient use (an owning temp, OFI-027), mirroring OP_INDEX.
Value em_index(EmberRt *ctx, Value arr, Value idx) {
    ObjArray *a = AS_ARRAY(arr);
    int64_t i = AS_INT(idx);
    if (i < 0 || (size_t)i >= a->length) {
        em_panic("array index out of bounds");
    }
    if (a->elem_kind == AEK_INLINE_STRUCT) {
        int fc = ctx->structs[a->elem_struct_id].field_count;
        Value copy = alloc_instance(ctx, a->elem_struct_id, 0, 0, fc);
        memcpy(AS_STRUCT(copy)->data,
               (unsigned char *)a->data + (size_t)i * a->elem_size, a->elem_size);
        struct_elem_retain(ctx, a->elem_struct_id, AS_STRUCT(copy)->data);
        return copy;
    }
    if (a->elem_kind == AEK_BOXED) {
        // A unique-owner aggregate element (value struct OR array) is returned as an owned CLONE
        // (mirrors OP_INDEX), safe to drop after transient use, not a borrow (OFI-062/063).
        Value elem = ((Value *)a->data)[i];
        if (IS_OBJ(elem) &&
            ((AS_OBJ(elem)->type == OBJ_STRUCT && !AS_STRUCT(elem)->is_enum) ||
             (AS_OBJ(elem)->type == OBJ_ARRAY && !((ObjArray *)AS_OBJ(elem))->borrowed))) {
            return clone_owned_else_borrow(ctx, elem);
        }
    }
    return array_box(a, (size_t)i);
}






// em_set_index mutates element `i` in place (the VM's OP_SET_INDEX): a boxed element's
// previous value is released before the new one overwrites it; a packed scalar is rewritten.
void em_set_index(EmberRt *ctx, Value arr, Value idx, Value value) {
    ObjArray *a = AS_ARRAY(arr);
    int64_t i = AS_INT(idx);
    if (i < 0 || (size_t)i >= a->length) {
        em_panic("array index out of bounds");
    }
    if (a->elem_kind == AEK_INLINE_STRUCT) {
        unsigned char *slot = (unsigned char *)a->data + (size_t)i * a->elem_size;
        struct_elem_release(ctx, a->elem_struct_id, slot);   // drop the old element's sub-fields
        memcpy(slot, AS_STRUCT(value)->data, a->elem_size);   // new bytes move in
        reclaim(ctx, AS_OBJ(value));
        return;
    }
    if (a->elem_kind == AEK_BOXED) {
        drop_value(ctx, ((Value *)a->data)[i]);
    }
    array_unbox(a, (size_t)i, value);
}






// em_array_append grows the array if full (doubling) and appends `value`, which moves in
// (the VM's OP_ARRAY_APPEND). Mutates the ObjArray through the shared header, so the caller's
// binding sees the new element. An inline-struct element's packed bytes move in (its boxed shell
// is reclaimed); a scalar/boxed element is stored directly. Returns unit.
Value em_array_append(EmberRt *ctx, Value arr, Value value) {
    ObjArray *a = AS_ARRAY(arr);
    if (a->length == a->capacity) {
        size_t newcap = a->capacity < 4 ? 4 : a->capacity * 2;
        void *nb = realloc(a->data, newcap * a->elem_size);
        if (nb == NULL) {
            em_panic("out of memory growing an array");
        }
        a->data     = nb;
        a->capacity = newcap;
    }
    if (a->elem_kind == AEK_INLINE_STRUCT) {
        memcpy((unsigned char *)a->data + a->length * a->elem_size,
               AS_STRUCT(value)->data, a->elem_size);
        a->length++;
        reclaim(ctx, AS_OBJ(value));   // move-in: free the shell, sub-fields transfer
    } else {
        array_unbox(a, a->length++, value);
    }
    return INT_VAL(0);
}






// em_str builds a string value from literal bytes (a fresh refcounted ObjString).
Value em_str(EmberRt *ctx, const char *bytes, int len) {
    ObjString *s = make_string(ctx, (size_t)len);
    memcpy(s->chars, bytes, (size_t)len);
    return OBJ_VAL(s);
}






// em_to_string renders a value as a string for interpolation (the VM's OP_TO_STRING): a
// string is identity (no copy); a float is "%g", a u64 (nk 7) "%llu", any other int "%lld".
Value em_to_string(EmberRt *ctx, Value v, int nk) {
    if (IS_STRING(v)) {
        // Already a string: return it OWNED (retained), so a consumer (em_add in an
        // interpolation fold) can drop it without freeing a borrowed source (a binding, or a
        // boxed struct's heap field). A non-string renders a fresh owned string below.
        OBJ_RETAIN(AS_OBJ(v));
        return v;
    }
    char buf[32];
    int n;
    if (nk == 10) {              // a bool renders as true/false, not 1/0
        n = snprintf(buf, sizeof buf, "%s", AS_INT(v) != 0 ? "true" : "false");
    } else if (IS_FLOAT(v)) {
        n = snprintf(buf, sizeof buf, "%g", AS_FLOAT(v));
    } else if (nk == 7) {
        n = snprintf(buf, sizeof buf, "%llu", (unsigned long long)(uint64_t)AS_INT(v));
    } else {
        n = snprintf(buf, sizeof buf, "%lld", (long long)AS_INT(v));
    }
    ObjString *s = make_string(ctx, (size_t)n);
    memcpy(s->chars, buf, (size_t)n);
    return OBJ_VAL(s);
}






// Write a value to stdout, mirroring the VM's print_value (int "%lld", float "%g", string
// bytes, anything else "<obj>"). A string's length is taken with strlen, like the VM.
static void em_print_value(Value v) {
    char buf[32];
    if (IS_INT(v)) {
        fwrite(buf, 1, (size_t)snprintf(buf, sizeof buf, "%lld", (long long)AS_INT(v)), stdout);
    } else if (IS_FLOAT(v)) {
        fwrite(buf, 1, (size_t)snprintf(buf, sizeof buf, "%g", AS_FLOAT(v)), stdout);
    } else if (IS_STRING(v)) {
        fwrite(AS_CSTRING(v), 1, strlen(AS_CSTRING(v)), stdout);
    } else {
        fwrite("<obj>", 1, 5, stdout);
    }
}






// print / println write the value and do NOT consume it — `print`/`println` are the VM's
// NATIVE_PRINT/PRINTLN, which only READ their argument and return unit; the argument's
// lifetime is the caller's (a named binding drops at scope, a temporary at the exit sweep).
Value em_print(EmberRt *ctx, Value v) {
    (void)ctx;
    em_print_value(v);
    return INT_VAL(0);
}






Value em_println(EmberRt *ctx, Value v) {
    (void)ctx;
    em_print_value(v);
    fputc('\n', stdout);
    return INT_VAL(0);
}






// em_closure builds a function value (the VM's OP_MAKE_CLOSURE / make_closure): an
// ObjClosure naming a lifted function by table index plus its `capture_count` captured
// values (varargs), each RETAINED so the closure owns its own reference while the capturing
// scope keeps its own. A bare function-value is a zero-capture closure. Refcounted, freely
// shareable like a string; drop_value releases each capture and reclaims it.
Value em_closure(EmberRt *ctx, int fn_index, int capture_count, ...) {
    ObjClosure *cl = pooled_alloc(ctx, sizeof(ObjClosure) +
                                  (size_t)capture_count * sizeof(Value));
    cl->obj.type      = OBJ_CLOSURE;
    register_object(ctx, (Obj *)cl);
    cl->fn_index      = fn_index;
    cl->capture_count = capture_count;
    va_list ap;
    va_start(ap, capture_count);
    for (int i = 0; i < capture_count; i++) {
        Value v = va_arg(ap, Value);
        if (IS_OBJ(v)) {
            OBJ_RETAIN(AS_OBJ(v));
        }
        cl->captures[i] = v;
    }
    va_end(ap);
    return OBJ_VAL(cl);
}






// rt_call_closure invokes a closure value (the VM's OP_CALL_CLOSURE): it lays out the lifted
// function's frame as [captures…, args…] and dispatches through `invoke` (the generated
// em_invoke, which routes a function-table index to the concrete em_fn_<k>). Both captures
// and arguments are RETAINED here because the lifted body releases every refcounted
// parameter on return, while the closure keeps its captures and the caller keeps its
// arguments — the erased-T runtime retain that keeps higher-order generic calls sound
// (over-retain leaks, never over-releases).
Value rt_call_closure(EmberRt *ctx, Value clo, int argc, const Value *args,
                      Value (*invoke)(EmberRt *, int, Value *)) {
    ObjClosure *cl = AS_CLOSURE(clo);
    int m = cl->capture_count;
    if (m < 0 || argc < 0 || m + argc > 320) {
        em_panic("closure call: too many slots");
    }
    Value slots[320];
    for (int i = 0; i < m; i++) {
        Value c = cl->captures[i];
        if (IS_OBJ(c)) {
            OBJ_RETAIN(AS_OBJ(c));
        }
        slots[i] = c;
    }
    for (int i = 0; i < argc; i++) {
        Value a = args[i];
        if (IS_OBJ(a)) {
            OBJ_RETAIN(AS_OBJ(a));
        }
        slots[m + i] = a;
    }
    return invoke(ctx, cl->fn_index, slots);
}






// box_pack_struct packs the C-side flat leaf Values of a value-type struct (one Value per SCALAR
// leaf, in recursive declared-field order — the `(Value*)&em_s` view) into a packed ObjStruct
// buffer at `base`, per `sid`'s layout. A nested inline-struct field RECURSES (a raw whole-struct
// memcpy would be unsound — the C em_s stores each scalar as a 16-byte Value, the packed buffer
// at natural width). A heap field is RETAINED (the box owns its own reference). Mirrors the VM's
// box_pack; the flat case (no nested fields) is one value_unbox per field, as before.
static void box_pack_struct(EmberRt *ctx, int sid, unsigned char *base,
                            const Value *leaves, int *idx) {
    const StructType *st = &ctx->structs[sid];
    for (int f = 0; f < st->field_count; f++) {
        unsigned char *p = base + st->offset[f];
        int k = st->kind[f];
        if (k == AEK_INLINE_STRUCT) {
            box_pack_struct(ctx, st->field_struct[f], p, leaves, idx);
        } else {
            value_unbox(p, k, leaves[*idx]);
            if (k == AEK_BOXED && IS_OBJ(leaves[*idx])) {
                OBJ_RETAIN(AS_OBJ(leaves[*idx]));
            }
            (*idx)++;
        }
    }
}






// unbox_flatten_struct is the inverse: read a packed ObjStruct buffer back into the C-side flat
// leaf Value[] (`(Value*)&em_s`), recursing through nested inline-struct fields. A BORROW — the
// box still owns any heap leaves; the unboxed copy is used read-only (e.g. a method's `self`).
static void unbox_flatten_struct(EmberRt *ctx, int sid, const unsigned char *base,
                                 Value *out, int *idx) {
    const StructType *st = &ctx->structs[sid];
    for (int f = 0; f < st->field_count; f++) {
        const unsigned char *p = base + st->offset[f];
        int k = st->kind[f];
        if (k == AEK_INLINE_STRUCT) {
            unbox_flatten_struct(ctx, st->field_struct[f], p, out, idx);
        } else {
            out[(*idx)++] = value_box(p, k);
        }
    }
}






// em_box_struct boxes a value-type struct — laid out in C as a contiguous leaf Value[] — into a
// heap ObjStruct with the VM's packed field layout, so it can be an interface receiver or flow
// through erased code as a uniform Value (the VM's OP_BOX_STRUCT). Handles NESTED inline-struct
// fields (non-flat structs) via the recursive leaf walk; heap fields are RETAINED so the box owns
// its own references and its drop_value releases them exactly once. `n` is the declared field count.
Value em_box_struct(EmberRt *ctx, int sid, const Value *fields, int n) {
    Value v = alloc_instance(ctx, sid, 0, 0, n);
    int idx = 0;
    box_pack_struct(ctx, sid, AS_STRUCT(v)->data, fields, &idx);
    return v;
}






// em_unbox_struct reads a boxed ObjStruct's packed fields back into a value-type struct's
// contiguous leaf Value[] — a BORROW (the box still owns any heap fields; the unboxed copy is
// used read-only). Inverse of em_box_struct; handles nested inline-struct fields recursively.
void em_unbox_struct(EmberRt *ctx, int sid, Value boxed, Value *out, int n) {
    (void)n;
    int idx = 0;
    unbox_flatten_struct(ctx, sid, AS_STRUCT(boxed)->data, out, &idx);
}






// em_struct CONSTRUCTS a heap struct value — the boxed representation a non-all-scalar struct
// (one with a string/array/enum field, e.g. a Config or a Map/Set) uses, mirroring the VM's
// OP_NEW_STRUCT. Like em_enum it MOVES each field in (no retain), packing it per the struct's
// layout. A unique-owner / refcounted value; drop_value releases it and its boxed fields.
Value em_struct(EmberRt *ctx, int sid, int n, ...) {
    Value v = alloc_instance(ctx, sid, 0, 0, n);
    ObjStruct *s = AS_STRUCT(v);
    va_list ap;
    va_start(ap, n);
    for (int i = 0; i < n; i++) {
        int k;
        unsigned char *p = field_loc(ctx, s, i, &k);
        value_unbox(p, k, va_arg(ap, Value));
    }
    va_end(ap);
    return v;
}






// Build-then-place construction of a boxed struct that has a NESTED INLINE-STRUCT field — the
// varargs em_struct can't place such a field (it's packed bytes, not one Value). The emitter calls
// em_struct_empty, then em_struct_put_field / em_struct_put_inline per declared field. Mirrors the
// VM's OP_NEW_STRUCT, which likewise places each field by kind. (OFI-054 A2.)
Value em_struct_empty(EmberRt *ctx, int sid) {
    return alloc_instance(ctx, sid, 0, 0, ctx->structs[sid].field_count);
}






// em_struct_put_field MOVES a scalar/heap field value into a freshly-built boxed struct's slot
// `idx` (the em_struct convention — no retain; the box adopts the value). The slot was never
// initialised, so there is no old value to drop (unlike em_set_field).
void em_struct_put_field(EmberRt *ctx, Value structval, int idx, Value val) {
    int k;
    unsigned char *p = field_loc(ctx, AS_STRUCT(structval), idx, &k);
    value_unbox(p, k, val);
}






// em_struct_put_inline places a NESTED INLINE-STRUCT field: copy the boxed source's packed bytes
// into the parent's inline slot, then reclaim the source shell (its bytes — and any boxed
// sub-fields — MOVE in). The VM's OP_NEW_STRUCT AEK_INLINE_STRUCT branch. Both are the same sid's
// packed layout, so the memcpy size is exact.
void em_struct_put_inline(EmberRt *ctx, Value structval, int idx, Value boxed_field) {
    ObjStruct *s = AS_STRUCT(structval);
    int k;
    unsigned char *p = field_loc(ctx, s, idx, &k);   // k == AEK_INLINE_STRUCT
    int nsid = field_inline_sid(ctx, s, idx);
    memcpy(p, AS_STRUCT(boxed_field)->data, (size_t)ctx->structs[nsid].total_size);
    reclaim(ctx, AS_OBJ(boxed_field));
}






// em_set_field overwrites field `idx` of a BOXED struct, dropping the previous boxed value
// first (the VM's OP_SET_FIELD) so a reassigned heap field does not leak. The new value MOVES
// in (no retain), matching the value-struct field-assignment convention.
void em_set_field(EmberRt *ctx, Value structval, int idx, Value newval) {
    ObjStruct *s = AS_STRUCT(structval);
    int k;
    unsigned char *p = field_loc(ctx, s, idx, &k);
    if (k == AEK_BOXED) {
        drop_value(ctx, value_box(p, k));
    }
    value_unbox(p, k, newval);
}






// ---- Native concurrency (M4): channels, nursery + deadlock detector, worker join --------
// Ported from the VM's threaded runtime (src/vm.c), re-expressed over EmberRt + thread-local
// contexts so generated C drives it directly. Parallel-only (pthreads + ObjChannel's condvars).
// Excluded under EMBER_MN: M:N is VM-only (the canonical runtime); the native backend keeps the
// 1:1 model, and these condvar-based ops don't exist when the channel carries fiber FIFOs instead.

#if EMBER_PARALLEL && !EMBER_MN

// The running thread's nursery (for channel-block deadlock detection); NULL at top level.
_Thread_local EmNursery *em_cur_nursery = NULL;
_Thread_local int        em_cur_slot    = 0;

// The shared merge target: a finished worker splices its private arena in here under the lock
// (once per worker), and a cross-thread free leaves its object on its home list, also collected
// here. main's exit sweep frees it (em_free_graveyard).
static pthread_mutex_t em_heap_lock = PTHREAD_MUTEX_INITIALIZER;
static Obj            *em_graveyard  = NULL;
static Obj            *em_gpool[POOL_CLASSES] = { NULL };


void em_merge(EmberRt *self) {
    pthread_mutex_lock(&em_heap_lock);
    if (self->objects != NULL) {
        Obj *tail = self->objects;
        while (tail->next != NULL) {
            tail = tail->next;
        }
        tail->next = em_graveyard;
        if (em_graveyard != NULL) {
            em_graveyard->prev = tail;
        }
        em_graveyard = self->objects;
    }
    for (int c = 0; c < POOL_CLASSES; c++) {
        if (self->pool[c] != NULL) {
            Obj *tail = self->pool[c];
            while (tail->next != NULL) {
                tail = tail->next;
            }
            tail->next = em_gpool[c];
            em_gpool[c] = self->pool[c];
        }
    }
    pthread_mutex_unlock(&em_heap_lock);
    self->objects = NULL;
    for (int c = 0; c < POOL_CLASSES; c++) {
        self->pool[c] = NULL;
    }
}






void em_free_graveyard(void) {
    free_list(em_graveyard);
    em_graveyard = NULL;
    drain_pool(em_gpool);
}






// A task is about to block on `ch` (is_send=1 send-on-full, 0 recv-on-empty): register it in
// its nursery slot. When every task in the group is parked AND none could currently proceed,
// the group is deadlocked — report once and abort (the VM wakes + propagates; a native binary
// just exits, killing the parked threads). Called holding `ch->lock` (order channel→nursery).
static void em_nursery_park(ObjChannel *ch, int is_send) {
    EmNursery *n = em_cur_nursery;
    if (n == NULL) {
        return;
    }
    int slot = em_cur_slot;
    pthread_mutex_lock(&n->lock);
    n->waits_on[slot] = ch;
    n->is_send[slot]  = is_send;
    if (!n->active[slot]) {
        n->active[slot] = 1;
        n->nwaiting++;
    }
    if (n->nwaiting == n->total) {
        int any_ready = 0;
        for (int i = 0; i < n->total && !any_ready; i++) {
            if (!n->active[i]) {
                continue;
            }
            ObjChannel *c = n->waits_on[i];
            any_ready = n->is_send[i] ? (c->count < c->capacity)
                                      : (c->count > 0 || c->closed);
        }
        if (!any_ready) {
            __atomic_store_n(&n->deadlocked, 1, __ATOMIC_SEQ_CST);
            pthread_mutex_unlock(&n->lock);
            fprintf(stderr, "emberc: deadlock: every task in the nursery is blocked\n");
            exit(70);
        }
    }
    pthread_mutex_unlock(&n->lock);
}


static void em_nursery_unpark(void) {
    EmNursery *n = em_cur_nursery;
    if (n == NULL) {
        return;
    }
    pthread_mutex_lock(&n->lock);
    if (n->active[em_cur_slot]) {
        n->active[em_cur_slot] = 0;
        n->nwaiting--;
    }
    pthread_mutex_unlock(&n->lock);
}


static int em_nursery_deadlocked(void) {
    return em_cur_nursery != NULL &&
           __atomic_load_n(&em_cur_nursery->deadlocked, __ATOMIC_SEQ_CST);
}






// channel(cap) — a buffered channel. Registered on the creating context; channels are
// nursery-scoped (drop_value defers them) and reclaimed by the exit sweep.
Value em_channel_new(EmberRt *ctx, int cap) {
    // Pooled like every other heap object (see alloc_channel in vm.c): a refcounted channel's
    // shell returns to the size-class pool on the last drop, so it needs a valid size_class.
    ObjChannel *ch = pooled_alloc(ctx, sizeof(ObjChannel));
    Value      *buf = malloc((cap > 0 ? (size_t)cap : 1) * sizeof(Value));
    if (buf == NULL) {
        em_panic("out of memory allocating a channel");
    }
    ch->obj.type = OBJ_CHANNEL;
    register_object(ctx, (Obj *)ch);
    ch->buffer   = buf;
    ch->capacity = cap > 0 ? cap : 1;
    ch->count    = 0;
    ch->head     = 0;
    ch->closed   = 0;
    pthread_mutex_init(&ch->lock, NULL);
    pthread_cond_init(&ch->not_empty, NULL);
    pthread_cond_init(&ch->not_full, NULL);
    ch->recv_waiters = 0;
    ch->send_waiters = 0;
    return OBJ_VAL(ch);
}






// send(ch, v) — enqueue, blocking (parking this thread on `not_full`) while the buffer is full;
// a receiver on another core wakes us, or the deadlock detector aborts. The value MOVES in.
Value em_channel_send(EmberRt *ctx, Value chv, Value v) {
    (void)ctx;
    ObjChannel *ch = AS_CHANNEL(chv);
    pthread_mutex_lock(&ch->lock);
    if (ch->closed) {                          // send on a closed channel is an error (OFI-086)
        pthread_mutex_unlock(&ch->lock);
        em_panic("send on a closed channel");
    }
    int parked = 0;
    while (ch->count == ch->capacity && !em_nursery_deadlocked()) {
        if (!parked) {
            parked = 1;
            ch->send_waiters++;
            em_nursery_park(ch, 1);
            continue;
        }
        pthread_cond_wait(&ch->not_full, &ch->lock);
    }
    if (parked) {
        ch->send_waiters--;
        em_nursery_unpark();
    }
    ch->buffer[(ch->head + ch->count) % ch->capacity] = v;
    ch->count++;
    if (ch->recv_waiters > 0) {
        pthread_cond_signal(&ch->not_empty);
    }
    pthread_mutex_unlock(&ch->lock);
    return INT_VAL(0);
}






// recv(ch) — dequeue an Option: Some(v) when a value is queued (blocking until one is, or the
// channel closes), None once the channel is closed and drained. The value MOVES out into Some.
Value em_channel_recv(EmberRt *ctx, Value chv, int enum_id, int some_tag, int none_tag) {
    ObjChannel *ch = AS_CHANNEL(chv);
    pthread_mutex_lock(&ch->lock);
    int parked = 0;
    while (ch->count == 0 && !ch->closed && !em_nursery_deadlocked()) {
        if (!parked) {
            parked = 1;
            ch->recv_waiters++;
            em_nursery_park(ch, 0);
            continue;
        }
        pthread_cond_wait(&ch->not_empty, &ch->lock);
    }
    if (parked) {
        ch->recv_waiters--;
        em_nursery_unpark();
    }
    if (ch->count == 0) {                       // drained + closed ⇒ None
        pthread_mutex_unlock(&ch->lock);
        return em_enum(ctx, enum_id, none_tag, 0);
    }
    Value v = ch->buffer[ch->head];
    ch->head = (ch->head + 1) % ch->capacity;
    ch->count--;
    if (ch->send_waiters > 0) {
        pthread_cond_signal(&ch->not_full);
    }
    pthread_mutex_unlock(&ch->lock);
    return em_enum(ctx, enum_id, some_tag, 1, v);
}






// close(ch) — queued values still drain; a later recv on the drained channel returns None
// instead of blocking. Idempotent.
Value em_channel_close(Value chv) {
    ObjChannel *ch = AS_CHANNEL(chv);
    pthread_mutex_lock(&ch->lock);
    ch->closed = 1;
    pthread_cond_broadcast(&ch->not_empty);
    pthread_cond_broadcast(&ch->not_full);
    pthread_mutex_unlock(&ch->lock);
    return INT_VAL(0);
}






// em_run_nursery — launch one OS thread per recorded task (each runs `worker`, a generated
// trampoline that sets up its thread-local context, runs the task, and merges its arena), then
// join all. One shared deadlock-detector block for the group lives on this frame until the join.
void em_run_nursery(EmTask *tasks, int n, void *(*worker)(void *)) {
    if (n <= 0) {
        return;
    }
    if (n > EM_MAX_GROUP_FIBERS) {
        em_panic("too many spawned tasks in one nursery");
    }
    EmNursery grp;
    grp.total      = n;
    grp.nwaiting   = 0;
    grp.deadlocked = 0;
    for (int i = 0; i < n; i++) {
        grp.active[i] = 0;
    }
    pthread_mutex_init(&grp.lock, NULL);
    pthread_t th[EM_MAX_GROUP_FIBERS];
    int       joinable[EM_MAX_GROUP_FIBERS];
    for (int i = 0; i < n; i++) {
        tasks[i].nursery = &grp;
        tasks[i].slot    = i;
        joinable[i] = (pthread_create(&th[i], NULL, worker, &tasks[i]) == 0);
        if (!joinable[i]) {
            em_panic("could not create a thread for a spawned task");
        }
    }
    for (int i = 0; i < n; i++) {
        if (joinable[i]) {
            pthread_join(th[i], NULL);
        }
    }
    pthread_mutex_destroy(&grp.lock);
}

#endif  // EMBER_PARALLEL






// rt_call_indirect dispatches a bounded-generic interface method whose function index was
// read out of a witness record (the VM's OP_CALL_INDIRECT). A built-in key type's Hash/Eq
// witness (index >= WITNESS_NATIVE_BASE) routes to the native shim; a user method routes to
// the generated em_invoke trampoline (which unboxes struct receivers/args). The arguments are
// BORROWS — a bound method reads its receiver and arguments, it does not consume them — so no
// retain/release here (unlike a closure call), matching the VM's OP_CALL_INDIRECT.
Value rt_call_indirect(EmberRt *ctx, int64_t fnidx, int argc, const Value *args,
                       Value (*invoke)(EmberRt *, int, Value *)) {
    if (fnidx >= WITNESS_NATIVE_BASE) {
        int nid = (int)(fnidx - WITNESS_NATIVE_BASE);
        if (nid == NATIVE_HASH_ANY) {
            return em_hash_any(argc >= 1 ? args[0] : INT_VAL(0));
        }
        if (nid == NATIVE_VALUE_EQ) {
            return INT_VAL(em_value_eq(argc >= 1 ? args[0] : INT_VAL(0),
                                       argc >= 2 ? args[1] : INT_VAL(0)) ? 1 : 0);
        }
        em_panic("indirect call: unsupported native witness");
    }
    if (argc < 0 || argc > 320) {
        em_panic("indirect call: too many args");
    }
    Value slots[320];
    for (int i = 0; i < argc; i++) {
        slots[i] = args[i];
    }
    return invoke(ctx, (int)fnidx, slots);
}






// ──────────────────────────────────────────────────────────────────────────────────────
// M5: UTF-8 helpers, string/array methods, numeric conversions, native builtins, and FFI.
// Each mirrors the VM opcode named in its comment so tests/native/ diffs bit-for-bit.
// ──────────────────────────────────────────────────────────────────────────────────────


// UTF-8 (code-point granularity). Moved here from src/vm.c (M5) so the runtime library owns
// them too; lenient — any invalid/overlong/surrogate/truncated sequence yields U+FFFD and
// consumes one byte, so decoding a string never fails.
int utf8_decode(const unsigned char *s, size_t len, uint32_t *cp) {
    unsigned char b = s[0];
    if (b < 0x80) { *cp = b; return 1; }
    int n; uint32_t c, min;
    if ((b & 0xE0) == 0xC0)      { n = 1; c = b & 0x1F; min = 0x80; }
    else if ((b & 0xF0) == 0xE0) { n = 2; c = b & 0x0F; min = 0x800; }
    else if ((b & 0xF8) == 0xF0) { n = 3; c = b & 0x07; min = 0x10000; }
    else                         { *cp = 0xFFFD; return 1; }   // stray continuation / 5–6-byte lead
    if (len < (size_t)(n + 1)) { *cp = 0xFFFD; return 1; }      // truncated
    for (int i = 1; i <= n; i++) {
        if ((s[i] & 0xC0) != 0x80) { *cp = 0xFFFD; return 1; }  // bad continuation byte
        c = (c << 6) | (uint32_t)(s[i] & 0x3F);
    }
    if (c < min || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) {
        *cp = 0xFFFD; return 1;                                 // overlong / surrogate / out of range
    }
    *cp = c;
    return n + 1;
}






// utf8_encode writes code point `cp` to `out` (room for 4 bytes) and returns the byte count
// (1–4). A surrogate or out-of-range code point is encoded as U+FFFD (lenient).
int utf8_encode(uint32_t cp, unsigned char *out) {
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) { cp = 0xFFFD; }
    if (cp < 0x80)   { out[0] = (unsigned char)cp; return 1; }
    if (cp < 0x800)  { out[0] = 0xC0 | (cp >> 6);  out[1] = 0x80 | (cp & 0x3F); return 2; }
    if (cp < 0x10000){ out[0] = 0xE0 | (cp >> 12); out[1] = 0x80 | ((cp >> 6) & 0x3F);
                       out[2] = 0x80 | (cp & 0x3F); return 3; }
    out[0] = 0xF0 | (cp >> 18); out[1] = 0x80 | ((cp >> 12) & 0x3F);
    out[2] = 0x80 | ((cp >> 6) & 0x3F); out[3] = 0x80 | (cp & 0x3F);
    return 4;
}






// em_str_chars — s.chars() → a [string] of the string's code points (OP_STR_CHARS). Each
// code point is re-encoded so an invalid byte materialises as a one-element U+FFFD string.
Value em_str_chars(EmberRt *ctx, Value sv) {
    ObjString *s = AS_STRING(sv);
    const unsigned char *b = (const unsigned char *)s->chars;
    size_t n = 0;
    for (size_t i = 0; i < s->length; ) {
        uint32_t cp;
        i += (size_t)utf8_decode(b + i, s->length - i, &cp);
        n++;
    }
    Value arr = alloc_array(ctx, n, AEK_BOXED);
    size_t k = 0;
    for (size_t i = 0; i < s->length; ) {
        uint32_t cp;
        int w = utf8_decode(b + i, s->length - i, &cp);
        unsigned char buf[4];
        int wn = utf8_encode(cp, buf);
        ObjString *ch = make_string(ctx, (size_t)wn);
        memcpy(ch->chars, buf, (size_t)wn);
        array_unbox(AS_ARRAY(arr), k++, OBJ_VAL(ch));
        i += (size_t)w;
    }
    return arr;
}






// em_str_split — s.split(sep) → a [string] of the pieces between occurrences of `sep`
// (OP_STR_SPLIT). An empty separator yields a single piece (the whole string).
Value em_str_split(EmberRt *ctx, Value sv, Value sepv) {
    ObjString *s   = AS_STRING(sv);
    ObjString *sep = AS_STRING(sepv);
    size_t slen = s->length, seplen = sep->length;
    size_t pieces = 1;
    if (seplen > 0) {
        for (size_t i = 0; i + seplen <= slen; ) {
            if (memcmp(s->chars + i, sep->chars, seplen) == 0) {
                pieces++;
                i += seplen;
            } else {
                i++;
            }
        }
    }
    Value arr = alloc_array(ctx, pieces, AEK_BOXED);
    if (seplen == 0) {
        ObjString *whole = make_string(ctx, slen);
        memcpy(whole->chars, s->chars, slen);
        array_unbox(AS_ARRAY(arr), 0, OBJ_VAL(whole));
        return arr;
    }
    size_t start = 0, idx = 0, i = 0;
    while (i + seplen <= slen) {
        if (memcmp(s->chars + i, sep->chars, seplen) == 0) {
            size_t len = i - start;
            ObjString *piece = make_string(ctx, len);
            memcpy(piece->chars, s->chars + start, len);
            array_unbox(AS_ARRAY(arr), idx++, OBJ_VAL(piece));
            i += seplen;
            start = i;
        } else {
            i++;
        }
    }
    size_t tail = slen - start;
    ObjString *last = make_string(ctx, tail);
    memcpy(last->chars, s->chars + start, tail);
    array_unbox(AS_ARRAY(arr), idx, OBJ_VAL(last));
    return arr;
}






// em_str_bytes — s.bytes() → a packed [u8] of the string's raw bytes (OP_STR_BYTES).
Value em_str_bytes(EmberRt *ctx, Value sv) {
    ObjString *s = AS_STRING(sv);
    Value arr = alloc_array(ctx, s->length, AEK_U8);
    for (size_t i = 0; i < s->length; i++) {
        array_unbox(AS_ARRAY(arr), i, INT_VAL((int64_t)(unsigned char)s->chars[i]));
    }
    return arr;
}






// em_str_char_count — s.char_count() → the number of code points (OP_STR_CHAR_COUNT).
Value em_str_char_count(Value sv) {
    ObjString *s = AS_STRING(sv);
    const unsigned char *b = (const unsigned char *)s->chars;
    size_t n = 0;
    for (size_t i = 0; i < s->length; ) {
        uint32_t cp;
        i += (size_t)utf8_decode(b + i, s->length - i, &cp);
        n++;
    }
    return INT_VAL((int64_t)n);
}






// em_str_parse_int — s.parse_int() → Option<int> (OP_STR_PARSE_INT). Some(n) for a valid
// optionally-signed decimal that fits int64; None for anything else (empty, junk, overflow).
Value em_str_parse_int(EmberRt *ctx, Value sv, int enum_id, int some_tag, int none_tag) {
    ObjString *s = AS_STRING(sv);
    size_t n = s->length, i = 0;
    int ok = n > 0, neg = 0;
    int64_t result = 0;
    if (ok && (s->chars[0] == '+' || s->chars[0] == '-')) {
        neg = (s->chars[0] == '-');
        i = 1;
        if (i == n) {
            ok = 0;   // a lone sign
        }
    }
    for (; ok && i < n; i++) {
        char ch = s->chars[i];
        if (ch < '0' || ch > '9') {
            ok = 0;
            break;
        }
        if (__builtin_mul_overflow(result, (int64_t)10, &result) ||
            __builtin_add_overflow(result, (int64_t)(ch - '0'), &result)) {
            ok = 0;   // magnitude beyond int64
            break;
        }
    }
    if (ok && neg) {
        result = -result;
    }
    Value field = INT_VAL(result);
    return em_enum(ctx, enum_id, ok ? some_tag : none_tag, ok ? 1 : 0, field);
}






// em_array_pop — arr.remove_last() removes and returns the last element (OP_ARRAY_POP). The
// array is mutated in place; a slice view is read-only (panic), as is an empty array.
Value em_array_pop(EmberRt *ctx, Value arr) {
    ObjArray *a = AS_ARRAY(arr);
    if (a->borrowed) {
        em_panic("cannot remove_last from a slice view");
    }
    if (a->length == 0) {
        em_panic("remove_last on an empty array");
    }
    a->length--;
    if (a->elem_kind == AEK_INLINE_STRUCT) {
        // Move the last element's bytes OUT into a fresh owned struct — its sub-field refs move
        // with it (NO struct_elem_retain; the shrunk length excludes the slot from later release).
        int fc = ctx->structs[a->elem_struct_id].field_count;
        Value copy = alloc_instance(ctx, a->elem_struct_id, 0, 0, fc);
        memcpy(AS_STRUCT(copy)->data,
               (unsigned char *)a->data + a->length * a->elem_size, a->elem_size);
        return copy;
    }
    return value_box((unsigned char *)a->data + a->length * a->elem_size, a->elem_kind);
}






// em_array_remove_at — arr.remove_at(i) removes + returns element i, shifting the tail down one slot
// (OP_ARRAY_REMOVE_AT). The removed element moves OUT (boxed without a retain); the shift relocates
// each later element's single owner; the excess last slot falls outside the shrunk length. Mirrors
// the VM handler — keep the two in step (the differential test + Crucible guard the parity).
Value em_array_remove_at(EmberRt *ctx, Value arr, Value iv) {
    ObjArray *a = AS_ARRAY(arr);
    if (a->borrowed) {
        em_panic("cannot remove_at from a slice view");
    }
    int64_t idx = AS_INT(iv);
    if (idx < 0 || (size_t)idx >= a->length) {
        em_panic("remove_at index out of range");
    }
    Value removed;
    if (a->elem_kind == AEK_INLINE_STRUCT) {
        int fc = ctx->structs[a->elem_struct_id].field_count;
        removed = alloc_instance(ctx, a->elem_struct_id, 0, 0, fc);
        memcpy(AS_STRUCT(removed)->data,
               (unsigned char *)a->data + (size_t)idx * a->elem_size, a->elem_size);
    } else {
        removed = value_box((unsigned char *)a->data + (size_t)idx * a->elem_size, a->elem_kind);
    }
    unsigned char *base = (unsigned char *)a->data;
    memmove(base + (size_t)idx * a->elem_size,
            base + ((size_t)idx + 1) * a->elem_size,
            (a->length - (size_t)idx - 1) * a->elem_size);
    a->length--;
    return removed;
}






// em_array_slice — arr.slice(lo, hi) copies arr[lo..hi] into a fresh OWNED array (OP_SLICE_COPY),
// retaining each copied heap element. Bounds are checked (panic out of range).
Value em_array_slice(EmberRt *ctx, Value arr, Value lov, Value hiv) {
    ObjArray *a = AS_ARRAY(arr);
    int64_t lo = AS_INT(lov), hi = AS_INT(hiv);
    if (lo < 0 || hi < lo || (size_t)hi > a->length) {
        em_panic("slice bounds out of range");
    }
    size_t n = (size_t)(hi - lo);
    // INLINE-STRUCT elements are total_size wide, not sizeof(Value) — use the struct-aware allocator
    // so o->elem_size == a->elem_size and the memcpy below can't overflow the buffer (OFI-083).
    Value out;
    if (a->elem_kind == AEK_INLINE_STRUCT && a->elem_struct_id >= 0) {
        out = alloc_struct_array(ctx, n, a->elem_struct_id);
    } else {
        out = alloc_array(ctx, n, a->elem_kind);
    }
    ObjArray *o = AS_ARRAY(out);
    o->elem_struct_id = a->elem_struct_id;
    if (n > 0) {
        memcpy(o->data, (unsigned char *)a->data + (size_t)lo * a->elem_size,
               n * a->elem_size);
        if (a->elem_kind == AEK_BOXED) {
            for (size_t i = 0; i < n; i++) {
                Value ev = ((Value *)o->data)[i];
                if (IS_OBJ(ev)) {
                    OBJ_RETAIN(AS_OBJ(ev));
                }
            }
        } else if (a->elem_kind == AEK_INLINE_STRUCT) {
            for (size_t i = 0; i < n; i++) {
                struct_elem_retain(ctx, o->elem_struct_id,
                                   (unsigned char *)o->data + i * o->elem_size);
            }
        }
    }
    return out;
}






// em_slice — arr[lo..hi] builds a borrowed Slice<T> VIEW over arr's buffer (the VM's OP_SLICE),
// zero-copy: the result's `data` points into arr at element `lo`, borrowed = 1, so on drop only
// its header is freed (never the buffer or the elements). Bounds are checked. The checker freezes
// arr while the view is live and forbids the view from escaping, so the borrow is always safe.
Value em_slice(EmberRt *ctx, Value arr, Value lov, Value hiv) {
    ObjArray *a = AS_ARRAY(arr);
    int64_t lo = AS_INT(lov), hi = AS_INT(hiv);
    if (lo < 0 || hi < lo || (size_t)hi > a->length) {
        em_panic("slice bounds out of range");
    }
    return alloc_slice(ctx, a, (size_t)lo, (size_t)hi);
}






// em_to_float — to_float(n): int → float (OP_INT_TO_FLOAT).
Value em_to_float(Value v) {
    return FLOAT_VAL((double)AS_INT(v));
}






// em_to_int — to_int(f): float → int, truncating toward zero (OP_FLOAT_TO_INT).
Value em_to_int(Value v) {
    return INT_VAL((int64_t)AS_FLOAT(v));
}






// em_conv — a numeric width conversion u8(x)/i32(x)/f64(x)/… (OP_CONV). Kinds 8/9 are float
// targets (8 = f32 rounds, 9 = f64 passes through); an integer target narrows with a range
// trap, except u64 (kind 7), a lossless bit-reinterpretation of any 64-bit pattern.
Value em_conv(Value v, int nk) {
    if (nk == 8 || nk == 9) {
        double f = AS_FLOAT(v);
        if (nk == 8) { f = (float)f; }
        return FLOAT_VAL(f);
    }
    int64_t i = AS_INT(v);
    if (nk != 7 && (i < EM_NK_MIN[nk] || i > EM_NK_MAX[nk])) {
        em_panic("value out of range for the target integer type");
    }
    return INT_VAL(i);
}






// em_clock — clock() → monotonic seconds as a float (OP_CLOCK). Native has no nondet
// capture/replay, so it reads the real clock directly.
Value em_clock(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return FLOAT_VAL((double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0);
}






// em_assert — a bare `assert(cond [, "msg"])`. Native treats contracts (requires/ensures) as
// release-elided, but a standalone assert stays a hard check that matches --emit=run: on a
// false condition it reports to stderr and halts with code 70 (a passing assert is silent).
Value em_assert(Value cond, const char *msg) {
    int pass = IS_INT(cond)   ? (AS_INT(cond) != 0)
             : IS_FLOAT(cond) ? (AS_FLOAT(cond) != 0.0)
             :                  (AS_OBJ(cond) != NULL);
    if (!pass) {
        fprintf(stderr, "assertion failed%s%s\n", (msg && msg[0]) ? ": " : "",
                (msg && msg[0]) ? msg : "");
        exit(70);
    }
    return INT_VAL(0);
}






// Command-line arguments for args(); the generated main() sets these from its argv so a
// native binary sees the same vector the VM driver passes through g_prog_argc/argv.
int    em_argc = 0;
char **em_argv = NULL;






// em_native — the native-builtin dispatcher (the VM's call_native, minus the verification
// /nondet/graphics paths which are VM-only). print/println keep their own emitter path; this
// covers stdin/file I/O, libm math, char/parse helpers, concat, and args/env/exit.
Value em_native(EmberRt *ctx, int nid, int argc, const Value *args) {
    switch (nid) {
        case NATIVE_READ_LINE: {
            size_t cap = 128, len = 0;
            char *buf = malloc(cap);
            if (buf == NULL) {
                return OBJ_VAL(make_string(ctx, 0));
            }
            int ch;
            while ((ch = fgetc(stdin)) != EOF) {
                if (ch == '\n') {
                    break;
                }
                if (len + 1 >= cap) {
                    cap *= 2;
                    char *nb = realloc(buf, cap);
                    if (nb == NULL) { break; }
                    buf = nb;
                }
                buf[len++] = (char)ch;
            }
            if (len > 0 && buf[len - 1] == '\r') {   // tolerate CRLF
                len--;
            }
            ObjString *s = make_string(ctx, len);
            memcpy(s->chars, buf, len);
            free(buf);
            return OBJ_VAL(s);
        }
        case NATIVE_READ_FILE: {
            const char *path = argc >= 1 ? AS_CSTRING(args[0]) : "";
            FILE *f = fopen(path, "rb");
            ObjString *s;
            long sz = -1;
            if (f != NULL) {
                fseek(f, 0, SEEK_END);
                sz = ftell(f);
                fseek(f, 0, SEEK_SET);
            }
            if (f == NULL || sz < 0) {
                s = make_string(ctx, 0);
            } else {
                char *buf = malloc((size_t)sz + 1);
                size_t got = (buf != NULL) ? fread(buf, 1, (size_t)sz, f) : 0;
                s = make_string(ctx, got);
                if (buf != NULL) {
                    memcpy(s->chars, buf, got);
                    free(buf);
                }
            }
            if (f != NULL) {
                fclose(f);
            }
            return OBJ_VAL(s);
        }
        case NATIVE_WRITE_FILE: {
            const char *path = argc >= 1 ? AS_CSTRING(args[0]) : "";
            FILE *f = fopen(path, "wb");
            if (f != NULL) {
                if (argc >= 2) {
                    ObjString *content = AS_STRING(args[1]);
                    fwrite(content->chars, 1, content->length, f);
                }
                fclose(f);
            }
            return INT_VAL(0);
        }
        case NATIVE_CHAR_CODE: {
            ObjString *s = argc >= 1 ? AS_STRING(args[0]) : NULL;
            if (s == NULL || s->length == 0) {
                return INT_VAL(-1);
            }
            uint32_t cp;
            utf8_decode((const unsigned char *)s->chars, s->length, &cp);
            return INT_VAL((int64_t)cp);
        }
        case NATIVE_FROM_CHAR_CODE: {
            int64_t n = argc >= 1 ? AS_INT(args[0]) : 0;
            unsigned char buf[4];
            int w = utf8_encode((n < 0 || n > 0x10FFFF) ? 0xFFFDu : (uint32_t)n, buf);
            ObjString *s = make_string(ctx, (size_t)w);
            memcpy(s->chars, buf, (size_t)w);
            return OBJ_VAL(s);
        }
        case NATIVE_PARSE_FLOAT: {
            const char *str = argc >= 1 ? AS_CSTRING(args[0]) : "";
            return FLOAT_VAL(strtod(str, NULL));
        }
        case NATIVE_SQRT:  return FLOAT_VAL(sqrt(AS_FLOAT(args[0])));
        case NATIVE_POW:   return FLOAT_VAL(pow(AS_FLOAT(args[0]), AS_FLOAT(args[1])));
        case NATIVE_ABS:   return FLOAT_VAL(fabs(AS_FLOAT(args[0])));
        case NATIVE_FLOOR: return FLOAT_VAL(floor(AS_FLOAT(args[0])));
        case NATIVE_CEIL:  return FLOAT_VAL(ceil(AS_FLOAT(args[0])));
        case NATIVE_ROUND: return FLOAT_VAL(round(AS_FLOAT(args[0])));
        case NATIVE_RANDOM:
            return FLOAT_VAL((double)rand() / ((double)RAND_MAX + 1.0));
        case NATIVE_HASH: {
            ObjString *s = argc >= 1 ? AS_STRING(args[0]) : NULL;
            uint64_t h = 1469598103934665603ULL;   // FNV-1a offset basis
            if (s != NULL) {
                for (size_t i = 0; i < s->length; i++) {
                    h ^= (unsigned char)s->chars[i];
                    h *= 1099511628211ULL;          // FNV-1a prime
                }
            }
            return INT_VAL((int64_t)(h & 0x7fffffffffffffffULL));
        }
        case NATIVE_CONCAT: {
            ObjArray *a = argc >= 1 ? AS_ARRAY(args[0]) : NULL;
            if (a == NULL || a->length == 0) {
                return OBJ_VAL(make_string(ctx, 0));
            }
            const Value *parts = (const Value *)a->data;
            size_t total = 0;
            for (size_t i = 0; i < a->length; i++) {
                total += AS_STRING(parts[i])->length;
            }
            ObjString *r = make_string(ctx, total);
            size_t off = 0;
            for (size_t i = 0; i < a->length; i++) {
                ObjString *p = AS_STRING(parts[i]);
                memcpy(r->chars + off, p->chars, p->length);
                off += p->length;
            }
            return OBJ_VAL(r);
        }
        case NATIVE_ARGS: {
            Value arr = alloc_array(ctx, (size_t)em_argc, AEK_BOXED);
            for (int i = 0; i < em_argc; i++) {
                size_t len = strlen(em_argv[i]);
                ObjString *s = make_string(ctx, len);
                memcpy(s->chars, em_argv[i], len);
                array_unbox(AS_ARRAY(arr), (size_t)i, OBJ_VAL(s));
            }
            return arr;
        }
        case NATIVE_ENV: {
            const char *name = argc >= 1 ? AS_CSTRING(args[0]) : "";
            const char *val  = getenv(name);
            if (val == NULL) {
                return OBJ_VAL(make_string(ctx, 0));
            }
            size_t len = strlen(val);
            ObjString *s = make_string(ctx, len);
            memcpy(s->chars, val, len);
            return OBJ_VAL(s);
        }
        case NATIVE_EXIT:
            exit(argc >= 1 ? (int)AS_INT(args[0]) : 0);
        default:
            em_panic("native backend: unsupported builtin in this build");
    }
    return INT_VAL(0);
}






// em_ffi — invoke `extern "c"` registry index `idx` through the in-tree C wrapper table
// (the VM's OP_CALL_C). `args` are the call's flattened scalar leaves (one Value per
// scalar/string/buffer/Ptr argument); the wrapper writes its result leaves to `out`. A scalar
// return is the single leaf; a struct return (rsid >= 0) is reassembled into a boxed struct.
Value em_ffi(EmberRt *ctx, int idx, int rsid, int argc, const Value *args) {
    Value in[CEXTERN_MAX_LEAVES];
    int n = argc < CEXTERN_MAX_LEAVES ? argc : CEXTERN_MAX_LEAVES;
    for (int i = 0; i < n; i++) {
        in[i] = args[i];
    }
    Value out[CEXTERN_MAX_LEAVES];
    int got = cextern_call(idx, in, out);
    if (cextern_sig(idx)->ret_is_string) {
        // A C-owned returned string (FFI copy-on-return, §5h / OFI-043): out[0] is a malloc'd
        // char* — copy it into an owned Ember string, then free the C buffer.
        char *p = (got > 0) ? (char *)(intptr_t)AS_INT(out[0]) : NULL;
        size_t len = (p != NULL) ? strlen(p) : 0;
        ObjString *s = make_string(ctx, len);
        if (p != NULL) {
            memcpy(s->chars, p, len);
            free(p);
        }
        return OBJ_VAL(s);
    }
    if (rsid >= 0) {
        return em_box_struct(ctx, rsid, out, got);
    }
    return got > 0 ? out[0] : INT_VAL(0);
}