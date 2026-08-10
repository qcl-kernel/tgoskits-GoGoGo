//! Driver-facing network device contracts.
//!
//! This module is the boundary between ax-net and low-level NIC drivers. It
//! keeps the protocol stack independent from a concrete transport such as
//! `rd_net` by exposing small RX/TX buffer traits, IRQ readiness flags, and an
//! Ethernet driver trait consumed by higher-level device adapters.
//!
//! # Ownership Model
//!
//! Drivers own their DMA rings or transport queues. ax-net borrows one RX or TX
//! buffer at a time, fills or reads the packet bytes, and then returns control
//! to the driver through transmit/recycle calls. This avoids baking one NIC
//! descriptor model into the protocol stack.
//!
//! # Error Mapping
//!
//! `NetDeviceError` is intentionally small. Device adapters should translate
//! driver-specific failures into retry, bad-state, unsupported, or I/O classes
//! and keep policy decisions such as packet drops at the adapter/router layer.

use alloc::{boxed::Box, collections::VecDeque, string::String, sync::Arc, vec::Vec};

use ax_sync::spin::SpinNoIrq;
use irq_framework::IrqId;
pub use rd_net::TxNotify;
use rd_net::{Net, NetError, RxQueue, TxQueue};

const RX_PREFETCH_TARGET: usize = 1;
/// Minimum Ethernet frame payload length (RFC 894).
///
/// Short frames are padded to this length on the wire by the driver's
/// `transmit()` path. The L2 frame byte counts reported through
/// `/proc/net/dev` should reflect the actual on-wire length, including
/// padding.
pub(crate) const ETH_ZLEN: usize = 60;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NetDeviceError {
    /// Operation should be retried later.
    Again,
    /// Device is not in a state that can perform the operation.
    BadState,
    /// Caller supplied an invalid size or argument.
    InvalidParam,
    /// Driver or transport I/O failed.
    Io,
    /// Driver could not allocate required resources.
    NoMemory,
    /// Operation is not supported by this device.
    Unsupported,
}

/// Bitmask of network interrupt events reported by a driver.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NetIrqEvents(u32);

impl NetIrqEvents {
    pub const RX_READY: Self = Self(1 << 0);
    pub const TX_DONE: Self = Self(1 << 1);
    pub const RX_ERROR: Self = Self(1 << 2);
    pub const SPURIOUS: Self = Self(1 << 31);

    pub const fn empty() -> Self {
        Self(0)
    }

    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    pub const fn intersects(self, other: Self) -> bool {
        (self.0 & other.0) != 0
    }
}

impl core::ops::BitOr for NetIrqEvents {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

impl core::ops::BitOrAssign for NetIrqEvents {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

pub type NetDeviceResult<T = ()> = Result<T, NetDeviceError>;

/// Receive buffer returned by a low-level driver.
pub trait NetRxBuffer: Send {
    /// Returns the packet bytes received from the device.
    ///
    /// The returned slice MUST represent the Ethernet frame **excluding** the
    /// trailing 4-byte FCS (Frame Check Sequence). The caller (e.g.,
    /// [`EthernetDevice`]) uses this length directly as the L2 frame byte count
    /// for `/proc/net/dev` statistics aligned with Linux semantics.
    fn packet(&self) -> &[u8];
    /// Returns the packet length.
    fn packet_len(&self) -> usize {
        self.packet().len()
    }
}

/// Transmit buffer allocated by a low-level driver.
pub trait NetTxBuffer: Send {
    /// Returns the current packet contents.
    fn packet(&self) -> &[u8];
    /// Returns writable packet storage.
    fn packet_mut(&mut self) -> &mut [u8];
    /// Returns the packet length requested at allocation time.
    fn packet_len(&self) -> usize;
}

/// Owned IRQ endpoint consumed by the platform IRQ callback.
///
/// The endpoint is intentionally narrower than [`EthernetDriver`]: hard IRQ
/// context may acknowledge/snapshot interrupt state and publish readiness bits,
/// but RX/TX queue work remains serialized through the normal driver path.
pub trait EthernetIrqHandler: Send + 'static {
    fn handle_irq(&mut self) -> NetIrqEvents;
}

/// Independently synchronized transmit endpoint for queue-capable drivers.
///
/// Drivers may expose this optional capability when TX can progress without
/// borrowing their control and receive state. The endpoint owns its queue
/// synchronization; callers never reach through it to device control or IRQ
/// state.
pub trait EthernetTxEndpoint: Send + Sync {
    /// Fills and submits one Ethernet frame.
    ///
    /// Once backing storage has been acquired and validated, the endpoint must
    /// invoke `fill` exactly once with a slice whose length is `frame_len`.
    fn transmit_frame(&self, frame_len: usize, fill: &mut dyn FnMut(&mut [u8])) -> NetDeviceResult;

    /// Fills and submits one frame with a device-notification policy.
    ///
    /// Endpoints without deferred notification may keep the default immediate
    /// behavior.
    fn transmit_frame_with_notify(
        &self,
        frame_len: usize,
        _notify: TxNotify,
        fill: &mut dyn FnMut(&mut [u8]),
    ) -> NetDeviceResult {
        self.transmit_frame(frame_len, fill)
    }

    /// Makes all deferred transmit descriptors visible to the device.
    fn flush(&self) {}
}

/// Minimal Ethernet driver contract consumed by [`EthernetDevice`].
///
/// Drivers may own DMA rings, MMIO state, or virtual queues internally. ax-net
/// only depends on packet buffers, a transmit/receive entry point, and an IRQ
/// summary so the protocol core stays detached from platform details.
pub trait EthernetDriver: Send + Sync {
    /// Stable human-readable device name.
    fn device_name(&self) -> &str;
    /// Platform IRQ id, if the device uses the shared Ethernet IRQ path.
    fn irq_id(&self) -> Option<IrqId>;
    /// Enables device IRQ delivery.
    fn enable_irq(&mut self);
    /// Disables device IRQ delivery.
    fn disable_irq(&mut self);
    /// Returns the device MAC address.
    fn mac_address(&self) -> [u8; 6];
    /// Returns an independently synchronized transmit endpoint when available.
    ///
    /// The default keeps existing drivers on the mutable device path. Queue-
    /// capable drivers can return a shared endpoint so established flows do not
    /// contend with receive and control operations.
    fn tx_endpoint(&mut self) -> Option<Arc<dyn EthernetTxEndpoint>> {
        None
    }
    /// Allocates a TX buffer large enough for one Ethernet frame.
    fn alloc_tx_buffer(&mut self, size: usize) -> NetDeviceResult<Box<dyn NetTxBuffer>>;
    /// Reclaims completed TX buffers owned by the driver.
    fn recycle_tx_buffers(&mut self) -> NetDeviceResult;
    /// Submits one filled TX buffer.
    fn transmit(&mut self, tx_buf: &mut dyn NetTxBuffer) -> NetDeviceResult;
    /// Receives one packet, or returns [`NetDeviceError::Again`] when idle.
    fn receive(&mut self) -> NetDeviceResult<Box<dyn NetRxBuffer>>;
    /// Returns an RX buffer to the driver.
    fn recycle_rx_buffer(&mut self, rx_buf: &mut dyn NetRxBuffer) -> NetDeviceResult;
    /// Handles a device interrupt and reports wake-relevant events.
    fn handle_irq(&mut self) -> NetIrqEvents;
    /// Detaches an owned IRQ endpoint for registration into the platform IRQ
    /// callback. Drivers with a registered IRQ should return `Some`; `None` is
    /// only for devices that do not use the shared Ethernet IRQ path.
    fn take_irq_handler(&mut self) -> Option<Box<dyn EthernetIrqHandler>> {
        None
    }
}

/// List of Ethernet drivers handed to network initialization.
pub type EthernetDeviceList = Vec<Box<dyn EthernetDriver>>;

struct VecTxBuffer {
    packet: Vec<u8>,
}

impl VecTxBuffer {
    fn new(size: usize) -> Self {
        Self {
            packet: alloc::vec![0; size],
        }
    }
}

impl NetTxBuffer for VecTxBuffer {
    fn packet(&self) -> &[u8] {
        &self.packet
    }

    fn packet_mut(&mut self) -> &mut [u8] {
        &mut self.packet
    }

    fn packet_len(&self) -> usize {
        self.packet.len()
    }
}

struct VecRxBuffer {
    packet: Vec<u8>,
}

impl NetRxBuffer for VecRxBuffer {
    fn packet(&self) -> &[u8] {
        &self.packet
    }
}

struct RdNetRxState {
    rx_queue: RxQueue,
    pending_rx: VecDeque<VecRxBuffer>,
}

struct RdNetTxEndpoint {
    queue: SpinNoIrq<TxQueue>,
}

impl RdNetTxEndpoint {
    fn buf_size(&self) -> usize {
        self.queue.lock().buf_size()
    }

    fn transmit_buffer(&self, packet: &[u8]) -> NetDeviceResult {
        let frame_len = packet.len();
        self.transmit_frame(frame_len, &mut |buffer| buffer.copy_from_slice(packet))
    }

    fn reclaim_completed(&self) -> NetDeviceResult {
        self.queue
            .lock()
            .reclaim_completed()
            .map(|_| ())
            .map_err(map_net_error)
    }
}

impl EthernetTxEndpoint for RdNetTxEndpoint {
    fn transmit_frame(&self, frame_len: usize, fill: &mut dyn FnMut(&mut [u8])) -> NetDeviceResult {
        self.transmit_frame_with_notify(frame_len, TxNotify::Immediate, fill)
    }

    fn transmit_frame_with_notify(
        &self,
        frame_len: usize,
        notify: TxNotify,
        fill: &mut dyn FnMut(&mut [u8]),
    ) -> NetDeviceResult {
        let tx_len = frame_len.max(ETH_ZLEN);
        let mut queue = self.queue.lock();
        let (_ret, mut pending) = queue
            .prepare_send(tx_len, |buffer| {
                fill(&mut buffer[..frame_len]);
                buffer[frame_len..tx_len].fill(0);
            })
            .map_err(map_net_error)?;
        pending
            .try_submit_with_notify(notify)
            .map_err(map_net_error)
    }

    fn flush(&self) {
        self.queue.lock().flush();
    }
}

pub struct RdNetDriver {
    name: String,
    mac: [u8; 6],
    irq: Option<IrqId>,
    control: Net,
    irq_handler: Option<rd_net::IrqHandler>,
    tx_endpoint: Arc<RdNetTxEndpoint>,
    rx_state: SpinNoIrq<RdNetRxState>,
}

impl RdNetDriver {
    /// Wraps an `rd_net` endpoint as an Ethernet driver.
    pub fn new(name: impl Into<String>, mut net: Net, irq: Option<IrqId>) -> NetDeviceResult<Self> {
        let mac = net.mac_address();
        let tx_queue = net.create_tx_queue().map_err(map_net_error)?;
        let rx_queue = net.create_rx_queue().map_err(map_net_error)?;
        let irq_handler = irq.as_ref().and_then(|_| net.take_irq_handler());

        Ok(Self {
            name: name.into(),
            mac,
            irq,
            control: net,
            irq_handler,
            tx_endpoint: Arc::new(RdNetTxEndpoint {
                queue: SpinNoIrq::new(tx_queue),
            }),
            rx_state: SpinNoIrq::new(RdNetRxState {
                rx_queue,
                pending_rx: VecDeque::with_capacity(RX_PREFETCH_TARGET),
            }),
        })
    }

    fn prefetch_rx_packets(&self, state: &mut RdNetRxState, target: usize) -> NetDeviceResult {
        while state.pending_rx.len() < target {
            let Some(packet) = state.rx_queue.receive(|packet| VecRxBuffer {
                packet: packet.to_vec(),
            }) else {
                break;
            };
            state.pending_rx.push_back(packet);
        }
        Ok(())
    }
}

impl EthernetDriver for RdNetDriver {
    fn device_name(&self) -> &str {
        &self.name
    }

    fn irq_id(&self) -> Option<IrqId> {
        self.irq
    }

    fn enable_irq(&mut self) {
        self.control.enable_irq();
    }

    fn disable_irq(&mut self) {
        self.control.disable_irq();
    }

    fn mac_address(&self) -> [u8; 6] {
        self.mac
    }

    fn tx_endpoint(&mut self) -> Option<Arc<dyn EthernetTxEndpoint>> {
        Some(Arc::clone(&self.tx_endpoint) as Arc<dyn EthernetTxEndpoint>)
    }

    fn alloc_tx_buffer(&mut self, size: usize) -> NetDeviceResult<Box<dyn NetTxBuffer>> {
        let capacity = self.tx_endpoint.buf_size();
        if size > capacity {
            return Err(NetDeviceError::InvalidParam);
        }
        Ok(Box::new(VecTxBuffer::new(size)))
    }

    fn recycle_tx_buffers(&mut self) -> NetDeviceResult {
        self.tx_endpoint.reclaim_completed()
    }

    fn transmit(&mut self, tx_buf: &mut dyn NetTxBuffer) -> NetDeviceResult {
        self.tx_endpoint.transmit_buffer(tx_buf.packet())
    }

    fn receive(&mut self) -> NetDeviceResult<Box<dyn NetRxBuffer>> {
        let mut state = self.rx_state.lock();
        self.prefetch_rx_packets(&mut state, RX_PREFETCH_TARGET)?;
        state
            .pending_rx
            .pop_front()
            .map(|packet| Box::new(packet) as Box<dyn NetRxBuffer>)
            .ok_or(NetDeviceError::Again)
    }

    fn recycle_rx_buffer(&mut self, _rx_buf: &mut dyn NetRxBuffer) -> NetDeviceResult {
        Ok(())
    }

    fn handle_irq(&mut self) -> NetIrqEvents {
        let Some(handler) = &mut self.irq_handler else {
            return NetIrqEvents::SPURIOUS;
        };

        map_rd_net_irq_event(handler.handle_irq())
    }

    fn take_irq_handler(&mut self) -> Option<Box<dyn EthernetIrqHandler>> {
        self.irq_handler
            .take()
            .map(|handler| Box::new(RdNetIrqHandler { handler }) as Box<dyn EthernetIrqHandler>)
    }
}

struct RdNetIrqHandler {
    handler: rd_net::IrqHandler,
}

impl EthernetIrqHandler for RdNetIrqHandler {
    fn handle_irq(&mut self) -> NetIrqEvents {
        map_rd_net_irq_event(self.handler.handle_irq())
    }
}

fn map_rd_net_irq_event(event: rd_net::Event) -> NetIrqEvents {
    let mut events = NetIrqEvents::empty();
    if event.rx_queue.iter().next().is_some() {
        events |= NetIrqEvents::RX_READY;
    }
    if event.tx_queue.iter().next().is_some() {
        events |= NetIrqEvents::TX_DONE;
    }

    if events.is_empty() {
        NetIrqEvents::SPURIOUS
    } else {
        events
    }
}

fn map_net_error(err: NetError) -> NetDeviceError {
    match err {
        NetError::Retry => NetDeviceError::Again,
        NetError::NoMemory => NetDeviceError::NoMemory,
        NetError::NotSupported => NetDeviceError::Unsupported,
        NetError::LinkDown | NetError::Other(_) => NetDeviceError::Io,
    }
}
