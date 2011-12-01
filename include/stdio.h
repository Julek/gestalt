#ifndef STDIO
#define STDIO

extern void print(char* string, ...);
extern void set_attributes(char attribs);
extern void set_cursor(unsigned short pos);
extern void gotoxy(unsigned short x, unsigned short y);
extern void clear_screen();
extern void scroll(unsigned char lines);
extern void putch(char c);

#endif
