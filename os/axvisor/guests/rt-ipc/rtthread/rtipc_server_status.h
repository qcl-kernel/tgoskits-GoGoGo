#ifndef RTIPC_SERVER_STATUS_H
#define RTIPC_SERVER_STATUS_H

typedef void (*rtipc_server_status_write_fn)(const char *text, void *context);

void rtipc_server_report_no_network(
    rtipc_server_status_write_fn write_status, void *context);

#endif
