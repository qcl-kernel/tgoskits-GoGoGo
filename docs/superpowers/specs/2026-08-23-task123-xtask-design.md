# Task123 xtask Integration Design

## Goal

Expose the existing Task123 guest-comparison workflow as a first-class
cargo xtask axvisor task123 command while preserving the behavior of the
repository direct run-task123.sh entrypoint.

## Design

The Rust command owns the thin entrypoint policy that used to live in the root
shell wrapper:

- prefer RTTHREAD_IMAGE and RTTHREAD_IMAGE_META when supplied;
- otherwise select the metadata-validated persistent image under
  tmp/rt-thread-5.2.2-native-current;
- always require image metadata;
- keep the runner in the foreground with inherited terminal streams;
- default to quick mode and retain allow-qemu-timer-limit for diagnostic
  QEMU TCG stability runs.

The command then starts os/axvisor/scripts/run_task123_guest_comparison.sh.
That runner remains the lifecycle owner for QEMU, guest serial input, marker
watching, resource sampling, and cleanup. It already delegates rootfs download
and extraction to the standard cargo xtask image pull qemu-aarch64 path, so no
duplicate download implementation is introduced.

The root run-task123.sh becomes a compatibility shim that invokes
cargo xtask axvisor task123. This keeps existing documentation and muscle
memory working while making the xtask command the canonical implementation.

## Testing

Rust unit tests cover CLI parsing, path resolution, persistent RT-Thread image
selection, environment propagation, and runner argument construction. Shell
contract tests cover the compatibility wrapper. Existing Task123 lifecycle,
result-gate, and realtime-control tests remain the end-to-end regression
surface.
