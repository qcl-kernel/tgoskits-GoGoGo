use ax_fs_ng::embedded::{EmbeddedEntryKind, parse_newc};

fn align4(value: usize) -> usize {
    (value + 3) & !3
}

fn append_entry(archive: &mut Vec<u8>, name: &str, mode: u32, data: &[u8]) {
    let namesize = name.len() + 1;
    let fields = [
        1, mode, 0, 0, 1, 0, data.len() as u32, 0, 0, 0, 0, namesize as u32, 0,
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

    let duplicate = archive(&[
        ("init", 0o100755, b"a"),
        ("init", 0o100755, b"b"),
    ]);
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
