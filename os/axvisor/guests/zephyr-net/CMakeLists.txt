cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(axvisor_zephyr_net)

target_sources(app PRIVATE src/main.c)

option(AXVISOR_RT_IRQ_TRACE "Trace Zephyr virtual timer IRQ boundaries" OFF)
if(AXVISOR_RT_IRQ_TRACE)
  target_compile_definitions(app PRIVATE AXVISOR_RT_IRQ_TRACE)
  zephyr_link_libraries(-Wl,--wrap=arm_gic_get_active)
endif()

# The passthrough virtio SPI is functional; avoid a periodic MMIO poll in the
# realtime workload. Define this at build time so the checked-in image uses the
# interrupt path while the polling fallback remains available for diagnostics.
target_compile_definitions(app PRIVATE AXVISOR_DISABLE_VIRTIO_IRQ_POLL)
