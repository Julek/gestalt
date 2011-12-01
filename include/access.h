#ifndef ACCESS_H
#define ACCESS_H

enum segment {k_text = 0, k_data = 1, k_rodata = 2, d_text = 3, d_data = 4, d_rodata = 5, s_text = 6, s_data = 7, s_rodata = 8, a_text = 9, a_data = 10, a_rodata = 11};
//k = kernel, d = driver, s = subkernel, a = application.

typedef enum segment segment;

#endif
