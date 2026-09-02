#include "rtipc_server_status.h"

void rtipc_server_report_no_network(
    rtipc_server_status_write_fn write_status, void *context)
{
    if (write_status != 0)
        write_status("RTIPC_FAILURE reason=no_network_device\n", context);
}
