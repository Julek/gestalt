#ifndef LINKER_SYMBOLS_H
#define LINKER_SYMBOLS_H

extern const unsigned int _begin, _stext, _etext, _srodata, _erodata, _sdata, _edata, _sbss, _ebss, _end;

#define begin (unsigned int)&_begin
#define stext (unsigned int)&_stext
#define etext (unsigned int)&_etext
#define srodata (unsigned int)&_srodata
#define erodata (unsigned int)&_erodata
#define sdata (unsigned int)&_sdata
#define edata (unsigned int)&_edata
#define sbss (unsigned int)&_sbss
#define ebss (unsigned int)&_ebss
#define end (unsigned int)&_end

#endif
