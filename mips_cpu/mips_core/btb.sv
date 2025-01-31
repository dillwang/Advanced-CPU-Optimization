/* first iteration. Direct-Mapped BTB first
*
*/

typedef struct packed {
    logic [`ADDR_WIDTH-1:0] target;  // Branch target address
    logic valid;                     // Valid bit
} BTBEntry;

BTBEntry btb [0:15];


