use crate::{Result, err, io_error, unsupported};
use hwp_model::Document;
use hwp5::Hwp5Container;
use hwp5::codec::compress;
use hwp5::record::{
    RecordNode, RecordScanBudget, RecordScanLimits, ScanMode, scan_stream_bounded, tag,
};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::Path,
};

const MAX_SECTION_BYTES: u64 = 16 * 1024 * 1024;
const PREVIEW_TEXT: &str = "/PrvText";

pub(crate) struct SectionPatch {
    before_sha256: [u8; 32],
    records: Vec<u8>,
}

impl SectionPatch {
    pub(crate) fn new(before_sha256: [u8; 32], roots: &[RecordNode]) -> Result<Self> {
        let records = RecordNode::serialize_forest(roots);
        if records.len() as u64 > MAX_SECTION_BYTES {
            return Err(unsupported());
        }
        Ok(Self {
            before_sha256,
            records,
        })
    }
}

pub(crate) fn open_editable(source: &Path, doc: &Document) -> Result<Hwp5Container> {
    let container = Hwp5Container::open(source).map_err(|_| unsupported())?;
    let header = container.file_header();
    // History, privacy protection and change tracking can reference edited records.
    if header.is_distribution()
        || header.attributes & ((1 << 6) | (1 << 13) | (1 << 14)) != 0
        || doc.sections.is_empty()
        || doc.sections.len() > 256
    {
        return Err(unsupported());
    }
    container.check_body_readable().map_err(|_| unsupported())?;
    let streams = container
        .list_streams_bounded(4096, 1024 * 1024)
        .map_err(|_| unsupported())?;
    let actual: BTreeSet<_> = streams
        .iter()
        .filter(|entry| entry.path.starts_with("/BodyText/Section"))
        .map(|entry| entry.path.clone())
        .collect();
    if actual != (0..doc.sections.len()).map(section_path).collect() {
        return Err(unsupported());
    }
    Ok(container)
}

pub(crate) fn read_section(
    container: &mut Hwp5Container,
    section: usize,
) -> Result<(Vec<u8>, Vec<RecordNode>)> {
    let data = container
        .read_record_stream_bounded(&section_path(section), MAX_SECTION_BYTES)
        .map_err(|_| unsupported())?;
    let mut budget = RecordScanBudget::new(RecordScanLimits {
        max_records: 100_000,
        max_depth: 48,
        max_allocation_bytes: 64 * 1024 * 1024,
    });
    let records =
        scan_stream_bounded(&data, ScanMode::Strict, &mut budget).map_err(|_| unsupported())?;
    // Require exact round-trip before altering any node in the section.
    if RecordNode::serialize_forest(&records.roots) != data {
        return Err(unsupported());
    }
    Ok((data, records.roots))
}

pub(crate) fn collect_ids(nodes: &[RecordNode], ids: &mut BTreeSet<u32>) {
    for node in nodes {
        if node.tag == tag::PARA_HEADER
            && let Some(value) = node.data.get(18..22)
        {
            ids.insert(u32::from_le_bytes(
                value.try_into().expect("four instance bytes"),
            ));
        }
        collect_ids(&node.children, ids);
    }
}

pub(crate) fn write_sections<'a>(
    source: &Path,
    output: &Path,
    expected: &Document,
    sections: impl IntoIterator<Item = (usize, &'a SectionPatch)>,
) -> Result<()> {
    let patches: BTreeMap<_, _> = sections
        .into_iter()
        .map(|(id, patch)| (section_path(id), patch))
        .collect();
    let mut before = open_editable(source, expected)?;
    for (path, patch) in &patches {
        let old = before
            .read_record_stream_bounded(path, MAX_SECTION_BYTES)
            .map_err(|_| unsupported())?;
        if <[u8; 32]>::from(Sha256::digest(old)) != patch.before_sha256 {
            return Err(err("source_changed", "한글 문서 구역이 바뀌었습니다."));
        }
    }
    let compressed = before.file_header().is_compressed();
    let preview = before
        .list_streams()
        .iter()
        .any(|entry| entry.path == PREVIEW_TEXT)
        .then(|| {
            expected
                .plain_text()
                .chars()
                .take(1000)
                .collect::<String>()
                .encode_utf16()
                .flat_map(u16::to_le_bytes)
                .collect::<Vec<_>>()
        });
    let pending = output.with_extension("hwp.pending");
    let mut copy = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&pending)
        .map_err(io_error)?;
    let result = (|| {
        io::copy(&mut File::open(source).map_err(io_error)?, &mut copy).map_err(io_error)?;
        drop(copy);
        {
            let mut file = cfb::open_rw(&pending).map_err(io_error)?;
            for (path, patch) in &patches {
                let encoded;
                let bytes = if compressed {
                    encoded = compress(&patch.records);
                    &encoded
                } else {
                    &patch.records
                };
                file.create_stream(path)
                    .map_err(io_error)?
                    .write_all(bytes)
                    .map_err(io_error)?;
            }
            if let Some(text) = &preview {
                file.create_stream(PREVIEW_TEXT)
                    .map_err(io_error)?
                    .write_all(text)
                    .map_err(io_error)?;
            }
            file.flush().map_err(io_error)?;
        }
        let mut after = Hwp5Container::open(&pending).map_err(|_| mismatch())?;
        let old_streams = before.list_streams();
        let new_streams = after.list_streams();
        if before.list_storages() != after.list_storages()
            || old_streams
                .iter()
                .map(|entry| &entry.path)
                .ne(new_streams.iter().map(|entry| &entry.path))
        {
            return Err(mismatch());
        }
        for entry in old_streams {
            let path = &entry.path;
            if let Some(patch) = patches.get(path) {
                if after
                    .read_record_stream_bounded(path, MAX_SECTION_BYTES)
                    .map_err(|_| mismatch())?
                    != patch.records
                {
                    return Err(mismatch());
                }
            } else {
                let old;
                let wanted = if path == PREVIEW_TEXT {
                    preview.as_deref().ok_or_else(mismatch)?
                } else {
                    old = before.read_stream_raw(path).map_err(|_| mismatch())?;
                    &old
                };
                if after.read_stream_raw(path).map_err(|_| mismatch())? != wanted {
                    return Err(mismatch());
                }
            }
        }
        if output.try_exists().map_err(io_error)? {
            return Err(mismatch());
        }
        fs::rename(&pending, output).map_err(io_error)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&pending);
    }
    result
}

fn section_path(section: usize) -> String {
    format!("/BodyText/Section{section}")
}

fn mismatch() -> crate::ApiError {
    err(
        "semantic_mismatch",
        "저장한 한글 문서의 원본 보존 내용을 확인하지 못했습니다.",
    )
}
