//! Read-only embedded root filesystem support.

use alloc::{
    collections::{BTreeMap, BTreeSet},
    string::{String, ToString},
    sync::Arc,
    vec::Vec,
};
use core::{any::Any, fmt, str, task::Context, time::Duration};

use ax_lazyinit::OnceLock;
use axfs_ng_vfs::{
    DeviceId, DirEntry, DirEntrySink, DirNode, DirNodeOps, FileNode, FileNodeOps, Filesystem,
    FilesystemOps, FsIoEvents, FsPollable, Metadata, MetadataUpdate, NodeFlags, NodeOps,
    NodePermission, NodeType, Reference, StatFs, VfsError, VfsResult, WeakDirEntry,
    path::{DOT, DOTDOT, MAX_NAME_LEN},
};

const NEWC_HEADER_LEN: usize = 110;
const NEWC_MAGIC: &[u8; 6] = b"070701";
const TRAILER: &str = "TRAILER!!!";
const FILE_TYPE_MASK: u32 = 0o170000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EmbeddedEntryKind {
    Directory,
    RegularFile,
    Symlink,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EmbeddedArchiveError {
    DuplicatePath,
    InvalidHeader,
    InvalidMode,
    InvalidPath,
    MissingTrailer,
    PathConflict,
    Truncated,
}

impl fmt::Display for EmbeddedArchiveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EmbeddedEntry<'a> {
    path: &'a str,
    kind: EmbeddedEntryKind,
    permissions: u16,
    data: &'a [u8],
}

impl<'a> EmbeddedEntry<'a> {
    pub fn path(&self) -> &'a str {
        self.path
    }

    pub fn kind(&self) -> EmbeddedEntryKind {
        self.kind
    }

    pub fn permissions(&self) -> u16 {
        self.permissions
    }

    pub fn data(&self) -> &'a [u8] {
        self.data
    }
}

pub fn parse_newc(bytes: &[u8]) -> Result<Vec<EmbeddedEntry<'_>>, EmbeddedArchiveError> {
    let mut entries = Vec::new();
    let mut paths = BTreeSet::<String>::new();
    let mut offset = 0usize;

    loop {
        let header = bytes
            .get(offset..offset.checked_add(NEWC_HEADER_LEN).ok_or(EmbeddedArchiveError::Truncated)?)
            .ok_or(EmbeddedArchiveError::Truncated)?;
        if header.get(..6) != Some(NEWC_MAGIC) {
            return Err(EmbeddedArchiveError::InvalidHeader);
        }
        let mode = parse_hex(header, 14)?;
        let file_size = usize::try_from(parse_hex(header, 54)?)
            .map_err(|_| EmbeddedArchiveError::InvalidHeader)?;
        let name_size = usize::try_from(parse_hex(header, 94)?)
            .map_err(|_| EmbeddedArchiveError::InvalidHeader)?;
        if name_size < 2 {
            return Err(EmbeddedArchiveError::InvalidPath);
        }

        offset = offset
            .checked_add(NEWC_HEADER_LEN)
            .ok_or(EmbeddedArchiveError::Truncated)?;
        let name_bytes = bytes
            .get(offset..offset.checked_add(name_size).ok_or(EmbeddedArchiveError::Truncated)?)
            .ok_or(EmbeddedArchiveError::Truncated)?;
        if name_bytes.last() != Some(&0) {
            return Err(EmbeddedArchiveError::InvalidPath);
        }
        let path = str::from_utf8(&name_bytes[..name_size - 1])
            .map_err(|_| EmbeddedArchiveError::InvalidPath)?;
        offset = align4(
            offset
                .checked_add(name_size)
                .ok_or(EmbeddedArchiveError::Truncated)?,
        )?;

        let data = bytes
            .get(offset..offset.checked_add(file_size).ok_or(EmbeddedArchiveError::Truncated)?)
            .ok_or(EmbeddedArchiveError::Truncated)?;
        offset = align4(
            offset
                .checked_add(file_size)
                .ok_or(EmbeddedArchiveError::Truncated)?,
        )?;
        if offset > bytes.len() {
            return Err(EmbeddedArchiveError::Truncated);
        }

        if path == TRAILER {
            if file_size != 0 {
                return Err(EmbeddedArchiveError::InvalidHeader);
            }
            return Ok(entries);
        }
        validate_path(path)?;
        if !paths.insert(path.into()) {
            return Err(EmbeddedArchiveError::DuplicatePath);
        }
        let kind = match mode & FILE_TYPE_MASK {
            0o040000 => EmbeddedEntryKind::Directory,
            0o100000 => EmbeddedEntryKind::RegularFile,
            0o120000 => EmbeddedEntryKind::Symlink,
            _ => return Err(EmbeddedArchiveError::InvalidMode),
        };
        if kind == EmbeddedEntryKind::Directory && !data.is_empty() {
            return Err(EmbeddedArchiveError::InvalidHeader);
        }
        entries.push(EmbeddedEntry {
            path,
            kind,
            permissions: (mode & 0o7777) as u16,
            data,
        });

        if offset == bytes.len() {
            return Err(EmbeddedArchiveError::MissingTrailer);
        }
    }
}

fn parse_hex(header: &[u8], offset: usize) -> Result<u32, EmbeddedArchiveError> {
    let field = header
        .get(offset..offset + 8)
        .ok_or(EmbeddedArchiveError::InvalidHeader)?;
    let field = str::from_utf8(field).map_err(|_| EmbeddedArchiveError::InvalidHeader)?;
    u32::from_str_radix(field, 16).map_err(|_| EmbeddedArchiveError::InvalidHeader)
}

fn align4(value: usize) -> Result<usize, EmbeddedArchiveError> {
    value
        .checked_add(3)
        .map(|value| value & !3)
        .ok_or(EmbeddedArchiveError::Truncated)
}

fn validate_path(path: &str) -> Result<(), EmbeddedArchiveError> {
    if path.is_empty() || path == "." || path.starts_with('/') || path.ends_with('/') {
        return Err(EmbeddedArchiveError::InvalidPath);
    }
    if path
        .split('/')
        .any(|component| component.is_empty() || component == "." || component == "..")
    {
        return Err(EmbeddedArchiveError::InvalidPath);
    }
    Ok(())
}

struct BuildNode {
    kind: EmbeddedEntryKind,
    permissions: u16,
    data: &'static [u8],
    explicit: bool,
    children: BTreeMap<String, BuildNode>,
}

impl BuildNode {
    fn root() -> Self {
        Self {
            kind: EmbeddedEntryKind::Directory,
            permissions: 0o755,
            data: &[],
            explicit: true,
            children: BTreeMap::new(),
        }
    }

    fn implicit_directory() -> Self {
        Self {
            kind: EmbeddedEntryKind::Directory,
            permissions: 0o755,
            data: &[],
            explicit: false,
            children: BTreeMap::new(),
        }
    }

    fn insert(&mut self, entry: EmbeddedEntry<'static>) -> Result<(), EmbeddedArchiveError> {
        let mut components = entry.path.split('/').peekable();
        let mut parent = self;
        while let Some(component) = components.next() {
            let is_leaf = components.peek().is_none();
            if is_leaf {
                let node = parent
                    .children
                    .entry(component.to_string())
                    .or_insert_with(Self::implicit_directory);
                if node.explicit
                    || (!node.children.is_empty() && entry.kind != EmbeddedEntryKind::Directory)
                {
                    return Err(EmbeddedArchiveError::PathConflict);
                }
                node.kind = entry.kind;
                node.permissions = entry.permissions;
                node.data = entry.data;
                node.explicit = true;
            } else {
                let node = parent
                    .children
                    .entry(component.to_string())
                    .or_insert_with(Self::implicit_directory);
                if node.kind != EmbeddedEntryKind::Directory {
                    return Err(EmbeddedArchiveError::PathConflict);
                }
                parent = node;
            }
        }
        Ok(())
    }

    fn freeze(self, next_inode: &mut u64) -> Arc<EmbeddedNode> {
        let inode = *next_inode;
        *next_inode += 1;
        let children = self
            .children
            .into_iter()
            .map(|(name, child)| (name, child.freeze(next_inode)))
            .collect();
        Arc::new(EmbeddedNode {
            inode,
            kind: self.kind,
            permissions: self.permissions,
            data: self.data,
            children,
        })
    }
}

struct EmbeddedNode {
    inode: u64,
    kind: EmbeddedEntryKind,
    permissions: u16,
    data: &'static [u8],
    children: BTreeMap<String, Arc<EmbeddedNode>>,
}

impl EmbeddedNode {
    fn node_type(&self) -> NodeType {
        match self.kind {
            EmbeddedEntryKind::Directory => NodeType::Directory,
            EmbeddedEntryKind::RegularFile => NodeType::RegularFile,
            EmbeddedEntryKind::Symlink => NodeType::Symlink,
        }
    }

    fn metadata(&self) -> Metadata {
        let size = self.data.len() as u64;
        Metadata {
            device: 0,
            inode: self.inode,
            nlink: if self.kind == EmbeddedEntryKind::Directory {
                2 + self
                    .children
                    .values()
                    .filter(|child| child.kind == EmbeddedEntryKind::Directory)
                    .count() as u64
            } else {
                1
            },
            mode: NodePermission::from_bits_truncate(self.permissions),
            node_type: self.node_type(),
            uid: 0,
            gid: 0,
            size,
            block_size: 4096,
            blocks: size.div_ceil(512),
            rdev: DeviceId::default(),
            atime: Duration::ZERO,
            mtime: Duration::ZERO,
            ctime: Duration::ZERO,
        }
    }
}

struct EmbeddedFilesystem {
    root: OnceLock<DirEntry>,
    entry_count: u64,
}

impl FilesystemOps for EmbeddedFilesystem {
    fn name(&self) -> &str {
        "embedded-cpio"
    }

    fn is_readonly(&self) -> bool {
        true
    }

    fn root_dir(&self) -> DirEntry {
        self.root.get().expect("embedded root not initialized").clone()
    }

    fn stat(&self) -> VfsResult<StatFs> {
        Ok(StatFs {
            fs_type: 0x71c7,
            block_size: 4096,
            blocks: 0,
            blocks_free: 0,
            blocks_available: 0,
            file_count: self.entry_count,
            free_file_count: 0,
            name_length: MAX_NAME_LEN as u32,
            fragment_size: 4096,
            mount_flags: 1,
        })
    }
}

struct EmbeddedDir {
    fs: Arc<EmbeddedFilesystem>,
    this: WeakDirEntry,
    node: Arc<EmbeddedNode>,
}

impl EmbeddedDir {
    fn entry(&self, name: &str, node: Arc<EmbeddedNode>) -> DirEntry {
        let reference = Reference::new(self.this.upgrade(), name.to_string());
        match node.kind {
            EmbeddedEntryKind::Directory => DirEntry::new_dir(
                |this| {
                    DirNode::new(Arc::new(Self {
                        fs: self.fs.clone(),
                        this,
                        node,
                    }))
                },
                reference,
            ),
            EmbeddedEntryKind::RegularFile | EmbeddedEntryKind::Symlink => {
                let node_type = node.node_type();
                DirEntry::new_file(
                    FileNode::new(Arc::new(EmbeddedFile {
                        fs: self.fs.clone(),
                        node,
                    })),
                    node_type,
                    reference,
                )
            }
        }
    }
}

impl NodeOps for EmbeddedDir {
    fn inode(&self) -> u64 {
        self.node.inode
    }

    fn metadata(&self) -> VfsResult<Metadata> {
        Ok(self.node.metadata())
    }

    fn update_metadata(&self, _update: MetadataUpdate) -> VfsResult<()> {
        Err(VfsError::ReadOnlyFilesystem)
    }

    fn filesystem(&self) -> &dyn FilesystemOps {
        &*self.fs
    }

    fn sync(&self, _data_only: bool) -> VfsResult<()> {
        Ok(())
    }

    fn into_any(self: Arc<Self>) -> Arc<dyn Any + Send + Sync> {
        self
    }
}

impl DirNodeOps for EmbeddedDir {
    fn read_dir(&self, offset: u64, sink: &mut dyn DirEntrySink) -> VfsResult<usize> {
        let this = self.this.upgrade().ok_or(VfsError::NotFound)?;
        let parent_inode = this.parent().map_or(self.node.inode, |parent| parent.inode());
        let mut entries = Vec::with_capacity(self.node.children.len() + 2);
        entries.push((DOT, self.node.inode, NodeType::Directory));
        entries.push((DOTDOT, parent_inode, NodeType::Directory));
        entries.extend(
            self.node
                .children
                .iter()
                .map(|(name, child)| (name.as_str(), child.inode, child.node_type())),
        );

        let mut count = 0;
        for (index, (name, inode, node_type)) in entries.into_iter().enumerate().skip(offset as usize)
        {
            if !sink.accept(name, inode, node_type, index as u64 + 1) {
                break;
            }
            count += 1;
        }
        Ok(count)
    }

    fn lookup(&self, name: &str) -> VfsResult<DirEntry> {
        let this = self.this.upgrade().ok_or(VfsError::NotFound)?;
        match name {
            DOT => Ok(this),
            DOTDOT => Ok(this.parent().unwrap_or(this)),
            _ => self
                .node
                .children
                .get(name)
                .cloned()
                .map(|node| self.entry(name, node))
                .ok_or(VfsError::NotFound),
        }
    }

    fn create(
        &self,
        _name: &str,
        _node_type: NodeType,
        _permission: NodePermission,
        _uid: u32,
        _gid: u32,
    ) -> VfsResult<DirEntry> {
        Err(VfsError::ReadOnlyFilesystem)
    }

    fn link(&self, _name: &str, _node: &DirEntry) -> VfsResult<DirEntry> {
        Err(VfsError::ReadOnlyFilesystem)
    }

    fn unlink(&self, _name: &str, _is_dir: bool) -> VfsResult<()> {
        Err(VfsError::ReadOnlyFilesystem)
    }

    fn rename(&self, _src_name: &str, _dst_dir: &DirNode, _dst_name: &str) -> VfsResult<()> {
        Err(VfsError::ReadOnlyFilesystem)
    }
}

struct EmbeddedFile {
    fs: Arc<EmbeddedFilesystem>,
    node: Arc<EmbeddedNode>,
}

impl NodeOps for EmbeddedFile {
    fn inode(&self) -> u64 {
        self.node.inode
    }

    fn metadata(&self) -> VfsResult<Metadata> {
        Ok(self.node.metadata())
    }

    fn update_metadata(&self, _update: MetadataUpdate) -> VfsResult<()> {
        Err(VfsError::ReadOnlyFilesystem)
    }

    fn filesystem(&self) -> &dyn FilesystemOps {
        &*self.fs
    }

    fn len(&self) -> VfsResult<u64> {
        Ok(self.node.data.len() as u64)
    }

    fn sync(&self, _data_only: bool) -> VfsResult<()> {
        Ok(())
    }

    fn into_any(self: Arc<Self>) -> Arc<dyn Any + Send + Sync> {
        self
    }

    fn flags(&self) -> NodeFlags {
        NodeFlags::NON_CACHEABLE
    }
}

impl FsPollable for EmbeddedFile {
    fn poll(&self) -> FsIoEvents {
        FsIoEvents::IN
    }

    fn register(&self, _context: &mut Context<'_>, _events: FsIoEvents) {}
}

impl FileNodeOps for EmbeddedFile {
    fn read_at(&self, buf: &mut [u8], offset: u64) -> VfsResult<usize> {
        let start = usize::try_from(offset).map_err(|_| VfsError::InvalidInput)?;
        if start >= self.node.data.len() {
            return Ok(0);
        }
        let data = &self.node.data[start..];
        let read = data.len().min(buf.len());
        buf[..read].copy_from_slice(&data[..read]);
        Ok(read)
    }

    fn write_at(&self, _buf: &[u8], _offset: u64) -> VfsResult<usize> {
        Err(VfsError::ReadOnlyFilesystem)
    }

    fn append(&self, _buf: &[u8]) -> VfsResult<(usize, u64)> {
        Err(VfsError::ReadOnlyFilesystem)
    }

    fn set_len(&self, _len: u64) -> VfsResult<()> {
        Err(VfsError::ReadOnlyFilesystem)
    }

    fn set_symlink(&self, _target: &str) -> VfsResult<()> {
        Err(VfsError::ReadOnlyFilesystem)
    }
}

/// Builds a read-only filesystem over a statically embedded newc CPIO archive.
pub fn new_filesystem(
    archive: &'static [u8],
) -> Result<Filesystem, EmbeddedArchiveError> {
    let entries = parse_newc(archive)?;
    let mut root = BuildNode::root();
    for entry in entries {
        root.insert(entry)?;
    }
    let mut next_inode = 1;
    let root_node = root.freeze(&mut next_inode);
    let fs = Arc::new(EmbeddedFilesystem {
        root: OnceLock::new(),
        entry_count: next_inode - 1,
    });
    let root_entry = DirEntry::new_dir(
        |this| {
            DirNode::new(Arc::new(EmbeddedDir {
                fs: fs.clone(),
                this,
                node: root_node,
            }))
        },
        Reference::root(),
    );
    fs.root.call_once(|| root_entry);
    Ok(Filesystem::new(fs))
}
