use jni_sys::{JNIEnv, jbyteArray, jclass, jint};
use std::{fs, path::Path};

const MAX_FILE_BYTES: u64 = 128 * 1024 * 1024;
const MAX_PATH_UTF8_BYTES: jint = 128 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
enum Family {
    Unknown = 0,
    Word = 1,
    Presentation = 2,
}

fn classify(path: &Path) -> Option<Family> {
    if !fs::symlink_metadata(path).ok()?.is_file() {
        return None;
    }
    let file = fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    let length = metadata.len();
    if !metadata.is_file() || !(1..=MAX_FILE_BYTES).contains(&length) {
        return None;
    }

    let container = cfb::CompoundFile::open(file).ok()?;
    let root_stream_length = |name| {
        container
            .entry(name)
            .ok()
            .filter(cfb::Entry::is_stream)
            .map(|entry| entry.len())
    };
    match (
        root_stream_length("/WordDocument"),
        root_stream_length("/PowerPoint Document"),
    ) {
        (Some(size), None) if (1..=length).contains(&size) => Some(Family::Word),
        (None, Some(size)) if (1..=length).contains(&size) => Some(Family::Presentation),
        _ => None,
    }
}

/// # Safety
/// The JVM supplies a valid environment for this thread and a byte array or null.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_io_github_canele452_personalinkvault_office_OfficeLegacyContainer_classifyNative(
    env: *mut JNIEnv,
    _class: jclass,
    path_utf8: jbyteArray,
) -> jint {
    std::panic::catch_unwind(|| {
        if path_utf8.is_null() {
            return None;
        }
        // SAFETY: The JVM owns the JNI table, and this local array lives for the call.
        let functions = unsafe { &**env };
        let length = unsafe { functions.GetArrayLength?(env, path_utf8) };
        if !(1..=MAX_PATH_UTF8_BYTES).contains(&length) {
            return None;
        }
        let mut bytes = vec![0u8; length as usize];
        // SAFETY: The region covers the full array and the destination holds that many bytes.
        unsafe {
            functions.GetByteArrayRegion?(env, path_utf8, 0, length, bytes.as_mut_ptr().cast());
            if functions.ExceptionCheck?(env) != 0 {
                return None;
            }
        }
        let path = std::str::from_utf8(&bytes).ok()?;
        classify(Path::new(path))
    })
    .ok()
    .flatten()
    .unwrap_or(Family::Unknown) as jint
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn fixture(path: &Path, streams: &[(&str, &[u8])]) {
        let mut container = cfb::create(path).unwrap();
        container.create_storage("/Embedded").unwrap();
        for (name, bytes) in streams {
            container
                .create_stream(name)
                .unwrap()
                .write_all(bytes)
                .unwrap();
        }
        container.flush().unwrap();
    }

    #[test]
    fn classifies_root_streams_without_using_the_extension() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("문서-📄.ppt");
        fixture(
            &path,
            &[
                ("/WordDocument", b"word"),
                ("/Embedded/PowerPoint Document", b"presentation"),
            ],
        );
        assert_eq!(classify(&path), Some(Family::Word));

        let path = folder.path().join("slides.doc");
        fixture(
            &path,
            &[
                ("/PowerPoint Document", b"presentation"),
                ("/Embedded/WordDocument", b"word"),
            ],
        );
        assert_eq!(classify(&path), Some(Family::Presentation));
    }

    #[test]
    fn rejects_ambiguous_nested_empty_and_corrupt_containers() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("unknown.doc");
        for streams in [
            &[
                ("/WordDocument", b"word".as_slice()),
                ("/PowerPoint Document", b"presentation".as_slice()),
            ][..],
            &[
                ("/WordDocument", b"word".as_slice()),
                ("/PowerPoint Document", b"".as_slice()),
            ][..],
            &[("/Embedded/WordDocument", b"word".as_slice())][..],
            &[("/PowerPoint Document", b"".as_slice())][..],
        ] {
            fixture(&path, streams);
            assert_eq!(classify(&path), None);
        }
        fs::write(&path, [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]).unwrap();
        assert_eq!(classify(&path), None);
        assert_eq!(classify(folder.path()), None);
    }
}
