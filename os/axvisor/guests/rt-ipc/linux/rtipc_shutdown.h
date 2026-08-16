#ifndef RTIPC_SHUTDOWN_H
#define RTIPC_SHUTDOWN_H

#include "rt_ipc.h"

#include <netinet/in.h>

typedef enum {
    RTIPC_CLIENT_SHUTDOWN_OK = 0,
    RTIPC_CLIENT_SHUTDOWN_IO_ERROR = -1,
    RTIPC_CLIENT_SHUTDOWN_TIMEOUT = -2,
    RTIPC_CLIENT_SHUTDOWN_INVALID = -3,
} rtipc_client_shutdown_result_t;

rtipc_client_shutdown_result_t rtipc_client_shutdown(
    int socket_fd, const struct sockaddr_in *peer,
    rtipc_connection_t *connection);

#endif
