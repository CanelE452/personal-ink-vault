use hwp_model::{HwpChar, Paragraph};
use hwp5::{Hwp5Container, codec::ByteReader, record::RecordHeader, record::tag};
use ink_hwp_native::request_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    env, fs,
    io::Write,
    ops::Range,
    path::{Path, PathBuf},
};

const PUBLIC_SHA: &str = "4ff3c231d835f37ceaa08ccd41f7db66d74d65a5a03c0791f6f683cc9fde0d39";
const SECTION: &str = "/BodyText/Section0";
const PREVIEW_TEXT: &str = "/PrvText";
const MIDDLE: usize = 1;
const LAST: usize = 8;
const MIDDLE_TEXT: &str = "새 본문 abc";
const LAST_TEXT: &str = "끝 문단 123";

fn project_path(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(relative)
}

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn public_fixture() -> PathBuf {
    let source = env::var_os("PIV_HWP5_ROW_FIXTURE").map_or_else(
        || {
            project_path(concat!(
                "build/research/hwp/hwp-cli-v1.3.1-source/",
                "hwp-cli-4e6e8c2a61694899e37b4f7c2f97523153a623b9/",
                "fixtures/pdf-parity/public/source/public-safety-rfp-p1.hwp"
            ))
        },
        PathBuf::from,
    );
    assert_eq!(hash(&fs::read(&source).unwrap()), PUBLIC_SHA);
    source
}

fn make_raw_variant(source: &Path) {
    let mut container = Hwp5Container::open(source).unwrap();
    assert!(container.file_header().is_compressed());
    let mut header = container.read_stream_raw("/FileHeader").unwrap();
    header[36] &= !1;
    let decoded: Vec<_> = container
        .list_streams()
        .into_iter()
        .filter(|entry| hwp5::container::is_record_stream(&entry.path))
        .map(|entry| {
            let bytes = container.read_record_stream(&entry.path).unwrap();
            (entry.path, bytes)
        })
        .collect();
    assert!(decoded.iter().any(|(name, _)| name == SECTION));
    drop(container);
    let mut cfb = cfb::open_rw(source).unwrap();
    cfb.create_stream("/FileHeader")
        .unwrap()
        .write_all(&header)
        .unwrap();
    for (name, bytes) in decoded {
        cfb.create_stream(name).unwrap().write_all(&bytes).unwrap();
    }
    cfb.flush().unwrap();
}

fn call(request: Value) -> Value {
    request_json(&request.to_string())
}

fn inspect(source: &Path, work: &Path) -> Value {
    let reply = call(json!({"mode":"inspect", "sourcePath":source, "outputDirectory":work}));
    assert!(reply["error"].is_null(), "{reply}");
    reply["snapshot"].clone()
}

fn apply(source: &Path, work: &Path, digest: &str, operations: Vec<Value>) -> Value {
    call(json!({
        "mode":"apply", "sourcePath":source, "outputDirectory":work,
        "sessionId":"hwp5-paragraph-insert-test", "expectedSourceSha256":digest,
        "fontDirectories":[project_path("build/native/fonts")], "operations":operations
    }))
}

fn saved(reply: &Value, source: &Path) -> PathBuf {
    assert_eq!(reply["status"], "saved", "{reply}");
    let output = PathBuf::from(reply["sourcePath"].as_str().unwrap());
    assert_ne!(output, source);
    assert_eq!(output.extension().unwrap(), "hwp");
    assert_eq!(hash(&fs::read(&output).unwrap()), reply["sourceSha256"]);
    let pdf = fs::read(reply["pdfPath"].as_str().unwrap()).unwrap();
    assert!(pdf.starts_with(b"%PDF-"));
    assert_eq!(hash(&pdf), reply["pdfSha256"]);
    assert!(reply["pdfPageCount"].as_u64().unwrap() > 0);
    output
}

fn paragraph(snapshot: &Value, index: usize) -> &Value {
    snapshot["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == format!("s0:p{index}"))
        .unwrap()
}

fn insertion(id: &str, reference: &str, anchor_text: &str, text: &str) -> Value {
    json!({"op":"paragraphInsert", "id":id, "referenceId":reference, "position":"after",
        "expectedTextSha256":hash(anchor_text.as_bytes()), "text":text})
}

fn after(snapshot: &Value, index: usize, id: &str, text: &str) -> Value {
    let anchor = paragraph(snapshot, index);
    insertion(
        id,
        anchor["id"].as_str().unwrap(),
        anchor["text"].as_str().unwrap(),
        text,
    )
}

fn deletion(id: &str, expected_text: &str) -> Value {
    json!({"op":"paragraphDelete","id":id,"expectedTextSha256":hash(expected_text.as_bytes())})
}

fn streams(path: &Path) -> (Vec<String>, BTreeMap<String, Vec<u8>>) {
    let mut container = Hwp5Container::open(path).unwrap();
    let streams = container
        .list_streams()
        .into_iter()
        .map(|entry| {
            let bytes = container.read_stream_raw(&entry.path).unwrap();
            (entry.path, bytes)
        })
        .collect();
    (container.list_storages(), streams)
}

struct ParagraphBlock {
    bytes: Range<usize>,
    header_payload: usize,
}

fn raw_paragraphs(bytes: &[u8]) -> Vec<ParagraphBlock> {
    let mut reader = ByteReader::new(bytes);
    let mut blocks: Vec<ParagraphBlock> = Vec::new();
    while !reader.is_empty() {
        let start = reader.pos();
        let record = RecordHeader::decode(&mut reader).unwrap();
        if record.level == 0 {
            assert_eq!(record.tag, tag::PARA_HEADER);
            if let Some(previous) = blocks.last_mut() {
                previous.bytes.end = start;
            }
            blocks.push(ParagraphBlock {
                bytes: start..bytes.len(),
                header_payload: reader.pos(),
            });
        }
        reader.read_bytes(record.size as usize).unwrap();
    }
    blocks
}

fn terminal(bytes: &[u8], block: &ParagraphBlock) -> bool {
    bytes[block.header_payload + 3] & 0x80 != 0
}

fn plain_text(para: &Paragraph) -> String {
    para.chars
        .iter()
        .filter_map(|c| match c {
            HwpChar::Text(value) => Some(*value),
            _ => None,
        })
        .collect()
}

#[test]
fn hwp5_public_paragraph_insert_preserves_source_records_and_moves_terminal_bit() {
    let public = public_fixture();
    let directory = tempfile::tempdir().unwrap();
    for compressed in [true, false] {
        let work = directory
            .path()
            .join(if compressed { "compressed" } else { "raw" });
        fs::create_dir(&work).unwrap();
        let source = work.join("original.hwp");
        fs::copy(&public, &source).unwrap();
        if !compressed {
            make_raw_variant(&source);
        }
        let original_bytes = fs::read(&source).unwrap();
        let original_hash = hash(&original_bytes);
        let original_model = hwp5::read_document(&source).unwrap().document;
        let original = &original_model.sections[0].paragraphs;
        assert_eq!(original.len(), LAST + 1);
        let before = inspect(&source, &work);
        // Supply later and earlier anchor in reverse order. IDs name the input
        // document's ordinals, even after another insertion changes output IDs.
        let reply = apply(
            &source,
            &work,
            &original_hash,
            vec![
                after(&before, LAST, "terminal-draft", LAST_TEXT),
                after(&before, MIDDLE, "middle-draft", MIDDLE_TEXT),
            ],
        );
        let output = saved(&reply, &source);
        for index in [MIDDLE, LAST] {
            assert_eq!(
                paragraph(&before, index)["structure"]["canInsertAfter"],
                true
            );
        }
        let after = inspect(&output, &work);
        let edited_model = hwp5::read_document(&output).unwrap().document;
        let edited = &edited_model.sections[0].paragraphs;
        assert_eq!(edited.len(), original.len() + 2);
        let previous_instances: BTreeSet<_> =
            original.iter().map(|p| p.header.instance_id).collect();
        for (source_index, result_index, expected) in [
            (MIDDLE, MIDDLE + 1, MIDDLE_TEXT),
            (LAST, LAST + 2, LAST_TEXT),
        ] {
            let anchor = &original[source_index];
            let added = &edited[result_index];
            let exposed = paragraph(&after, result_index);
            assert_eq!(exposed["text"], expected);
            assert_eq!(
                exposed["paragraphFormat"],
                paragraph(&before, source_index)["paragraphFormat"]
            );
            assert_eq!(plain_text(added), expected);
            assert_eq!(
                (added.para_shape, added.style),
                (anchor.para_shape, anchor.style)
            );
            assert_eq!(
                added.char_shape_runs.as_slice(),
                &[anchor.char_shape_runs[0]]
            );
            assert!(matches!(added.chars.last(), Some(HwpChar::CharCtrl(13))));
            assert_eq!(
                added.wchar_len() as usize,
                expected.encode_utf16().count() + 1
            );
            assert!(added.controls.is_empty() && added.line_segs.is_empty());
            assert!(!previous_instances.contains(&added.header.instance_id));
        }
        assert_ne!(
            edited[MIDDLE + 1].header.instance_id,
            edited[LAST + 2].header.instance_id
        );

        let (original_storage, original_streams) = streams(&source);
        let (saved_storage, saved_streams) = streams(&output);
        assert_eq!(saved_storage, original_storage);
        assert_eq!(
            saved_streams.keys().collect::<Vec<_>>(),
            original_streams.keys().collect::<Vec<_>>()
        );
        for (name, bytes) in &original_streams {
            if name != SECTION && name != PREVIEW_TEXT {
                assert_eq!(
                    &saved_streams[name], bytes,
                    "modified unrelated stream {name}"
                );
            }
        }
        let mut original_cfb = Hwp5Container::open(&source).unwrap();
        let mut saved_cfb = Hwp5Container::open(&output).unwrap();
        assert_eq!(original_cfb.file_header().is_compressed(), compressed);
        assert_eq!(saved_cfb.file_header().is_compressed(), compressed);
        let raw_before = original_cfb.read_record_stream(SECTION).unwrap();
        let mut raw_after = saved_cfb.read_record_stream(SECTION).unwrap();
        let before_blocks = raw_paragraphs(&raw_before);
        let after_blocks = raw_paragraphs(&raw_after);
        assert_eq!(before_blocks.len(), LAST + 1);
        assert_eq!(after_blocks.len(), LAST + 3);
        assert!(terminal(&raw_before, &before_blocks[LAST]));
        assert!(terminal(&raw_after, &after_blocks[LAST + 2]));
        assert!(
            after_blocks[..LAST + 2]
                .iter()
                .all(|block| !terminal(&raw_after, block))
        );
        raw_after[after_blocks[LAST + 1].header_payload + 3] |= 0x80;
        for index in [LAST + 2, MIDDLE + 1] {
            raw_after.drain(after_blocks[index].bytes.clone());
        }
        assert_eq!(
            raw_after, raw_before,
            "non-target records must stay byte-identical"
        );
        assert_eq!(fs::read(&source).unwrap(), original_bytes);
    }
    assert_eq!(hash(&fs::read(public).unwrap()), PUBLIC_SHA);
}

#[test]
fn hwp5_paragraph_insert_rejects_stale_repeated_and_non_body_anchors() {
    let source = public_fixture();
    let directory = tempfile::tempdir().unwrap();
    let work = directory.path();
    let before = inspect(&source, work);
    let valid = after(&before, MIDDLE, "middle-draft", MIDDLE_TEXT);
    let mut stale = valid.clone();
    stale["expectedTextSha256"] = json!("0".repeat(64));
    let mut wrong_position = valid.clone();
    wrong_position["position"] = json!("before");
    for (operations, expected) in [
        (vec![stale], "source_changed"),
        (vec![wrong_position], "invalid_request"),
        (
            vec![valid.clone(), after(&before, MIDDLE, "other-draft", "중복")],
            "invalid_request",
        ),
        (
            vec![valid, after(&before, LAST, "middle-draft", "중복")],
            "invalid_request",
        ),
        (
            vec![insertion("table-carrier", "s0:p2", "", "거절")],
            "unsupported_structure",
        ),
        (
            vec![insertion("table-cell", "s0:p2:t0:0,0", "", "거절")],
            "invalid_request",
        ),
        (
            vec![insertion("section-controls", "s0:p0", "", "거절")],
            "unsupported_structure",
        ),
    ] {
        let reply = apply(&source, work, PUBLIC_SHA, operations);
        assert_eq!(reply["error"]["code"], expected, "{reply}");
        assert!(reply["error"]["workingSourcePath"].is_null(), "{reply}");
        assert!(
            reply["sourcePath"].is_null() && reply["pdfPath"].is_null(),
            "{reply}"
        );
    }
    assert_eq!(hash(&fs::read(source).unwrap()), PUBLIC_SHA);
}

#[test]
fn hwp5_paragraph_insert_keeps_original_ordinals_for_text_edits_and_reopened_anchors() {
    const EDITED: &str = "기존 요구사항 변경";
    const FOLLOWUP: &str = "후속 본문";
    let source = public_fixture();
    let directory = tempfile::tempdir().unwrap();
    let work = directory.path();
    let before = inspect(&source, work);
    assert_eq!(paragraph(&before, 5)["text"], "2. 요구사항");
    let original_neighbor = paragraph(&before, 6)["text"].clone();
    let reply = apply(
        &source,
        work,
        PUBLIC_SHA,
        vec![
            after(&before, MIDDLE, "middle-draft", MIDDLE_TEXT),
            json!({"op":"paragraphText", "id":"s0:p5", "text":EDITED}),
        ],
    );
    let output = saved(&reply, &source);
    let after_insert = inspect(&output, work);
    assert_eq!(paragraph(&after_insert, MIDDLE + 1)["text"], MIDDLE_TEXT);
    assert_eq!(paragraph(&after_insert, 6)["text"], EDITED);
    assert_eq!(paragraph(&after_insert, 7)["text"], original_neighbor);
    assert_eq!(
        paragraph(&after_insert, MIDDLE + 1)["structure"]["canInsertAfter"],
        true,
    );
    let output_before = fs::read(&output).unwrap();
    let followup = apply(
        &output,
        work,
        &hash(&output_before),
        vec![after(&after_insert, MIDDLE + 1, "followup-draft", FOLLOWUP)],
    );
    let reopened = inspect(&saved(&followup, &output), work);
    assert_eq!(paragraph(&reopened, MIDDLE + 1)["text"], MIDDLE_TEXT);
    assert_eq!(paragraph(&reopened, MIDDLE + 2)["text"], FOLLOWUP);
    assert_eq!(paragraph(&reopened, 7)["text"], EDITED);
    assert_eq!(paragraph(&reopened, 8)["text"], original_neighbor);
    assert_eq!(fs::read(output).unwrap(), output_before);
    assert_eq!(hash(&fs::read(source).unwrap()), PUBLIC_SHA);
}

#[test]
fn hwp5_paragraph_delete_preserves_every_surviving_record() {
    let directory = tempfile::tempdir().unwrap();
    for (name, index) in [("compressed", MIDDLE), ("raw", LAST)] {
        let work = directory.path().join(name);
        fs::create_dir(&work).unwrap();
        let source = work.join("original.hwp");
        fs::copy(public_fixture(), &source).unwrap();
        if name == "raw" {
            make_raw_variant(&source);
        }
        let original_bytes = fs::read(&source).unwrap();
        let before = inspect(&source, &work);
        let selected = paragraph(&before, index);
        let reply = apply(
            &source,
            &work,
            &hash(&original_bytes),
            vec![deletion(
                selected["id"].as_str().unwrap(),
                selected["text"].as_str().unwrap(),
            )],
        );
        let output = saved(&reply, &source);
        assert_eq!(selected["structure"]["canDelete"], true);
        assert_eq!(
            reply["snapshot"]["paragraphs"].as_array().unwrap().len() + 1,
            before["paragraphs"].as_array().unwrap().len()
        );

        let (old_storage, old_streams) = streams(&source);
        let (new_storage, new_streams) = streams(&output);
        assert_eq!(old_storage, new_storage);
        assert!(old_streams.keys().eq(new_streams.keys()));
        for (name, bytes) in &old_streams {
            if name != SECTION && name != PREVIEW_TEXT {
                assert_eq!(&new_streams[name], bytes, "{name}");
            }
        }
        let mut expected = Hwp5Container::open(&source)
            .unwrap()
            .read_record_stream(SECTION)
            .unwrap();
        let blocks = raw_paragraphs(&expected);
        assert_eq!(blocks.len(), LAST + 1);
        if index == LAST {
            expected[blocks[index - 1].header_payload + 3] |= 0x80;
        }
        expected.drain(blocks[index].bytes.clone());
        let actual = Hwp5Container::open(&output)
            .unwrap()
            .read_record_stream(SECTION)
            .unwrap();
        assert_eq!(actual, expected);
        assert_eq!(fs::read(source).unwrap(), original_bytes);
    }
}

#[test]
fn hwp5_paragraph_delete_refuses_stale_mixed_and_protected_targets() {
    let source = public_fixture();
    let directory = tempfile::tempdir().unwrap();
    let work = directory.path();
    let before = inspect(&source, work);
    let selected = paragraph(&before, MIDDLE);
    let valid = deletion(
        selected["id"].as_str().unwrap(),
        selected["text"].as_str().unwrap(),
    );
    assert!(
        before["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|p| p["id"] != "s0:p0" || p["structure"]["canDelete"] != true)
    );
    for (operations, error) in [
        (vec![deletion("s0:p1", "wrong text")], "source_changed"),
        (vec![valid.clone(), valid], "invalid_request"),
        (vec![deletion("s0:p2", "")], "unsupported_structure"),
        (vec![deletion("s0:p2:t0", "")], "invalid_request"),
        (vec![deletion("s0:p0", "")], "unsupported_structure"),
    ] {
        let reply = apply(&source, work, PUBLIC_SHA, operations);
        assert_eq!(reply["error"]["code"], error, "{reply}");
        assert!(reply["error"]["workingSourcePath"].is_null(), "{reply}");
        assert!(reply["sourcePath"].is_null() && reply["pdfPath"].is_null());
    }
    assert_eq!(hash(&fs::read(source).unwrap()), PUBLIC_SHA);
}
