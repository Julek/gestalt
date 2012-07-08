ENTRY (loader)

SECTIONS {
	 . = 0x00100000;
	 
	 _begin = .;

	 .text :{
	       _stext = .;
	       *(.text)
	       _etext = .;
	       }

	  .rodata ALIGN (0x1000) : {
	  	  _srodata = .;
	  	  *(.rodata)
		  _erodata = .;
		  }

	.data ALIGN (0x1000) : {
	      _sdata = .;
	      *(.data)
	      _edata = .;
	      }

	.bss ALIGN (0x1000) : {
	     _sbss = .;
	     *(COMMON)
	     *(.bss)
	     _ebss = .;
	     }

	.end ALIGN (0x1000) : {
	     _end = .;
	     }
}    
