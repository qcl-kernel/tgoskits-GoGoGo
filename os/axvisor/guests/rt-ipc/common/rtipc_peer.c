#include "rtipc_peer.h"

#include <string.h>

static bool same_peer(const rtipc_peer_endpoint_t *first,
                      const rtipc_peer_endpoint_t *second)
{
    return first->address == second->address && first->port == second->port;
}

void rtipc_peer_guard_init(rtipc_peer_guard_t *guard)
{
    memset(guard, 0, sizeof(*guard));
}

bool rtipc_peer_guard_claim(rtipc_peer_guard_t *guard,
                            const rtipc_peer_endpoint_t *peer,
                            uint64_t now_ms)
{
    if (guard->claimed)
        return same_peer(&guard->owner, peer);
    if (guard->closed_valid && now_ms <= guard->closed_until_ms)
        return false;
    guard->owner = *peer;
    guard->claimed = true;
    guard->closed_valid = false;
    return true;
}

bool rtipc_peer_guard_accepts(const rtipc_peer_guard_t *guard,
                              const rtipc_peer_endpoint_t *peer)
{
    return guard->claimed && same_peer(&guard->owner, peer);
}

bool rtipc_peer_guard_retire(rtipc_peer_guard_t *guard, uint64_t session_id,
                             uint32_t fin_sequence,
                             uint64_t expires_at_ms)
{
    if (!guard->claimed)
        return false;
    guard->closed_owner = guard->owner;
    guard->closed_session_id = session_id;
    guard->closed_fin_sequence = fin_sequence;
    guard->closed_until_ms = expires_at_ms;
    guard->claimed = false;
    guard->closed_valid = true;
    return true;
}

bool rtipc_peer_guard_accepts_closed_fin(
    const rtipc_peer_guard_t *guard, const rtipc_peer_endpoint_t *peer,
    uint64_t session_id, uint32_t fin_sequence, uint64_t now_ms)
{
    return !guard->claimed && guard->closed_valid &&
           now_ms <= guard->closed_until_ms &&
           guard->closed_session_id == session_id &&
           guard->closed_fin_sequence == fin_sequence &&
           same_peer(&guard->closed_owner, peer);
}

void rtipc_peer_guard_release(rtipc_peer_guard_t *guard)
{
    memset(guard, 0, sizeof(*guard));
}
