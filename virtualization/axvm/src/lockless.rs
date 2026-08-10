// Copyright 2025 The Axvisor Team
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Lock-free data structures for the AxVM hot path.
//!
//! These primitives avoid `SpinNoIrq`-based mutual exclusion on the vCPU
//! interrupt delivery path, reducing worst-case interrupt latency.

use core::{
    cell::UnsafeCell,
    sync::atomic::{AtomicUsize, Ordering},
};

/// A lock-free single-producer, single-consumer (SPSC) ring buffer for
/// pending interrupts.
///
/// # Safety
///
/// - **Producer** (interrupt injection path, may run on any CPU): calls
///   [`push`]. Only one producer is allowed concurrently — the current
///   implementation serialises producers through the existing interrupt
///   routing layer.
/// - **Consumer** (vCPU run loop on the owning CPU): calls [`drain`].
///   Only one consumer is allowed.
///
/// The `N` parameter is the buffer capacity; it must be a power of two.
pub(crate) struct InterruptQueue<const N: usize> {
    buffer: [AtomicUsize; N],
    /// Next write index (producer).
    head: AtomicUsize,
    /// Next read index (consumer).
    tail: AtomicUsize,
}

/// An iterator that drains all queued entries.
pub(crate) struct DrainIter<'a, const N: usize> {
    queue: &'a InterruptQueue<N>,
    consumed: usize,
}

impl<const N: usize> InterruptQueue<N> {
    /// Creates an empty interrupt queue.
    pub const fn new() -> Self {
        const EMPTY: AtomicUsize = AtomicUsize::new(0);
        Self {
            buffer: [EMPTY; N],
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
        }
    }

    /// Returns `true` when the queue is empty.
    pub fn is_empty(&self) -> bool {
        let head = self.head.load(Ordering::Acquire);
        let tail = self.tail.load(Ordering::Acquire);
        head == tail
    }

    /// Pushes one interrupt vector into the queue.
    ///
    /// Returns `Ok(())` on success, `Err(vector)` if the queue is full.
    pub fn push(&self, vector: usize) -> Result<(), usize> {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);
        let next_head = (head + 1) & (N - 1);
        if next_head == tail {
            return Err(vector); // full
        }
        self.buffer[head].store(vector, Ordering::Release);
        self.head.store(next_head, Ordering::Release);
        Ok(())
    }

    /// Drains all queued entries into a `Vec`.
    pub fn drain(&self) -> alloc::vec::Vec<usize> {
        let mut result = alloc::vec::Vec::with_capacity(N);
        // SAFETY: drain is only called from the consumer context (vCPU run loop).
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Acquire);
        let mut idx = tail;
        while idx != head {
            result.push(self.buffer[idx].load(Ordering::Relaxed));
            idx = (idx + 1) & (N - 1);
        }
        self.tail.store(head, Ordering::Release);
        result
    }

    /// Returns the number of queued entries.
    pub fn len(&self) -> usize {
        let head = self.head.load(Ordering::Acquire);
        let tail = self.tail.load(Ordering::Acquire);
        if head >= tail {
            head - tail
        } else {
            N - tail + head
        }
    }
}

// InterruptQueue is !Sync by design (SPSC). It must only be accessed from
// its owning vCPU task context.
unsafe impl<const N: usize> Send for InterruptQueue<N> {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_and_drain_single() {
        let q = InterruptQueue::<8>::new();
        assert!(q.is_empty());

        q.push(42).unwrap();
        assert!(!q.is_empty());
        assert_eq!(q.len(), 1);

        let drained = q.drain();
        assert_eq!(drained, vec![42]);
        assert!(q.is_empty());
    }

    #[test]
    fn push_and_drain_multiple() {
        let q = InterruptQueue::<8>::new();
        for v in [10, 20, 30, 40] {
            q.push(v).unwrap();
        }
        assert_eq!(q.len(), 4);
        assert_eq!(q.drain(), vec![10, 20, 30, 40]);
        assert!(q.is_empty());
    }

    #[test]
    fn push_returns_error_when_full() {
        let q = InterruptQueue::<4>::new();
        // capacity is N-1 = 3
        assert!(q.push(1).is_ok());
        assert!(q.push(2).is_ok());
        assert!(q.push(3).is_ok());
        assert!(q.push(4).is_err());
    }

    #[test]
    fn drain_then_refill() {
        let q = InterruptQueue::<8>::new();
        q.push(1).unwrap();
        q.push(2).unwrap();
        assert_eq!(q.drain(), vec![1, 2]);
        assert!(q.is_empty());

        q.push(3).unwrap();
        q.push(4).unwrap();
        assert_eq!(q.drain(), vec![3, 4]);
    }
}
