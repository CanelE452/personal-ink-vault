use ink_hwp_native::request_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    env, fs,
    path::{Path, PathBuf},
};

const FIXTURE_SHA: &str = "4ff3c231d835f37ceaa08ccd41f7db66d74d65a5a03c0791f6f683cc9fde0d39";
const TABLE_ID: &str = "s0:p2:t0";
const REMOVED_DATE: &str = "2026. 9.-2027. 2.";
const SECTION: &str = "/BodyText/Section0";
const PREVIEW: &str = "/PrvText";

fn sha(path: &Path) -> String {
    Sha256::digest(fs::read(path).unwrap())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn project_path(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(path)
}

fn public_fixture() -> PathBuf {
    let path = env::var_os("PIV_HWP5_ROW_FIXTURE").map_or_else(
        || {
            project_path(concat!(
                "build/research/hwp/hwp-cli-v1.3.1-source/",
                "hwp-cli-4e6e8c2a61694899e37b4f7c2f97523153a623b9/",
                "fixtures/pdf-parity/public/source/public-safety-rfp-p1.hwp"
            ))
        },
        PathBuf::from,
    );
    assert!(
        path.is_file(),
        "Set PIV_HWP5_ROW_FIXTURE to the pinned public HWP5 fixture"
    );
    assert_eq!(sha(&path), FIXTURE_SHA);
    path
}

fn call(request: Value) -> Value {
    request_json(&request.to_string())
}

fn inspect(path: &Path, work: &Path) -> Value {
    let result = call(json!({"mode":"inspect","sourcePath":path,"outputDirectory":work}));
    assert!(result["error"].is_null(), "{result}");
    result["snapshot"].clone()
}

fn table<'a>(snapshot: &'a Value, id: &str) -> &'a Value {
    snapshot["tables"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == id)
        .unwrap()
}

fn row_operation(id: &str, action: &str, index: usize) -> Value {
    json!({"op":"tableStructure","id":id,"action":action,"index":index})
}

fn apply(source: &Path, work: &Path, expected: &str, operations: Vec<Value>) -> Value {
    call(json!({
        "mode":"apply", "sourcePath":source, "outputDirectory":work,
        "sessionId":"hwp5-table-row-test", "expectedSourceSha256":expected,
        "fontDirectories":[project_path("build/native/fonts")], "operations":operations
    }))
}

fn check_saved(result: &Value, source: &Path) -> PathBuf {
    assert_eq!(result["status"], "saved", "{result}");
    let saved = PathBuf::from(result["sourcePath"].as_str().unwrap());
    let pdf = Path::new(result["pdfPath"].as_str().unwrap());
    assert_ne!(saved, source);
    assert_eq!(saved.extension().unwrap(), "hwp");
    assert_eq!(sha(&saved), result["sourceSha256"]);
    assert_eq!(sha(pdf), result["pdfSha256"]);
    assert_eq!(result["pdfPageCount"], 1);
    assert!(fs::read(pdf).unwrap().starts_with(b"%PDF-"));
    saved
}

fn streams(path: &Path) -> (Vec<String>, BTreeMap<String, Vec<u8>>) {
    let mut container = hwp5::Hwp5Container::open(path).unwrap();
    let streams = container
        .list_streams()
        .into_iter()
        .map(|stream| {
            let bytes = container.read_stream_raw(&stream.path).unwrap();
            (stream.path, bytes)
        })
        .collect();
    (container.list_storages(), streams)
}

fn preview_text(bytes: &[u8]) -> String {
    assert_eq!(bytes.len() % 2, 0);
    let units: Vec<_> = bytes
        .chunks_exact(2)
        .map(|x| u16::from_le_bytes([x[0], x[1]]))
        .collect();
    String::from_utf16(&units).unwrap()
}

#[test]
fn hwp5_edits_real_inline_table_rows_and_preserves_the_other_streams() {
    let fixture = public_fixture();
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("original.hwp");
    fs::copy(fixture, &source).unwrap();
    let before = inspect(&source, dir.path());
    let original = table(&before, TABLE_ID);
    assert_eq!(original["cells"]["1,1"], REMOVED_DATE);
    assert_eq!(
        original["structure"],
        json!({"rows":3,"columns":2,"canInsertRow":true,"canDeleteRow":true,"canInsertColumn":false,"canDeleteColumn":false}),
        "{original}"
    );

    let inserted = apply(
        &source,
        dir.path(),
        FIXTURE_SHA,
        vec![row_operation(TABLE_ID, "insertRow", 1)],
    );
    let inserted_path = check_saved(&inserted, &source);
    let reopened = inspect(&inserted_path, dir.path());
    let after_insert = table(&reopened, TABLE_ID);
    assert_eq!(after_insert, table(&inserted["snapshot"], TABLE_ID));
    assert_eq!(after_insert["structure"]["rows"], 4);
    assert_eq!(after_insert["cells"]["1,0"], "");
    assert_eq!(after_insert["cells"]["1,1"], "");
    assert_eq!(after_insert["cells"]["2,1"], REMOVED_DATE);
    assert_eq!(
        after_insert["cellTextDetails"]["2,1"],
        original["cellTextDetails"]["1,1"]
    );
    assert_eq!(table(&reopened, "s0:p4:t0"), table(&before, "s0:p4:t0"));

    let filled = apply(
        &inserted_path,
        dir.path(),
        &sha(&inserted_path),
        vec![json!({"op":"tableCellText","tableId":TABLE_ID,"cell":"1,0","text":"추가"})],
    );
    let filled_path = check_saved(&filled, &inserted_path);
    assert_eq!(
        table(&inspect(&filled_path, dir.path()), TABLE_ID)["cells"]["1,0"],
        "추가"
    );

    let deleted = apply(
        &source,
        dir.path(),
        FIXTURE_SHA,
        vec![row_operation(TABLE_ID, "deleteRow", 1)],
    );
    let deleted_path = check_saved(&deleted, &source);
    let reopened = inspect(&deleted_path, dir.path());
    let after_delete = table(&reopened, TABLE_ID);
    assert_eq!(after_delete, table(&deleted["snapshot"], TABLE_ID));
    assert_eq!(after_delete["structure"]["rows"], 2);
    assert_eq!(after_delete["cells"]["1,1"], original["cells"]["2,1"]);
    assert_eq!(
        after_delete["cellTextDetails"]["1,1"],
        original["cellTextDetails"]["2,1"]
    );
    assert_eq!(table(&reopened, "s0:p4:t0"), table(&before, "s0:p4:t0"));

    let (original_storages, original_streams) = streams(&source);
    assert!(preview_text(&original_streams[PREVIEW]).contains(REMOVED_DATE));
    for candidate in [inserted_path, deleted_path.clone()] {
        let (candidate_storages, candidate_streams) = streams(&candidate);
        assert_eq!(candidate_storages, original_storages);
        assert_eq!(
            candidate_streams.keys().collect::<Vec<_>>(),
            original_streams.keys().collect::<Vec<_>>()
        );
        assert_ne!(candidate_streams[SECTION], original_streams[SECTION]);
        for (name, original) in &original_streams {
            if name != SECTION && name != PREVIEW {
                assert_eq!(
                    &candidate_streams[name], original,
                    "modified unrelated stream {name}"
                );
            }
        }
        assert_eq!(
            preview_text(&candidate_streams[PREVIEW]).contains(REMOVED_DATE),
            candidate != deleted_path
        );
    }
    assert_eq!(sha(&source), FIXTURE_SHA);
}

#[test]
fn hwp5_rejects_stale_out_of_range_and_mixed_table_operations() {
    let source = public_fixture();
    let dir = tempfile::tempdir().unwrap();
    let valid = row_operation(TABLE_ID, "insertRow", 1);
    let missing_digest = call(json!({
        "mode":"apply", "sourcePath":source, "outputDirectory":dir.path(),
        "sessionId":"hwp5-table-row-test", "operations":[valid.clone()]
    }));
    assert_eq!(missing_digest["error"]["code"], "invalid_request");
    assert_eq!(
        apply(&source, dir.path(), &"0".repeat(64), vec![valid.clone()])["error"]["code"],
        "source_changed"
    );
    assert_eq!(
        apply(&source, dir.path(), FIXTURE_SHA, vec![valid.clone(), valid])["error"]["code"],
        "invalid_request"
    );
    for (action, index, code) in [
        ("deleteRow", 3, "invalid_request"),
        ("insertRow", 4, "invalid_request"),
        ("insertColumn", 0, "unsupported_structure"),
        ("deleteColumn", 0, "unsupported_structure"),
    ] {
        let result = apply(
            &source,
            dir.path(),
            FIXTURE_SHA,
            vec![row_operation(TABLE_ID, action, index)],
        );
        assert_eq!(result["error"]["code"], code, "{result}");
        assert!(result["error"]["workingSourcePath"].is_null(), "{result}");
        assert!(
            result["sourcePath"].is_null() && result["pdfPath"].is_null(),
            "{result}"
        );
    }
    assert_eq!(sha(&source), FIXTURE_SHA);
}

#[test]
fn hwp5_does_not_advertise_or_apply_row_edits_on_a_merged_table() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("merged.hwp");
    let mut document = hwp_convert::from_markdown("Intro\n\n| A | B |\n| --- | --- |\n| C | D |\n");
    hwp_convert::merge_cells(&mut document, 0, 0, 0, 0, 1).unwrap();
    hwp5::write_document(&document, &source, &hwp5::WriteOptions::default()).unwrap();
    let before = sha(&source);
    let snapshot = inspect(&source, dir.path());
    let target = &snapshot["tables"][0];
    assert!(target["structure"].is_null(), "{target}");
    let id = target["id"].as_str().unwrap();
    assert!(id.ends_with(":t0"), "{target}");
    let result = apply(
        &source,
        dir.path(),
        &before,
        vec![row_operation(id, "insertRow", 1)],
    );
    assert_eq!(result["error"]["code"], "unsupported_structure", "{result}");
    assert!(result["error"]["workingSourcePath"].is_null(), "{result}");
    assert_eq!(sha(&source), before);
}
