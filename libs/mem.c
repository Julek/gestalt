/*#include <mem.h>

bool set_mem(void* start, char start_offset, void* end, char end_offset) {
  if((((unsigned long)start) > ((unsigned long)end)) || (((unsigned long)start) == ((unsigned long)end) && start_offset > end_offset) || (start_offset >= sizeof(char)) || (end_offset >= sizeof(char))){
    return false;
  } else {
    
    if(start_offset != 0){
      unsigned long mask = 1;
      for(int i = 0; i < start_offset; ++i)
	mask *= 2;
      mask = mask - 1;
      mask = ~mask;
      start += 1;
    }
    return true;
  }
}
*/
