cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS "$ENV{ZEPHYR_BASE}")
project(axvisor_zephyr_task123)

target_include_directories(app PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../rt-ipc/common"
  "${CMAKE_CURRENT_SOURCE_DIR}/../task3/src/common"
)
target_sources(app PRIVATE
  src/main.c
  "${CMAKE_CURRENT_SOURCE_DIR}/../rt-ipc/common/rt_ipc.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/../rt-ipc/common/rtipc_echo_responder.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/../rt-ipc/common/rtipc_peer.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/../rt-ipc/common/rtipc_time.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/../task3/src/common/controller.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/../task3/src/common/session.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/../task3/src/common/task3_protocol.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/../task3/src/common/task3_server_core.c"
)
target_compile_definitions(app PRIVATE AXVISOR_DISABLE_VIRTIO_IRQ_POLL)
