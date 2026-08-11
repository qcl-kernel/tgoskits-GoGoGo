CC ?= gcc
CFLAGS = -Wall -Wextra -O2 -I../common

target/protocol_test: protocol_test.c ../common/rt_ipc.c ../common/rt_ipc.h
	mkdir -p target
	$(CC) $(CFLAGS) -o target/protocol_test protocol_test.c ../common/rt_ipc.c

target/loopback_test: loopback_test.c ../common/rt_ipc.c ../common/rt_ipc.h
	mkdir -p target
	$(CC) $(CFLAGS) -o target/loopback_test loopback_test.c ../common/rt_ipc.c

test: target/protocol_test
	./target/protocol_test

test_loopback: target/loopback_test
	./target/loopback_test

clean:
	rm -rf target

.PHONY: test test_loopback clean
