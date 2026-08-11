# RT-IPC Protocol Integration Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax for tracking.

**Goal:** Integrate RT-IPC reliable UDP protocol so Linux and RT-Thread communicate over virtio-net with handshake, CRC, ACK retransmission, heartbeat, and auto-reconnect.

**Architecture:** Shared C protocol core compiled into both Linux client and RT-Thread server. Linux sends CTRL_CMD, RT-Thread echoes STATUS_REP over UDP port 9876 on the 192.168.77.0/24 virtio-net.

**Tech Stack:** C99, POSIX sockets (Linux), RT-Thread SAL/lwIP sockets, aarch64-linux-gnu-gcc, SCons, cpio

---

### Task 1: Copy Protocol Core into Guest Tree

**Files:**
- Create: os/axvisor/guests/rt-ipc/common/rt_ipc.h
- Create: os/axvisor/guests/rt-ipc/common/rt_ipc.c

- [ ] Step 1: Create directory structure
- [ ] Step 2: Copy rt_ipc.h from protocol/c/include/
- [ ] Step 3: Copy rt_ipc.c from protocol/c/src/
- [ ] Step 4: Verify files exist and are non-empty
- [ ] Step 5: Commit

---

### Task 2: Protocol Core Unit Tests (Host-Compiled)

**Files:**
- Create: os/axvisor/guests/rt-ipc/tests/protocol_test.c
- Create: os/axvisor/guests/rt-ipc/tests/Makefile

Tests: header serialize/parse round-trip, CRC16 known vectors, SYN->SYNACK->CONNECTED, cumulative ACK, reorder buffer, duplicate filtering, CRC failure discard.

- [ ] Step 1: Write failing test file
- [ ] Step 2: Write Makefile for host compilation
- [ ] Step 3: Run test to verify it fails
- [ ] Step 4: Fix until all tests pass
- [ ] Step 5: Commit

---

### Task 3: RT-Thread Server

**Files:**
- Create: os/axvisor/guests/rt-ipc/rtthread/rtipic_server.c
- Create: os/axvisor/guests/rt-ipc/rtthread/SConscript

Server: bind 0.0.0.0:9876, recvfrom 100ms timeout, on_recv + tick loop, respond STATUS_REP to CTRL_CMD, INIT_APP_EXPORT, thread prio 15 stack 64KB.

- [ ] Step 1: Write server source
- [ ] Step 2: Write SConscript
- [ ] Step 3: Commit

---

### Task 4: Linux Client

**Files:**
- Create: os/axvisor/guests/rt-ipc/linux/rtipic_client.c
- Create: os/axvisor/guests/rt-ipc/linux/Makefile

Client: SYN handshake, 1000x CTRL_CMD per payload size (64/256/1024), RTT P50/P95/P99, disconnect after 500 msgs, reconnect, FIN.

- [ ] Step 1: Write client source
- [ ] Step 2: Write Makefile (static aarch64 cross-compile)
- [ ] Step 3: Cross-compile and verify binary
- [ ] Step 4: Commit

---

### Task 5: Update apply-rtthread-patches.sh

**Files:**
- Modify: os/axvisor/patches/rtthread/apply-rtthread-patches.sh

Enable RT_USING_SAL, SAL_USING_POSIX in rtconfig.h. Install server files into BSP applications/rt-ipc-test/.

- [ ] Step 1: Add SAL/socket enablement to rtconfig.h section
- [ ] Step 2: Add server source installation
- [ ] Step 3: Verify patch script syntax
- [ ] Step 4: Commit

---

### Task 6: Update Linux initramfs

**Files:**
- Modify: os/axvisor/guests/linux-net/init-linux-1

Build rtipic-client, add to initramfs cpio as /bin/rtipic-client, update init to run it.

- [ ] Step 1: Build rtipic-client binary
- [ ] Step 2: Add to initramfs staging
- [ ] Step 3: Update init-linux-1 to run test after network config
- [ ] Step 4: Commit

---

### Task 7: QEMU Integration Test Script

**Files:**
- Create: os/axvisor/scripts/run_rtipc_test.sh

Build all, launch QEMU, wait for ALL TESTS COMPLETE, extract statistics.

- [ ] Step 1: Write the test script
- [ ] Step 2: Run the script
- [ ] Step 3: Verify output contains RT-IPC results
- [ ] Step 4: Commit

---

### Task 8: Reliability Loopback Test

**Files:**
- Create: os/axvisor/guests/rt-ipc/tests/loopback_test.c

In-memory channel with configurable loss/reorder/duplicate. 500 round-trips. Verify all delivered, retransmissions occurred.

- [ ] Step 1: Write loopback test
- [ ] Step 2: Add to test Makefile
- [ ] Step 3: Run and verify
- [ ] Step 4: Commit
