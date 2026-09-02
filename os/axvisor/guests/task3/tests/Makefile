CC ?= cc
CFLAGS ?= -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic
CPPFLAGS ?= -I../src/common
BIN_DIR := ../build/tests
PROTOCOL_BIN := $(BIN_DIR)/test_task3_protocol
CONTROLLER_BIN := $(BIN_DIR)/test_controller
Y4M_BIN := $(BIN_DIR)/test_y4m
CNN_RUNNER := $(BIN_DIR)/cnn_runner
SESSION_BIN := $(BIN_DIR)/test_session
METRICS_BIN := $(BIN_DIR)/test_metrics
DEADLINE_BIN := $(BIN_DIR)/test_deadline
LINUX_BIN := $(BIN_DIR)/task3-linux-host
RTTHREAD_SERVER_BIN := $(BIN_DIR)/test_rtthread_server
SOURCE_CACHE_ROOT := $(if $(strip $(TGOS_SOURCE_CACHE)),$(TGOS_SOURCE_CACHE),../../../../../tmp/source-cache)
MODEL_DIR ?= $(SOURCE_CACHE_ROOT)/task3-model
RTIPC_DIR ?= ../../rt-ipc/common

ifeq ($(SANITIZE),1)
CFLAGS += -O1 -fsanitize=address,undefined -fno-omit-frame-pointer
LDFLAGS += -fsanitize=address,undefined
endif

.PHONY: test test_task3_protocol test_controller test_y4m test_dataset test_model cnn_runner test_session test_metrics test_deadline linux_cli test_linux_cli test_rtthread_server test_doctor test_reporting test_contracts test_docs clean

test: test_task3_protocol test_controller test_y4m test_dataset test_model test_session test_metrics test_deadline test_linux_cli test_rtthread_server test_doctor test_reporting test_contracts

test_task3_protocol: $(PROTOCOL_BIN)
	$(PROTOCOL_BIN)

$(PROTOCOL_BIN): test_task3_protocol.c ../src/common/task3_protocol.c ../src/common/task3_protocol.h
	mkdir -p $(BIN_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ test_task3_protocol.c ../src/common/task3_protocol.c $(LDFLAGS)

test_controller: $(CONTROLLER_BIN)
	$(CONTROLLER_BIN)

$(CONTROLLER_BIN): test_controller.c ../src/common/controller.c ../src/common/controller.h ../src/common/task3_protocol.h
	mkdir -p $(BIN_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ test_controller.c ../src/common/controller.c $(LDFLAGS)

test_y4m: $(Y4M_BIN)
	$(Y4M_BIN)

$(Y4M_BIN): test_y4m.c ../src/linux/y4m.c ../src/linux/y4m.h
	mkdir -p $(BIN_DIR)
	$(CC) -I../src/linux $(CFLAGS) -o $@ test_y4m.c ../src/linux/y4m.c $(LDFLAGS)

test_dataset:
	cd .. && python3 -m unittest tests.test_dataset -v

test_model:
	cd .. && python3 -m unittest tests.test_model -v

cnn_runner: $(CNN_RUNNER)

$(CNN_RUNNER): cnn_runner.c ../src/linux/cnn.c ../src/linux/cnn.h $(MODEL_DIR)/model_weights.h
	mkdir -p $(BIN_DIR)
	$(CC) -I../src/linux -I$(MODEL_DIR) $(CFLAGS) -o $@ cnn_runner.c ../src/linux/cnn.c $(LDFLAGS)

test_session: $(SESSION_BIN)
	$(SESSION_BIN)

$(SESSION_BIN): test_session.c ../src/common/session.c ../src/common/session.h ../src/common/controller.c ../src/common/controller.h ../src/common/task3_protocol.c ../src/common/task3_protocol.h $(RTIPC_DIR)/rt_ipc.c $(RTIPC_DIR)/rt_ipc.h
	mkdir -p $(BIN_DIR)
	$(CC) -I../src/common -I$(RTIPC_DIR) $(CFLAGS) -Wno-unused-parameter -o $@ test_session.c ../src/common/session.c ../src/common/controller.c ../src/common/task3_protocol.c $(RTIPC_DIR)/rt_ipc.c $(LDFLAGS)

test_metrics: $(METRICS_BIN)
	$(METRICS_BIN)

$(METRICS_BIN): test_metrics.c ../src/linux/metrics.c ../src/linux/metrics.h
	mkdir -p $(BIN_DIR)
	$(CC) -I../src/linux $(CFLAGS) -o $@ test_metrics.c ../src/linux/metrics.c $(LDFLAGS)

test_deadline: $(DEADLINE_BIN)
	$(DEADLINE_BIN)

$(DEADLINE_BIN): test_deadline.c ../src/linux/deadline.c ../src/linux/deadline.h
	mkdir -p $(BIN_DIR)
	$(CC) -I../src/linux $(CFLAGS) -o $@ test_deadline.c ../src/linux/deadline.c $(LDFLAGS)

linux_cli: $(LINUX_BIN)

$(LINUX_BIN): ../src/linux/main.c ../src/linux/rtipc_client.c ../src/linux/rtipc_client.h ../src/linux/deadline.c ../src/linux/deadline.h ../src/linux/metrics.c ../src/linux/metrics.h ../src/linux/y4m.c ../src/linux/y4m.h ../src/linux/cnn.c ../src/linux/cnn.h ../src/common/session.c ../src/common/session.h ../src/common/task3_protocol.c ../src/common/task3_protocol.h $(RTIPC_DIR)/rt_ipc.c $(RTIPC_DIR)/rt_ipc.h $(MODEL_DIR)/model_weights.h
	mkdir -p $(BIN_DIR)
	$(CC) -I../src/linux -I../src/common -I$(RTIPC_DIR) -I$(MODEL_DIR) $(CFLAGS) -Wno-unused-parameter -o $@ ../src/linux/main.c ../src/linux/rtipc_client.c ../src/linux/deadline.c ../src/linux/metrics.c ../src/linux/y4m.c ../src/linux/cnn.c ../src/common/session.c ../src/common/task3_protocol.c $(RTIPC_DIR)/rt_ipc.c $(LDFLAGS)

test_linux_cli: $(LINUX_BIN)
	sh ./test_linux_cli.sh

test_rtthread_server: $(RTTHREAD_SERVER_BIN)
	$(RTTHREAD_SERVER_BIN)

$(RTTHREAD_SERVER_BIN): test_rtthread_server.c ../src/rtthread/task3_server.c ../src/common/task3_server_core.c ../src/common/task3_server_core.h ../src/common/controller.c ../src/common/controller.h ../src/common/task3_protocol.c ../src/common/task3_protocol.h
	mkdir -p $(BIN_DIR)
	$(CC) -DTASK3_HOST_TEST=1 -Irtthread_stubs -I../src/common -I$(RTIPC_DIR) $(CFLAGS) -o $@ test_rtthread_server.c ../src/common/task3_server_core.c ../src/common/controller.c ../src/common/task3_protocol.c $(LDFLAGS)

test_doctor:
	sh ./test_doctor.sh

test_reporting:
	cd .. && python3 -m unittest tests.test_summarize tests.test_fault_summary tests.test_report -v

test_contracts:
	sh ./test_build_contracts.sh
	sh ./test_run_demo_contract.sh
	sh ./test_fault_contract.sh
	sh ./test_axvisor_contract.sh

test_docs:
	sh ./test_docs_contract.sh

clean:
	rm -f $(PROTOCOL_BIN) $(CONTROLLER_BIN) $(Y4M_BIN) $(CNN_RUNNER) $(SESSION_BIN) $(METRICS_BIN) $(DEADLINE_BIN) $(LINUX_BIN) $(RTTHREAD_SERVER_BIN)
