/*
 * (c)2014 Tweag I/O
 *
 * The Static Pointer Table implementation.
 *
 * https://ghc.haskell.org/trac/ghc/wiki/StaticPointers
 * https://ghc.haskell.org/trac/ghc/wiki/StaticPointers/ImplementationPlan
 *
 */

#include "StaticPtrTable.h"
#include "Rts.h"
#include "RtsUtils.h"
#include "Hash.h"
#include "Stable.h"

static HashTable * spt = NULL;

#ifdef THREADED_RTS
static Mutex spt_lock;
#endif

/// Hash function for the SPT.
static int hashFingerprint(HashTable *table, StgWord64 key[2]) {
  // Take half of the key to compute the hash.
  return hashWord(table, (StgWord)key[1]);
}

/// Comparison function for the SPT.
static int compareFingerprint(StgWord64 ptra[2], StgWord64 ptrb[2]) {
  return ptra[0] == ptrb[0] && ptra[1] == ptrb[1];
}

void hs_spt_insert(StgWord64 key[2],void *spe_closure) {
  // hs_spt_insert is called from constructor functions, so
  // the SPT needs to be initialized here.
  if (spt == NULL) {
    spt = allocHashTable_( (HashFunction *)hashFingerprint
                         , (CompareFunction *)compareFingerprint
                         );
#ifdef THREADED_RTS
    initMutex(&spt_lock);
#endif
  }

  StgStablePtr * entry = stgMallocBytes( sizeof(StgStablePtr)
                                       , "hs_spt_insert: entry"
                                       );
  *entry = getStablePtr(spe_closure);
  ACQUIRE_LOCK(&spt_lock);
  insertHashTable(spt, (StgWord)key, entry);
  RELEASE_LOCK(&spt_lock);
}

static void freeSptEntry(void* entry) {
  freeStablePtr(*(StgStablePtr*)entry);
  stgFree(entry);
}

void hs_spt_remove(StgWord64 key[2]) {
   if (spt) {
     ACQUIRE_LOCK(&spt_lock);
     StgStablePtr* entry = removeHashTable(spt, (StgWord)key, NULL);
     RELEASE_LOCK(&spt_lock);

     if (entry)
       freeSptEntry(entry);
   }
}

StgPtr hs_spt_lookup(StgWord64 key[2]) {
  if (spt) {
    ACQUIRE_LOCK(&spt_lock);
    const StgStablePtr * entry = lookupHashTable(spt, (StgWord)key);
    RELEASE_LOCK(&spt_lock);
    const StgPtr ret = entry ? deRefStablePtr(*entry) : NULL;
    return ret;
  } else
    return NULL;
}

int hs_spt_keys(StgPtr keys[], int szKeys) {
  if (spt) {
    ACQUIRE_LOCK(&spt_lock);
    const int ret = keysHashTable(spt, (StgWord*)keys, szKeys);
    RELEASE_LOCK(&spt_lock);
    return ret;
  } else
    return 0;
}

int hs_spt_key_count() {
  return spt ? keyCountHashTable(spt) : 0;
}

void exitStaticPtrTable() {
  if (spt) {
    freeHashTable(spt, freeSptEntry);
    spt = NULL;
#ifdef THREADED_RTS
    closeMutex(&spt_lock);
#endif
  }
}
