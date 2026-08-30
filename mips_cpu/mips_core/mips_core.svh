`define DATA_WIDTH 32
`define ADDR_WIDTH 26


// ---------------------------------------------------------------------------
// Filling a multidimensional unpacked array is the one construct where
// no single literal satisfies both Verilator and yosys-slang.
//
//   '{default: X}                yosys-slang fills every leaf, which is what
//                                the LRM's "default" is usually read to mean.
//                                but Verilator applies it one level only and
//                                rejects the rest: "CONST is not an unpacked
//                                array, but is in an unpacked array context".
//
//   '{default: '{default: X}}    Verilator: correct for two dimensions.
//                                yosys-slang: rejected, because it has already
//                                recursed and the inner pattern now targets a
//                                leaf: "invalid target type 'logic' for
//                                assignment pattern".
//
// Neither tool is wrong; they read the same sentence differently. A loop is not
// the way out -- it trips Verilator's BLKLOOPINIT above --unroll-count and
// yosys-slang's 4000-iteration --unroll-limit, and mixing blocking and
// nonblocking assignment on one variable is illegal besides. So choose the
// literal per tool, on the VERILATOR macro that Verilator predefines and
// yosys-slang does not.
//
// Do not start a comment line here with the word Verilator: `// verilator ...`
// is a metacomment and the tool rejects any directive it does not recognise.
//
// One dimension needs no macro: '{default: X} is agreed there.
`ifdef VERILATOR
	`define FILL2(v) '{default: '{default: v}}
	`define FILL3(v) '{default: '{default: '{default: v}}}
`else
	`define FILL2(v) '{default: v}
	`define FILL3(v) '{default: v}
`endif

import mips_core_pkg::*;
