use hwp_model::{Document, HwpChar, Paragraph};
use ink_hwp_native::request_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};
use tempfile::TempDir;

const TARGET: &str = "원문 정렬 경계";
const OTHER: &str = "다른 문단 보존";

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn text(paragraph: &Paragraph) -> String {
    paragraph
        .chars
        .iter()
        .filter_map(|item| match item {
            HwpChar::Text(value) => Some(*value),
            HwpChar::CharCtrl(10) => Some('\n'),
            HwpChar::InlineCtrl { code: 9, .. } => Some('\t'),
            _ => None,
        })
        .collect()
}

fn target_index(document: &Document) -> usize {
    document.sections[0]
        .paragraphs
        .iter()
        .position(|paragraph| text(paragraph) == TARGET)
        .unwrap()
}

fn call(value: Value) -> Value {
    request_json(&value.to_string())
}

fn inspect(source: &Path) -> Value {
    let result = call(json!({"mode":"inspect", "sourcePath":source}));
    assert!(
        result.get("error").is_none(),
        "Boundary fixture must reach native inspect: {result}"
    );
    result["snapshot"].clone()
}

fn format(source: &Path, output: &Path, paragraph: &Value, alignment: &str) -> Value {
    call(json!({
        "mode":"apply", "sourcePath":source, "outputDirectory":output,
        "expectedSourceSha256":hash(&fs::read(source).unwrap()), "sessionId":"alignment-boundary",
        "fontDirectories":[Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build/native/fonts")],
        "operations":[{"op":"paragraphFormat", "id":paragraph["id"],
            "expectedTextSha256":hash(paragraph["text"].as_str().unwrap().as_bytes()), "alignment":alignment}]
    }))
}

fn target(snapshot: &Value) -> Value {
    snapshot["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|paragraph| paragraph["text"] == TARGET)
        .unwrap()
        .clone()
}

fn docinfo(source: &Path) -> Vec<hwp5::record::RecordNode> {
    let mut container = hwp5::Hwp5Container::open(source).unwrap();
    let raw = container.read_record_stream("/DocInfo").unwrap();
    hwp5::record::scan_stream(&raw, hwp5::record::ScanMode::Strict)
        .unwrap()
        .roots
}

fn shapes(nodes: &[hwp5::record::RecordNode], output: &mut Vec<Vec<u8>>) {
    for node in nodes {
        if node.tag == hwp5::record::tag::PARA_SHAPE {
            output.push(node.data.clone());
        }
        shapes(&node.children, output);
    }
}

fn raw_shapes(source: &Path) -> Vec<Vec<u8>> {
    let mut result = Vec::new();
    shapes(&docinfo(source), &mut result);
    result
}

fn zero_numbering_id(nodes: &mut [hwp5::record::RecordNode], remaining: &mut usize) -> bool {
    for node in nodes {
        if node.tag == hwp5::record::tag::PARA_SHAPE {
            if *remaining == 0 {
                assert_eq!(u16::from_le_bytes(node.data[30..32].try_into().unwrap()), 1);
                node.data[30..32].copy_from_slice(&0u16.to_le_bytes());
                return true;
            }
            *remaining -= 1;
        }
        if zero_numbering_id(&mut node.children, remaining) {
            return true;
        }
    }
    false
}

fn ambiguous_reuse_fixture() -> (TempDir, PathBuf, usize, usize) {
    let directory = TempDir::new().unwrap();
    let source = directory.path().join("reuse-original.hwp");
    let mut document = hwp_convert::from_markdown(&format!("1. {TARGET}\n2. {OTHER}\n"));
    let target = target_index(&document);
    let other = document.sections[0]
        .paragraphs
        .iter()
        .position(|paragraph| text(paragraph) == OTHER)
        .unwrap();
    let source_id = document.sections[0].paragraphs[target].para_shape.0 as usize;
    let mut right = document.header.para_shapes[source_id].clone();
    assert_eq!(
        right.head_type(),
        2,
        "The fixture must use numbered source paragraphs"
    );
    assert_eq!(right.numbering_id, 0);
    assert_ne!(right.alignment(), 2);
    right.attr1 = (right.attr1 & !(7 << 2)) | (2 << 2);
    let candidate_id = document.header.para_shapes.len();
    document.header.para_shapes.push(right);
    document.sections[0].paragraphs[other].para_shape = hwp_model::ParaShapeId(candidate_id as u16);
    hwp5::write_document_with_report(&document, &source, &hwp5::WriteOptions::default()).unwrap();

    let before = raw_shapes(&source);
    let mut nodes = docinfo(&source);
    let mut remaining = source_id;
    assert!(zero_numbering_id(&mut nodes, &mut remaining));
    let encoded = hwp5::codec::compress(&hwp5::record::RecordNode::serialize_forest(&nodes));
    let mut container = cfb::open_rw(&source).unwrap();
    container
        .create_stream("/DocInfo")
        .unwrap()
        .write_all(&encoded)
        .unwrap();
    container.flush().unwrap();
    drop(container);
    let after = raw_shapes(&source);
    assert_eq!(before.len(), after.len());
    for (index, (left, right)) in before.iter().zip(&after).enumerate() {
        if index == source_id {
            let mut expected = left.clone();
            expected[30..32].copy_from_slice(&0u16.to_le_bytes());
            assert_eq!(
                right, &expected,
                "Only the target raw numbering sentinel changes"
            );
        } else {
            assert_eq!(left, right, "Unrelated fixture shape changed");
        }
    }
    (directory, source, source_id, candidate_id)
}

#[test]
fn hwp_existing_shape_reuse_preserves_original_raw_source_fields() {
    let (directory, source, source_id, candidate_id) = ambiguous_reuse_fixture();
    let bytes = fs::read(&source).unwrap();
    let parsed = hwp5::read_document(&source).unwrap();
    assert!(
        parsed.warnings.is_empty(),
        "Upstream fixture must be accepted without parser warnings: {:?}",
        parsed.warnings
    );
    let target_index = target_index(&parsed.document);
    assert_eq!(
        parsed.document.sections[0].paragraphs[target_index]
            .para_shape
            .0 as usize,
        source_id
    );
    let source_shape = &parsed.document.header.para_shapes[source_id];
    let existing_shape = &parsed.document.header.para_shapes[candidate_id];
    let mut changed = source_shape.clone();
    changed.attr1 = (changed.attr1 & !(7 << 2)) | (2 << 2);
    assert_eq!(
        &changed, existing_shape,
        "The raw0/raw1 normalization must collide in the actual pinned IR"
    );
    let raw = raw_shapes(&source);
    let mut expected = raw[source_id].clone();
    let attr = u32::from_le_bytes(expected[..4].try_into().unwrap());
    expected[..4].copy_from_slice(&((attr & !(7 << 2)) | (2 << 2)).to_le_bytes());
    assert_eq!(&expected[30..32], &[0, 0]);
    assert_eq!(&raw[candidate_id][30..32], &[1, 0]);
    assert_ne!(expected, raw[candidate_id]);

    let snapshot = inspect(&source);
    let paragraph = target(&snapshot);
    let advertised = paragraph.get("paragraphFormat").is_some();
    assert!(
        advertised,
        "The accepted fixture must advertise source-bound alignment"
    );
    println!(
        "HWP_BOUNDARY_REUSE parserWarnings=0 normalizedCollision=true alignmentAdvertised={advertised}"
    );
    let result = format(
        &source,
        &directory.path().join("edited"),
        &paragraph,
        "right",
    );
    assert_eq!(
        fs::read(&source).unwrap(),
        bytes,
        "The input file must remain unchanged"
    );
    assert_eq!(result["status"], "saved", "{result}");
    let output = Path::new(result["sourcePath"].as_str().unwrap());
    let reopened = hwp5::read_document(output).unwrap();
    assert!(reopened.warnings.is_empty());
    let target_id = reopened.document.sections[0].paragraphs[target_index]
        .para_shape
        .0 as usize;
    let after = raw_shapes(output);
    assert_eq!(
        after[target_id], expected,
        "A reused raw shape must equal the original target payload with only alignment bits changed; IR equality alone loses the raw numbering sentinel"
    );
}

fn cfb_streams(path: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut container = hwp5::Hwp5Container::open(path).unwrap();
    let entries = container.list_streams_bounded(128, 16 * 1024).unwrap();
    let mut streams = BTreeMap::new();
    for entry in entries {
        let bytes = container
            .read_stream_raw_bounded(&entry.path, 16 * 1024 * 1024)
            .unwrap();
        assert!(streams.insert(entry.path, bytes).is_none());
    }
    streams
}

#[test]
fn hwp_uncompressed_alignment_preserves_flag_raw_styles_and_unrelated_streams() {
    let (directory, source, source_id, _) = ambiguous_reuse_fixture();
    let mut compressed = hwp5::Hwp5Container::open(&source).unwrap();
    assert!(compressed.file_header().is_compressed());
    let mut header = compressed.file_header().clone();
    let header_before = compressed
        .read_stream_raw_bounded("/FileHeader", 256)
        .unwrap();
    assert_eq!(
        header.serialize(),
        header_before,
        "Public header serialization must preserve this fixture before changing its compression bit"
    );
    header.attributes &= !1;
    let header_after = header.serialize();
    assert!(
        !hwp5::FileHeader::parse(&header_after)
            .unwrap()
            .is_compressed()
    );
    let entries = compressed.list_streams_bounded(128, 16 * 1024).unwrap();
    let mut records = BTreeMap::new();
    for entry in entries {
        if hwp5::container::is_record_stream(&entry.path) {
            let raw = compressed
                .read_stream_raw_bounded(&entry.path, 16 * 1024 * 1024)
                .unwrap();
            let decoded =
                hwp5::codec::decompress_bounded(&raw, &entry.path, 16 * 1024 * 1024).unwrap();
            assert_eq!(
                decoded,
                compressed
                    .read_record_stream_bounded(&entry.path, 16 * 1024 * 1024)
                    .unwrap()
            );
            assert!(records.insert(entry.path, decoded).is_none());
        }
    }
    assert!(records.contains_key("/DocInfo"));
    assert!(records.contains_key("/BodyText/Section0"));
    drop(compressed);
    let mut writable = cfb::open_rw(&source).unwrap();
    for (path, raw) in &records {
        writable
            .create_stream(path)
            .unwrap()
            .write_all(raw)
            .unwrap();
    }
    writable
        .create_stream("/FileHeader")
        .unwrap()
        .write_all(&header_after)
        .unwrap();
    writable.flush().unwrap();
    drop(writable);

    let bytes = fs::read(&source).unwrap();
    let before = cfb_streams(&source);
    assert_eq!(before["/FileHeader"], header_after);
    for (path, raw) in &records {
        assert_eq!(
            &before[path], raw,
            "The uncompressed fixture must contain raw record bytes: {path}"
        );
    }
    let original_container = hwp5::Hwp5Container::open(&source).unwrap();
    assert_eq!(original_container.file_header().attributes & 1, 0);
    assert!(!original_container.file_header().is_compressed());
    let storages = original_container.list_storages();
    drop(original_container);
    let parsed = hwp5::read_document(&source).unwrap();
    assert!(
        parsed.warnings.is_empty(),
        "The uncompressed fixture must be accepted without parser warnings: {:?}",
        parsed.warnings
    );
    let index = target_index(&parsed.document);
    assert_eq!(
        parsed.document.sections[0].paragraphs[index].para_shape.0 as usize,
        source_id
    );
    let snapshot = inspect(&source);
    let paragraph = target(&snapshot);
    assert!(
        paragraph.get("paragraphFormat").is_some(),
        "The uncompressed fixture must expose alignment before applying it"
    );
    let result = format(
        &source,
        &directory.path().join("uncompressed-edited"),
        &paragraph,
        "center",
    );
    assert_eq!(result["status"], "saved", "{result}");
    let output = Path::new(result["sourcePath"].as_str().unwrap());
    assert_ne!(output, source);
    assert_eq!(output.extension(), source.extension());
    let reopened_container = hwp5::Hwp5Container::open(output).unwrap();
    assert!(!reopened_container.file_header().is_compressed());
    assert_eq!(
        reopened_container.file_header().attributes,
        header.attributes
    );
    assert_eq!(reopened_container.list_storages(), storages);
    drop(reopened_container);
    let reopened = hwp5::read_document(output).unwrap();
    assert!(reopened.warnings.is_empty(), "{:?}", reopened.warnings);
    assert_eq!(
        parsed.document.sections.len(),
        reopened.document.sections.len()
    );
    assert_eq!(
        parsed.document.sections[0].paragraphs.len(),
        reopened.document.sections[0].paragraphs.len()
    );
    let target_id = reopened.document.sections[0].paragraphs[index].para_shape.0 as usize;
    assert_eq!(
        reopened.document.header.para_shapes[target_id].alignment(),
        3
    );
    assert_eq!(
        text(&reopened.document.sections[0].paragraphs[index]),
        TARGET
    );
    let mut expected_paragraph = parsed.document.sections[0].paragraphs[index].clone();
    expected_paragraph.para_shape = reopened.document.sections[0].paragraphs[index].para_shape;
    expected_paragraph.line_segs.clear();
    assert_eq!(
        reopened.document.sections[0].paragraphs[index],
        expected_paragraph
    );
    for (paragraph_index, (original, edited)) in parsed.document.sections[0]
        .paragraphs
        .iter()
        .zip(&reopened.document.sections[0].paragraphs)
        .enumerate()
    {
        if paragraph_index != index {
            assert_eq!(original, edited, "Unrelated paragraph changed");
        }
    }
    let mut expected_shape = raw_shapes(&source)[source_id].clone();
    let attr = u32::from_le_bytes(expected_shape[..4].try_into().unwrap());
    expected_shape[..4].copy_from_slice(&((attr & !(7 << 2)) | (3 << 2)).to_le_bytes());
    assert_eq!(raw_shapes(output)[target_id], expected_shape);
    let after = cfb_streams(output);
    assert_eq!(
        before.keys().collect::<Vec<_>>(),
        after.keys().collect::<Vec<_>>()
    );
    for (path, raw) in &before {
        if !["/DocInfo", "/BodyText/Section0", "/PrvText"].contains(&path.as_str()) {
            assert_eq!(raw, &after[path], "Unrelated CFB stream changed: {path}");
        }
    }
    assert_eq!(
        fs::read(&source).unwrap(),
        bytes,
        "The uncompressed input file must remain unchanged"
    );
}

fn zip_entries(path: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    let mut entries = BTreeMap::new();
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).unwrap();
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes).unwrap();
        assert!(entries.insert(entry.name().to_owned(), bytes).is_none());
    }
    entries
}

#[test]
fn hwpx_alignment_preserves_cache_named_elements_inside_foreign_text_metadata() {
    const METADATA: &str =
        "<v:metadata xmlns:v=\"urn:piv-private\"><hp:linesegarray/></v:metadata>";
    let directory = TempDir::new().unwrap();
    let source = directory.path().join("metadata-original.hwpx");
    let document = hwp_convert::from_markdown(&format!("{TARGET}\n\n{OTHER}\n"));
    hwpx::write_document(&document, &source).unwrap();
    let original_entries = zip_entries(&source);
    let section = String::from_utf8(original_entries["Contents/section0.xml"].clone()).unwrap();
    assert!(section.contains("</hp:t>"));
    let changed = section.replacen("</hp:t>", &format!("{METADATA}</hp:t>"), 1);
    let temporary = directory.path().join("metadata-rewritten.hwpx");
    let mut input = zip::ZipArchive::new(fs::File::open(&source).unwrap()).unwrap();
    let mut output = zip::ZipWriter::new(fs::File::create(&temporary).unwrap());
    for index in 0..input.len() {
        let mut entry = input.by_index(index).unwrap();
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes).unwrap();
        output
            .start_file(
                entry.name(),
                zip::write::SimpleFileOptions::default().compression_method(entry.compression()),
            )
            .unwrap();
        output
            .write_all(if entry.name() == "Contents/section0.xml" {
                changed.as_bytes()
            } else {
                &bytes
            })
            .unwrap();
    }
    output.finish().unwrap();
    drop(input);
    fs::rename(&temporary, &source).unwrap();
    let source_bytes = fs::read(&source).unwrap();
    let before = zip_entries(&source);
    let parsed = hwpx::read_document(&source).unwrap();
    assert!(
        parsed.warnings.is_empty(),
        "Foreign inline metadata must reach the parser without warnings: {:?}",
        parsed.warnings
    );
    assert_eq!(
        text(&parsed.document.sections[0].paragraphs[target_index(&parsed.document)]),
        TARGET
    );
    let snapshot = inspect(&source);
    let paragraph = target(&snapshot);
    assert!(
        paragraph.get("paragraphFormat").is_some(),
        "The fixture must advertise source-bound alignment before applying: {snapshot}"
    );
    let result = format(
        &source,
        &directory.path().join("edited"),
        &paragraph,
        "center",
    );
    assert_eq!(result["status"], "saved", "{result}");
    let output = Path::new(result["sourcePath"].as_str().unwrap());
    let after = zip_entries(output);
    let reopened = hwpx::read_document(output).unwrap().document;
    let target_id = reopened.sections[0].paragraphs[target_index(&reopened)]
        .para_shape
        .0;
    let original_id = parsed.document.sections[0].paragraphs[target_index(&parsed.document)]
        .para_shape
        .0;
    let expected_section = changed.replacen(
        &format!("paraPrIDRef=\"{original_id}\""),
        &format!("paraPrIDRef=\"{target_id}\""),
        1,
    );
    let actual_section = std::str::from_utf8(&after["Contents/section0.xml"]).unwrap();
    assert!(
        actual_section.contains(METADATA),
        "An alignment edit must not delete a cache-named element inside opaque text metadata"
    );
    assert_eq!(
        actual_section, expected_section,
        "Only the target paragraph style reference may change in this source"
    );
    assert_eq!(
        before.keys().collect::<Vec<_>>(),
        after.keys().collect::<Vec<_>>()
    );
    for (name, bytes) in &before {
        if !["Contents/header.xml", "Contents/section0.xml"].contains(&name.as_str()) {
            assert_eq!(bytes, &after[name], "Unrelated HWPX entry changed: {name}");
        }
    }
    assert_eq!(fs::read(&source).unwrap(), source_bytes);
}
