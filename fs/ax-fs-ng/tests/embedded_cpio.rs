use ax_fs_ng::embedded::{EmbeddedArchiveError, EmbeddedEntryKind, new_filesystem, parse_newc};
use axfs_ng_vfs::{MetadataUpdate, NodePermission, NodeType, VfsError};

fn align4(value: usize) -> usize {
    (value + 3) & !3
}

fn append_entry(archive: &mut Vec<u8>, name: &str, mode: u32, data: &[u8]) {
    let namesize = name.len() + 1;
    let fields = [
        1,
        mode,
        0,
        0,
        1,
        0,
        data.len() as u32,
        0,
        0,
        0,
        0,
        namesize as u32,
        0,
    ];
    archive.extend_from_slice(b"070701");
    for field in fields {
        archive.extend_from_slice(format!("{field:08x}").as_bytes());
    }
    archive.extend_from_slice(name.as_bytes());
    archive.push(0);
    archive.resize(align4(archive.len()), 0);
    archive.extend_from_slice(data);
    archive.resize(align4(archive.len()), 0);
}

fn archive(entries: &[(&str, u32, &[u8])]) -> Vec<u8> {
    let mut result = Vec::new();
    for (name, mode, data) in entries {
        append_entry(&mut result, name, *mode, data);
    }
    append_entry(&mut result, "TRAILER!!!", 0, &[]);
    result
}

#[test]
fn parses_directories_files_symlinks_and_modes() {
    let bytes = archive(&[
        ("bin", 0o040755, &[]),
        ("bin/init", 0o100755, b"ELF"),
        ("bin/sh", 0o120777, b"init"),
    ]);

    let entries = parse_newc(&bytes).unwrap();

    assert_eq!(entries.len(), 3);
    assert_eq!(entries[0].path(), "bin");
    assert_eq!(entries[0].kind(), EmbeddedEntryKind::Directory);
    assert_eq!(entries[0].permissions(), 0o755);
    assert_eq!(entries[1].kind(), EmbeddedEntryKind::RegularFile);
    assert_eq!(entries[1].permissions(), 0o755);
    assert_eq!(entries[1].data(), b"ELF");
    assert_eq!(entries[2].kind(), EmbeddedEntryKind::Symlink);
    assert_eq!(entries[2].data(), b"init");
}

#[test]
fn rejects_unsafe_and_duplicate_paths() {
    for name in ["/init", "../init", "bin/../init", "bin//init", "."] {
        let bytes = archive(&[(name, 0o100755, b"x")]);
        assert!(parse_newc(&bytes).is_err(), "unsafe path accepted: {name}");
    }

    let duplicate = archive(&[("init", 0o100755, b"a"), ("init", 0o100755, b"b")]);
    assert!(parse_newc(&duplicate).is_err());
}

#[test]
fn rejects_truncated_and_malformed_archives() {
    let valid = archive(&[("init", 0o100755, b"payload")]);
    for length in [0, 5, 109, valid.len() - 1] {
        assert!(parse_newc(&valid[..length]).is_err());
    }

    let mut bad_magic = valid;
    bad_magic[0] = b'1';
    assert!(parse_newc(&bad_magic).is_err());
}

#[test]
fn exposes_archive_as_read_only_filesystem() {
    let bytes = Box::leak(
        archive(&[
            ("bin", 0o040755, &[]),
            ("bin/init", 0o100755, b"ELF payload"),
            ("bin/sh", 0o120777, b"init"),
        ])
        .into_boxed_slice(),
    );

    let fs = new_filesystem(bytes).unwrap();
    assert!(fs.is_readonly());
    assert_eq!(fs.name(), "embedded-cpio");

    let root = fs.root_dir();
    let bin = root.as_dir().unwrap().lookup("bin").unwrap();
    assert_eq!(bin.node_type(), NodeType::Directory);
    assert_eq!(bin.metadata().unwrap().mode.bits(), 0o755);

    let init = bin.as_dir().unwrap().lookup("init").unwrap();
    assert_eq!(init.node_type(), NodeType::RegularFile);
    assert_eq!(init.metadata().unwrap().mode.bits(), 0o755);
    let mut payload = [0u8; 16];
    let read = init.as_file().unwrap().read_at(&mut payload, 4).unwrap();
    assert_eq!(&payload[..read], b"payload");

    let sh = bin.as_dir().unwrap().lookup("sh").unwrap();
    assert_eq!(sh.node_type(), NodeType::Symlink);
    let mut target = [0u8; 8];
    let read = sh.as_file().unwrap().read_at(&mut target, 0).unwrap();
    assert_eq!(&target[..read], b"init");

    assert_eq!(
        init.update_metadata(MetadataUpdate {
            mode: Some(NodePermission::from_bits_truncate(0o700)),
            ..MetadataUpdate::default()
        }),
        Err(VfsError::ReadOnlyFilesystem)
    );
    assert_eq!(
        init.as_file().unwrap().write_at(b"x", 0),
        Err(VfsError::ReadOnlyFilesystem)
    );
    assert!(matches!(
        root.as_dir().unwrap().create(
            "tmp",
            NodeType::Directory,
            NodePermission::from_bits_truncate(0o755),
            0,
            0,
        ),
        Err(VfsError::ReadOnlyFilesystem)
    ));
}

#[test]
fn creates_implicit_directories_and_rejects_path_conflicts() {
    let implicit = Box::leak(archive(&[("usr/bin/tool", 0o100755, b"tool")]).into_boxed_slice());
    let fs = new_filesystem(implicit).unwrap();
    let usr = fs.root_dir().as_dir().unwrap().lookup("usr").unwrap();
    let bin = usr.as_dir().unwrap().lookup("bin").unwrap();
    assert!(bin.as_dir().unwrap().lookup("tool").is_ok());

    let conflict = Box::leak(
        archive(&[
            ("usr", 0o100755, b"file"),
            ("usr/bin/tool", 0o100755, b"tool"),
        ])
        .into_boxed_slice(),
    );
    assert!(matches!(
        new_filesystem(conflict),
        Err(EmbeddedArchiveError::PathConflict)
    ));
}
