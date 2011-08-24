#include <stdio.h>
#include <system.h>
#include <stdarg.h>

unsigned short *restrict videoram = (unsigned short*)0xb8000;
unsigned short cursor = 0;
unsigned short attributes = (0x07 << 8);

void print(char* string, ...)
{
  va_list list;
  va_start(list, string);
  for(int i = 0; string[i]; i++)
    {
      if(string[i] == '%')
	{
	  if(string[i + 1] == 'i')
	    {
	      int num = va_arg(list, int);
	      if(num < 0)
		{
		  putch('-');
		  num *= -1;
		}
	      if(num <= 9)
		{
		  putch((char)(num + 48));
		  i++;
		  continue;
		}
	      int pow = 1;
	      for(int temp = num; temp >= 10; temp /= 10, pow *= 10);
	      for(; pow != 0; pow /= 10)
		{
		  putch((char)((num / pow) + 48));
		  num -= ((num / pow) * pow);
		}	    
	      i++;
	      continue;
	    }
	  if(string[i + 1] == 'u')
	    {
	      unsigned int num = va_arg(list, unsigned int);
	      if(num <= 9)
		{
		  putch((char)(num + 48));
		  i++;
		  continue;
		}
	      unsigned int pow = 1;
	      for(unsigned int temp = num; temp >= 10; temp /= 10, pow *= 10);
	      for(; pow != 0; pow /= 10)
		{
		  putch((char)((num / pow) + 48));
		  num -= ((num / pow) * pow);
		}	    
	      i++;
	      continue;
	    }
	  if(string[i + 1] == 'c')
	    {
	      char c = (char)va_arg(list, int);
	      putch(c);
	      i++;
	      continue;
	    }
	  if(string[i + 1] == 's')
	    {
	      char* s = va_arg(list, char*);
	      print(s);
	      i++;
	      continue;
	    }
	}
      putch(string[i]);
    }
  return;
}

void putch(char c)
{
  if(c == '\n')
    {
      cursor = cursor + 80 - (cursor % 80);
      
      if(cursor >= (80*25))
	scroll(1);
      
      return;
    }
  videoram[cursor++] = (unsigned short)(c) | attributes;
  if(cursor >= 80*25)
    scroll(1);
  set_cursor(cursor);
  return;
}

void scroll(unsigned char lines)
{
  if(lines > 25)
    {
      clear_screen();
      cursor = 0;
      set_cursor(cursor);
      return;
    }

  for(int i = 0; i < ((25 - lines)*80); i++)
    videoram[i] = videoram[i + (80 * lines)];

  for(int i = 80*(25-lines); i < 25*80; i++)
    videoram[i] = (unsigned short)0;

  if(cursor < 80*lines)
    cursor = 0;
  else
    cursor -= (80*lines);

  return;
}

void set_attributes(char attribs)
{
  attributes = (((unsigned short)(attribs)) << 8);
  return;
}

void set_cursor(unsigned short pos)
{

  outb(0x3D4, 0x0F);
  outb(0x3D5, (unsigned char)(pos&0xFF));
  outb(0x3D4, 0x0E);
  outb(0x3D5, (unsigned char)((pos >> 8)&0xFF));

  return;
}

void gotoxy(unsigned short x, unsigned short y)
{
  cursor = 80*y + x;
  set_cursor(cursor);
  return;
}

void clear_screen()
{
  for(int i = 0; i < 2000; i++)
    videoram[i] = 0;
  cursor = 0;
  set_cursor(0);
  return;
}
