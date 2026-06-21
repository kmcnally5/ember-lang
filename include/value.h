#ifndef EMBER_VALUE_H
#define EMBER_VALUE_H

#include <stddef.h>
#include <stdint.h>

// Under the parallel runtime (`-DEMBER_PARALLEL`: real OS threads, one per spawn today —
// see docs/architecture.md), channels are the cross-thread handoff point, so they carry
// their own mutex + condition variable (see ObjChannel).
#if defined(EMBER_PARALLEL) && EMBER_PARALLEL
#include <pthread.h>
#endif

// A runtime value. It is a tagged union: an inline 64-bit integer (which also
// represents bool as 0/1) or a pointer to a heap-allocated object. Keeping the
// value a fixed size lets the VM stack stay uniform; aggregates (structs) live
// on the heap and are referenced by pointer. This is a runtime-representation
// choice only — the language's ownership/move semantics are a compile-time
// discipline layered above it (MANIFESTO §3.1, §5c).
typedef struct Obj Obj;

typedef enum {
    VAL_INT,
    VAL_FLOAT,
    VAL_OBJ
} ValueType;

typedef struct {
    ValueType type;
    union {
        int64_t integer;
        double  floating;
        Obj    *obj;
    } as;
} Value;

#define INT_VAL(i)    ((Value){ VAL_INT,   { .integer  = (int64_t)(i) } })
#define FLOAT_VAL(f)  ((Value){ VAL_FLOAT, { .floating = (double)(f) } })
#define OBJ_VAL(o)    ((Value){ VAL_OBJ,   { .obj = (Obj *)(o) } })

#define IS_INT(v)     ((v).type == VAL_INT)
#define IS_FLOAT(v)   ((v).type == VAL_FLOAT)
#define IS_OBJ(v)     ((v).type == VAL_OBJ)
#define AS_INT(v)     ((v).as.integer)
#define AS_FLOAT(v)   ((v).as.floating)
#define AS_OBJ(v)     ((v).as.obj)

// Heap objects. `Obj` is the common header; concrete objects embed it first so a
// pointer to the object is also a pointer to its header. Every allocation is
// threaded onto a doubly-linked list rooted at the VM, so a value freed mid-run
// (scope-exit drop) can be unlinked in O(1); the list is also walked to free
// whatever survives to the end of the run.
typedef enum {
    OBJ_STRUCT,
    OBJ_STRING,
    OBJ_ARRAY,
    OBJ_CHANNEL,
    OBJ_CLOSURE,
    OBJ_INTERFACE
} ObjType;

struct Obj {
    ObjType type;
    Obj    *next;
    Obj    *prev;
    void   *home;       // the VM (worker arena) that allocated this object. Under
                        // the parallel runtime each worker has its own lock-free
                        // pool + object list; an object is physically reclaimed only
                        // by its home (a same-thread free), so a cross-thread free
                        // (a channel-passed value dropped on another worker) defers
                        // to the exit sweep. Compared for identity only, never
                        // dereferenced, so a finished worker's pointer is safe to
                        // test. Serial build: always the single VM.
    int     refcount;   // shared, immutable values (strings) are reference-counted:
                        // freed when the last owning binding releases them. Unique
                        // owners (structs) ignore this and are freed directly.
    int     size_class; // allocation pool bucket (block size / 16), or -1 if the
                        // block is malloc-exact and must be free()d. Lets a dead
                        // object be recycled by the next same-sized allocation
                        // instead of round-tripping through malloc/free — objects
                        // (Some(x), struct instances, map entries, small strings)
                        // churn in hot loops. Fills what was struct padding.
};

// An immutable string: its byte length and inline NUL-terminated bytes.
typedef struct {
    Obj    obj;
    size_t length;
    char   chars[];
} ObjString;

#define IS_STRING(v)   (IS_OBJ(v) && AS_OBJ(v)->type == OBJ_STRING)
#define AS_STRING(v)   ((ObjString *)AS_OBJ(v))
#define AS_CSTRING(v)  (((ObjString *)AS_OBJ(v))->chars)

// A heap instance, shared by structs and enum variants: a type id, a `tag` (the
// variant index for an enum; 0 for a struct), and fields in a PACKED buffer.
// A struct's field layout (offset + kind per field) lives in the program's
// StructType[type_id], so scalar fields pack at their natural width; an enum's
// fields are all 16-byte boxed Values at offset index*16 (no descriptor needed).
// `is_enum` distinguishes the two: a struct is a unique-owner value (freed at
// scope exit by OP_DROP); an enum is an immutable, freely-shareable value.
typedef struct {
    Obj           obj;
    int           type_id;
    int           tag;
    int           is_enum;
    int           field_count;
    unsigned char data[];   // packed fields; see StructType for a struct's layout
} ObjStruct;

#define IS_STRUCT(v)  (IS_OBJ(v) && AS_OBJ(v)->type == OBJ_STRUCT)
#define AS_STRUCT(v)  ((ObjStruct *)AS_OBJ(v))

// An array element's storage kind. A scalar element is stored *packed* in its
// natural width (a [u8] is a byte buffer, an [i32] is int32s), so a large numeric
// array costs its true size rather than 16 bytes/element. AEK_BOXED keeps the
// uniform Value[] for elements that are heap objects (structs, strings, enums,
// nested arrays, channels) — those can't be packed in the erased value model.
// The order is shared with the checker's array_elem_kind (codegen emits the byte).
typedef enum {
    AEK_BOXED = 0,
    AEK_I8, AEK_I16, AEK_I32, AEK_I64,
    AEK_U8, AEK_U16, AEK_U32, AEK_U64,
    AEK_F32, AEK_F64, AEK_BOOL,
    // An all-scalar struct stored INLINE: the buffer holds the struct's packed bytes
    // (elem_size = the struct's total_size), no per-element heap object. The struct
    // type id is in ObjArray.elem_struct_id. Indexing materialises a value COPY (a
    // fresh ObjStruct) — the elements are value types (value-types campaign, OFI-027
    // made the materialised copies safe to drop after transient use).
    AEK_INLINE_STRUCT
} ArrayElemKind;

// A growable, uniquely-owned array. Homogeneous (the checker enforces a single
// element type). Elements live in a separate heap buffer of `capacity` slots so
// `append` can grow by reallocating it without moving the ObjArray itself (whose
// address a binding holds). `data` is a `Value[]` when `elem_kind == AEK_BOXED`,
// otherwise a packed buffer of `capacity * elem_size` bytes.
typedef struct {
    Obj      obj;
    size_t   length;
    size_t   capacity;
    uint8_t  elem_kind;       // ArrayElemKind
    uint8_t  elem_size;       // bytes per element (sizeof(Value) when boxed)
    uint8_t  borrowed;        // 1 = a SLICE view (Slice<T>): `data` points into another array's
                              // buffer, so it is read-only and neither frees the buffer on drop
                              // nor owns its elements. The checker freezes the source while a
                              // view is live and forbids the view from escaping (slices §).
    int      elem_struct_id;  // for AEK_INLINE_STRUCT: the element struct's type id
                              // (to materialise an ObjStruct on index); -1 otherwise
    void    *data;
} ObjArray;

#define IS_ARRAY(v)   (IS_OBJ(v) && AS_OBJ(v)->type == OBJ_ARRAY)
#define AS_ARRAY(v)   ((ObjArray *)AS_OBJ(v))

struct Fiber;   // defined in src/vm.c; ObjChannel parks fibers on it under EMBER_MN

// A buffered channel: a fixed-capacity circular queue of Values. Shared between
// fibers (cooperative single-threading makes the shared mutation race-free); send
// blocks when full, recv when empty (the scheduler yields and resumes).
typedef struct {
    Obj    obj;
    Value *buffer;    // heap array of `capacity` slots
    int    capacity;
    int    count;     // number of queued values
    int    head;      // index of the next value to dequeue
    int    closed;    // 1 once close() ran: drains, then recv yields None
#if defined(EMBER_PARALLEL) && EMBER_PARALLEL
    // In parallel mode tasks on different cores share a channel: send/recv/close take `lock`.
    pthread_mutex_t lock;
#if defined(EMBER_MN) && EMBER_MN
    // M:N: a blocked op does NOT block its OS thread — the fiber PARKS. Parked fibers hang off
    // the channel in two intrusive FIFOs (linked via Fiber.wait_next), so a waker can move the
    // exact peer that can now proceed onto the ready-queue. No condvars: the worker, not the OS
    // thread, is what waits. (Verified lost-wakeup-free: park + the emptiness re-check are one
    // critical section under `lock`; see the M:N channel protocol in docs/architecture.md.)
    struct Fiber *recv_head, *recv_tail;   // receivers parked on an empty channel, FIFO
    struct Fiber *send_head, *send_tail;   // senders parked on a full channel, FIFO
#else
    // 1:1 thread-per-fiber: a blocked op blocks its OS thread on a condvar. TWO condvars so a
    // wake-up targets exactly the kind of task that can proceed (no thundering herd): a receiver
    // on an empty channel waits on `not_empty`; a sender on a full one waits on `not_full`.
    pthread_cond_t  not_empty;   // signalled by send / broadcast by close
    pthread_cond_t  not_full;    // signalled by recv / broadcast by close
    int             recv_waiters;// tasks blocked in recv (waiting on not_empty)
    int             send_waiters;// tasks blocked in send (waiting on not_full)
#endif
#endif
} ObjChannel;

#define IS_CHANNEL(v) (IS_OBJ(v) && AS_OBJ(v)->type == OBJ_CHANNEL)
#define AS_CHANNEL(v) ((ObjChannel *)AS_OBJ(v))

// A function value (closure): a reference to a compiled function by table index
// plus the values it captured *by value* at creation. A bare named function used
// as a value is a closure with zero captures. Refcounted and freely shareable like
// a string; freeing it releases each captured value. The lifted function sees its
// locals as [captures..., declared params...].
typedef struct {
    Obj   obj;
    int   fn_index;
    int   capture_count;
    Value captures[];     // captured-by-value environment, in capture order
} ObjClosure;

#define IS_CLOSURE(v) (IS_OBJ(v) && AS_OBJ(v)->type == OBJ_CLOSURE)
#define AS_CLOSURE(v) ((ObjClosure *)AS_OBJ(v))

// An interface value (dynamic dispatch): a struct receiver bundled with its vtable —
// Go's (data, itable) / Rust's `dyn (data, vtable)`. The `vtable` is the witness record
// built for (receiver's struct, interface): an ObjStruct whose fields are the impl's
// method fn-indices in interface-method order. The interface value uniquely OWNS its
// receiver (a struct move type), so dropping it drops the receiver; the vtable holds only
// ints, so it needs no recursive release. A method call reads vtable[slot] and calls it
// indirectly with `receiver` as self (OP_CALL_DYN).
typedef struct {
    Obj   obj;
    Value receiver;       // the boxed struct the interface was built from (owned)
    Value vtable;         // the witness ObjStruct (method fn-indices)
} ObjInterface;

#define IS_INTERFACE(v) (IS_OBJ(v) && AS_OBJ(v)->type == OBJ_INTERFACE)
#define AS_INTERFACE(v) ((ObjInterface *)AS_OBJ(v))

#endif // EMBER_VALUE_H
