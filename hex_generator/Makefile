CC = mips-linux-gnu-gcc
CFLAG = -mips32 -mabi=32 -mno-abicalls -fno-stack-protector -fno-builtin -O3

LD = mips-linux-gnu-ld

OBJCOPY = mips-linux-gnu-objcopy
OBJCOPYFLAG = -j .text -j .data --gap-fill 0x00

OBJDUMP = mips-linux-gnu-objdump
OBJDUMPFLAG = -j .text -M hwr-names=numeric,cp0-names=numeric -D -z

DEPS = custom_inst.h

SRCS    := $(wildcard ./*.c)
HEX    := $(patsubst %.c, %.hex, $(SRCS))
DIS    := $(patsubst %.c, %.dis, $(SRCS))

.PHONY : all clean

all: $(HEX) $(DIS)

%.o : %.c

# .SECONDARY :
.INTERMEDIATE : start.o

start.o: start.s
	$(CC) -c $(CFLAG) start.s

%.s: %.c $(DEPS)
	$(CC) -S $(CFLAG) $<

%.o: %.s
	$(CC) -c $(CFLAG) $^

%.out: %.o start.o mips.ld
	$(LD) -o $@ -T mips.ld $< start.o
	$(OBJCOPY) $(OBJCOPYFLAG) $@ $@

%.hex: %.out
	readelf -x .text -x .data $^ | awk '$$1 ~ 0x {print $$2 RS $$3 RS $$4 RS $$5}' > $@

%.dis: %.out
	$(OBJDUMP) $(OBJDUMPFLAG) $^ > $@

clean:
	bash -i -c "rm -f *.o *.out *.dis *.gch *.hex !(start.s|!(*.s))"