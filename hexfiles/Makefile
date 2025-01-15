BZ2S    := $(wildcard ./*.bz2)
TXTS    := $(wildcard ./*.txt)

.PHONY : unzip zip

unzip: $(BZ2S)
	bunzip2 -k $(BZ2S)

zip: $(TXTS)
	bzip2 $(TXTS)

clean:
	rm -f *.txt

clean_all:
	rm -f *.c *.dis *.hex *.txt *.bz2 *.h *.ld *.s