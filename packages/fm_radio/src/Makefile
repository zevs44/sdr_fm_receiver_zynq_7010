# Базовый Makefile для компиляции fm_radio

fm_radio: fm_radio.o
	$(CC) $(LDFLAGS) fm_radio.o -o fm_radio

fm_radio.o: fm_radio.c
	$(CC) $(CFLAGS) -c fm_radio.c

clean:
	rm -f *.o fm_radio