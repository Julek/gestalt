#include <idt.h>
#include <interrupt_stubs.h>
#include <pic.h>
#include <regs.h>
#include <stdio.h>
#include <system.h>
#include <interrupt_handler.h>

void *int_routines[256] = {[0 ... 255] = 0};

char* exceptions[32] = {
  "Division By Zero Exception\n",
  "Debug Exception\n",
  "Non Maskable Interrupt Exception\n",
  "Breakpoint Exception\n",
  "Into Detected Overflow Exception\n",
  "Out of Bounds Exception\n",
  "Invalid Opcode Exception\n",
  "No Coprocessor Exception\n",
  "Double Fault Exception\n",
  "Coprocessor Segment Overrun Exception\n",
  "Bad TSS Exception\n",
  "Segment Not Present Exception\n",
  "Stack Fault Exception\n",
  "General Protection Fault Exception\n",
  "Page Fault Exception\n",
  "x87 FPU Floating-Point Error\n",
  "Coprocessor Fault Exception\n",
  "Alignment Check Exception\n",
  "Machine Check Exception\n",
  "SIMD floating point exception\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n"};

void install_ints()
{
  setup_idt();
  pic_remap();
  install_kint(0, (unsigned int)int0, 0x08);
  install_kint(1, (unsigned int)int1, 0x08);
  install_kint(2, (unsigned int)int2, 0x08);
  install_kint(3, (unsigned int)int3, 0x08);
  install_kint(4, (unsigned int)int4, 0x08);
  install_kint(5, (unsigned int)int5, 0x08);
  install_kint(6, (unsigned int)int6, 0x08);
  install_kint(7, (unsigned int)int7, 0x08);
  install_kint(8, (unsigned int)int8, 0x08);
  install_kint(9, (unsigned int)int9, 0x08);
  install_kint(10, (unsigned int)int10, 0x08);
  install_kint(11, (unsigned int)int11, 0x08);
  install_kint(12, (unsigned int)int12, 0x08);
  install_kint(13, (unsigned int)int13, 0x08);
  install_kint(14, (unsigned int)int14, 0x08);
  install_kint(15, (unsigned int)int15, 0x08);
  install_kint(16, (unsigned int)int16, 0x08);
  install_kint(17, (unsigned int)int17, 0x08);
  install_kint(18, (unsigned int)int18, 0x08);
  install_kint(19, (unsigned int)int19, 0x08);
  install_kint(20, (unsigned int)int20, 0x08);
  install_kint(21, (unsigned int)int21, 0x08);
  install_kint(22, (unsigned int)int22, 0x08);
  install_kint(23, (unsigned int)int23, 0x08);
  install_kint(24, (unsigned int)int24, 0x08);
  install_kint(25, (unsigned int)int25, 0x08);
  install_kint(26, (unsigned int)int26, 0x08);
  install_kint(27, (unsigned int)int27, 0x08);
  install_kint(28, (unsigned int)int28, 0x08);
  install_kint(29, (unsigned int)int29, 0x08);
  install_kint(30, (unsigned int)int30, 0x08);
  install_kint(31, (unsigned int)int31, 0x08);
  install_kint(32, (unsigned int)int32, 0x08);
  install_kint(33, (unsigned int)int33, 0x08);
  install_kint(34, (unsigned int)int34, 0x08);
  install_kint(35, (unsigned int)int35, 0x08);
  install_kint(36, (unsigned int)int36, 0x08);
  install_kint(37, (unsigned int)int37, 0x08);
  install_kint(38, (unsigned int)int38, 0x08);
  install_kint(39, (unsigned int)int39, 0x08);
  install_kint(40, (unsigned int)int40, 0x08);
  install_kint(41, (unsigned int)int41, 0x08);
  install_kint(42, (unsigned int)int42, 0x08);
  install_kint(43, (unsigned int)int43, 0x08);
  install_kint(44, (unsigned int)int44, 0x08);
  install_kint(45, (unsigned int)int45, 0x08);
  install_kint(46, (unsigned int)int46, 0x08);
  install_kint(47, (unsigned int)int47, 0x08);
  install_kint(48, (unsigned int)int48, 0x08);
  install_kint(49, (unsigned int)int49, 0x08);
  install_kint(50, (unsigned int)int50, 0x08);
  install_kint(51, (unsigned int)int51, 0x08);
  install_kint(52, (unsigned int)int52, 0x08);
  install_kint(53, (unsigned int)int53, 0x08);
  install_kint(54, (unsigned int)int54, 0x08);
  install_kint(55, (unsigned int)int55, 0x08);
  install_kint(56, (unsigned int)int56, 0x08);
  install_kint(57, (unsigned int)int57, 0x08);
  install_kint(58, (unsigned int)int58, 0x08);
  install_kint(59, (unsigned int)int59, 0x08);
  install_kint(60, (unsigned int)int60, 0x08);
  install_kint(61, (unsigned int)int61, 0x08);
  install_kint(62, (unsigned int)int62, 0x08);
  install_kint(63, (unsigned int)int63, 0x08);
  install_kint(64, (unsigned int)int64, 0x08);
  install_kint(65, (unsigned int)int65, 0x08);
  install_kint(66, (unsigned int)int66, 0x08);
  install_kint(67, (unsigned int)int67, 0x08);
  install_kint(68, (unsigned int)int68, 0x08);
  install_kint(69, (unsigned int)int69, 0x08);
  install_kint(70, (unsigned int)int70, 0x08);
  install_kint(71, (unsigned int)int71, 0x08);
  install_kint(72, (unsigned int)int72, 0x08);
  install_kint(73, (unsigned int)int73, 0x08);
  install_kint(74, (unsigned int)int74, 0x08);
  install_kint(75, (unsigned int)int75, 0x08);
  install_kint(76, (unsigned int)int76, 0x08);
  install_kint(77, (unsigned int)int77, 0x08);
  install_kint(78, (unsigned int)int78, 0x08);
  install_kint(79, (unsigned int)int79, 0x08);
  install_kint(80, (unsigned int)int80, 0x08);
  install_kint(81, (unsigned int)int81, 0x08);
  install_kint(82, (unsigned int)int82, 0x08);
  install_kint(83, (unsigned int)int83, 0x08);
  install_kint(84, (unsigned int)int84, 0x08);
  install_kint(85, (unsigned int)int85, 0x08);
  install_kint(86, (unsigned int)int86, 0x08);
  install_kint(87, (unsigned int)int87, 0x08);
  install_kint(88, (unsigned int)int88, 0x08);
  install_kint(89, (unsigned int)int89, 0x08);
  install_kint(90, (unsigned int)int90, 0x08);
  install_kint(91, (unsigned int)int91, 0x08);
  install_kint(92, (unsigned int)int92, 0x08);
  install_kint(93, (unsigned int)int93, 0x08);
  install_kint(94, (unsigned int)int94, 0x08);
  install_kint(95, (unsigned int)int95, 0x08);
  install_kint(96, (unsigned int)int96, 0x08);
  install_kint(97, (unsigned int)int97, 0x08);
  install_kint(98, (unsigned int)int98, 0x08);
  install_kint(99, (unsigned int)int99, 0x08);
  install_kint(100, (unsigned int)int100, 0x08);
  install_kint(101, (unsigned int)int101, 0x08);
  install_kint(102, (unsigned int)int102, 0x08);
  install_kint(103, (unsigned int)int103, 0x08);
  install_kint(104, (unsigned int)int104, 0x08);
  install_kint(105, (unsigned int)int105, 0x08);
  install_kint(106, (unsigned int)int106, 0x08);
  install_kint(107, (unsigned int)int107, 0x08);
  install_kint(108, (unsigned int)int108, 0x08);
  install_kint(109, (unsigned int)int109, 0x08);
  install_kint(110, (unsigned int)int110, 0x08);
  install_kint(111, (unsigned int)int111, 0x08);
  install_kint(112, (unsigned int)int112, 0x08);
  install_kint(113, (unsigned int)int113, 0x08);
  install_kint(114, (unsigned int)int114, 0x08);
  install_kint(115, (unsigned int)int115, 0x08);
  install_kint(116, (unsigned int)int116, 0x08);
  install_kint(117, (unsigned int)int117, 0x08);
  install_kint(118, (unsigned int)int118, 0x08);
  install_kint(119, (unsigned int)int119, 0x08);
  install_kint(120, (unsigned int)int120, 0x08);
  install_kint(121, (unsigned int)int121, 0x08);
  install_kint(122, (unsigned int)int122, 0x08);
  install_kint(123, (unsigned int)int123, 0x08);
  install_kint(124, (unsigned int)int124, 0x08);
  install_kint(125, (unsigned int)int125, 0x08);
  install_kint(126, (unsigned int)int126, 0x08);
  install_kint(127, (unsigned int)int127, 0x08);
  install_kint(128, (unsigned int)int128, 0x08);
  install_kint(129, (unsigned int)int129, 0x08);
  install_kint(130, (unsigned int)int130, 0x08);
  install_kint(131, (unsigned int)int131, 0x08);
  install_kint(132, (unsigned int)int132, 0x08);
  install_kint(133, (unsigned int)int133, 0x08);
  install_kint(134, (unsigned int)int134, 0x08);
  install_kint(135, (unsigned int)int135, 0x08);
  install_kint(136, (unsigned int)int136, 0x08);
  install_kint(137, (unsigned int)int137, 0x08);
  install_kint(138, (unsigned int)int138, 0x08);
  install_kint(139, (unsigned int)int139, 0x08);
  install_kint(140, (unsigned int)int140, 0x08);
  install_kint(141, (unsigned int)int141, 0x08);
  install_kint(142, (unsigned int)int142, 0x08);
  install_kint(143, (unsigned int)int143, 0x08);
  install_kint(144, (unsigned int)int144, 0x08);
  install_kint(145, (unsigned int)int145, 0x08);
  install_kint(146, (unsigned int)int146, 0x08);
  install_kint(147, (unsigned int)int147, 0x08);
  install_kint(148, (unsigned int)int148, 0x08);
  install_kint(149, (unsigned int)int149, 0x08);
  install_kint(150, (unsigned int)int150, 0x08);
  install_kint(151, (unsigned int)int151, 0x08);
  install_kint(152, (unsigned int)int152, 0x08);
  install_kint(153, (unsigned int)int153, 0x08);
  install_kint(154, (unsigned int)int154, 0x08);
  install_kint(155, (unsigned int)int155, 0x08);
  install_kint(156, (unsigned int)int156, 0x08);
  install_kint(157, (unsigned int)int157, 0x08);
  install_kint(158, (unsigned int)int158, 0x08);
  install_kint(159, (unsigned int)int159, 0x08);
  install_kint(160, (unsigned int)int160, 0x08);
  install_kint(161, (unsigned int)int161, 0x08);
  install_kint(162, (unsigned int)int162, 0x08);
  install_kint(163, (unsigned int)int163, 0x08);
  install_kint(164, (unsigned int)int164, 0x08);
  install_kint(165, (unsigned int)int165, 0x08);
  install_kint(166, (unsigned int)int166, 0x08);
  install_kint(167, (unsigned int)int167, 0x08);
  install_kint(168, (unsigned int)int168, 0x08);
  install_kint(169, (unsigned int)int169, 0x08);
  install_kint(170, (unsigned int)int170, 0x08);
  install_kint(171, (unsigned int)int171, 0x08);
  install_kint(172, (unsigned int)int172, 0x08);
  install_kint(173, (unsigned int)int173, 0x08);
  install_kint(174, (unsigned int)int174, 0x08);
  install_kint(175, (unsigned int)int175, 0x08);
  install_kint(176, (unsigned int)int176, 0x08);
  install_kint(177, (unsigned int)int177, 0x08);
  install_kint(178, (unsigned int)int178, 0x08);
  install_kint(179, (unsigned int)int179, 0x08);
  install_kint(180, (unsigned int)int180, 0x08);
  install_kint(181, (unsigned int)int181, 0x08);
  install_kint(182, (unsigned int)int182, 0x08);
  install_kint(183, (unsigned int)int183, 0x08);
  install_kint(184, (unsigned int)int184, 0x08);
  install_kint(185, (unsigned int)int185, 0x08);
  install_kint(186, (unsigned int)int186, 0x08);
  install_kint(187, (unsigned int)int187, 0x08);
  install_kint(188, (unsigned int)int188, 0x08);
  install_kint(189, (unsigned int)int189, 0x08);
  install_kint(190, (unsigned int)int190, 0x08);
  install_kint(191, (unsigned int)int191, 0x08);
  install_kint(192, (unsigned int)int192, 0x08);
  install_kint(193, (unsigned int)int193, 0x08);
  install_kint(194, (unsigned int)int194, 0x08);
  install_kint(195, (unsigned int)int195, 0x08);
  install_kint(196, (unsigned int)int196, 0x08);
  install_kint(197, (unsigned int)int197, 0x08);
  install_kint(198, (unsigned int)int198, 0x08);
  install_kint(199, (unsigned int)int199, 0x08);
  install_kint(200, (unsigned int)int200, 0x08);
  install_kint(201, (unsigned int)int201, 0x08);
  install_kint(202, (unsigned int)int202, 0x08);
  install_kint(203, (unsigned int)int203, 0x08);
  install_kint(204, (unsigned int)int204, 0x08);
  install_kint(205, (unsigned int)int205, 0x08);
  install_kint(206, (unsigned int)int206, 0x08);
  install_kint(207, (unsigned int)int207, 0x08);
  install_kint(208, (unsigned int)int208, 0x08);
  install_kint(209, (unsigned int)int209, 0x08);
  install_kint(210, (unsigned int)int210, 0x08);
  install_kint(211, (unsigned int)int211, 0x08);
  install_kint(212, (unsigned int)int212, 0x08);
  install_kint(213, (unsigned int)int213, 0x08);
  install_kint(214, (unsigned int)int214, 0x08);
  install_kint(215, (unsigned int)int215, 0x08);
  install_kint(216, (unsigned int)int216, 0x08);
  install_kint(217, (unsigned int)int217, 0x08);
  install_kint(218, (unsigned int)int218, 0x08);
  install_kint(219, (unsigned int)int219, 0x08);
  install_kint(220, (unsigned int)int220, 0x08);
  install_kint(221, (unsigned int)int221, 0x08);
  install_kint(222, (unsigned int)int222, 0x08);
  install_kint(223, (unsigned int)int223, 0x08);
  install_kint(224, (unsigned int)int224, 0x08);
  install_kint(225, (unsigned int)int225, 0x08);
  install_kint(226, (unsigned int)int226, 0x08);
  install_kint(227, (unsigned int)int227, 0x08);
  install_kint(228, (unsigned int)int228, 0x08);
  install_kint(229, (unsigned int)int229, 0x08);
  install_kint(230, (unsigned int)int230, 0x08);
  install_kint(231, (unsigned int)int231, 0x08);
  install_kint(232, (unsigned int)int232, 0x08);
  install_kint(233, (unsigned int)int233, 0x08);
  install_kint(234, (unsigned int)int234, 0x08);
  install_kint(235, (unsigned int)int235, 0x08);
  install_kint(236, (unsigned int)int236, 0x08);
  install_kint(237, (unsigned int)int237, 0x08);
  install_kint(238, (unsigned int)int238, 0x08);
  install_kint(239, (unsigned int)int239, 0x08);
  install_kint(240, (unsigned int)int240, 0x08);
  install_kint(241, (unsigned int)int241, 0x08);
  install_kint(242, (unsigned int)int242, 0x08);
  install_kint(243, (unsigned int)int243, 0x08);
  install_kint(244, (unsigned int)int244, 0x08);
  install_kint(245, (unsigned int)int245, 0x08);
  install_kint(246, (unsigned int)int246, 0x08);
  install_kint(247, (unsigned int)int247, 0x08);
  install_kint(248, (unsigned int)int248, 0x08);
  install_kint(249, (unsigned int)int249, 0x08);
  install_kint(250, (unsigned int)int250, 0x08);
  install_kint(251, (unsigned int)int251, 0x08);
  install_kint(252, (unsigned int)int252, 0x08);
  install_kint(253, (unsigned int)int253, 0x08);
  install_kint(254, (unsigned int)int254, 0x08);
  install_kint(255, (unsigned int)int255, 0x08);
  lidt();
  return;
}

void int_handler(regs* r)
{
  
  void (*handler)(regs *r);
  handler = int_routines[r->int_no];

  if(r->int_no < 32)
    {

      print("\n%s", exceptions[r->int_no]);
      print("eip: %h\n", r->eip);

      if(handler)
	handler(r);

      else
	{
	  print("System Halting!!!\n");
	  kill();
	}

    }

  else if((r->int_no >= PIC_BASE) && (r->int_no < (PIC_BASE + 16)))
    {

      if(handler)
	handler(r);
      
      if(r->int_no >= 40)
	outb(0xA0, 0x20);
      
      outb(0x20, 0x20);

    }

  else
    {
      if(handler)
	handler(r);
      
      else
	{
	  print("Unhandled interrupt.\n");
	}
    }

  return;
}
