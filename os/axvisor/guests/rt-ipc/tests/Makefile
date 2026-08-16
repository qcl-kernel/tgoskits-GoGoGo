CC ?= gcc
CFLAGS = -Wall -Wextra -O2 -I../common

TEST_BINS := target/protocol_test target/echo_responder_test \
	target/loopback_test target/fault_profile_test \
	target/state_machine_regression_test target/crc_concurrency_test \
	target/linux_shutdown_test target/platform_safety_test

all: $(TEST_BINS)

target/protocol_test: protocol_test.c ../common/rt_ipc.c ../common/rt_ipc.h
	mkdir -p target
	$(CC) $(CFLAGS) -o target/protocol_test protocol_test.c ../common/rt_ipc.c

target/loopback_test: loopback_test.c ../common/rt_ipc.c ../common/rt_ipc.h
	mkdir -p target
	$(CC) $(CFLAGS) -o target/loopback_test loopback_test.c ../common/rt_ipc.c

target/echo_responder_test: echo_responder_test.c ../common/rt_ipc.c ../common/rt_ipc.h \
		../rtthread/rtipc_echo_responder.c ../rtthread/rtipc_echo_responder.h \
		../rtthread/rtipc_server_status.c ../rtthread/rtipc_server_status.h
	mkdir -p target
	$(CC) $(CFLAGS) -o target/echo_responder_test echo_responder_test.c \
		../common/rt_ipc.c ../rtthread/rtipc_echo_responder.c \
		../rtthread/rtipc_server_status.c

target/fault_profile_test: fault_profile_test.c ../common/rt_ipc.c \
		../common/rt_ipc.h ../linux/rtipc_fault.c ../linux/rtipc_fault.h
	mkdir -p target
	$(CC) $(CFLAGS) -o target/fault_profile_test fault_profile_test.c \
		../common/rt_ipc.c ../linux/rtipc_fault.c

target/state_machine_regression_test: state_machine_regression_test.c \
		../common/rt_ipc.c ../common/rt_ipc.h
	mkdir -p target
	$(CC) $(CFLAGS) -o target/state_machine_regression_test \
		state_machine_regression_test.c ../common/rt_ipc.c

target/platform_safety_test: platform_safety_test.c \
		../rtthread/rtipc_peer.c ../rtthread/rtipc_peer.h \
		../rtthread/rtipc_time.c ../rtthread/rtipc_time.h
	mkdir -p target
	$(CC) $(CFLAGS) -o target/platform_safety_test platform_safety_test.c \
		../rtthread/rtipc_peer.c ../rtthread/rtipc_time.c

target/crc_concurrency_test: crc_concurrency_test.c ../common/rt_ipc.c \
		../common/rt_ipc.h
	mkdir -p target
	$(CC) $(CFLAGS) -pthread -o target/crc_concurrency_test \
		crc_concurrency_test.c ../common/rt_ipc.c

../linux/target/rtipic-client-host: ../linux/rtipc_client.c \
		../linux/rtipc_fault.c ../linux/rtipc_fault.h \
		../linux/rtipc_shutdown.c ../linux/rtipc_shutdown.h ../common/rt_ipc.c \
		../common/rt_ipc.h
	$(MAKE) -C ../linux \
		HOSTCFLAGS='-D_POSIX_C_SOURCE=200809L $(CFLAGS)' \
		target/rtipic-client-host

../linux/target/rtipic-client-clock-fail: ../linux/rtipc_client.c \
		../linux/rtipc_client_report.c ../linux/rtipc_client_report.h \
		../linux/rtipc_fault.c ../linux/rtipc_fault.h \
		../linux/rtipc_shutdown.c ../linux/rtipc_shutdown.h \
		../common/rt_ipc.c ../common/rt_ipc.h client_clock_wrap.c
	$(MAKE) -C ../linux \
		HOSTCFLAGS='-D_POSIX_C_SOURCE=200809L $(CFLAGS)' \
		target/rtipic-client-clock-fail

target/linux_shutdown_test: linux_shutdown_test.c ../common/rt_ipc.c \
		../common/rt_ipc.h ../linux/rtipc_client_report.c \
		../linux/rtipc_client_report.h ../linux/rtipc_shutdown.c \
		../linux/rtipc_shutdown.h ../linux/target/rtipic-client-host \
		../linux/target/rtipic-client-clock-fail
	mkdir -p target
	$(CC) $(CFLAGS) -Wl,--wrap=clock_gettime -o target/linux_shutdown_test \
		linux_shutdown_test.c ../common/rt_ipc.c \
		../linux/rtipc_client_report.c ../linux/rtipc_shutdown.c

test: all
	./target/protocol_test
	./target/echo_responder_test
	./target/loopback_test
	./target/fault_profile_test
	./target/state_machine_regression_test
	@if nm target/crc_concurrency_test | \
		grep -Eq ' [BbDd] (crc16_table|crc16_table_inited)$$'; then \
		echo 'FAIL: CRC implementation contains writable shared table state'; \
		exit 1; \
	fi
	./target/crc_concurrency_test
	./target/linux_shutdown_test
	./target/platform_safety_test
	bash ./test_rtthread_server_contract.sh

test_loopback: target/loopback_test
	./target/loopback_test

test_fault_profile: target/fault_profile_test
	./target/fault_profile_test

test_state_machine: target/state_machine_regression_test
	./target/state_machine_regression_test

test_crc_concurrency: target/crc_concurrency_test
	@if nm target/crc_concurrency_test | \
		grep -Eq ' [BbDd] (crc16_table|crc16_table_inited)$$'; then \
		echo 'FAIL: CRC implementation contains writable shared table state'; \
		exit 1; \
	fi
	./target/crc_concurrency_test

clean:
	rm -rf target

.PHONY: all test test_loopback test_fault_profile test_state_machine \
	test_crc_concurrency clean
