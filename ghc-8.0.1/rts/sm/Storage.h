/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 1998-2009
 *
 * External Storage Manger Interface
 *
 * ---------------------------------------------------------------------------*/

#ifndef SM_STORAGE_H
#define SM_STORAGE_H

#include "Capability.h"

#include "BeginPrivate.h"

/* -----------------------------------------------------------------------------
   Initialisation / De-initialisation
   -------------------------------------------------------------------------- */

void initStorage(void);
void exitStorage(void);
void freeStorage(rtsBool free_heap);

// Adding more Capabilities later: this function allocates nurseries
// and initialises other storage-related things.
void storageAddCapabilities (nat from, nat to);

/* -----------------------------------------------------------------------------
   Storage manager state
   -------------------------------------------------------------------------- */

INLINE_HEADER rtsBool
doYouWantToGC( Capability *cap )
{
  return (cap->r.rCurrentNursery->link == NULL ||
          g0->n_new_large_words >= large_alloc_lim);
}

/* for splitting blocks groups in two */
bdescr * splitLargeBlock (bdescr *bd, W_ blocks);

/* -----------------------------------------------------------------------------
   Generational garbage collection support

   updateWithIndirection(p1,p2)  Updates the object at p1 with an
                                 indirection pointing to p2.  This is
                                 normally called for objects in an old
                                 generation (>0) when they are updated.

   updateWithPermIndirection(p1,p2)  As above but uses a permanent indir.

   -------------------------------------------------------------------------- */

/*
 * Storage manager mutex
 */
#if defined(THREADED_RTS)
extern Mutex sm_mutex;
#endif

#if defined(THREADED_RTS)
#define ACQUIRE_SM_LOCK   ACQUIRE_LOCK(&sm_mutex);
#define RELEASE_SM_LOCK   RELEASE_LOCK(&sm_mutex);
#define ASSERT_SM_LOCK()  ASSERT_LOCK_HELD(&sm_mutex);
#else
#define ACQUIRE_SM_LOCK
#define RELEASE_SM_LOCK
#define ASSERT_SM_LOCK()
#endif

/* -----------------------------------------------------------------------------
   The write barrier for MVARs and TVARs
   -------------------------------------------------------------------------- */

void dirty_MVAR(StgRegTable *reg, StgClosure *p);
void dirty_TVAR(Capability *cap, StgTVar *p);

/* -----------------------------------------------------------------------------
   Nursery manipulation
   -------------------------------------------------------------------------- */

extern nursery *nurseries;
extern nat n_nurseries;

void     resetNurseries       ( void );
void     clearNursery         ( Capability *cap );
void     resizeNurseries      ( W_ blocks );
void     resizeNurseriesFixed ( void );
W_       countNurseryBlocks   ( void );
rtsBool  getNewNursery        ( Capability *cap );

/* -----------------------------------------------------------------------------
   Allocation accounting

   See [Note allocation accounting] in Storage.c
   -------------------------------------------------------------------------- */

//
// Called when we are finished allocating into a block; account for the amount
// allocated in cap->total_allocated.
//
INLINE_HEADER void finishedNurseryBlock (Capability *cap, bdescr *bd) {
    cap->total_allocated += bd->free - bd->start;
}

INLINE_HEADER void newNurseryBlock (bdescr *bd) {
    bd->free = bd->start;
}

void    updateNurseriesStats (void);
StgWord calcTotalAllocated   (void);

/* -----------------------------------------------------------------------------
   Stats 'n' DEBUG stuff
   -------------------------------------------------------------------------- */

W_    countLargeAllocated  (void);
W_    countOccupied        (bdescr *bd);
W_    calcNeeded           (rtsBool force_major, W_ *blocks_needed);

W_    gcThreadLiveWords  (nat i, nat g);
W_    gcThreadLiveBlocks (nat i, nat g);

W_    genLiveWords  (generation *gen);
W_    genLiveBlocks (generation *gen);

W_    calcLiveBlocks (void);
W_    calcLiveWords  (void);

/* ----------------------------------------------------------------------------
   Storage manager internal APIs and globals
   ------------------------------------------------------------------------- */

extern bdescr *exec_block;

void move_STACK  (StgStack *src, StgStack *dest);

/* -----------------------------------------------------------------------------
   Note [STATIC_LINK fields]

   The low 2 bits of the static link field have the following meaning:

   00     we haven't seen this static object before

   01/10  if it equals static_flag, then we saw it in this GC, otherwise
          we saw it in the previous GC.

   11     ignore during GC.  This value is used in two ways
          - When we put CAFs on a list (see Note [CAF lists])
          - a static constructor that was determined to have no CAF
            references at compile time is given this value, so we
            don't traverse it during GC

  This choice of values is quite deliberate, because it means we can
  decide whether a static object should be traversed during GC using a
  single test:

  bits = link_field & 3;
  if ((bits | prev_static_flag) != 3) { ... }

  -------------------------------------------------------------------------- */

#define STATIC_BITS 3

#define STATIC_FLAG_A 1
#define STATIC_FLAG_B 2
#define STATIC_FLAG_LIST 3

#define END_OF_CAF_LIST ((StgClosure*)STATIC_FLAG_LIST)

// The previous and current values of the static flag.  These flip
// between STATIC_FLAG_A and STATIC_FLAG_B at each major GC.
extern nat prev_static_flag, static_flag;

// In the chain of static objects built up during GC, all the link
// fields are tagged with the current static_flag value.  How to mark
// the end of the chain?  It must be a special value so that we can
// tell it is the end of the chain, but note that we're going to store
// this value in the link field of a static object, which means that
// during the NEXT GC we should treat it like any other object that
// has not been visited during this GC.  Therefore, we use static_flag
// as the sentinel value.
#define END_OF_STATIC_OBJECT_LIST ((StgClosure*)(StgWord)static_flag)

#define UNTAG_STATIC_LIST_PTR(p) ((StgClosure*)((StgWord)(p) & ~STATIC_BITS))

/* -----------------------------------------------------------------------------
   Note [CAF lists]

   dyn_caf_list  (CAFs chained through static_link)
      This is a chain of all CAFs in the program, used for
      dynamically-linked GHCi.
      See Note [dyn_caf_list].

   debug_caf_list  (CAFs chained through saved_info)
      A chain of all *live* CAFs in the program, that does not keep
      the CAFs alive.  Used for detecting when we enter a GC'd CAF,
      and to give diagnostics with +RTS -DG.

   revertible_caf_list  (CAFs chained through static_link)
      A chain of CAFs in object code loaded with the RTS linker.
      These CAFs can be reverted to their unevaluated state using
      revertCAFs.

 Pointers in these lists are tagged with STATIC_FLAG_LIST, so when
 traversing the list remember to untag each pointer with
 UNTAG_STATIC_LIST_PTR().
 --------------------------------------------------------------------------- */

extern StgIndStatic * dyn_caf_list;
extern StgIndStatic * debug_caf_list;
extern StgIndStatic * revertible_caf_list;

#include "EndPrivate.h"

#endif /* SM_STORAGE_H */
