//! Read-only embedded root filesystem support.

use alloc::{collections::BTreeSet, string::String, vec::Vec};
use core::{fmt, str};

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
