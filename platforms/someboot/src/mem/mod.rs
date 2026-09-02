use core::ops::Range;

use byte_unit::{Byte, UnitType};
use kernutil::StaticCell;
pub use kernutil::memory::{MemoryDescriptor, MemoryType, PageTableInfo};
use num_align::NumAlign;
use ranges_ext::*;

pub mod mmu;
pub(crate) mod ram;
pub(crate) mod region;

pub use mmu::{MemAttributes, PteConfig};
pub use page_table_generic::*;

use crate::{ArchTrait, DCacheOp, arch::Arch, smp::cpu_area_region};

pub const KB: usize = 1024;
pub const MB: usize = 1024 * KB;
pub const GB: usize = 1024 * MB;
pub const KIMAGE_MAP_ALIGN: usize = 2 * MB;

static mut VM_LOAD_OFFSET: isize = 0;
static MEMORY_MAP: StaticCell<MemoryMap> = StaticCell::new(MemoryMap::new());

/// Load address of the kernel start
static mut KIMAGE_START: Option<PhysAddr> = None;
/// Load address of the kernel end
static mut KIMAGE_END: PhysAddr = PhysAddr::from_usize(0);

const MEMORY_MAP_CAPACITY: usize = 512;

#[cfg(all(target_arch = "aarch64", feature = "qemu-aarch64-three-guest-net"))]
const QEMU_AARCH64_THREE_GUEST_RAM: Range<usize> = 0x8000_0000..0xb000_0000;

pub type MemoryMap = heapless::Vec<MemoryDescriptor, MEMORY_MAP_CAPACITY>;

pub(crate) fn setup_entry(
    kernel_start: PhysAddr,
    kernel_end: PhysAddr,
    kernel_start_link: VirtAddr,
) {
    unsafe {
        KIMAGE_START = Some(kernel_start);
        KIMAGE_END = kernel_end.as_usize().align_up(KIMAGE_MAP_ALIGN).into();

        VM_LOAD_OFFSET = kernel_start.as_usize() as isize - kernel_start_link.as_usize() as isize;
    }
}

pub fn stack_size() -> usize {
    unsafe extern "C" {
        fn STACK_SIZE();
    }
    STACK_SIZE as *const () as usize
}

/// Get the offset between virtual address and physical address of the loaded kernel image
pub fn vm_load_offset() -> isize {
    unsafe { VM_LOAD_OFFSET }
}

/// RAM 物理地址应当转换为的内核虚拟地址
pub fn __va(paddr: usize) -> *mut u8 {
    crate::arch::Arch::_va(paddr)
}

/// IO 物理地址应当转换为的内核虚拟地址
pub fn __io(paddr: usize) -> *mut u8 {
    crate::arch::Arch::_io(paddr)
}

pub fn cpu_area_phys_to_virt(paddr: usize) -> *mut u8 {
    crate::arch::Arch::cpu_area_phys_to_virt(paddr)
}

/// kernel image 物理地址转换为内核虚拟地址
pub(crate) fn __kimage_va(paddr: usize) -> *mut u8 {
    (paddr as isize - vm_load_offset()) as usize as *mut u8
}

pub(crate) fn __kimage_va_to_pa(vaddr: *const u8) -> usize {
    (vaddr as usize as isize + vm_load_offset()) as usize
}

pub fn memory_map() -> &'static [MemoryDescriptor] {
    MEMORY_MAP.as_slice()
}

pub fn dcache_range(op: DCacheOp, addr: *const u8, size: usize) {
    Arch::dcache_range(op, addr as _, size);
}

pub fn dma_coherent_before_make_uncached(addr: *const u8, size: usize) {
    Arch::dma_coherent_before_make_uncached(addr as _, size);
}

pub fn dma_coherent_before_restore_cached(addr: *const u8, size: usize) {
    Arch::dma_coherent_before_restore_cached(addr as _, size);
}

pub fn dma_coherent_after_mapping_update() {
    Arch::dma_coherent_after_mapping_update();
}

#[cfg(any(
    test,
    all(axtest, feature = "axtest"),
    all(target_arch = "riscv64", feature = "thead-mae")
))]
pub(crate) fn cache_line_range(
    addr: usize,
    size: usize,
    line_size: usize,
) -> Option<(usize, usize)> {
    if size == 0 || line_size == 0 || !line_size.is_power_of_two() {
        return None;
    }
    let end = addr.checked_add(size)?;
    Some((addr & !(line_size - 1), end))
}

#[cfg(all(axtest, feature = "axtest"))]
pub(crate) fn mem_constants_and_cache_line_rules_hold_for_test() -> bool {
    // KB/MB/GB constants
    assert!(KB == 1024);
    assert!(MB == 1024 * KB);
    assert!(GB == 1024 * MB);

    // KIMAGE_MAP_ALIGN
    assert!(KIMAGE_MAP_ALIGN == 2 * MB);

    // cache_line_range: valid inputs
    let result = cache_line_range(0x1000, 64, 64).unwrap();
    assert!(result.0 == 0x1000); // aligned down
    assert!(result.1 == 0x1040); // addr + size

    // cache_line_range: zero size returns None
    assert!(cache_line_range(0x1000, 0, 64).is_none());

    // cache_line_range: zero line_size returns None
    assert!(cache_line_range(0x1000, 64, 0).is_none());

    // cache_line_range: non-power-of-2 line_size returns None
    assert!(cache_line_range(0x1000, 64, 63).is_none());

    // cache_line_range: overflow returns None
    assert!(cache_line_range(usize::MAX, 1, 64).is_none());

    true
}

/// 物理RAM实际转换为的内核虚拟地址
pub fn phys_to_virt(paddr: usize) -> *mut u8 {
    if mmu::is_kernel_relocated() {
        if kimage_range().contains(&paddr) {
            __kimage_va(paddr)
        } else if cpu_area_region().contains(&paddr) {
            cpu_area_phys_to_virt(paddr)
        } else {
            __va(paddr)
        }
    } else if cfg!(target_arch = "loongarch64") {
        __va(paddr)
    } else {
        paddr as *mut u8
    }
}

pub fn virt_to_phys(vaddr: *const u8) -> usize {
    crate::arch::Arch::virt_to_phys(vaddr)
}

pub(crate) fn _fixmap_io(paddr: usize) -> *mut u8 {
    if mmu::is_kernel_relocated() || cfg!(target_arch = "loongarch64") {
        __io(paddr)
    } else {
        paddr as *mut u8
    }
}

pub(crate) fn early_init() {
    crate::fdt::init_memory_map();

    let kernel_range = kimage_range();
    add_memory_descriptor(MemoryDescriptor {
        physical_start: kernel_range.start,
        size_in_bytes: kernel_range.end - kernel_range.start,
        memory_type: MemoryType::KImage,
    })
    .unwrap_or_else(|err| {
        panic!("failed to add KImage memory descriptor {kernel_range:#x?}: {err:?}")
    });
    reserve_arch_early_ranges();

    unsafe { MEMORY_MAP.update(|m| m.sort_by_key(|a| a.physical_start)) };

    print_memory_map();

    let mut free_range = None;

    for desc in memory_map().iter() {
        if desc.memory_type == MemoryType::Free && desc.size_in_bytes > 8 * MB {
            free_range = Some(desc.physical_start..(desc.physical_start + desc.size_in_bytes));
            break;
        }
    }

    ram::init(free_range.expect("No free memory"));

    crate::fdt::save_fdt();
    crate::smp::alloc_percpu();
}

fn reserve_arch_early_ranges() {
    #[cfg(all(target_arch = "aarch64", feature = "qemu-aarch64-three-guest-net"))]
    unsafe {
        MEMORY_MAP.update(|map| {
            apply_early_reserved_ranges(map, &[QEMU_AARCH64_THREE_GUEST_RAM]);
        });
    }

    #[cfg(target_arch = "x86_64")]
    {
        // AP trampoline lives in low memory and must stay reserved.
        let tramp = crate::arch::power::AP_TRAMPOLINE_PADDR;
        let desc =
            MemoryDescriptor::new_aligned(tramp, page_size(), MemoryType::Reserved, page_size());
        match add_memory_descriptor(desc) {
            Ok(()) => {}
            Err(RangeError::Conflict { existing, .. })
                if existing.memory_type != MemoryType::Free =>
            {
                // Already reserved by firmware map; keep it as-is.
            }
            Err(err) => panic!("failed to reserve x86 AP trampoline: {err:?}"),
        }
    }
}

#[cfg(any(
    test,
    all(target_arch = "aarch64", feature = "qemu-aarch64-three-guest-net")
))]
fn apply_early_reserved_ranges(map: &mut MemoryMap, ranges: &[Range<usize>]) {
    const ALIGNMENT: usize = 4 * KB;

    for (index, range) in ranges.iter().enumerate() {
        let size = range.end.checked_sub(range.start).unwrap_or_else(|| {
            panic!("invalid early reserved range {range:#x?}: expected non-empty ordered range")
        });
        assert!(
            size != 0,
            "invalid early reserved range {range:#x?}: expected non-empty ordered range"
        );
        assert!(
            range.start.is_multiple_of(ALIGNMENT) && range.end.is_multiple_of(ALIGNMENT),
            "invalid early reserved range {range:#x?}: start and end must be 4 KiB aligned"
        );

        for previous in &ranges[..index] {
            assert!(
                range.start >= previous.end || range.end <= previous.start,
                "invalid early reserved range {range:#x?}: requested ranges overlap {previous:#x?}"
            );
        }

        let mut contained_in_free = false;
        let mut non_free_overlap = None;
        for desc in map.iter() {
            let desc_end = desc
                .physical_start
                .checked_add(desc.size_in_bytes)
                .unwrap_or_else(|| {
                    panic!(
                        "cannot validate early reserved range {range:#x?}: memory descriptor \
                         overflows: {desc:?}"
                    )
                });
            if desc.memory_type == MemoryType::Free
                && desc.physical_start <= range.start
                && range.end <= desc_end
            {
                contained_in_free = true;
            }
            if desc.memory_type != MemoryType::Free
                && range.start < desc_end
                && range.end > desc.physical_start
            {
                non_free_overlap = Some((desc.memory_type, desc.physical_start..desc_end));
            }
        }

        if let Some((memory_type, existing)) = non_free_overlap {
            panic!(
                "invalid early reserved range {range:#x?}: overlaps {memory_type:?} descriptor \
                 {existing:#x?}"
            );
        }
        if !contained_in_free {
            panic!("invalid early reserved range {range:#x?}: outside FREE RAM");
        }
    }

    let mut updated = map.clone();
    for range in ranges {
        let desc = MemoryDescriptor::new_with_range(range.clone(), MemoryType::Reserved);
        updated.merge_add(desc).unwrap_or_else(|err| {
            panic!("failed to add early reserved range {range:#x?}: {err:?}")
        });
    }
    *map = updated;
}

/// Get the physical range of the kernel image
pub(crate) fn kimage_range() -> core::ops::Range<usize> {
    unsafe {
        let Some(start) = KIMAGE_START else {
            panic!("Kernel image start is not set");
        };
        let end = KIMAGE_END;
        start.as_usize()..end.as_usize()
    }
}

pub fn page_size() -> usize {
    unsafe extern "C" {
        static PAGE_SIZE: usize;
    }
    core::ptr::addr_of!(PAGE_SIZE) as usize
}

pub(crate) fn memory_map_setup() {
    // let kernel_range = kimage_range();
    // let desc = MemoryDescriptor::new_with_range(kernel_range, MemoryType::KImage);

    // add_memory_descriptor(desc).unwrap();

    let ram_range = ram::used_range();
    if !ram_range.is_empty() {
        let desc = MemoryDescriptor::new_with_range(ram_range, MemoryType::Reserved);
        add_memory_descriptor(desc).unwrap();
    }
    if let Some(desc) = crate::console::debug_to_memory_desc() {
        add_memory_descriptor(desc).unwrap();
    }
}

pub fn print_memory_map() {
    println!("Memory Map:");
    unsafe { MEMORY_MAP.update(|m| m.sort_by_key(|m| m.physical_start)) };

    for desc in memory_map().iter() {
        let fmt = Byte::from(desc.size_in_bytes).get_appropriate_unit(UnitType::Binary);
        println!(
            "  {} {:>#016x} - {:>#016x} ({:#.2})",
            desc.memory_type,
            desc.physical_start,
            desc.physical_start + desc.size_in_bytes,
            fmt
        );
    }
}

pub(crate) fn add_memory_descriptor(
    desc: MemoryDescriptor,
) -> Result<(), RangeError<MemoryDescriptor>> {
    unsafe { MEMORY_MAP.update(|mem| mem.merge_add(desc)) }
}

pub fn kernel_space() -> Range<usize> {
    Arch::kernel_space()
}

#[cfg(test)]
mod tests {
    extern crate std;

    use std::panic::{AssertUnwindSafe, catch_unwind};

    use super::*;

    fn memory_map_with(range: Range<usize>, memory_type: MemoryType) -> MemoryMap {
        let mut map = MemoryMap::new();
        map.merge_add(MemoryDescriptor::new_with_range(range, memory_type))
            .unwrap();
        map
    }

    fn assert_memory_types(map: &mut MemoryMap, expected: &[(Range<usize>, MemoryType)]) {
        map.sort_by_key(|desc| desc.physical_start);
        let actual: heapless::Vec<_, MEMORY_MAP_CAPACITY> = map
            .iter()
            .map(|desc| {
                (
                    desc.physical_start..desc.physical_start + desc.size_in_bytes,
                    desc.memory_type,
                )
            })
            .collect();
        assert_eq!(actual.as_slice(), expected);
    }

    #[test]
    fn cache_line_range_covers_unaligned_buffer() {
        assert_eq!(cache_line_range(0x1003, 1, 64), Some((0x1000, 0x1004)));
        assert_eq!(cache_line_range(0x103f, 2, 64), Some((0x1000, 0x1041)));
    }

    #[test]
    fn cache_line_range_skips_empty_invalid_line_and_overflow() {
        assert_eq!(cache_line_range(0x1000, 0, 64), None);
        assert_eq!(cache_line_range(0x1000, 1, 0), None);
        assert_eq!(cache_line_range(0x1000, 1, 63), None);
        assert_eq!(cache_line_range(usize::MAX, 2, 64), None);
    }

    #[test]
    fn qemu_aarch64_three_guest_reservation_splits_free_ram() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);

        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xb000_0000]);

        assert_memory_types(
            &mut map,
            &[
                (0x4000_0000..0x8000_0000, MemoryType::Free),
                (0x8000_0000..0xb000_0000, MemoryType::Reserved),
                (0xb000_0000..0x2_4000_0000, MemoryType::Free),
            ],
        );
    }

    #[test]
    #[should_panic(expected = "outside FREE RAM")]
    fn qemu_aarch64_three_guest_reservation_rejects_too_small_ram() {
        let mut map = memory_map_with(0x4000_0000..0x9000_0000, MemoryType::Free);
        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xb000_0000]);
    }

    #[test]
    #[should_panic(expected = "4 KiB aligned")]
    fn qemu_aarch64_three_guest_reservation_rejects_misaligned_start() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);
        apply_early_reserved_ranges(&mut map, &[0x8000_0001..0xb000_0000]);
    }

    #[test]
    #[should_panic(expected = "4 KiB aligned")]
    fn qemu_aarch64_three_guest_reservation_rejects_misaligned_end() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);
        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xafff_ffff]);
    }

    #[test]
    #[should_panic(expected = "non-empty ordered range")]
    fn qemu_aarch64_three_guest_reservation_rejects_empty_range() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);
        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0x8000_0000]);
    }

    #[test]
    #[should_panic(expected = "non-empty ordered range")]
    fn qemu_aarch64_three_guest_reservation_rejects_reversed_range() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);
        apply_early_reserved_ranges(&mut map, &[0xb000_0000..0x8000_0000]);
    }

    #[test]
    #[should_panic(expected = "overlaps KImage")]
    fn qemu_aarch64_three_guest_reservation_rejects_kimage_overlap() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);
        map.merge_add(MemoryDescriptor::new_with_range(
            0x9000_0000..0x9100_0000,
            MemoryType::KImage,
        ))
        .unwrap();
        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xb000_0000]);
    }

    #[test]
    #[should_panic(expected = "overlaps Reserved")]
    fn qemu_aarch64_three_guest_reservation_rejects_firmware_reservation_overlap() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);
        map.merge_add(MemoryDescriptor::new_with_range(
            0x9000_0000..0x9100_0000,
            MemoryType::Reserved,
        ))
        .unwrap();
        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xb000_0000]);
    }

    #[test]
    #[should_panic(expected = "overlaps Mmio")]
    fn qemu_aarch64_three_guest_reservation_rejects_other_non_free_overlap() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);
        map.merge_add(MemoryDescriptor::new_with_range(
            0x9000_0000..0x9100_0000,
            MemoryType::Mmio,
        ))
        .unwrap();
        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xb000_0000]);
    }

    #[test]
    #[should_panic(expected = "overlaps Reserved")]
    fn early_reservation_scans_later_reserved_descriptor_after_containing_free() {
        let mut map = MemoryMap::new();
        map.push(MemoryDescriptor::new_with_range(
            0x4000_0000..0x2_4000_0000,
            MemoryType::Free,
        ))
        .unwrap();
        map.push(MemoryDescriptor::new_with_range(
            0x9000_0000..0x9100_0000,
            MemoryType::Reserved,
        ))
        .unwrap();

        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xb000_0000]);
    }

    #[test]
    #[should_panic(expected = "overlaps KImage")]
    fn early_reservation_scans_later_kimage_descriptor_after_containing_free() {
        let mut map = MemoryMap::new();
        map.push(MemoryDescriptor::new_with_range(
            0x4000_0000..0x2_4000_0000,
            MemoryType::Free,
        ))
        .unwrap();
        map.push(MemoryDescriptor::new_with_range(
            0x9000_0000..0x9100_0000,
            MemoryType::KImage,
        ))
        .unwrap();

        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xb000_0000]);
    }

    #[test]
    #[should_panic(expected = "memory descriptor overflows")]
    fn early_reservation_scans_later_overflowing_descriptor_after_containing_free() {
        let mut map = MemoryMap::new();
        map.push(MemoryDescriptor::new_with_range(
            0x4000_0000..0x2_4000_0000,
            MemoryType::Free,
        ))
        .unwrap();
        map.push(MemoryDescriptor {
            physical_start: usize::MAX - 0xfff,
            size_in_bytes: 0x2000,
            memory_type: MemoryType::Reserved,
        })
        .unwrap();

        apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xb000_0000]);
    }

    #[test]
    fn early_reservation_capacity_failure_leaves_map_unchanged() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);
        for index in 0..MEMORY_MAP_CAPACITY - 1 {
            let start = index * 0x2000;
            map.push(MemoryDescriptor::new_with_range(
                start..start + 0x1000,
                MemoryType::Reserved,
            ))
            .unwrap();
        }
        assert_eq!(map.len(), MEMORY_MAP_CAPACITY);
        let original = map.clone();

        let result = catch_unwind(AssertUnwindSafe(|| {
            apply_early_reserved_ranges(&mut map, &[0x8000_0000..0xb000_0000]);
        }));

        assert!(result.is_err());
        assert_eq!(map, original);
    }

    #[test]
    fn early_reservation_applies_two_disjoint_ranges() {
        let mut map = memory_map_with(0x4000_0000..0x1_4000_0000, MemoryType::Free);

        apply_early_reserved_ranges(
            &mut map,
            &[0x8000_0000..0x9000_0000, 0xa000_0000..0xb000_0000],
        );

        assert_memory_types(
            &mut map,
            &[
                (0x4000_0000..0x8000_0000, MemoryType::Free),
                (0x8000_0000..0x9000_0000, MemoryType::Reserved),
                (0x9000_0000..0xa000_0000, MemoryType::Free),
                (0xa000_0000..0xb000_0000, MemoryType::Reserved),
                (0xb000_0000..0x1_4000_0000, MemoryType::Free),
            ],
        );
    }

    #[test]
    #[should_panic(expected = "requested ranges overlap")]
    fn qemu_aarch64_three_guest_reservation_rejects_requested_range_overlap() {
        let mut map = memory_map_with(0x4000_0000..0x2_4000_0000, MemoryType::Free);
        apply_early_reserved_ranges(
            &mut map,
            &[0x8000_0000..0xa000_0000, 0x9000_0000..0xb000_0000],
        );
    }
}

#[cfg(all(axtest, feature = "axtest"))]
pub(crate) fn mem_constants_and_types_hold_for_test() -> bool {
    // Test memory constants
    assert_eq!(KB, 1024);
    assert_eq!(MB, 1024 * 1024);
    assert_eq!(GB, 1024 * 1024 * 1024);
    assert_eq!(KIMAGE_MAP_ALIGN, 2 * MB);

    // Test MemoryMap capacity
    assert_eq!(MEMORY_MAP_CAPACITY, 512);

    true
}

#[cfg(all(axtest, feature = "axtest"))]
pub(crate) fn mem_byte_unit_types_hold_for_test() -> bool {
    // Test byte_unit types exist
    use byte_unit::Byte;

    // Test that Byte can be created
    let _byte = Byte::from_u64(1024);

    true
}
