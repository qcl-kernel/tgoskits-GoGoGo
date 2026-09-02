#ifndef RTIPC_PEER_H
#define RTIPC_PEER_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint32_t address;
    uint16_t port;
} rtipc_peer_endpoint_t;

typedef struct {
    rtipc_peer_endpoint_t owner;
    rtipc_peer_endpoint_t closed_owner;
    uint64_t closed_session_id;
    uint64_t closed_until_ms;
    uint32_t closed_fin_sequence;
    bool claimed;
    bool closed_valid;
} rtipc_peer_guard_t;

void rtipc_peer_guard_init(rtipc_peer_guard_t *guard);
bool rtipc_peer_guard_claim(rtipc_peer_guard_t *guard,
                            const rtipc_peer_endpoint_t *peer,
                            uint64_t now_ms);
bool rtipc_peer_guard_accepts(const rtipc_peer_guard_t *guard,
                              const rtipc_peer_endpoint_t *peer);
bool rtipc_peer_guard_retire(rtipc_peer_guard_t *guard, uint64_t session_id,
                             uint32_t fin_sequence,
                             uint64_t expires_at_ms);
bool rtipc_peer_guard_accepts_closed_fin(
    const rtipc_peer_guard_t *guard, const rtipc_peer_endpoint_t *peer,
    uint64_t session_id, uint32_t fin_sequence, uint64_t now_ms);
void rtipc_peer_guard_release(rtipc_peer_guard_t *guard);

#endif
