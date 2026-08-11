CROSS_COMPILE ?= aarch64-linux-gnu-
CC = $(CROSS_COMPILE)gcc
CFLAGS = -Wall -Wextra -O2 -static -I../common

target/rtipic-client: rtipc_client.c ../common/rt_ipc.c ../common/rt_ipc.h
	mkdir -p target
	$(CC) $(CFLAGS) -o target/rtipic-client rtipc_client.c ../common/rt_ipc.c

clean:
	rm -rf target

.PHONY: clean
