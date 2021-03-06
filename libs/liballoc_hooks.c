#include <paging.h>

int liballoc_lock() {
  lock_allocation();
  return 0;
}

int liballoc_unlock() {
  unlock_allocation();
  return 0;
}

void* liballoc_alloc(int num_pages) {
  return (void*)palloc(num_pages);
}

void* liballoc_free(void* page_address, int num_pages) {
  if(pfree((unsigned long)page_address, num_pages)) {
    return (void*)0;
  } else {
    return (void*)1;
  }
}
