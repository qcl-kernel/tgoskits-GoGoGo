CROSS_COMPILE ?= aarch64-linux-gnu-
CC = $(CROSS_COMPILE)gcc
CFLAGS = -Wall -Wextra -O2 -static -I../common
HOSTCC ?= gcc
HOSTCFLAGS ?= -Wall -Wextra -O2 -static -I../common

CLIENT_SOURCES = rtipc_client.c rtipc_client_report.c rtipc_fault.c \
	rtipc_shutdown.c \
	../common/rt_ipc.c
CLIENT_HEADERS = rtipc_client_report.h rtipc_fault.h rtipc_shutdown.h \
	../common/rt_ipc.h

target/rtipic-client: $(CLIENT_SOURCES) $(CLIENT_HEADERS)
	mkdir -p target
	$(CC) $(CFLAGS) -o $@ $(CLIENT_SOURCES)

target/rtipic-client-host: $(CLIENT_SOURCES) $(CLIENT_HEADERS)
	mkdir -p target
	$(HOSTCC) $(HOSTCFLAGS) -o $@ $(CLIENT_SOURCES)

target/rtipic-client-clock-fail: $(CLIENT_SOURCES) $(CLIENT_HEADERS) \
		../tests/client_clock_wrap.c
	mkdir -p target
	$(HOSTCC) $(HOSTCFLAGS) -Wl,--wrap=clock_gettime -o $@ \
		$(CLIENT_SOURCES) ../tests/client_clock_wrap.c

clean:
	rm -rf target

.PHONY: clean
