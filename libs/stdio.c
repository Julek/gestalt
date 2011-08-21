#include <stdio.h>
#include <system.h>

unsigned short *restrict videoram = (unsigned short*)0xb8000;
unsigned short cursor = 0;
unsigned short attributes = (0x07 << 8);

void print(char* string)
{
  for(int i = 0; string[i]; i++)
    {
      if(string[i] == '\n')
	{
	  cursor = cursor + 80 - (cursor % 80);

	  if(cursor > (80*25))
	    scroll(1);

	  continue;
	}
      videoram[cursor++] = (unsigned short)(string[i]) | attributes;

      if(cursor > (80*25))
	  scroll(1);

    }
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

  for(int i = 0; i <= ((25 - lines)*80); i++)
    videoram[i] = videoram[i + (80 * lines)];

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
