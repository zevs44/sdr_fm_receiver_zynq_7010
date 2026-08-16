# Local Makefile for compiling the source code

all: fm_monitor

fm_monitor: fm_monitor.o
	$(CC) $(LDFLAGS) fm_monitor.o -o fm_monitor

fm_monitor.o: fm_monitor.c
	$(CC) $(CFLAGS) -c fm_monitor.c

clean:
	rm -f *.o fm_monitor
