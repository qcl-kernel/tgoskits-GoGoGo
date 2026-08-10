use alloc::{boxed::Box, collections::VecDeque, sync::Arc};
use core::sync::atomic::{AtomicU8, Ordering as AtomicOrdering, fence};

use ax_kspin::SpinRaw as Mutex;
use dma_api::CoherentArray;
use log::{debug, info, warn};
use mbarrier::wmb;
use rdif_eth::{DmaBuffer, IRxQueue, ITxQueue, NetError, QueueConfig, TxNotify};

use crate::{
    DMA_ALIGN, EARLY_PACKET_LOG_COUNT, LINK_DOWN_DROP_LOG_INTERVAL, MAX_PACKET, QUEUE_ID0,
    QUEUE_SIZE, RX_BUF_SIZE, RX_DESC_PER_CACHE_LINE, RX_IDLE_LOG_INTERVAL,
    RX_OVERFLOW_REARM_IDLE_POLLS, RX_QUEUE_CONFIG_SIZE, RX_RECLAIM_LOG_INTERVAL,
    RX_START_THRESHOLD, TX_LINK_SAMPLE_INTERVAL, TX_RECLAIM_LOG_INTERVAL, TX_SUBMIT_LOG_INTERVAL,
    descriptor::{RxDesc, TxDesc},
    read_status,
    registers::{DEFAULT_IRQ_MASK, Regs, irq_has_rx_overflow},
    set_rx_mode,
};

pub(crate) type QueueStart = Arc<Mutex<QueueStartState>>;
pub(crate) type IrqPollControl = Arc<IrqPollState>;

/// Coordinates administrative IRQ state with temporary poll-mode masking.
///
/// Hard IRQ and task context synchronize through one atomic state word. MMIO
/// callbacks run only after the corresponding state transition, and rearm
/// checks the state again after unmasking so a racing IRQ or disable operation
/// always leaves the hardware masked.
pub(crate) struct IrqPollState {
    state: AtomicU8,
}

const IRQ_ENABLED: u8 = 1 << 0;
const IRQ_POLLING: u8 = 1 << 1;
pub(crate) const IRQ_TX_PENDING: u8 = 1 << 2;
pub(crate) const IRQ_RX_PENDING: u8 = 1 << 3;
const IRQ_MASKING: u8 = 1 << 4;
const IRQ_QUEUE_PENDING: u8 = IRQ_TX_PENDING | IRQ_RX_PENDING;

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum IrqPollPhase {
    Disabled,
    Enabled,
    Polling,
}

impl IrqPollState {
    pub(crate) const fn new() -> Self {
        Self {
            state: AtomicU8::new(0),
        }
    }

    pub(crate) fn enable(&self, unmask: impl FnOnce(), remask: impl FnOnce()) {
        if self
            .state
            .compare_exchange(
                0,
                IRQ_ENABLED,
                AtomicOrdering::AcqRel,
                AtomicOrdering::Acquire,
            )
            .is_err()
        {
            return;
        }
        unmask();
        if self.state.load(AtomicOrdering::Acquire) != IRQ_ENABLED {
            remask();
        }
    }

    pub(crate) fn disable(&self, mask: impl FnOnce()) {
        self.state.store(0, AtomicOrdering::Release);
        mask();
    }

    pub(crate) fn is_enabled(&self) -> bool {
        self.state.load(AtomicOrdering::Acquire) == IRQ_ENABLED
    }

    /// Enters poll mode from hard IRQ context.
    pub(crate) fn begin_poll(
        &self,
        queue_events: u8,
        mask: impl FnOnce(),
        unmask: impl FnOnce(),
        remask: impl FnOnce(),
    ) -> bool {
        debug_assert!(queue_events != 0 && queue_events & !IRQ_QUEUE_PENDING == 0);
        let Ok(previous) =
            self.state
                .try_update(AtomicOrdering::AcqRel, AtomicOrdering::Acquire, |state| {
                    if state & IRQ_ENABLED == 0 {
                        return None;
                    }
                    let mut next = state | IRQ_POLLING | (queue_events & IRQ_QUEUE_PENDING);
                    if state & IRQ_POLLING == 0 {
                        next |= IRQ_MASKING;
                    }
                    Some(next)
                })
        else {
            return false;
        };
        let started = previous & IRQ_POLLING == 0;
        if !started {
            return false;
        }

        mask();
        let rearm = loop {
            let state = self.state.load(AtomicOrdering::Acquire);
            if state & (IRQ_ENABLED | IRQ_POLLING | IRQ_MASKING)
                != (IRQ_ENABLED | IRQ_POLLING | IRQ_MASKING)
            {
                return true;
            }
            let mut next = state & !IRQ_MASKING;
            if next & IRQ_QUEUE_PENDING == 0 {
                next &= !IRQ_POLLING;
            }
            match self.state.compare_exchange_weak(
                state,
                next,
                AtomicOrdering::AcqRel,
                AtomicOrdering::Acquire,
            ) {
                Ok(_) => break next & IRQ_POLLING == 0,
                Err(_) => continue,
            }
        };
        if rearm {
            self.finish_rearm(unmask, remask);
        }
        true
    }

    /// Marks one queue drained and rearms IRQ delivery after all pending queues drain.
    pub(crate) fn complete_queue(
        &self,
        queue_event: u8,
        unmask: impl FnOnce(),
        remask: impl FnOnce(),
    ) -> bool {
        debug_assert!(queue_event.count_ones() == 1 && queue_event & !IRQ_QUEUE_PENDING == 0);
        let rearm = loop {
            let state = self.state.load(AtomicOrdering::Acquire);
            if state & (IRQ_ENABLED | IRQ_POLLING | queue_event)
                != (IRQ_ENABLED | IRQ_POLLING | queue_event)
            {
                return false;
            }
            let mut next = state & !queue_event;
            if next & (IRQ_QUEUE_PENDING | IRQ_MASKING) == 0 {
                next &= !IRQ_POLLING;
            }
            match self.state.compare_exchange_weak(
                state,
                next,
                AtomicOrdering::AcqRel,
                AtomicOrdering::Acquire,
            ) {
                Ok(_) => break next & IRQ_POLLING == 0,
                Err(_) => continue,
            }
        };
        if !rearm {
            return false;
        }
        self.finish_rearm(unmask, remask)
    }

    fn finish_rearm(&self, unmask: impl FnOnce(), remask: impl FnOnce()) -> bool {
        unmask();
        if self.state.load(AtomicOrdering::Acquire) != IRQ_ENABLED {
            remask();
            false
        } else {
            true
        }
    }

    #[cfg(test)]
    fn phase(&self) -> IrqPollPhase {
        let state = self.state.load(AtomicOrdering::Acquire);
        if state == 0 {
            IrqPollPhase::Disabled
        } else if state == IRQ_ENABLED {
            IrqPollPhase::Enabled
        } else if state & (IRQ_ENABLED | IRQ_POLLING) == (IRQ_ENABLED | IRQ_POLLING) {
            IrqPollPhase::Polling
        } else {
            unreachable!("invalid IRQ poll state")
        }
    }
}

#[derive(Default)]
pub(crate) struct QueueStartState {
    pub(crate) tx_base: Option<u64>,
    pub(crate) rx_base: Option<u64>,
    pub(crate) rx_ready: bool,
    pub(crate) started: bool,
}

pub(crate) struct Rtl8125TxQueue {
    pub(crate) regs: Regs,
    pub(crate) irq_poll: IrqPollControl,
    pub(crate) desc: CoherentArray<TxDesc>,
    pub(crate) dma_mask: u64,
    pub(crate) bus_addrs: [Option<u64>; QUEUE_SIZE],
    pub(crate) next_submit: usize,
    pub(crate) next_reclaim: usize,
    pub(crate) link_up: Option<bool>,
    pub(crate) link_down_drops: u64,
    pub(crate) submitted: u64,
    pub(crate) reclaimed: u64,
    pub(crate) notification: TxNotificationState,
}

#[derive(Default)]
pub(crate) struct TxNotificationState {
    pending: bool,
}

impl TxNotificationState {
    fn descriptor_submitted(&mut self, notify: TxNotify) -> bool {
        self.pending = true;
        notify == TxNotify::Immediate && self.take_pending()
    }

    fn take_pending(&mut self) -> bool {
        core::mem::take(&mut self.pending)
    }
}

impl ITxQueue for Rtl8125TxQueue {
    fn id(&self) -> usize {
        QUEUE_ID0
    }

    fn config(&self) -> QueueConfig {
        QueueConfig {
            dma_mask: self.dma_mask,
            align: DMA_ALIGN,
            buf_size: MAX_PACKET,
            ring_size: QUEUE_SIZE,
        }
    }

    fn submit(&mut self, buffer: DmaBuffer) -> core::result::Result<(), NetError> {
        self.submit_with_notify(buffer, TxNotify::Immediate)
    }

    fn submit_with_notify(
        &mut self,
        buffer: DmaBuffer,
        notify: TxNotify,
    ) -> core::result::Result<(), NetError> {
        if buffer.len > MAX_PACKET {
            return Err(NetError::NotSupported);
        }

        if let Err(err) = tx_link_state(self.observe_link_before_tx(buffer.len)) {
            self.link_down_drops = self.link_down_drops.saturating_add(1);
            return Err(err);
        }

        let idx = self.next_submit;
        let next = (idx + 1) % QUEUE_SIZE;
        if self.bus_addrs[idx].is_some() {
            return Err(NetError::Retry);
        }

        let ring_end = idx == QUEUE_SIZE - 1;
        let desc = TxDesc::new_cpu_owned(buffer.bus_addr, buffer.len, ring_end);
        self.desc.set_cpu(idx, desc);
        release_dma_descriptor();
        self.desc.set_cpu(idx, desc.release_to_hw());
        self.bus_addrs[idx] = Some(buffer.bus_addr);
        self.next_submit = next;
        self.submitted = self.submitted.saturating_add(1);
        if self.notification.descriptor_submitted(notify) {
            self.notify_device();
        }
        if self.submitted <= EARLY_PACKET_LOG_COUNT
            || self.submitted.is_multiple_of(TX_SUBMIT_LOG_INTERVAL)
        {
            info!(
                "RTL8125 tx submitted: idx={idx}, len={}, submitted={}, reclaimed={}, status={:?}",
                buffer.len,
                self.submitted,
                self.reclaimed,
                read_status(self.regs),
            );
        }
        Ok(())
    }

    fn flush(&mut self) {
        if self.notification.take_pending() {
            self.notify_device();
        }
    }

    fn reclaim(&mut self) -> Option<u64> {
        let idx = self.next_reclaim;
        if self.bus_addrs[idx].is_none() {
            self.complete_irq_poll();
            return None;
        }
        let Some(desc) = self.desc.read_cpu(idx) else {
            self.complete_irq_poll();
            return None;
        };
        if desc.is_owned_by_hw() {
            self.complete_irq_poll();
            return None;
        }

        self.next_reclaim = (idx + 1) % QUEUE_SIZE;
        let bus_addr = self.bus_addrs[idx].take()?;
        self.reclaimed = self.reclaimed.saturating_add(1);
        if self.reclaimed <= EARLY_PACKET_LOG_COUNT
            || self.reclaimed.is_multiple_of(TX_RECLAIM_LOG_INTERVAL)
        {
            info!(
                "RTL8125 tx reclaimed: idx={idx}, len={}, submitted={}, reclaimed={}, status={:?}",
                desc.len(),
                self.submitted,
                self.reclaimed,
                read_status(self.regs),
            );
        }
        Some(bus_addr)
    }
}

fn tx_link_state(link_up: bool) -> core::result::Result<(), NetError> {
    if link_up {
        Ok(())
    } else {
        Err(NetError::LinkDown)
    }
}

impl Rtl8125TxQueue {
    fn notify_device(&self) {
        // Coherent DMA removes cache-maintenance requirements, but descriptor
        // ownership still has to reach the device before the MMIO doorbell.
        wmb();
        self.regs.poll_tx();
    }

    fn complete_irq_poll(&self) {
        self.irq_poll.complete_queue(
            IRQ_TX_PENDING,
            || self.regs.write_interrupt_mask(DEFAULT_IRQ_MASK),
            || self.regs.write_interrupt_mask(0),
        );
    }

    fn observe_link_before_tx(&mut self, len: usize) -> bool {
        let must_sample = self.link_up != Some(true)
            || self.submitted == 0
            || self.submitted.is_multiple_of(TX_LINK_SAMPLE_INTERVAL);
        if !must_sample {
            return true;
        }

        let link_up = self.regs.link_up();
        let changed = self.link_up.replace(link_up) != Some(link_up);

        if link_up {
            if changed {
                let status = read_status(self.regs);
                info!("RTL8125 tx link up before submit: len={len}, status={status:?}");
            }
        } else if changed
            || self.link_down_drops == 0
            || self
                .link_down_drops
                .is_multiple_of(LINK_DOWN_DROP_LOG_INTERVAL)
        {
            let status = read_status(self.regs);
            warn!(
                "RTL8125 tx link down before submit: len={len}, dropped_tx={}, status={status:?}",
                self.link_down_drops
            );
        }

        link_up
    }
}

pub(crate) struct Rtl8125RxQueue {
    pub(crate) regs: Regs,
    pub(crate) irq_poll: IrqPollControl,
    pub(crate) desc: CoherentArray<RxDesc>,
    pub(crate) dma_mask: u64,
    pub(crate) start: QueueStart,
    pub(crate) bus_addrs: [Option<u64>; QUEUE_SIZE],
    pub(crate) next_submit: usize,
    pub(crate) next_reclaim: usize,
    pub(crate) idle_polls: u64,
    pub(crate) last_rx_rearm_idle: u64,
    pub(crate) submitted: usize,
    pub(crate) reclaimed: u64,
    pub(crate) rx_errors: u64,
    pub(crate) deferred_refill: VecDeque<u64>,
}

impl IRxQueue for Rtl8125RxQueue {
    fn id(&self) -> usize {
        QUEUE_ID0
    }

    fn config(&self) -> QueueConfig {
        QueueConfig {
            dma_mask: self.dma_mask,
            align: DMA_ALIGN,
            buf_size: RX_BUF_SIZE,
            ring_size: RX_QUEUE_CONFIG_SIZE,
        }
    }

    fn submit(&mut self, buffer: DmaBuffer) -> core::result::Result<(), NetError> {
        if buffer.len < RX_BUF_SIZE {
            return Err(NetError::NotSupported);
        }

        self.flush_deferred_refill();
        if self.submitted >= RX_START_THRESHOLD {
            self.deferred_refill.push_back(buffer.bus_addr);
            self.flush_deferred_refill();
            return Ok(());
        }

        let idx = self.next_submit;
        let next = (idx + 1) % QUEUE_SIZE;
        if self.bus_addrs[idx].is_some() {
            return Err(NetError::Retry);
        }

        let ring_end = idx == QUEUE_SIZE - 1;
        let desc = RxDesc::new_cpu_owned(buffer.bus_addr, RX_BUF_SIZE, ring_end);
        self.desc.set_cpu(idx, desc);
        release_dma_descriptor();
        self.desc.set_cpu(idx, desc.release_to_hw());
        self.bus_addrs[idx] = Some(buffer.bus_addr);
        self.next_submit = next;
        self.submitted = self.submitted.saturating_add(1);
        if self.submitted >= RX_START_THRESHOLD {
            let was_ready = {
                let mut start = self.start.lock();
                let was_ready = start.rx_ready;
                start.rx_ready = true;
                was_ready
            };
            if !was_ready {
                let last_opts1 = self
                    .desc
                    .read_cpu(QUEUE_SIZE - 1)
                    .map_or(0, |desc| desc.opts1);
                info!(
                    "RTL8125 rx ring ready: submitted={}, last_desc_opts1={:#x}",
                    self.submitted, last_opts1
                );
            }
            try_start_queues(self.regs, self.dma_mask, &self.start);
        }
        Ok(())
    }

    fn reclaim(&mut self) -> Option<(u64, usize)> {
        let idx = self.next_reclaim;
        let Some(bus_addr) = self.bus_addrs[idx] else {
            self.complete_irq_poll();
            return None;
        };
        let Some(desc) = self.desc.read_cpu(idx) else {
            self.complete_irq_poll();
            return None;
        };
        if desc.is_owned_by_hw() {
            self.idle_polls = self.idle_polls.saturating_add(1);
            if self.idle_polls.saturating_sub(self.last_rx_rearm_idle)
                >= RX_OVERFLOW_REARM_IDLE_POLLS
                && irq_has_rx_overflow(self.regs.read_interrupt_status())
            {
                self.last_rx_rearm_idle = self.idle_polls;
                let status = read_status(self.regs);
                warn!(
                    "RTL8125 rx overflow rearm: idx={idx}, opts1={:#x}, submitted={}, \
                     reclaimed={}, status={status:?}",
                    desc.opts1, self.submitted, self.reclaimed
                );
                self.regs.write_interrupt_status(status.intr_status);
                set_rx_mode(self.regs);
                self.regs.enable_tx_rx();
                self.regs.commit();
            }
            if self.idle_polls.is_multiple_of(RX_IDLE_LOG_INTERVAL) {
                let status = read_status(self.regs);
                debug!(
                    "RTL8125 rx idle: idx={idx}, opts1={:#x}, submitted={}, reclaimed={}, \
                     status={:?}",
                    desc.opts1, self.submitted, self.reclaimed, status,
                );
            }
            self.complete_irq_poll();
            return None;
        }
        acquire_dma_descriptor();
        let Some(desc) = self.desc.read_cpu(idx) else {
            self.complete_irq_poll();
            return None;
        };
        self.idle_polls = 0;
        self.last_rx_rearm_idle = 0;

        self.next_reclaim = (idx + 1) % QUEUE_SIZE;
        self.bus_addrs[idx] = None;

        if desc.has_error() || !desc.is_whole_packet() {
            self.rx_errors = self.rx_errors.saturating_add(1);
            warn!(
                "RTL8125 rx error: idx={idx}, opts1={:#x}, submitted={}, reclaimed={}, errors={}, \
                 status={:?}",
                desc.opts1,
                self.submitted,
                self.reclaimed,
                self.rx_errors,
                read_status(self.regs),
            );
            return Some((bus_addr, 0));
        }
        let len = desc.packet_len();
        self.reclaimed = self.reclaimed.saturating_add(1);
        if self.reclaimed.is_multiple_of(RX_RECLAIM_LOG_INTERVAL) {
            info!(
                "RTL8125 rx packet: idx={idx}, len={len}, submitted={}, reclaimed={}, status={:?}",
                self.submitted,
                self.reclaimed,
                read_status(self.regs),
            );
        }
        Some((bus_addr, len))
    }
}

impl Rtl8125RxQueue {
    fn complete_irq_poll(&self) {
        self.irq_poll.complete_queue(
            IRQ_RX_PENDING,
            || self.regs.write_interrupt_mask(DEFAULT_IRQ_MASK),
            || self.regs.write_interrupt_mask(0),
        );
    }

    fn flush_deferred_refill(&mut self) {
        while self.deferred_refill.len() >= RX_DESC_PER_CACHE_LINE {
            let Some(bus_addr) = self.deferred_refill.pop_front() else {
                break;
            };
            if let Err(err) = self.submit_deferred_buffer(bus_addr) {
                warn!("RTL8125 rx deferred refill failed: {err:?}");
                self.deferred_refill.push_front(bus_addr);
                break;
            }
        }
    }

    fn submit_deferred_buffer(&mut self, bus_addr: u64) -> core::result::Result<(), NetError> {
        let idx = self.next_submit;
        let next = (idx + 1) % QUEUE_SIZE;
        if self.bus_addrs[idx].is_some() {
            return Err(NetError::Retry);
        }

        let ring_end = idx == QUEUE_SIZE - 1;
        let desc = RxDesc::new_cpu_owned(bus_addr, RX_BUF_SIZE, ring_end);
        self.desc.set_cpu(idx, desc);
        release_dma_descriptor();
        self.desc.set_cpu(idx, desc.release_to_hw());
        self.bus_addrs[idx] = Some(bus_addr);
        self.next_submit = next;
        self.submitted = self.submitted.saturating_add(1);
        Ok(())
    }
}

pub(crate) fn release_dma_descriptor() {
    fence(AtomicOrdering::Release);
}

fn acquire_dma_descriptor() {
    fence(AtomicOrdering::Acquire);
}

pub(crate) fn try_start_queues(regs: Regs, dma_mask: u64, start: &QueueStart) {
    let (tx_base, rx_base) = {
        let mut start = start.lock();
        if start.started || !start.rx_ready {
            return;
        }
        let (Some(tx_base), Some(rx_base)) = (start.tx_base, start.rx_base) else {
            return;
        };
        start.started = true;
        (tx_base, rx_base)
    };

    regs.unlock_config();
    regs.write_tx_desc_base(tx_base);
    regs.write_rx_desc_base(rx_base);
    regs.lock_config();

    info!("RTL8125 queue DMA bases: tx={tx_base:#x}, rx={rx_base:#x}, mask={dma_mask:#x}");
    regs.write_rx_max_size(RX_BUF_SIZE as u16 + 1);
    regs.enable_tx_rx();
    regs.write_default_rx_config_8125b();
    regs.write_default_tx_config();
    regs.write_interrupt_status(u32::MAX);
    set_rx_mode(regs);
    regs.commit();
    info!("RTL8125 queues started: status={:?}", read_status(regs));
}

pub(crate) fn boxed_tx(queue: Rtl8125TxQueue) -> Box<dyn ITxQueue> {
    Box::new(queue)
}

pub(crate) fn boxed_rx(queue: Rtl8125RxQueue) -> Box<dyn IRxQueue> {
    Box::new(queue)
}

#[cfg(test)]
mod tests {
    use core::sync::atomic::{AtomicUsize, Ordering};

    use rdif_eth::TxNotify;

    use super::{
        IRQ_RX_PENDING, IRQ_TX_PENDING, IrqPollPhase, IrqPollState, TxNotificationState,
        tx_link_state,
    };

    fn begin_poll(state: &IrqPollState, queue_events: u8) -> bool {
        state.begin_poll(queue_events, || {}, || {}, || {})
    }

    #[test]
    fn deferred_descriptors_share_one_device_notification() {
        let mut notification = TxNotificationState::default();

        assert!(!notification.descriptor_submitted(TxNotify::Deferred));
        assert!(!notification.descriptor_submitted(TxNotify::Deferred));
        assert!(notification.take_pending());
        assert!(!notification.take_pending());
        assert!(notification.descriptor_submitted(TxNotify::Immediate));
        assert!(!notification.take_pending());
    }

    #[test]
    fn link_down_is_distinct_from_transient_ring_backpressure() {
        assert!(matches!(tx_link_state(true), Ok(())));
        assert!(matches!(
            tx_link_state(false),
            Err(rdif_eth::NetError::LinkDown)
        ));
    }

    #[test]
    fn irq_poll_stays_masked_until_the_ring_is_drained() {
        let state = IrqPollState::new();
        state.enable(|| {}, || {});

        assert!(begin_poll(&state, IRQ_RX_PENDING));
        assert!(!begin_poll(&state, IRQ_RX_PENDING));
        assert_eq!(state.phase(), IrqPollPhase::Polling);
        assert!(!state.is_enabled());

        // A budget-exhausted worker does not complete the phase. Only the
        // later empty-ring observation re-enables delivery.
        assert_eq!(state.phase(), IrqPollPhase::Polling);
        assert!(state.complete_queue(IRQ_RX_PENDING, || {}, || {}));
        assert_eq!(state.phase(), IrqPollPhase::Enabled);
    }

    #[test]
    fn irq_arriving_during_rearm_keeps_delivery_masked() {
        let state = IrqPollState::new();
        let mask_count = AtomicUsize::new(0);
        state.enable(|| {}, || {});
        assert!(begin_poll(&state, IRQ_RX_PENDING));

        let completed = state.complete_queue(
            IRQ_RX_PENDING,
            || {
                assert!(state.begin_poll(
                    IRQ_RX_PENDING,
                    || {
                        mask_count.fetch_add(1, Ordering::AcqRel);
                    },
                    || {},
                    || {},
                ));
            },
            || {
                mask_count.fetch_add(1, Ordering::AcqRel);
            },
        );

        assert!(!completed);
        assert_eq!(state.phase(), IrqPollPhase::Polling);
        assert_eq!(mask_count.load(Ordering::Acquire), 2);
    }

    #[test]
    fn poll_completion_cannot_rearm_before_hardware_mask_finishes() {
        let state = IrqPollState::new();
        let hardware_enabled = core::sync::atomic::AtomicBool::new(false);
        state.enable(
            || hardware_enabled.store(true, Ordering::Release),
            || hardware_enabled.store(false, Ordering::Release),
        );

        assert!(state.begin_poll(
            IRQ_RX_PENDING,
            || {
                // Model a worker on another CPU observing the published Polling
                // state before the hard-IRQ CPU has completed its MMIO mask write.
                assert!(!state.complete_queue(
                    IRQ_RX_PENDING,
                    || hardware_enabled.store(true, Ordering::Release),
                    || hardware_enabled.store(false, Ordering::Release),
                ));
                hardware_enabled.store(false, Ordering::Release);
            },
            || hardware_enabled.store(true, Ordering::Release),
            || hardware_enabled.store(false, Ordering::Release),
        ));

        assert_eq!(state.phase(), IrqPollPhase::Enabled);
        assert!(hardware_enabled.load(Ordering::Acquire));
    }

    #[test]
    fn repeated_enable_does_not_cancel_an_active_poll() {
        let state = IrqPollState::new();
        let unmask_count = AtomicUsize::new(0);
        state.enable(
            || {
                unmask_count.fetch_add(1, Ordering::AcqRel);
            },
            || {},
        );
        assert!(begin_poll(&state, IRQ_RX_PENDING));

        state.enable(
            || {
                unmask_count.fetch_add(1, Ordering::AcqRel);
            },
            || {},
        );

        assert_eq!(state.phase(), IrqPollPhase::Polling);
        assert_eq!(unmask_count.load(Ordering::Acquire), 1);
    }

    #[test]
    fn rx_drain_does_not_rearm_while_tx_completion_is_pending() {
        let state = IrqPollState::new();
        state.enable(|| {}, || {});
        assert!(begin_poll(&state, IRQ_TX_PENDING | IRQ_RX_PENDING));

        let completed = state.complete_queue(IRQ_RX_PENDING, || {}, || {});

        assert!(!completed);
        assert_eq!(state.phase(), IrqPollPhase::Polling);
        assert!(state.complete_queue(IRQ_TX_PENDING, || {}, || {}));
        assert_eq!(state.phase(), IrqPollPhase::Enabled);
    }

    #[test]
    fn queue_event_arriving_during_poll_is_latched_until_its_queue_drains() {
        let state = IrqPollState::new();
        state.enable(|| {}, || {});
        assert!(begin_poll(&state, IRQ_RX_PENDING));
        assert!(!begin_poll(&state, IRQ_TX_PENDING));

        assert!(!state.complete_queue(IRQ_RX_PENDING, || {}, || {}));
        assert_eq!(state.phase(), IrqPollPhase::Polling);
        assert!(state.complete_queue(IRQ_TX_PENDING, || {}, || {}));
        assert_eq!(state.phase(), IrqPollPhase::Enabled);
    }

    #[test]
    fn administrative_disable_prevents_poll_completion_from_unmasking() {
        let state = IrqPollState::new();
        let unmask_count = AtomicUsize::new(0);
        state.enable(|| {}, || {});
        assert!(begin_poll(&state, IRQ_RX_PENDING));
        state.disable(|| {});

        assert!(!state.complete_queue(
            IRQ_RX_PENDING,
            || {
                unmask_count.fetch_add(1, Ordering::AcqRel);
            },
            || {},
        ));
        assert_eq!(state.phase(), IrqPollPhase::Disabled);
        assert_eq!(unmask_count.load(Ordering::Acquire), 0);
        assert!(!begin_poll(&state, IRQ_RX_PENDING));
    }
}
