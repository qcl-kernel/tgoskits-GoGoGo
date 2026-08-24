#include <stdint.h>
#include <stdio.h>

#include "../common/rtipc_peer.h"
#include "../common/rtipc_time.h"

static int peer_ownership_rejects_takeover(void)
{
    rtipc_peer_guard_t guard;
    const rtipc_peer_endpoint_t first = {
        .address = UINT32_C(0xc0a84d01),
        .port = UINT16_C(10001),
    };
    const rtipc_peer_endpoint_t second = {
        .address = UINT32_C(0xc0a84d02),
        .port = UINT16_C(10002),
    };

    rtipc_peer_guard_init(&guard);
    if (!rtipc_peer_guard_claim(&guard, &first, 0) ||
        !rtipc_peer_guard_accepts(&guard, &first) ||
        rtipc_peer_guard_accepts(&guard, &second) ||
        rtipc_peer_guard_claim(&guard, &second, 0)) {
        fputs("peer guard allowed session takeover\n", stderr);
        return -1;
    }

    rtipc_peer_guard_release(&guard);
    if (!rtipc_peer_guard_claim(&guard, &second, 0) ||
        !rtipc_peer_guard_accepts(&guard, &second)) {
        fputs("peer guard did not allow a new owner after release\n", stderr);
        return -1;
    }
    return 0;
}

static int tick_extension_is_monotonic_across_wrap(void)
{
    rtipc_tick_extender_t clock;

    rtipc_tick_extender_init(&clock);
    uint64_t before = rtipc_tick_extender_update(&clock,
                                                 UINT32_MAX - UINT32_C(15));
    uint64_t after = rtipc_tick_extender_update(&clock, UINT32_C(5));
    if (after <= before || after - before != UINT64_C(21)) {
        fprintf(stderr, "tick wrap before=%llu after=%llu\n",
                (unsigned long long)before, (unsigned long long)after);
        return -1;
    }
    return 0;
}

static int peer_guard_recovers_a_lost_fin_ack(void)
{
    const uint64_t session_id = UINT64_C(0x123456789abcdef0);
    const uint32_t fin_sequence = 77;
    rtipc_peer_guard_t guard;
    const rtipc_peer_endpoint_t owner = {
        .address = UINT32_C(0x0a000001),
        .port = UINT16_C(9876),
    };
    const rtipc_peer_endpoint_t foreign = {
        .address = UINT32_C(0x0a000002),
        .port = UINT16_C(9876),
    };

    rtipc_peer_guard_init(&guard);
    if (!rtipc_peer_guard_claim(&guard, &owner, 0) ||
        !rtipc_peer_guard_retire(&guard, session_id, fin_sequence, 1000) ||
        guard.claimed || rtipc_peer_guard_accepts(&guard, &owner) ||
        !rtipc_peer_guard_accepts_closed_fin(
            &guard, &owner, session_id, fin_sequence, 999) ||
        rtipc_peer_guard_accepts_closed_fin(
            &guard, &foreign, session_id, fin_sequence, 999) ||
        rtipc_peer_guard_accepts_closed_fin(
            &guard, &owner, session_id + 1, fin_sequence, 999) ||
        rtipc_peer_guard_accepts_closed_fin(
            &guard, &owner, session_id, fin_sequence + 1, 999) ||
        rtipc_peer_guard_accepts_closed_fin(
            &guard, &owner, session_id, fin_sequence, 1001)) {
        fputs("peer FIN tombstone matching failed\n", stderr);
        return -1;
    }

    if (rtipc_peer_guard_claim(&guard, &foreign, 999) ||
        !rtipc_peer_guard_accepts_closed_fin(
            &guard, &owner, session_id, fin_sequence, 999)) {
        fputs("new peer displaced a live FIN tombstone\n", stderr);
        return -1;
    }

    if (!rtipc_peer_guard_claim(&guard, &foreign, 1001) ||
        !rtipc_peer_guard_accepts(&guard, &foreign)) {
        fputs("new peer was rejected after FIN tombstone expiry\n", stderr);
        return -1;
    }
    return 0;
}

int main(void)
{
    if (peer_ownership_rejects_takeover() != 0)
        return 1;
    if (peer_guard_recovers_a_lost_fin_ack() != 0)
        return 1;
    if (tick_extension_is_monotonic_across_wrap() != 0)
        return 1;
    puts("PASS: RT-IPC platform safety");
    return 0;
}
