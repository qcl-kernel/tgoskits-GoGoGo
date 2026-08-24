//! Configured VirtIO MMIO network devices connected by an internal L2 switch.

use alloc::{collections::VecDeque, format, string::String, sync::Arc};
use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};

use axdevice::*;
use axdevice_base::{
    BusAccess, BusKind, BusResponse, ControllerInputId, Device, DeviceAccess, DeviceError,
    DmaGrant, InterruptSharing, InterruptTrigger, IrqLine, Resource,
};
use axvirtio_common::{GuestMemory, NoGuestMemoryAccessor, VirtioError};
use axvirtio_net::{
    DeviceEvent, NetworkBackend, NetworkBackendError, RxOutcome, VirtioMmioNetDevice,
    VirtioNetConfig,
    switch::{EgressOutcome, SwitchPort, SwitchPortId, SwitchPortRegistration, VirtualSwitch},
};
use axvm::{ConfiguredDeviceError, ConfiguredModelRegistration, DeviceInstantiationContext};
use axvm_types::GuestPhysAddr;
use axvmconfig::VirtualDeviceRequest;

const MMIO_SLOT: &str = "mmio";
const IRQ_SLOT: &str = "irq";
const MMIO_SIZE: u64 = 0x200;
const GUEST_MMIO_BASE: u64 = 0x0a00_0000;
const GUEST_IRQ_INPUT: usize = 48;
const INGRESS_CAPACITY: usize = 64;

static NEXT_PORT_ID: AtomicUsize = AtomicUsize::new(0);
static INTERNAL_SWITCH: Mutex<Option<Arc<VirtualSwitch>>> = Mutex::new(None);

/// Catalog entry for `[[devices.virtual]] model = "virtio-net"`.
pub const REGISTRATION: ConfiguredModelRegistration = ConfiguredModelRegistration {
    model: "virtio-net",
    create: create_device_node,
};

fn create_device_node(
    id: DeviceNodeId,
    request: &VirtualDeviceRequest,
    context: &DeviceInstantiationContext,
) -> Result<DeviceNodeSpec, ConfiguredDeviceError> {
    let guest_mac = parse_mac(request, "guest_mac")?;
    let controller =
        context
            .default_wired_controller()
            .ok_or_else(|| ConfiguredDeviceError::Instantiation {
                device: request.id.clone(),
                model: request.model.clone(),
                detail: "virtio-net requires a wired interrupt controller".into(),
            })?;
    let model: Arc<dyn DeviceModel> = Arc::new(VirtioNetModel {
        guest_mac,
        controller,
        vm_id: context
            .vm_id()
            .ok_or_else(|| ConfiguredDeviceError::Instantiation {
                device: request.id.clone(),
                model: request.model.clone(),
                detail: "virtio-net requires a VM identity".into(),
            })?,
    });
    let mut node = DeviceNodeSpec::virtual_device(id, model);
    if let Some(controller_node) = context.default_wired_controller_node() {
        node = node.with_dependency(controller_node.clone());
    }
    Ok(node)
}

fn parse_mac(request: &VirtualDeviceRequest, key: &str) -> Result<[u8; 6], ConfiguredDeviceError> {
    let values = request
        .options
        .get(key)
        .and_then(toml::Value::as_array)
        .ok_or_else(|| invalid_options(request, format!("missing six-octet array `{key}`")))?;
    if values.len() != 6 {
        return Err(invalid_options(
            request,
            format!("`{key}` must contain exactly six octets"),
        ));
    }
    let mut mac = [0u8; 6];
    for (octet, value) in mac.iter_mut().zip(values) {
        *octet = value
            .as_integer()
            .and_then(|value| u8::try_from(value).ok())
            .ok_or_else(|| invalid_options(request, format!("`{key}` contains a non-u8 octet")))?;
    }
    if mac == [0; 6] || mac[0] & 1 != 0 {
        return Err(invalid_options(
            request,
            format!("`{key}` must be a nonzero unicast MAC address"),
        ));
    }
    Ok(mac)
}

fn invalid_options(request: &VirtualDeviceRequest, detail: String) -> ConfiguredDeviceError {
    ConfiguredDeviceError::InvalidOptions {
        device: request.id.clone(),
        model: request.model.clone(),
        detail,
    }
}

struct VirtioNetModel {
    guest_mac: [u8; 6],
    controller: axdevice_base::InterruptControllerId,
    vm_id: usize,
}

impl DeviceModel for VirtioNetModel {
    fn requirements(&self) -> DeviceManagerResult<DeviceRequirements> {
        DeviceRequirements::new()
            .with_mmio(
                ResourceSlot::new(MMIO_SLOT)?,
                MMIO_SIZE,
                4,
                ResourceRequest::Fixed(GUEST_MMIO_BASE),
            )?
            .with_wired_irq(
                ResourceSlot::new(IRQ_SLOT)?,
                self.controller,
                InterruptTrigger::EdgeTriggered,
                InterruptSharing::Exclusive,
                ResourceRequest::Fixed(ControllerInputId::new(GUEST_IRQ_INPUT)),
            )
    }

    fn firmware(&self) -> DeviceFirmwareSpec {
        DeviceFirmwareSpec::new("virtio_mmio")
            .with_compatible("virtio,mmio")
            .with_register(ResourceSlot::new(MMIO_SLOT).expect("static slot is valid"))
            .with_interrupt(ResourceSlot::new(IRQ_SLOT).expect("static slot is valid"))
    }

    fn build(&self, context: &mut DeviceBuildContext<'_>) -> DeviceManagerResult<DeviceBundle> {
        let (base, size) = context.mmio(MMIO_SLOT)?;
        let irq = context.irq(IRQ_SLOT)?;
        let irq_id = irq.input().value() as u32;
        let switch = internal_switch();
        let port_id = SwitchPortId::new(NEXT_PORT_ID.fetch_add(1, Ordering::Relaxed), 0, 0);
        let endpoint = PortEndpoint::new(
            port_id,
            self.guest_mac,
            switch.clone(),
            Arc::new(AxvmWakeTarget { vm_id: self.vm_id }),
        );
        let registration = switch.register_owned(endpoint.clone()).map_err(|error| {
            DeviceManagerError::InvalidConfig {
                operation: "register virtio-net switch port",
                detail: format!("{error:?}"),
            }
        })?;
        endpoint.activate();

        let backend = SwitchBackend {
            endpoint: endpoint.clone(),
            switch,
        };
        let model = Arc::new(
            VirtioMmioNetDevice::new_with_vendor_id(
                GuestPhysAddr::from(base as usize),
                size as usize,
                backend,
                VirtioNetConfig::new(self.guest_mac),
                NoGuestMemoryAccessor,
                // RT-Thread's BSP virtio probe (drv_virtio.c) requires the
                // spec-standard 0x1AF4 vendor ID; Linux guests ignore it.
                0x1AF4,
            )
            .map_err(|error| DeviceManagerError::InvalidConfig {
                operation: "construct virtio-net device",
                detail: format!("{error:?}"),
            })?,
        );
        let grant = DmaGrant::new();
        let device = Arc::new(VirtioNetRuntimeDevice {
            model,
            irq,
            grant: grant.clone(),
            endpoint,
            _registration: registration,
            resources: alloc::vec![
                Resource::MmioRange { base, size },
                Resource::IrqLine {
                    line: irq_id,
                    trigger: InterruptTrigger::EdgeTriggered,
                },
            ]
            .into_boxed_slice(),
        });
        let mut bundle = DeviceBundle::new();
        bundle.add_dma_pollable_device(device.clone(), device, grant);
        Ok(bundle)
    }
}

fn internal_switch() -> Arc<VirtualSwitch> {
    let mut slot = INTERNAL_SWITCH
        .lock()
        .expect("virtio-net switch mutex poisoned");
    slot.get_or_insert_with(VirtualSwitch::new).clone()
}

#[derive(Clone)]
struct SwitchBackend {
    endpoint: Arc<PortEndpoint>,
    switch: Arc<VirtualSwitch>,
}

impl NetworkBackend for SwitchBackend {
    fn transmit(&self, frame: &[u8]) -> Result<(), NetworkBackendError> {
        let outcome = self.switch.switch_from_port(self.endpoint.id(), frame);
        match outcome {
            EgressOutcome::Forwarded { .. } => {}
            EgressOutcome::Dropped(reason) => {
                log::warn!(
                    "virtio-net TX[{}] {} bytes dropped: {:?}",
                    self.endpoint.id().vm_id,
                    frame.len(),
                    reason
                );
            }
        }
        Ok(())
    }

    fn rx_queue_notified(&self) {
        self.endpoint.retry_deferred_ingress();
    }
}

struct IngressState {
    frames: VecDeque<alloc::vec::Vec<u8>>,
    // DMA RX work is event-driven. A switch ingress notification or an
    // effective guest RX kick grants one poll pass; routine vCPU iterations
    // must not touch the guest queue without that qualification.
    poll_pending: bool,
    // A retained front frame is either waiting for a guest kick
    // (`deferred_retry`), eligible for one delivery attempt, or in flight.
    // A kick observed in flight is consumed by that attempt's completion.
    deferred_retry: bool,
    rx_attempt_in_flight: bool,
    retry_kick_pending: bool,
}

struct PortEndpoint {
    id: SwitchPortId,
    mac: [u8; 6],
    ingress: Mutex<IngressState>,
    active: AtomicBool,
    wake_target: Arc<dyn WakeTarget>,
    _switch: Arc<VirtualSwitch>,
}

trait WakeTarget: Send + Sync {
    fn notify(&self);
}

struct AxvmWakeTarget {
    vm_id: usize,
}

impl WakeTarget for AxvmWakeTarget {
    fn notify(&self) {
        // Wake only; vCPU0 polls DMA devices at the top of its next run-loop
        // iteration. Polling synchronously from the sender's device access
        // would let two VM device runtimes re-enter each other.
        if let Err(error) = axvm::notify_vm_vcpu(self.vm_id, 0) {
            warn!(
                "failed to notify VM[{}] for virtio-net RX: {error:#}",
                self.vm_id
            );
        }
    }
}

impl PortEndpoint {
    fn new(
        id: SwitchPortId,
        mac: [u8; 6],
        switch: Arc<VirtualSwitch>,
        wake_target: Arc<dyn WakeTarget>,
    ) -> Arc<Self> {
        Arc::new(Self {
            id,
            mac,
            ingress: Mutex::new(IngressState {
                frames: VecDeque::new(),
                poll_pending: false,
                deferred_retry: false,
                rx_attempt_in_flight: false,
                retry_kick_pending: false,
            }),
            active: AtomicBool::new(false),
            wake_target,
            _switch: switch,
        })
    }

    fn activate(&self) {
        self.active.store(true, Ordering::Release);
    }

    fn pop_ingress(&self) -> Option<alloc::vec::Vec<u8>> {
        let mut ingress = self.lock_ingress();
        if ingress.deferred_retry {
            return None;
        }
        let frame = ingress.frames.pop_front();
        if frame.is_some() {
            ingress.deferred_retry = false;
            ingress.rx_attempt_in_flight = true;
        }
        frame
    }

    fn take_poll_qualification(&self) -> bool {
        core::mem::take(&mut self.lock_ingress().poll_pending)
    }

    fn requeue_deferred_ingress(&self, frame: alloc::vec::Vec<u8>) {
        let should_wake = {
            let mut ingress = self.lock_ingress();
            ingress.frames.push_front(frame);
            ingress.rx_attempt_in_flight = false;
            let should_wake = core::mem::take(&mut ingress.retry_kick_pending);
            ingress.deferred_retry = !should_wake;
            if should_wake {
                ingress.poll_pending = true;
            }
            should_wake
        };
        if should_wake {
            self.wake_target.notify();
        }
    }

    fn finish_ingress_attempt(&self) {
        let mut ingress = self.lock_ingress();
        ingress.rx_attempt_in_flight = false;
        ingress.retry_kick_pending = false;
    }

    fn retry_deferred_ingress(&self) {
        let should_wake = {
            let mut ingress = self.lock_ingress();
            let should_wake = ingress.deferred_retry && !ingress.frames.is_empty();
            if should_wake {
                ingress.deferred_retry = false;
                ingress.poll_pending = true;
            } else if ingress.rx_attempt_in_flight {
                ingress.retry_kick_pending = true;
            }
            should_wake
        };
        if should_wake {
            self.wake_target.notify();
        }
    }

    fn lock_ingress(&self) -> MutexGuard<'_, IngressState> {
        self.ingress
            .lock()
            .expect("virtio-net ingress mutex poisoned")
    }
}

impl SwitchPort for PortEndpoint {
    fn id(&self) -> SwitchPortId {
        self.id
    }

    fn guest_mac(&self) -> [u8; 6] {
        self.mac
    }

    fn is_active(&self) -> bool {
        self.active.load(Ordering::Acquire)
    }

    fn deliver_ingress(&self, frame: &[u8]) -> bool {
        let mut ingress = self.lock_ingress();
        if !self.is_active() || ingress.frames.len() >= INGRESS_CAPACITY {
            return false;
        }
        ingress.frames.push_back(frame.into());
        true
    }

    fn notify_ingress(&self) {
        self.lock_ingress().poll_pending = true;
        self.wake_target.notify();
    }
}

struct ScopedDeviceMemory<'a> {
    access: &'a mut dyn DeviceAccess,
    grant: &'a DmaGrant,
}

impl GuestMemory for ScopedDeviceMemory<'_> {
    fn read(&mut self, guest_addr: GuestPhysAddr, data: &mut [u8]) -> Result<(), VirtioError> {
        self.access
            .read_guest_memory(self.grant, guest_addr, data)
            .map_err(|_| VirtioError::InvalidAddress)
    }

    fn write(&mut self, guest_addr: GuestPhysAddr, data: &[u8]) -> Result<(), VirtioError> {
        self.access
            .write_guest_memory(self.grant, guest_addr, data)
            .map_err(|_| VirtioError::InvalidAddress)
    }
}

struct VirtioNetRuntimeDevice {
    model: Arc<VirtioMmioNetDevice<SwitchBackend, NoGuestMemoryAccessor>>,
    irq: IrqLine,
    grant: DmaGrant,
    endpoint: Arc<PortEndpoint>,
    _registration: SwitchPortRegistration,
    resources: alloc::boxed::Box<[Resource]>,
}

impl Device for VirtioNetRuntimeDevice {
    fn name(&self) -> &str {
        "virtio-net"
    }

    fn resources(&self) -> &[Resource] {
        &self.resources
    }

    fn access(
        &self,
        access: &BusAccess,
        context: &mut dyn DeviceAccess,
    ) -> Result<BusResponse, DeviceError> {
        if access.kind != BusKind::Mmio {
            return Err(DeviceError::OutOfRange { addr: access.addr });
        }
        let address = GuestPhysAddr::from(access.addr as usize);
        if access.is_read {
            return self
                .model
                .mmio_read(address, access.width)
                .map(|value| BusResponse::Read {
                    value: value as u64,
                })
                .map_err(map_virtio_error);
        }
        let mut memory = ScopedDeviceMemory {
            access: context,
            grant: &self.grant,
        };
        let event = self
            .model
            .mmio_write_with_memory(address, access.width, access.data as usize, &mut memory)
            .map_err(map_virtio_error)?;
        self.pulse_if_pending(event)?;
        Ok(BusResponse::Write)
    }
}

impl DmaPollableDeviceOps for VirtioNetRuntimeDevice {
    fn poll_dma(
        &self,
        _now_ns: u64,
        access: &mut dyn DeviceAccess,
        grant: &DmaGrant,
    ) -> DeviceManagerResult {
        if !self.endpoint.take_poll_qualification() {
            return Ok(());
        }
        let mut memory = ScopedDeviceMemory { access, grant };
        while let Some(frame) = self.endpoint.pop_ingress() {
            match self.model.receive_frame_with_memory(&frame, &mut memory) {
                Ok(RxOutcome::Delivered { notify, .. }) => {
                    self.endpoint.finish_ingress_attempt();
                    if notify {
                        self.irq
                            .pulse()
                            .map_err(|error| DeviceManagerError::InvalidState {
                                operation: "pulse virtio-net RX interrupt",
                                detail: format!("{error}"),
                            })?;
                    }
                }
                Ok(RxOutcome::NoGuestBuffer) => {
                    self.endpoint.requeue_deferred_ingress(frame);
                    break;
                }
                Err(axvirtio_net::NetError::NotReady) => {
                    // Driver/queue readiness is transient during guest boot
                    // and reset. Retain the frame until the guest kicks RX;
                    // treating it as a permanent error loses the first
                    // network request after a virtio reset.
                    self.endpoint.requeue_deferred_ingress(frame);
                    break;
                }
                Err(error) => {
                    self.endpoint.finish_ingress_attempt();
                    warn!("virtio-net drops an ingress frame: {error:?}");
                }
            }
        }
        Ok(())
    }
}

impl VirtioNetRuntimeDevice {
    fn pulse_if_pending(&self, event: DeviceEvent) -> Result<(), DeviceError> {
        if event == DeviceEvent::InterruptPending {
            self.irq.pulse().map_err(|error| DeviceError::Backend {
                operation: "pulse virtio-net interrupt",
                detail: format!("{error}"),
            })?;
        }
        Ok(())
    }
}

fn map_virtio_error(error: VirtioError) -> DeviceError {
    DeviceError::InvalidInput {
        operation: "access virtio-net MMIO transport",
        detail: format!("{error:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axdevice_base::{
        ControllerInputId, DeviceId, InterruptControllerId, IrqResult, WiredIrqInput, WiredIrqSink,
    };
    use axvirtio_common::constants as vc;
    use axvm_types::AccessWidth;

    const TEST_BASE_IPA: usize = 0x0a00_0000;
    const TEST_REGION_LEN: usize = 0x200;
    const TEST_RX_DESC: usize = 0x1000;
    const TEST_RX_AVAIL: usize = 0x2000;
    const TEST_RX_USED: usize = 0x3000;
    const TEST_RX_BUFFER: usize = 0x4000;

    struct CountingWakeTarget {
        notifications: AtomicUsize,
    }

    impl WakeTarget for CountingWakeTarget {
        fn notify(&self) {
            self.notifications.fetch_add(1, Ordering::Relaxed);
        }
    }

    struct CountingIrqSink {
        pulses: AtomicUsize,
    }

    impl WiredIrqSink for CountingIrqSink {
        fn set_level(&self, _input: ControllerInputId, _asserted: bool) -> IrqResult {
            Ok(())
        }

        fn pulse(&self, _input: ControllerInputId) -> IrqResult {
            self.pulses.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
    }

    struct TestDeviceAccess {
        bytes: alloc::vec::Vec<u8>,
    }

    impl TestDeviceAccess {
        fn new(size: usize) -> Self {
            Self {
                bytes: alloc::vec![0; size],
            }
        }

        fn put(&mut self, addr: usize, data: &[u8]) {
            self.bytes[addr..addr + data.len()].copy_from_slice(data);
        }

        fn read_u16(&self, addr: usize) -> u16 {
            u16::from_le_bytes(self.bytes[addr..addr + 2].try_into().unwrap())
        }
    }

    impl DeviceAccess for TestDeviceAccess {
        fn device_id(&self) -> DeviceId {
            DeviceId::new(0)
        }

        fn read_guest_memory(
            &mut self,
            _grant: &DmaGrant,
            addr: GuestPhysAddr,
            data: &mut [u8],
        ) -> Result<(), DeviceError> {
            let start = addr.as_usize();
            let end = start
                .checked_add(data.len())
                .filter(|end| *end <= self.bytes.len())
                .ok_or(DeviceError::OutOfRange { addr: start as u64 })?;
            data.copy_from_slice(&self.bytes[start..end]);
            Ok(())
        }

        fn write_guest_memory(
            &mut self,
            _grant: &DmaGrant,
            addr: GuestPhysAddr,
            data: &[u8],
        ) -> Result<(), DeviceError> {
            let start = addr.as_usize();
            let end = start
                .checked_add(data.len())
                .filter(|end| *end <= self.bytes.len())
                .ok_or(DeviceError::OutOfRange { addr: start as u64 })?;
            self.bytes[start..end].copy_from_slice(data);
            Ok(())
        }
    }

    fn runtime_mmio_write(
        device: &VirtioNetRuntimeDevice,
        memory: &mut TestDeviceAccess,
        register: usize,
        value: u32,
    ) {
        let response = device
            .access(
                &BusAccess {
                    kind: BusKind::Mmio,
                    is_read: false,
                    addr: (TEST_BASE_IPA + register) as u64,
                    width: AccessWidth::Dword,
                    data: value as u64,
                },
                memory,
            )
            .unwrap();
        assert!(matches!(response, BusResponse::Write));
    }

    fn configure_empty_rx_queue(device: &VirtioNetRuntimeDevice, memory: &mut TestDeviceAccess) {
        let features = axvirtio_net::AXVIRTIO_NET_FEATURES;
        runtime_mmio_write(device, memory, vc::VIRTIO_MMIO_DRIVER_FEATURES_SEL, 0);
        runtime_mmio_write(
            device,
            memory,
            vc::VIRTIO_MMIO_DRIVER_FEATURES,
            features as u32,
        );
        runtime_mmio_write(device, memory, vc::VIRTIO_MMIO_DRIVER_FEATURES_SEL, 1);
        runtime_mmio_write(
            device,
            memory,
            vc::VIRTIO_MMIO_DRIVER_FEATURES,
            (features >> 32) as u32,
        );
        runtime_mmio_write(
            device,
            memory,
            vc::VIRTIO_MMIO_STATUS,
            vc::VIRTIO_STATUS_ACKNOWLEDGE
                | vc::VIRTIO_STATUS_DRIVER
                | vc::VIRTIO_STATUS_FEATURES_OK,
        );
        runtime_mmio_write(device, memory, vc::VIRTIO_MMIO_QUEUE_SEL, 0);
        runtime_mmio_write(device, memory, vc::VIRTIO_MMIO_QUEUE_NUM, 4);
        runtime_mmio_write(
            device,
            memory,
            vc::VIRTIO_MMIO_QUEUE_DESC_LOW,
            TEST_RX_DESC as u32,
        );
        runtime_mmio_write(
            device,
            memory,
            vc::VIRTIO_MMIO_QUEUE_AVAIL_LOW,
            TEST_RX_AVAIL as u32,
        );
        runtime_mmio_write(
            device,
            memory,
            vc::VIRTIO_MMIO_QUEUE_USED_LOW,
            TEST_RX_USED as u32,
        );
        runtime_mmio_write(device, memory, vc::VIRTIO_MMIO_QUEUE_READY, 1);
        runtime_mmio_write(
            device,
            memory,
            vc::VIRTIO_MMIO_STATUS,
            vc::VIRTIO_STATUS_ACKNOWLEDGE
                | vc::VIRTIO_STATUS_DRIVER
                | vc::VIRTIO_STATUS_FEATURES_OK
                | vc::VIRTIO_STATUS_DRIVER_OK,
        );
    }

    fn install_rx_descriptor(memory: &mut TestDeviceAccess) {
        let mut descriptor = [0u8; 16];
        descriptor[0..8].copy_from_slice(&(TEST_RX_BUFFER as u64).to_le_bytes());
        descriptor[8..12].copy_from_slice(&128u32.to_le_bytes());
        descriptor[12..14].copy_from_slice(&vc::VIRTQ_DESC_F_WRITE.to_le_bytes());
        memory.put(TEST_RX_DESC, &descriptor);
        memory.put(TEST_RX_AVAIL + 2, &1u16.to_le_bytes());
        memory.put(TEST_RX_AVAIL + 4, &0u16.to_le_bytes());
    }

    #[cfg_attr(axtest, axtest::axtest)]
    #[cfg_attr(not(axtest), test)]
    fn runtime_poll_dma_requires_ingress_notification() {
        let switch = VirtualSwitch::new();
        let wake_target = Arc::new(CountingWakeTarget {
            notifications: AtomicUsize::new(0),
        });
        let endpoint = PortEndpoint::new(
            SwitchPortId::new(1, 0, 0),
            [0x02, 0, 0, 0, 0, 1],
            switch.clone(),
            wake_target.clone(),
        );
        let registration = switch.register_owned(endpoint.clone()).unwrap();
        endpoint.activate();
        let backend = SwitchBackend {
            endpoint: endpoint.clone(),
            switch,
        };
        let model = Arc::new(
            VirtioMmioNetDevice::new(
                GuestPhysAddr::from(TEST_BASE_IPA),
                TEST_REGION_LEN,
                backend,
                VirtioNetConfig::new([0x02, 0, 0, 0, 0, 1]),
                NoGuestMemoryAccessor,
            )
            .unwrap(),
        );
        let irq_sink = Arc::new(CountingIrqSink {
            pulses: AtomicUsize::new(0),
        });
        let irq = WiredIrqInput::new(
            InterruptControllerId::new(0),
            ControllerInputId::new(48),
            InterruptTrigger::EdgeTriggered,
            irq_sink.clone(),
        )
        .connect()
        .unwrap();
        let grant = DmaGrant::new();
        let device = VirtioNetRuntimeDevice {
            model,
            irq,
            grant: grant.clone(),
            endpoint: endpoint.clone(),
            _registration: registration,
            resources: alloc::vec![].into_boxed_slice(),
        };
        let mut memory = TestDeviceAccess::new(0x8000);
        configure_empty_rx_queue(&device, &mut memory);
        install_rx_descriptor(&mut memory);
        assert!(endpoint.deliver_ingress(&[0x5a; 64]));

        for now_ns in 0..3 {
            device.poll_dma(now_ns, &mut memory, &grant).unwrap();
        }

        assert_eq!(memory.read_u16(TEST_RX_USED + 2), 0);
        assert_eq!(irq_sink.pulses.load(Ordering::Relaxed), 0);
        {
            let ingress = endpoint.lock_ingress();
            assert_eq!(ingress.frames.len(), 1);
            assert!(!ingress.rx_attempt_in_flight);
        }

        endpoint.notify_ingress();
        assert_eq!(wake_target.notifications.load(Ordering::Relaxed), 1);
        device.poll_dma(3, &mut memory, &grant).unwrap();

        assert_eq!(memory.read_u16(TEST_RX_USED + 2), 1);
        assert_eq!(irq_sink.pulses.load(Ordering::Relaxed), 1);
        assert_eq!(
            &memory.bytes[TEST_RX_BUFFER + axvirtio_net::VIRTIO_NET_HDR_MODERN_SIZE
                ..TEST_RX_BUFFER + axvirtio_net::VIRTIO_NET_HDR_MODERN_SIZE + 64],
            &[0x5a; 64]
        );
    }

    #[cfg_attr(axtest, axtest::axtest)]
    #[cfg_attr(not(axtest), test)]
    fn runtime_no_buffer_waits_for_mmio_rx_kick_before_delivery() {
        let switch = VirtualSwitch::new();
        let wake_target = Arc::new(CountingWakeTarget {
            notifications: AtomicUsize::new(0),
        });
        let endpoint = PortEndpoint::new(
            SwitchPortId::new(1, 0, 0),
            [0x02, 0, 0, 0, 0, 1],
            switch.clone(),
            wake_target.clone(),
        );
        let registration = switch.register_owned(endpoint.clone()).unwrap();
        endpoint.activate();
        let backend = SwitchBackend {
            endpoint: endpoint.clone(),
            switch,
        };
        let model = Arc::new(
            VirtioMmioNetDevice::new(
                GuestPhysAddr::from(TEST_BASE_IPA),
                TEST_REGION_LEN,
                backend,
                VirtioNetConfig::new([0x02, 0, 0, 0, 0, 1]),
                NoGuestMemoryAccessor,
            )
            .unwrap(),
        );
        let irq_sink = Arc::new(CountingIrqSink {
            pulses: AtomicUsize::new(0),
        });
        let irq = WiredIrqInput::new(
            InterruptControllerId::new(0),
            ControllerInputId::new(48),
            InterruptTrigger::EdgeTriggered,
            irq_sink.clone(),
        )
        .connect()
        .unwrap();
        let grant = DmaGrant::new();
        let device = VirtioNetRuntimeDevice {
            model,
            irq,
            grant: grant.clone(),
            endpoint: endpoint.clone(),
            _registration: registration,
            resources: alloc::vec![].into_boxed_slice(),
        };
        let mut memory = TestDeviceAccess::new(0x8000);
        configure_empty_rx_queue(&device, &mut memory);
        assert!(endpoint.deliver_ingress(&[0x5a; 64]));
        endpoint.notify_ingress();

        device.poll_dma(0, &mut memory, &grant).unwrap();
        assert_eq!(memory.read_u16(TEST_RX_USED + 2), 0);
        install_rx_descriptor(&mut memory);
        device.poll_dma(0, &mut memory, &grant).unwrap();
        assert_eq!(memory.read_u16(TEST_RX_USED + 2), 0);

        runtime_mmio_write(&device, &mut memory, vc::VIRTIO_MMIO_QUEUE_NOTIFY, 0);
        assert_eq!(wake_target.notifications.load(Ordering::Relaxed), 2);
        device.poll_dma(0, &mut memory, &grant).unwrap();

        assert_eq!(memory.read_u16(TEST_RX_USED + 2), 1);
        assert_eq!(irq_sink.pulses.load(Ordering::Relaxed), 1);
        assert_eq!(
            &memory.bytes[TEST_RX_BUFFER + axvirtio_net::VIRTIO_NET_HDR_MODERN_SIZE
                ..TEST_RX_BUFFER + axvirtio_net::VIRTIO_NET_HDR_MODERN_SIZE + 64],
            &[0x5a; 64]
        );
    }

    #[test]
    fn virtio_net_declares_the_rtthread_guest_abi_resources() {
        let model = VirtioNetModel {
            guest_mac: [0x52, 0x54, 0, 0x77, 0, 3],
            controller: InterruptControllerId::new(0),
            vm_id: 3,
        };
        let requirements = model.requirements().unwrap();

        assert!(requirements.entries().iter().any(|requirement| {
            matches!(
                requirement,
                DeviceRequirement::Mmio {
                    slot,
                    size: 0x200,
                    alignment: 4,
                    request: ResourceRequest::Fixed(0x0a00_0000),
                } if slot.as_str() == MMIO_SLOT
            )
        }));
        assert!(requirements.entries().iter().any(|requirement| {
            matches!(
                requirement,
                DeviceRequirement::WiredIrq {
                    slot,
                    controller,
                    trigger: InterruptTrigger::EdgeTriggered,
                    sharing: InterruptSharing::Exclusive,
                    request: ResourceRequest::Fixed(input),
                } if slot.as_str() == IRQ_SLOT
                    && *controller == InterruptControllerId::new(0)
                    && input.value() == 48
            )
        }));
    }

    #[cfg_attr(axtest, axtest::axtest)]
    #[cfg_attr(not(axtest), test)]
    fn rx_queue_kick_consumes_one_deferred_retry_qualification() {
        let switch = VirtualSwitch::new();
        let wake_target = Arc::new(CountingWakeTarget {
            notifications: AtomicUsize::new(0),
        });
        let endpoint = PortEndpoint::new(
            SwitchPortId::new(1, 0, 0),
            [0x02, 0, 0, 0, 0, 1],
            switch.clone(),
            wake_target.clone(),
        );
        endpoint.activate();
        assert!(endpoint.deliver_ingress(&[0; 64]));
        let frame = endpoint.pop_ingress().expect("queued ingress frame");
        endpoint.requeue_deferred_ingress(frame);
        let backend = SwitchBackend { endpoint, switch };

        backend.rx_queue_notified();
        backend.rx_queue_notified();

        assert_eq!(wake_target.notifications.load(Ordering::Relaxed), 1);
    }

    #[cfg_attr(axtest, axtest::axtest)]
    #[cfg_attr(not(axtest), test)]
    fn rx_queue_kick_does_not_wake_without_deferred_retry() {
        let switch = VirtualSwitch::new();
        let wake_target = Arc::new(CountingWakeTarget {
            notifications: AtomicUsize::new(0),
        });
        let endpoint = PortEndpoint::new(
            SwitchPortId::new(1, 0, 0),
            [0x02, 0, 0, 0, 0, 1],
            switch.clone(),
            wake_target.clone(),
        );
        endpoint.activate();
        let backend = SwitchBackend { endpoint, switch };

        backend.rx_queue_notified();

        assert_eq!(wake_target.notifications.load(Ordering::Relaxed), 0);
    }

    #[cfg_attr(axtest, axtest::axtest)]
    #[cfg_attr(not(axtest), test)]
    fn rx_queue_kick_during_delivery_attempt_wakes_after_no_buffer_requeue() {
        let switch = VirtualSwitch::new();
        let wake_target = Arc::new(CountingWakeTarget {
            notifications: AtomicUsize::new(0),
        });
        let endpoint = PortEndpoint::new(
            SwitchPortId::new(1, 0, 0),
            [0x02, 0, 0, 0, 0, 1],
            switch.clone(),
            wake_target.clone(),
        );
        endpoint.activate();
        assert!(endpoint.deliver_ingress(&[0; 64]));
        let frame = endpoint.pop_ingress().expect("queued ingress frame");
        let backend = SwitchBackend {
            endpoint: endpoint.clone(),
            switch,
        };

        backend.rx_queue_notified();
        endpoint.requeue_deferred_ingress(frame);

        assert_eq!(wake_target.notifications.load(Ordering::Relaxed), 1);
    }

    #[cfg_attr(axtest, axtest::axtest)]
    #[cfg_attr(not(axtest), test)]
    fn deferred_frame_cannot_be_polled_again_before_rx_queue_kick() {
        let switch = VirtualSwitch::new();
        let wake_target = Arc::new(CountingWakeTarget {
            notifications: AtomicUsize::new(0),
        });
        let endpoint = PortEndpoint::new(
            SwitchPortId::new(1, 0, 0),
            [0x02, 0, 0, 0, 0, 1],
            switch.clone(),
            wake_target,
        );
        endpoint.activate();
        assert!(endpoint.deliver_ingress(&[0; 64]));
        let frame = endpoint.pop_ingress().expect("queued ingress frame");
        endpoint.requeue_deferred_ingress(frame);
        let backend = SwitchBackend {
            endpoint: endpoint.clone(),
            switch,
        };

        assert!(endpoint.pop_ingress().is_none());
        backend.rx_queue_notified();
        assert!(endpoint.pop_ingress().is_some());
    }

    #[cfg_attr(axtest, axtest::axtest)]
    #[cfg_attr(not(axtest), test)]
    fn completed_attempt_discards_in_flight_rx_queue_kick() {
        let switch = VirtualSwitch::new();
        let wake_target = Arc::new(CountingWakeTarget {
            notifications: AtomicUsize::new(0),
        });
        let endpoint = PortEndpoint::new(
            SwitchPortId::new(1, 0, 0),
            [0x02, 0, 0, 0, 0, 1],
            switch.clone(),
            wake_target.clone(),
        );
        endpoint.activate();
        let backend = SwitchBackend {
            endpoint: endpoint.clone(),
            switch,
        };

        assert!(endpoint.deliver_ingress(&[0; 64]));
        assert!(endpoint.pop_ingress().is_some());
        backend.rx_queue_notified();
        endpoint.finish_ingress_attempt();

        assert!(endpoint.deliver_ingress(&[1; 64]));
        let frame = endpoint.pop_ingress().expect("second ingress frame");
        endpoint.requeue_deferred_ingress(frame);
        assert_eq!(wake_target.notifications.load(Ordering::Relaxed), 0);
        assert!(endpoint.pop_ingress().is_none());

        backend.rx_queue_notified();
        assert_eq!(wake_target.notifications.load(Ordering::Relaxed), 1);
    }
}
