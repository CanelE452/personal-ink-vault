use hwp_model::{Document, HwpChar, Paragraph};
use ink_hwp_native::request_json;
use quick_xml::{Reader, events::Event};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};
use tempfile::TempDir;

const TARGET: &str = "정렬 원문 한글 abc";
const OTHER: &str = "공유 스타일 다른 문단";

fn hash_bytes(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn file_hash(path: &Path) -> String {
    hash_bytes(&fs::read(path).unwrap())
}

fn call(value: Value) -> Value {
    request_json(&value.to_string())
}

fn inspect(path: &Path) -> Value {
    let reply = call(json!({"mode":"inspect","sourcePath":path}));
    assert!(reply.get("error").is_none(), "{reply}");
    reply["snapshot"].clone()
}

fn load(path: &Path) -> Document {
    if path.extension().unwrap() == "hwp" {
        hwp5::read_document(path).unwrap().document
    } else {
        hwpx::read_document(path).unwrap().document
    }
}

fn fixture(ext: &str) -> (TempDir, PathBuf) {
    let directory = TempDir::new().unwrap();
    let source = directory.path().join(format!("original.{ext}"));
    let mut document = hwp_convert::from_markdown(&format!(
        "{TARGET}\n\n{OTHER}\n\n보존 **굵게** 와 *기울임* 글자\n\n| 가 | 나 |\n| --- | --- |\n| 보존 셀 | 다른 셀 |\n"
    ));
    let shape = document.sections[0].paragraphs[0].para_shape;
    document.sections[0].paragraphs[1].para_shape = shape;
    let mut right = document.header.para_shapes[shape.0 as usize].clone();
    right.attr1 = (right.attr1 & !(7 << 2)) | (2 << 2);
    let right_id = hwp_model::ParaShapeId(document.header.para_shapes.len() as u16);
    document.header.para_shapes.push(right);
    document.sections[0].paragraphs[2].para_shape = right_id;
    document.metadata.title = Some("정렬 보존 시험".into());
    if ext == "hwp" {
        document.hwp5_xml_template.push((
            "/XMLTemplate/Keep.xml".into(),
            b"<keep value=\"UNCHANGED\"/>".to_vec(),
        ));
        document.header.extras.push(hwp_model::OpaqueRecord {
            tag: 0x3e0,
            data: b"UNCHANGED_DOCINFO_RECORD".to_vec(),
            children: vec![],
        });
        hwp5::write_document_with_report(&document, &source, &hwp5::WriteOptions::default())
            .unwrap();
    } else {
        document.hwpx_extra_entries.push((
            "DocOptions/Keep.xml".into(),
            b"<keep value=\"UNCHANGED\"/>".to_vec(),
        ));
        hwpx::write_document(&document, &source).unwrap();
    }
    (directory, source)
}

fn target(snapshot: &Value) -> Value {
    snapshot["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["text"] == TARGET)
        .unwrap()
        .clone()
}

fn format_operation(paragraph: &Value, alignment: &str) -> Value {
    json!({"op":"paragraphFormat","id":paragraph["id"],
        "expectedTextSha256":hash_bytes(paragraph["text"].as_str().unwrap().as_bytes()),
        "alignment":alignment})
}

fn apply(source: &Path, output: &Path, operations: Vec<Value>) -> Value {
    call(
        json!({"mode":"apply","sourcePath":source,"outputDirectory":output,
        "expectedSourceSha256":file_hash(source),"sessionId":"alignment-test",
        "fontDirectories":[Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build/native/fonts")],
        "operations":operations}),
    )
}

fn saved_path(reply: &Value, source: &Path) -> PathBuf {
    assert_eq!(reply["status"], "saved", "{reply}");
    let path = PathBuf::from(reply["sourcePath"].as_str().unwrap());
    assert_ne!(path, source);
    assert_eq!(path.extension(), source.extension());
    assert_eq!(file_hash(&path), reply["sourceSha256"]);
    let pdf = fs::read(reply["pdfPath"].as_str().unwrap()).unwrap();
    assert!(pdf.starts_with(b"%PDF-"));
    assert!(reply["pdfPageCount"].as_u64().unwrap() > 0);
    path
}

fn paragraph<'a>(document: &'a Document, id: &str) -> &'a Paragraph {
    let mut parts = id.split(':');
    let section: usize = parts
        .next()
        .unwrap()
        .strip_prefix('s')
        .unwrap()
        .parse()
        .unwrap();
    let paragraph: usize = parts
        .next()
        .unwrap()
        .strip_prefix('p')
        .unwrap()
        .parse()
        .unwrap();
    assert!(parts.next().is_none());
    &document.sections[section].paragraphs[paragraph]
}

fn location(id: &str) -> (usize, usize) {
    let parts: Vec<_> = id.split(':').collect();
    assert_eq!(parts.len(), 2);
    (
        parts[0].strip_prefix('s').unwrap().parse().unwrap(),
        parts[1].strip_prefix('p').unwrap().parse().unwrap(),
    )
}

fn text_of(paragraph: &Paragraph) -> String {
    paragraph
        .chars
        .iter()
        .filter_map(|c| match c {
            HwpChar::Text(c) => Some(*c),
            HwpChar::CharCtrl(10) => Some('\n'),
            HwpChar::InlineCtrl { code: 9, .. } => Some('\t'),
            _ => None,
        })
        .collect()
}

fn alignment_code(value: &str) -> u8 {
    match value {
        "justify" => 0,
        "left" => 1,
        "right" => 2,
        "center" => 3,
        _ => panic!("unsupported assertion value"),
    }
}

fn assert_aligned(document: &Document, id: &str, expected: &str) {
    let para = paragraph(document, id);
    assert_eq!(
        document.header.para_shapes[para.para_shape.0 as usize].alignment(),
        alignment_code(expected)
    );
}

fn assert_alignment_isolation(before: &Document, after: &Document, id: &str) {
    assert_eq!(before.meta, after.meta);
    assert_eq!(before.metadata, after.metadata);
    assert_eq!(before.bin_streams, after.bin_streams);
    assert_eq!(before.hwp5_xml_template, after.hwp5_xml_template);
    assert_eq!(before.hwp5_doc_history, after.hwp5_doc_history);
    assert_eq!(before.hwpx_extra_entries, after.hwpx_extra_entries);
    assert_eq!(before.sections.len(), after.sections.len());
    for (si, section) in before.sections.iter().enumerate() {
        assert_eq!(
            section.paragraphs.len(),
            after.sections[si].paragraphs.len()
        );
        for (pi, original) in section.paragraphs.iter().enumerate() {
            let reopened = &after.sections[si].paragraphs[pi];
            if format!("s{si}:p{pi}") == id {
                let mut expected = original.clone();
                expected.para_shape = reopened.para_shape;
                expected.line_segs.clear();
                assert_eq!(
                    &expected, reopened,
                    "alignment-only edit changed target text/runs/controls"
                );
            } else {
                assert_eq!(
                    original, reopened,
                    "non-target paragraph changed: s{si}:p{pi}"
                );
            }
        }
    }
    let mut old_header = before.header.clone();
    let mut new_header = after.header.clone();
    assert!(new_header.para_shapes.starts_with(&old_header.para_shapes));
    old_header.para_shapes.clear();
    new_header.para_shapes.clear();
    if old_header.id_mappings_counts.len() > 13 && new_header.id_mappings_counts.len() > 13 {
        old_header.id_mappings_counts[13] = 0;
        new_header.id_mappings_counts[13] = 0;
    }
    assert_eq!(
        old_header, new_header,
        "unrelated style tables or metadata changed"
    );
}

fn zip_entries(path: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    let mut result = BTreeMap::new();
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).unwrap();
        let mut bytes = vec![];
        entry.read_to_end(&mut bytes).unwrap();
        assert!(result.insert(entry.name().to_owned(), bytes).is_none());
    }
    result
}

fn rewrite_zip(path: &Path, transform: impl Fn(&str, Vec<u8>) -> Vec<u8>) {
    let mut archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    let output = path.with_extension("temporary");
    let mut writer = zip::ZipWriter::new(fs::File::create(&output).unwrap());
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).unwrap();
        let name = entry.name().to_owned();
        let mut bytes = vec![];
        entry.read_to_end(&mut bytes).unwrap();
        writer
            .start_file(
                &name,
                zip::write::SimpleFileOptions::default().compression_method(entry.compression()),
            )
            .unwrap();
        writer.write_all(&transform(&name, bytes)).unwrap();
    }
    writer.finish().unwrap();
    drop(archive);
    fs::rename(output, path).unwrap();
}

fn xml_blocks(xml: &str, local: &[u8]) -> Vec<String> {
    let mut reader = Reader::from_str(xml);
    let mut starts = Vec::new();
    let mut result = Vec::new();
    loop {
        let start = reader.buffer_position() as usize;
        match reader.read_event().unwrap() {
            Event::Start(e) if e.local_name().as_ref() == local => starts.push(start),
            Event::Empty(e) if e.local_name().as_ref() == local => {
                result.push(xml[start..reader.buffer_position() as usize].to_owned())
            }
            Event::End(e) if e.local_name().as_ref() == local => {
                result
                    .push(xml[starts.pop().unwrap()..reader.buffer_position() as usize].to_owned());
            }
            Event::Eof => break,
            _ => {}
        }
    }
    result
}

fn top_paragraphs(xml: &str) -> Vec<String> {
    let mut reader = Reader::from_str(xml);
    let mut depth = 0usize;
    let mut paragraph_start = None;
    let mut paragraphs = Vec::new();
    loop {
        let start = reader.buffer_position() as usize;
        match reader.read_event().unwrap() {
            Event::Start(element) => {
                if depth == 1 && element.local_name().as_ref() == b"p" {
                    paragraph_start = Some(start);
                }
                depth += 1;
            }
            Event::Empty(element) if depth == 1 && element.local_name().as_ref() == b"p" => {
                paragraphs.push(xml[start..reader.buffer_position() as usize].to_owned());
            }
            Event::End(_) => {
                depth -= 1;
                if depth == 1
                    && let Some(start) = paragraph_start.take()
                {
                    paragraphs.push(xml[start..reader.buffer_position() as usize].to_owned());
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    paragraphs
}

fn replace_block(xml: &str, original: &str, changed: &str) -> String {
    assert_ne!(
        original, changed,
        "fixture mutation did not change its actual target"
    );
    assert_eq!(
        xml.matches(original).count(),
        1,
        "fixture target is ambiguous"
    );
    xml.replacen(original, changed, 1)
}

fn replace_style(xml: &str, id: u16, change: impl FnOnce(&str) -> String) -> String {
    let original = xml_blocks(xml, b"paraPr")
        .into_iter()
        .find(|block| attribute(block, b"id") == id.to_string())
        .unwrap();
    let changed = change(&original);
    replace_block(xml, &original, &changed)
}

fn attribute(xml: &str, key: &[u8]) -> String {
    let mut reader = Reader::from_str(xml);
    match reader.read_event().unwrap() {
        Event::Start(e) | Event::Empty(e) => e
            .attributes()
            .map(Result::unwrap)
            .find(|a| a.key.as_ref() == key)
            .unwrap()
            .decoded_and_normalized_value(quick_xml::XmlVersion::Implicit1_0, reader.decoder())
            .unwrap()
            .into_owned(),
        _ => panic!("expected an XML element"),
    }
}

#[test]
fn inspect_exposes_original_alignment_for_both_formats() {
    for ext in ["hwp", "hwpx"] {
        let (_directory, source) = fixture(ext);
        let snapshot = inspect(&source);
        let item = target(&snapshot);
        assert_eq!(
            item["paragraphFormat"]["alignment"], "justify",
            "{snapshot}"
        );
        assert_eq!(
            snapshot["paragraphs"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["text"] == OTHER)
                .unwrap()["paragraphFormat"]["alignment"],
            "justify"
        );
    }
}

#[test]
fn all_four_alignments_save_in_original_format_and_isolate_shared_styles() {
    for ext in ["hwp", "hwpx"] {
        for alignment in ["left", "center", "right", "justify"] {
            let (directory, source) = fixture(ext);
            let source_hash = file_hash(&source);
            let snapshot = inspect(&source);
            let item = target(&snapshot);
            let original = load(&source);
            assert_eq!(
                original.sections[0].paragraphs[0].para_shape,
                original.sections[0].paragraphs[1].para_shape
            );
            let reply = apply(
                &source,
                &directory.path().join(alignment),
                vec![format_operation(&item, alignment)],
            );
            let output = saved_path(&reply, &source);
            let reopened = load(&output);
            assert_aligned(&reopened, item["id"].as_str().unwrap(), alignment);
            assert_alignment_isolation(&original, &reopened, item["id"].as_str().unwrap());
            let fresh = inspect(&output);
            assert_eq!(target(&fresh)["paragraphFormat"]["alignment"], alignment);
            assert_eq!(file_hash(&source), source_hash);
        }
    }
}

#[test]
fn alignment_only_keeps_multiple_character_styles_and_other_cells() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let original = load(&source);
        let snapshot = inspect(&source);
        let item = snapshot["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["text"].as_str().unwrap().contains("굵게"))
            .unwrap();
        assert!(
            paragraph(&original, item["id"].as_str().unwrap())
                .char_shape_runs
                .len()
                > 1
        );
        let reply = apply(
            &source,
            &directory.path().join("rich"),
            vec![format_operation(item, "center")],
        );
        let output = saved_path(&reply, &source);
        let reopened = load(&output);
        assert_aligned(&reopened, item["id"].as_str().unwrap(), "center");
        assert_alignment_isolation(&original, &reopened, item["id"].as_str().unwrap());
    }
}

#[test]
fn text_and_alignment_validate_against_original_batch_in_either_order() {
    for ext in ["hwp", "hwpx"] {
        for text_first in [false, true] {
            let (directory, source) = fixture(ext);
            let item = target(&inspect(&source));
            let format = format_operation(&item, "center");
            let text = json!({"op":"paragraphText","id":item["id"],"text":"변경된 본문 한글"});
            let operations = if text_first {
                vec![text, format]
            } else {
                vec![format, text]
            };
            let reply = apply(&source, &directory.path().join("batch"), operations);
            let output = saved_path(&reply, &source);
            let reopened = load(&output);
            assert_eq!(
                text_of(paragraph(&reopened, item["id"].as_str().unwrap())),
                "변경된 본문 한글"
            );
            assert_aligned(&reopened, item["id"].as_str().unwrap(), "center");
        }
    }
}

#[test]
fn stale_original_text_never_saves_even_if_an_earlier_text_op_matches_it() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let item = target(&inspect(&source));
        let mut format = format_operation(&item, "left");
        format["expectedTextSha256"] = json!(hash_bytes("수정된 본문".as_bytes()));
        let reply = apply(
            &source,
            &directory.path().join("stale"),
            vec![
                json!({"op":"paragraphText","id":item["id"],"text":"수정된 본문"}),
                format,
            ],
        );
        assert_eq!(reply["error"]["code"], "source_changed", "{reply}");
        assert!(reply.get("sourcePath").is_none());
        assert!(reply["error"].get("workingSourcePath").is_none());
    }
}

#[test]
fn alignment_contract_rejects_unknown_fields_values_and_malformed_digests() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let item = target(&inspect(&source));
        let valid = format_operation(&item, "left");
        let mut invalid = Vec::new();
        for field in [
            "styleName",
            "listKind",
            "listLevel",
            "pageBreakBefore",
            "unknown",
        ] {
            let mut op = valid.clone();
            op[field] = json!(null);
            invalid.push(op);
        }
        for value in [
            json!("other"),
            json!("LEFT"),
            json!(""),
            json!(null),
            json!(2),
        ] {
            let mut op = valid.clone();
            op["alignment"] = value;
            invalid.push(op);
        }
        for value in [
            json!(""),
            json!("0".repeat(63)),
            json!("G".repeat(64)),
            json!(null),
            json!(42),
        ] {
            let mut op = valid.clone();
            op["expectedTextSha256"] = value;
            invalid.push(op);
        }
        for field in ["id", "alignment", "expectedTextSha256"] {
            let mut op = valid.clone();
            op.as_object_mut().unwrap().remove(field);
            invalid.push(op);
        }
        for (index, op) in invalid.into_iter().enumerate() {
            let reply = apply(
                &source,
                &directory.path().join(format!("invalid-{index}")),
                vec![op],
            );
            assert_eq!(reply["error"]["code"], "invalid_request", "{reply}");
            assert!(reply["error"].get("workingSourcePath").is_none());
        }
    }
}

#[test]
fn duplicate_format_is_rejected_but_unrelated_legacy_text_edit_still_saves() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let item = target(&inspect(&source));
        let reply = apply(
            &source,
            &directory.path().join("duplicate"),
            vec![
                format_operation(&item, "left"),
                format_operation(&item, "right"),
            ],
        );
        assert_eq!(reply["error"]["code"], "invalid_request", "{reply}");
        let text = apply(
            &source,
            &directory.path().join("legacy"),
            vec![json!({"op":"paragraphText","id":item["id"],"text":"기존 텍스트 경로"})],
        );
        let output = saved_path(&text, &source);
        assert_eq!(
            text_of(paragraph(&load(&output), item["id"].as_str().unwrap())),
            "기존 텍스트 경로"
        );
    }
}

#[test]
fn hwp_reuses_an_identical_existing_para_shape_without_appending() {
    let (directory, source) = fixture("hwp");
    let original = load(&source);
    let item = target(&inspect(&source));
    let reply = apply(
        &source,
        &directory.path().join("reuse"),
        vec![format_operation(&item, "right")],
    );
    let output = saved_path(&reply, &source);
    let reopened = load(&output);
    assert_eq!(reopened.header.para_shapes, original.header.para_shapes);
    assert_aligned(&reopened, item["id"].as_str().unwrap(), "right");
}

fn hwp_streams(path: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut container = hwp5::Hwp5Container::open(path).unwrap();
    container
        .list_streams()
        .into_iter()
        .map(|entry| {
            let bytes = container.read_stream_raw(&entry.path).unwrap();
            (entry.path, bytes)
        })
        .collect()
}

fn docinfo_records(path: &Path) -> Vec<(usize, u16, Vec<u8>)> {
    fn walk(
        nodes: &[hwp5::record::RecordNode],
        depth: usize,
        out: &mut Vec<(usize, u16, Vec<u8>)>,
    ) {
        for node in nodes {
            out.push((depth, node.tag, node.data.clone()));
            walk(&node.children, depth + 1, out);
        }
    }
    let mut container = hwp5::Hwp5Container::open(path).unwrap();
    let raw = container.read_record_stream("/DocInfo").unwrap();
    let scan = hwp5::record::scan_stream(&raw, hwp5::record::ScanMode::Strict).unwrap();
    let mut records = Vec::new();
    walk(&scan.roots, 0, &mut records);
    records
}

#[test]
fn hwp_docinfo_only_appends_the_alignment_clone_and_changes_its_mapping_count() {
    let (directory, source) = fixture("hwp");
    let item = target(&inspect(&source));
    let original_document = load(&source);
    let source_shape = paragraph(&original_document, item["id"].as_str().unwrap())
        .para_shape
        .0 as usize;
    assert_eq!(
        text_of(paragraph(&original_document, item["id"].as_str().unwrap())),
        TARGET
    );
    let reply = apply(
        &source,
        &directory.path().join("append"),
        vec![format_operation(&item, "center")],
    );
    let output = saved_path(&reply, &source);
    let before_streams = hwp_streams(&source);
    let after_streams = hwp_streams(&output);
    assert_eq!(
        before_streams.keys().collect::<Vec<_>>(),
        after_streams.keys().collect::<Vec<_>>()
    );
    for (name, bytes) in before_streams {
        if !["/DocInfo", "/BodyText/Section0", "/PrvText"].contains(&name.as_str()) {
            assert_eq!(
                bytes, after_streams[&name],
                "unrelated HWP stream changed: {name}"
            );
        }
    }
    let before = docinfo_records(&source);
    let after = docinfo_records(&output);
    let tag = hwp5::record::tag::PARA_SHAPE;
    let old_shapes: Vec<_> = before.iter().filter(|(_, t, _)| *t == tag).collect();
    let new_shapes: Vec<_> = after.iter().filter(|(_, t, _)| *t == tag).collect();
    assert_eq!(new_shapes.len(), old_shapes.len() + 1);
    assert_eq!(&new_shapes[..old_shapes.len()], old_shapes.as_slice());
    let mut expected_clone = old_shapes[source_shape].2.clone();
    let attr = u32::from_le_bytes(expected_clone[..4].try_into().unwrap());
    expected_clone[..4].copy_from_slice(&((attr & !(7 << 2)) | (3 << 2)).to_le_bytes());
    assert_eq!(new_shapes.last().unwrap().2, expected_clone);
    let normalize = |records: Vec<(usize, u16, Vec<u8>)>| {
        records
            .into_iter()
            .filter(|(_, t, _)| *t != tag)
            .map(|(depth, tag, mut data)| {
                if tag == hwp5::record::tag::ID_MAPPINGS {
                    data[52..56].fill(0);
                }
                (depth, tag, data)
            })
            .collect::<Vec<_>>()
    };
    assert_eq!(normalize(before), normalize(after));
}

#[test]
fn hwpx_clones_raw_para_property_and_keeps_all_unrelated_xml_and_entries_exact() {
    let (directory, source) = fixture("hwpx");
    let original_item = target(&inspect(&source));
    let original_document = load(&source);
    let source_shape = paragraph(&original_document, original_item["id"].as_str().unwrap())
        .para_shape
        .0;
    let (section, paragraph_index) = location(original_item["id"].as_str().unwrap());
    let section_name = format!("Contents/section{section}.xml");
    rewrite_zip(&source, |name, bytes| {
        if name != "Contents/header.xml" {
            return bytes;
        }
        replace_style(&String::from_utf8(bytes).unwrap(), source_shape, |style| {
            assert!(style.contains("horizontal=\"JUSTIFY\""));
            style.replacen("<hh:paraPr ", "<hh:paraPr xmlns:v=\"urn:vendor\" v:id=\"SHADOW\" v:keep=\"RAW_STYLE\" ", 1)
                .replacen("horizontal=\"JUSTIFY\"", "v:horizontal=\"RIGHT\" horizontal=\"JUSTIFY\"", 1)
                .replacen("</hh:paraPr>", "<hh:unmodeled keep=\"DO_NOT_REBUILD\"/><v:metadata v:keep=\"EXACT\"/></hh:paraPr>", 1)
        }).into_bytes()
    });
    let before = zip_entries(&source);
    let item = target(&inspect(&source));
    assert_eq!(item["id"], original_item["id"]);
    assert_eq!(
        paragraph(&load(&source), item["id"].as_str().unwrap())
            .para_shape
            .0,
        source_shape
    );
    let mutated_header = std::str::from_utf8(&before["Contents/header.xml"]).unwrap();
    let mutated_shapes = xml_blocks(mutated_header, b"paraPr");
    let mutated_style = &mutated_shapes[source_shape as usize];
    assert_eq!(attribute(mutated_style, b"id"), source_shape.to_string());
    assert!(mutated_style.contains("xmlns:v=\"urn:vendor\""));
    assert!(mutated_style.contains("v:horizontal=\"RIGHT\" horizontal=\"JUSTIFY\""));
    assert!(mutated_style.contains("<v:metadata v:keep=\"EXACT\"/>"));
    let reply = apply(
        &source,
        &directory.path().join("raw"),
        vec![format_operation(&item, "center")],
    );
    let output = saved_path(&reply, &source);
    let after = zip_entries(&output);
    assert_eq!(
        before.keys().collect::<Vec<_>>(),
        after.keys().collect::<Vec<_>>()
    );
    for (name, bytes) in &before {
        if name != "Contents/header.xml" && name != &section_name {
            assert_eq!(bytes, &after[name], "unrelated ZIP entry changed: {name}");
        }
    }
    let old_header = std::str::from_utf8(&before["Contents/header.xml"]).unwrap();
    let new_header = std::str::from_utf8(&after["Contents/header.xml"]).unwrap();
    let old_shapes = xml_blocks(old_header, b"paraPr");
    let new_shapes = xml_blocks(new_header, b"paraPr");
    assert_eq!(new_shapes.len(), old_shapes.len() + 1);
    assert_eq!(&new_shapes[..old_shapes.len()], old_shapes.as_slice());
    let new_id = attribute(new_shapes.last().unwrap(), b"id");
    let clone = old_shapes[source_shape as usize]
        .replacen(
            &format!("id=\"{source_shape}\""),
            &format!("id=\"{new_id}\""),
            1,
        )
        .replacen("horizontal=\"JUSTIFY\"", "horizontal=\"CENTER\"", 1);
    assert_eq!(*new_shapes.last().unwrap(), clone);
    let expected_header = old_header
        .replacen(
            &format!("<hh:paraProperties itemCnt=\"{}\">", old_shapes.len()),
            &format!("<hh:paraProperties itemCnt=\"{}\">", new_shapes.len()),
            1,
        )
        .replacen(
            "</hh:paraProperties>",
            &format!("{clone}</hh:paraProperties>"),
            1,
        );
    assert_eq!(new_header, expected_header);
    let old_section = std::str::from_utf8(&before[&section_name]).unwrap();
    let new_section = std::str::from_utf8(&after[&section_name]).unwrap();
    let old_paragraph = &top_paragraphs(old_section)[paragraph_index];
    assert_eq!(
        attribute(old_paragraph, b"paraPrIDRef"),
        source_shape.to_string()
    );
    assert!(!old_section.contains("linesegarray"));
    assert_eq!(
        new_section,
        replace_block(
            old_section,
            old_paragraph,
            &old_paragraph.replacen(
                &format!("paraPrIDRef=\"{source_shape}\""),
                &format!("paraPrIDRef=\"{new_id}\""),
                1
            )
        )
    );
}

#[test]
fn hwpx_alignment_uses_namespace_uris_instead_of_fixed_prefixes() {
    let (directory, source) = fixture("hwpx");
    rewrite_zip(&source, |name, bytes| {
        if !["Contents/header.xml", "Contents/section0.xml"].contains(&name) {
            return bytes;
        }
        String::from_utf8(bytes)
            .unwrap()
            .replace("xmlns:hh=", "xmlns:head=")
            .replace("hh:", "head:")
            .replace("xmlns:hp=", "xmlns:para=")
            .replace("hp:", "para:")
            .into_bytes()
    });
    let item = target(&inspect(&source));
    let reply = apply(
        &source,
        &directory.path().join("prefix"),
        vec![format_operation(&item, "left")],
    );
    let output = saved_path(&reply, &source);
    assert_aligned(&load(&output), item["id"].as_str().unwrap(), "left");
    let entries = zip_entries(&output);
    let header = std::str::from_utf8(&entries["Contents/header.xml"]).unwrap();
    assert!(header.contains("<head:paraPr"));
    assert!(!header.contains("<hh:paraPr"));
}

#[test]
fn hwpx_ambiguous_header_ids_hide_alignment_but_keep_legacy_text_edits() {
    for variant in [
        "sparse",
        "duplicate",
        "order",
        "missing",
        "foreign",
        "foreign-align",
        "qualified-id",
        "qualified-reference",
        "unknown-align",
    ] {
        let (directory, source) = fixture("hwpx");
        let original_item = target(&inspect(&source));
        let original_document = load(&source);
        let source_shape = paragraph(&original_document, original_item["id"].as_str().unwrap())
            .para_shape
            .0;
        let (section, paragraph_index) = location(original_item["id"].as_str().unwrap());
        let section_name = format!("Contents/section{section}.xml");
        let original_entries = zip_entries(&source);
        rewrite_zip(&source, |name, bytes| {
            if variant == "qualified-reference" && name == section_name {
                let xml = String::from_utf8(bytes).unwrap();
                let paragraphs = top_paragraphs(&xml);
                let original = &paragraphs[paragraph_index];
                assert_eq!(
                    attribute(original, b"paraPrIDRef"),
                    source_shape.to_string()
                );
                let changed = original.replacen(
                    &format!("paraPrIDRef=\"{source_shape}\""),
                    &format!("xmlns:v=\"urn:vendor\" v:paraPrIDRef=\"{source_shape}\""),
                    1,
                );
                return replace_block(&xml, original, &changed).into_bytes();
            }
            if name != "Contents/header.xml" {
                return bytes;
            }
            let header = String::from_utf8(bytes).unwrap();
            let shapes = xml_blocks(&header, b"paraPr");
            assert!(shapes.len() >= 2);
            assert_eq!(
                attribute(&shapes[source_shape as usize], b"id"),
                source_shape.to_string()
            );
            let neighbor = (source_shape as usize + 1) % shapes.len();
            let source_id = format!("id=\"{source_shape}\"");
            match variant {
                "sparse" => replace_style(&header, source_shape, |style| {
                    style.replacen(&source_id, &format!("id=\"{}\"", shapes.len() + 3), 1)
                }),
                "duplicate" => replace_style(&header, source_shape, |style| {
                    style.replacen(&source_id, &format!("id=\"{neighbor}\""), 1)
                }),
                "order" => {
                    let marker = "PIV_TEST_STYLE_SWAP";
                    assert!(!header.contains(marker));
                    header
                        .replacen(&shapes[source_shape as usize], marker, 1)
                        .replacen(&shapes[neighbor], &shapes[source_shape as usize], 1)
                        .replacen(marker, &shapes[neighbor], 1)
                }
                "missing" => replace_style(&header, source_shape, |style| {
                    style.replacen(&source_id, &format!("missing=\"{source_shape}\""), 1)
                }),
                "foreign" => header.replace(
                    "http://www.hancom.co.kr/hwpml/2011/head",
                    "urn:foreign-header",
                ),
                "foreign-align" => replace_style(&header, source_shape, |style| {
                    style.replacen("<hh:align ", "<v:align xmlns:v=\"urn:vendor\" ", 1)
                }),
                "qualified-id" => replace_style(&header, source_shape, |style| {
                    style.replacen(
                        &source_id,
                        &format!("xmlns:v=\"urn:vendor\" v:id=\"{source_shape}\""),
                        1,
                    )
                }),
                "qualified-reference" => header,
                "unknown-align" => replace_style(&header, source_shape, |style| {
                    style.replacen("horizontal=\"JUSTIFY\"", "horizontal=\"VENDOR_UNKNOWN\"", 1)
                }),
                _ => unreachable!(),
            }
            .into_bytes()
        });
        let mutated_entries = zip_entries(&source);
        if variant == "qualified-reference" {
            assert_eq!(
                original_entries["Contents/header.xml"],
                mutated_entries["Contents/header.xml"]
            );
            let section_xml = std::str::from_utf8(&mutated_entries[&section_name]).unwrap();
            let paragraphs = top_paragraphs(section_xml);
            assert!(
                paragraphs[paragraph_index].contains(&format!("v:paraPrIDRef=\"{source_shape}\""))
            );
            assert!(!paragraphs[paragraph_index].contains(" paraPrIDRef="));
        } else {
            assert_ne!(
                original_entries["Contents/header.xml"], mutated_entries["Contents/header.xml"],
                "mutation missed its target: {variant}"
            );
            assert_eq!(
                original_entries[&section_name],
                mutated_entries[&section_name]
            );
        }
        let snapshot = inspect(&source);
        let item = target(&snapshot);
        assert!(
            item.get("paragraphFormat")
                .and_then(|v| v.get("alignment"))
                .is_none(),
            "unsafe mapping exposed alignment: {variant}: {snapshot}"
        );
        let refused = apply(
            &source,
            &directory.path().join("refused"),
            vec![format_operation(&item, "left")],
        );
        assert_eq!(
            refused["error"]["code"], "unsupported_structure",
            "{variant}: {refused}"
        );
        let text = apply(
            &source,
            &directory.path().join("text"),
            vec![json!({"op":"paragraphText","id":item["id"],"text":"기존 본문 편집"})],
        );
        if variant == "qualified-reference" {
            assert_eq!(text["error"]["code"], "unsupported_loss", "{text}");
        } else {
            saved_path(&text, &source);
        }
    }
}

#[test]
fn known_noneditable_alignment_is_other_until_an_explicit_choice() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let original_item = target(&inspect(&source));
        let original_document = load(&source);
        let source_shape = paragraph(&original_document, original_item["id"].as_str().unwrap())
            .para_shape
            .0 as usize;
        if ext == "hwp" {
            let mut document = load(&source);
            let original = document.clone();
            document.header.para_shapes[source_shape].attr1 =
                (document.header.para_shapes[source_shape].attr1 & !(7 << 2)) | (4 << 2);
            let changed = directory.path().join("distributed.hwp");
            hwp5::rewrite_document_with_report(
                &source,
                &original,
                &document,
                &changed,
                &hwp5::WriteOptions {
                    preserve_linesegs: true,
                    ..Default::default()
                },
            )
            .unwrap();
            fs::copy(changed, &source).unwrap();
        } else {
            rewrite_zip(&source, |name, bytes| {
                if name == "Contents/header.xml" {
                    replace_style(
                        &String::from_utf8(bytes).unwrap(),
                        source_shape as u16,
                        |style| {
                            style.replacen("horizontal=\"JUSTIFY\"", "horizontal=\"DISTRIBUTE\"", 1)
                        },
                    )
                    .into_bytes()
                } else {
                    bytes
                }
            });
        }
        let mutated = load(&source);
        let mutated_paragraph = paragraph(&mutated, original_item["id"].as_str().unwrap());
        assert_eq!(mutated_paragraph.para_shape.0 as usize, source_shape);
        assert_eq!(
            mutated.header.para_shapes[source_shape].alignment(),
            4,
            "fixture did not change the actual target alignment"
        );
        let item = target(&inspect(&source));
        assert_eq!(item["paragraphFormat"]["alignment"], "other");
        let reply = apply(
            &source,
            &directory.path().join("explicit"),
            vec![format_operation(&item, "center")],
        );
        let output = saved_path(&reply, &source);
        assert_aligned(&load(&output), item["id"].as_str().unwrap(), "center");
        let other = inspect(&output)["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["text"] == OTHER)
            .unwrap()
            .clone();
        assert_eq!(other["paragraphFormat"]["alignment"], "other");
    }
}

#[test]
fn stale_source_hash_is_rejected_before_alignment_publication() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let item = target(&inspect(&source));
        let reply = call(json!({"mode":"apply","sourcePath":source,
            "outputDirectory":directory.path().join("stale-source"),
            "expectedSourceSha256":"0".repeat(64),"sessionId":"stale",
            "operations":[format_operation(&item, "left")]}));
        assert_eq!(reply["error"]["code"], "source_changed", "{reply}");
        assert!(reply["error"].get("workingSourcePath").is_none());
    }
}

fn insert_after(paragraph: &Value, text: &str) -> Value {
    json!({"op":"paragraphInsert", "id":"draft-added", "referenceId":paragraph["id"],
        "position":"after", "expectedTextSha256":hash_bytes(paragraph["text"].as_str().unwrap().as_bytes()),
        "text":text})
}

#[test]
fn hwpx_paragraph_insert_preserves_existing_xml_and_reopens_as_an_independent_paragraph() {
    let (directory, source) = fixture("hwpx");
    let source_hash = file_hash(&source);
    let anchor = target(&inspect(&source));
    let text = "새 본문 😀 <A&B> a=>b";
    let reply = apply(
        &source,
        &directory.path().join("insert-paragraph"),
        vec![insert_after(&anchor, text)],
    );
    let output = saved_path(&reply, &source);
    assert_eq!(file_hash(&source), source_hash);
    assert_eq!(anchor["structure"]["canInsertAfter"], true);
    let (section, index) = location(anchor["id"].as_str().unwrap());
    let section_name = format!("Contents/section{section}.xml");
    let mut before = zip_entries(&source);
    let mut after = zip_entries(&output);
    let before_section = String::from_utf8(before.remove(&section_name).unwrap()).unwrap();
    let after_section = String::from_utf8(after.remove(&section_name).unwrap()).unwrap();
    assert_eq!(before, after);
    let mut after_paragraphs = top_paragraphs(&after_section);
    let inserted = after_paragraphs.remove(index + 1);
    assert_eq!(top_paragraphs(&before_section), after_paragraphs);
    assert!(!inserted.contains("secPr"));
    let inserted_id = attribute(&inserted, b"id");
    let mut reader = Reader::from_str(&before_section);
    loop {
        match reader.read_event().unwrap() {
            Event::Start(element) | Event::Empty(element) => {
                assert!(!element.attributes().flatten().any(|value| {
                    matches!(value.key.as_ref(), b"id" | b"instid")
                        && value.value.as_ref() == inserted_id.as_bytes()
                }));
            }
            Event::Eof => break,
            _ => {}
        }
    }
    assert_eq!(after_section.replacen(&inserted, "", 1), before_section);

    let snapshot = inspect(&output);
    let new_paragraph = snapshot["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["text"] == text)
        .unwrap();
    assert_eq!(new_paragraph["id"], format!("s{section}:p{}", index + 1));
    assert_eq!(new_paragraph["paragraphFormat"], anchor["paragraphFormat"]);
    let aligned = apply(
        &output,
        &directory.path().join("align-inserted"),
        vec![format_operation(new_paragraph, "center")],
    );
    let reopened = load(&saved_path(&aligned, &output));
    assert_aligned(&reopened, new_paragraph["id"].as_str().unwrap(), "center");
    assert_aligned(
        &reopened,
        anchor["id"].as_str().unwrap(),
        anchor["paragraphFormat"]["alignment"].as_str().unwrap(),
    );
}

#[test]
fn hwpx_paragraph_insert_keeps_source_ids_for_other_edits_and_rejects_stale_anchor() {
    let (directory, source) = fixture("hwpx");
    let snapshot = inspect(&source);
    let anchor = target(&snapshot);
    let other = snapshot["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["text"] == OTHER)
        .unwrap();
    let mut stale = insert_after(&anchor, "새 본문");
    stale["expectedTextSha256"] = json!("0".repeat(64));
    let rejected = apply(&source, &directory.path().join("stale-insert"), vec![stale]);
    assert_eq!(rejected["error"]["code"], "source_changed", "{rejected}");
    let saved = apply(
        &source,
        &directory.path().join("mixed-insert"),
        vec![
            insert_after(&anchor, "새 본문"),
            json!({"op":"paragraphText", "id":other["id"], "text":"뒤 문단 수정"}),
        ],
    );
    let output = saved_path(&saved, &source);
    let document = load(&output);
    let (section, index) = location(anchor["id"].as_str().unwrap());
    assert_eq!(
        text_of(&document.sections[section].paragraphs[index + 1]),
        "새 본문"
    );
    let (section, index) = location(other["id"].as_str().unwrap());
    assert_eq!(
        text_of(&document.sections[section].paragraphs[index + 1]),
        "뒤 문단 수정"
    );
}

#[test]
fn hwpx_paragraph_insert_inherits_the_first_text_style_after_section_controls() {
    let (directory, source) = fixture("hwpx");
    let anchor = target(&inspect(&source));
    let (section, index) = location(anchor["id"].as_str().unwrap());
    let original = load(&source);
    assert!(original.header.char_shapes.len() > 1);
    let control_style = original.sections[section].paragraphs[index].char_shape_runs[0]
        .1
        .0;
    let body_style = u16::from(control_style == 0);
    rewrite_zip(&source, |name, bytes| {
        if name != format!("Contents/section{section}.xml") {
            return bytes;
        }
        let xml = String::from_utf8(bytes).unwrap();
        let target = &top_paragraphs(&xml)[index];
        let body = target.find("<hp:t").unwrap_or_else(|| panic!("{target}"));
        assert!(target[..body].contains("</hp:secPr>"), "{target}");
        let mut split = target.clone();
        split.insert_str(
            body,
            &format!("</hp:run><hp:run charPrIDRef=\"{body_style}\">"),
        );
        xml.replacen(target, &split, 1).into_bytes()
    });
    let anchor = target(&inspect(&source));
    let reply = apply(
        &source,
        &directory.path().join("insert-visible-style"),
        vec![insert_after(&anchor, "본문 스타일")],
    );
    let opened = load(&saved_path(&reply, &source));
    assert_eq!(
        opened.sections[section].paragraphs[index + 1].char_shape_runs[0]
            .1
            .0,
        body_style
    );
}

#[test]
fn hwpx_paragraph_insert_refuses_ambiguous_raw_paragraph_order() {
    let (directory, source) = fixture("hwpx");
    let anchor = target(&inspect(&source));
    let (section, index) = location(anchor["id"].as_str().unwrap());
    rewrite_zip(&source, |name, bytes| {
        if name != format!("Contents/section{section}.xml") {
            return bytes;
        }
        let xml = String::from_utf8(bytes).unwrap();
        let target = &top_paragraphs(&xml)[index];
        let shifted = format!("<hp:unmodeled>{target}</hp:unmodeled>");
        xml.replacen(target, &shifted, 1)
            .replacen(
                "</hs:sec>",
                "<hp:p id=\"99999\" paraPrIDRef=\"0\" styleIDRef=\"0\"/></hs:sec>",
                1,
            )
            .into_bytes()
    });
    let anchor = target(&inspect(&source));
    assert_ne!(anchor["structure"]["canInsertAfter"], true);
    let reply = apply(
        &source,
        &directory.path().join("ambiguous-raw-order"),
        vec![insert_after(&anchor, "바뀌면 안 됨")],
    );
    assert_eq!(reply["error"]["code"], "unsupported_structure", "{reply}");
}

fn delete_paragraph(paragraph: &Value) -> Value {
    json!({"op":"paragraphDelete", "id":paragraph["id"],
        "expectedTextSha256":hash_bytes(paragraph["text"].as_str().unwrap().as_bytes())})
}

#[test]
fn hwpx_paragraph_delete_removes_exact_xml_span_and_retains_other_members() {
    let (directory, source) = fixture("hwpx");
    let source_hash = file_hash(&source);
    let before = inspect(&source);
    let selected = before["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["text"] == OTHER)
        .unwrap();
    let reply = apply(
        &source,
        &directory.path().join("delete-paragraph"),
        vec![delete_paragraph(selected)],
    );
    let output = saved_path(&reply, &source);
    assert_eq!(selected["structure"]["canDelete"], true);
    assert_eq!(file_hash(&source), source_hash);
    assert_eq!(
        file_hash(Path::new(reply["pdfPath"].as_str().unwrap())),
        reply["pdfSha256"]
    );
    let (section, index) = location(selected["id"].as_str().unwrap());
    let name = format!("Contents/section{section}.xml");
    let mut old_members = zip_entries(&source);
    let mut new_members = zip_entries(&output);
    let old = String::from_utf8(old_members.remove(&name).unwrap()).unwrap();
    let new = String::from_utf8(new_members.remove(&name).unwrap()).unwrap();
    let mut old_paragraphs = top_paragraphs(&old);
    let selected_xml = old_paragraphs.remove(index);
    assert_eq!(old.matches(&selected_xml).count(), 1);
    assert_eq!(old.replacen(&selected_xml, "", 1), new);
    assert_eq!(old_paragraphs, top_paragraphs(&new));
    assert_eq!(old_members, new_members);
    let reopened = inspect(&output);
    assert!(
        reopened["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|p| p["text"] != OTHER)
    );
    assert_eq!(reopened["tables"][0]["cells"], before["tables"][0]["cells"]);
}

#[test]
fn hwpx_paragraph_delete_refuses_section_anchor_and_opaque_paragraph_data() {
    let (directory, source) = fixture("hwpx");
    let initial = inspect(&source);
    let first = target(&initial);
    let selected = initial["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["text"] == OTHER)
        .unwrap();
    let (section, index) = location(selected["id"].as_str().unwrap());
    let mut stale = delete_paragraph(selected);
    stale["expectedTextSha256"] = json!("0".repeat(64));
    for (operation, error) in [
        (delete_paragraph(&first), "unsupported_structure"),
        (stale, "source_changed"),
    ] {
        let reply = apply(&source, directory.path(), vec![operation]);
        assert_eq!(reply["error"]["code"], error, "{reply}");
    }
    rewrite_zip(&source, |name, bytes| {
        if name != format!("Contents/section{section}.xml") {
            return bytes;
        }
        let xml = String::from_utf8(bytes).unwrap();
        let original = &top_paragraphs(&xml)[index];
        let opaque = original.replacen("<hp:p ", r#"<hp:p unknown="retain" "#, 1);
        replace_block(&xml, original, &opaque).into_bytes()
    });
    let source_hash = file_hash(&source);
    assert!(
        inspect(&source)["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|p| p["text"] != OTHER || p["structure"]["canDelete"] != true)
    );
    let reply = apply(&source, directory.path(), vec![delete_paragraph(selected)]);
    assert_eq!(reply["error"]["code"], "unsupported_structure", "{reply}");
    assert!(reply["error"]["workingSourcePath"].is_null(), "{reply}");
    assert_eq!(file_hash(&source), source_hash);
}

#[test]
fn hwpx_alignment_removes_only_the_targets_known_layout_cache() {
    let (directory, source) = fixture("hwpx");
    let original_item = target(&inspect(&source));
    let original_document = load(&source);
    let source_shape = paragraph(&original_document, original_item["id"].as_str().unwrap())
        .para_shape
        .0;
    let (section, paragraph_index) = location(original_item["id"].as_str().unwrap());
    let section_name = format!("Contents/section{section}.xml");
    const CACHE: &str = "<hp:linesegarray><hp:lineseg textpos=\"0\" vertpos=\"0\" vertsize=\"1000\" textheight=\"1000\" baseline=\"800\" spacing=\"0\" horzpos=\"0\" horzsize=\"30000\" flags=\"0\"/></hp:linesegarray>";
    rewrite_zip(&source, |name, bytes| {
        if name == section_name {
            let xml = String::from_utf8(bytes).unwrap();
            let paragraphs = top_paragraphs(&xml);
            let original = &paragraphs[paragraph_index];
            assert_eq!(
                attribute(original, b"paraPrIDRef"),
                source_shape.to_string()
            );
            let changed = format!(
                "{}{CACHE}</hp:p>",
                original.strip_suffix("</hp:p>").unwrap()
            );
            replace_block(&xml, original, &changed).into_bytes()
        } else {
            bytes
        }
    });
    let before = zip_entries(&source);
    let item = target(&inspect(&source));
    assert_eq!(item["id"], original_item["id"]);
    assert_eq!(
        paragraph(&load(&source), item["id"].as_str().unwrap())
            .line_segs
            .len(),
        1,
        "fixture cache missed the actual target paragraph"
    );
    let reply = apply(
        &source,
        &directory.path().join("cache"),
        vec![format_operation(&item, "left")],
    );
    let output = saved_path(&reply, &source);
    let after = zip_entries(&output);
    let old_section = std::str::from_utf8(&before[&section_name]).unwrap();
    let new_section = std::str::from_utf8(&after[&section_name]).unwrap();
    let header = std::str::from_utf8(&after["Contents/header.xml"]).unwrap();
    let styles = xml_blocks(header, b"paraPr");
    let new_id = attribute(styles.last().unwrap(), b"id");
    let original_paragraphs = top_paragraphs(old_section);
    let original_paragraph = &original_paragraphs[paragraph_index];
    assert!(original_paragraph.contains(CACHE));
    let expected_paragraph = original_paragraph
        .replacen(
            &format!("paraPrIDRef=\"{source_shape}\""),
            &format!("paraPrIDRef=\"{new_id}\""),
            1,
        )
        .replacen(CACHE, "", 1);
    assert_eq!(
        new_section,
        replace_block(old_section, original_paragraph, &expected_paragraph)
    );
}

#[test]
fn hwpx_unknown_layout_cache_data_is_never_discarded_to_enable_alignment() {
    let (directory, source) = fixture("hwpx");
    let original_item = target(&inspect(&source));
    let (section, paragraph_index) = location(original_item["id"].as_str().unwrap());
    let section_name = format!("Contents/section{section}.xml");
    rewrite_zip(&source, |name, bytes| {
        if name == section_name {
            let xml = String::from_utf8(bytes).unwrap();
            let paragraphs = top_paragraphs(&xml);
            let original = &paragraphs[paragraph_index];
            let changed = format!(
                "{}<hp:linesegarray keep=\"PRIVATE\"/></hp:p>",
                original.strip_suffix("</hp:p>").unwrap()
            );
            replace_block(&xml, original, &changed).into_bytes()
        } else {
            bytes
        }
    });
    let original = file_hash(&source);
    let item = target(&inspect(&source));
    let entries = zip_entries(&source);
    let section_xml = std::str::from_utf8(&entries[&section_name]).unwrap();
    assert!(
        top_paragraphs(section_xml)[paragraph_index]
            .contains("<hp:linesegarray keep=\"PRIVATE\"/>")
    );
    let reply = apply(
        &source,
        &directory.path().join("cache"),
        vec![format_operation(&item, "left")],
    );
    assert_eq!(reply["error"]["code"], "unsupported_loss", "{reply}");
    assert!(reply["error"].get("workingSourcePath").is_none());
    assert_eq!(file_hash(&source), original);
}
