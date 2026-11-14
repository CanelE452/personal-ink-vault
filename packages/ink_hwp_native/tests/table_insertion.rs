use ink_hwp_native::request_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fs, io::Read, path::Path};

#[path = "support/table_structure.rs"]
mod table_structure;

fn inspect(path: &Path) -> Value {
    request_json(&json!({"mode":"inspect","sourcePath":path}).to_string())
}

fn sha(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn apply(path: &Path, ops: &[Value], source_sha: &str) -> Value {
    let fonts = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build/native/fonts");
    request_json(
        &json!({"mode":"apply","sourcePath":path,
        "outputDirectory":path.parent().unwrap().join("work"),"fontDirectories":[fonts],
        "expectedSourceSha256":source_sha,"sessionId":"table-insertion-test","operations":ops})
        .to_string(),
    )
}

fn entries(path: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    (0..archive.len())
        .map(|index| {
            let mut file = archive.by_index(index).unwrap();
            let name = file.name().to_owned();
            let mut bytes = Vec::new();
            file.read_to_end(&mut bytes).unwrap();
            (name, bytes)
        })
        .collect()
}

fn fixture(dir: &Path) -> std::path::PathBuf {
    let path = dir.join("source.hwpx");
    let document = hwp_convert::from_markdown(
        "INSERT_HERE\n\nFOLLOWING_PARAGRAPH\n\n| ORIGINAL_A | ORIGINAL_B |\n| --- | --- |\n| existing | row |\n",
    );
    hwpx::write_document(&document, &path).unwrap();
    path
}

fn insertion(snapshot: &Value) -> Value {
    let anchor = snapshot["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["text"] == "INSERT_HERE")
        .unwrap();
    json!({"op":"tableInsert","id":"new-table-test","referenceId":anchor["id"],
        "position":"after","expectedTextSha256":sha(b"INSERT_HERE"),"rows":2,"columns":3})
}

#[test]
fn inserts_after_anchor_preserving_bytes_and_reopens_editable_cells_and_pdf() {
    let temp = tempfile::tempdir().unwrap();
    let source = fixture(temp.path());
    let source_bytes = fs::read(&source).unwrap();
    let before = inspect(&source);
    let before = &before["snapshot"];
    assert_eq!(before["supportsHwpTableInsert"], true, "{before}");
    assert_eq!(before["paragraphs"][0]["tableInsertAnchor"], true);
    assert_eq!(before["tables"].as_array().unwrap().len(), 1);
    let result = apply(&source, &[insertion(before)], &sha(&source_bytes));
    assert_eq!(result["status"], "saved", "{result}");
    assert_eq!(fs::read(&source).unwrap(), source_bytes);
    let output = Path::new(result["sourcePath"].as_str().unwrap());
    let pdf = fs::read(result["pdfPath"].as_str().unwrap()).unwrap();
    assert!(pdf.starts_with(b"%PDF-"));
    assert!(result["pdfPageCount"].as_u64().unwrap() > 0);

    let old = entries(&source);
    let new = entries(output);
    assert_eq!(
        old.keys().collect::<Vec<_>>(),
        new.keys().collect::<Vec<_>>()
    );
    let section = "Contents/section0.xml";
    for (key, bytes) in old.iter().filter(|(key, _)| key.as_str() != section) {
        assert_eq!(new[key], *bytes, "changed untouched entry {key}");
    }
    let old_xml = std::str::from_utf8(&old[section]).unwrap();
    let new_xml = std::str::from_utf8(&new[section]).unwrap();
    let anchor = old_xml.find("INSERT_HERE").unwrap();
    let split = anchor + old_xml[anchor..].find("</hp:p>").unwrap() + "</hp:p>".len();
    assert!(new_xml.starts_with(&old_xml[..split]));
    assert!(new_xml.ends_with(&old_xml[split..]));
    let added = &new_xml[split..new_xml.len() - (old_xml.len() - split)];
    assert!(added.contains("<hp:tbl "));
    assert_eq!(added.matches("<hp:tr>").count(), 2);
    assert_eq!(added.matches("<hp:tc ").count(), 6);

    let reopened = inspect(output);
    let tables = reopened["snapshot"]["tables"].as_array().unwrap();
    assert_eq!(tables.len(), 2);
    assert_eq!(tables[0]["id"], "s0:p1:t0");
    assert_eq!(tables[0]["cells"].as_object().unwrap().len(), 6);
    for row in 0..2 {
        for col in 0..3 {
            let key = format!("{row},{col}");
            assert_eq!(tables[0]["cells"][&key], "");
            assert_eq!(tables[0]["cellTextDetails"][&key]["canReplace"], true);
        }
    }
    assert_eq!(tables[1]["cells"]["1,0"], "existing");
    let edited = apply(
        output,
        &[json!({"op":"tableCellText","tableId":tables[0]["id"],
        "cell":"0,0","text":"새 셀"})],
        &sha(&fs::read(output).unwrap()),
    );
    assert_eq!(edited["status"], "saved", "{edited}");
    assert_eq!(edited["snapshot"]["tables"][0]["cells"]["0,0"], "새 셀");
}

#[test]
fn table_insert_requires_exact_source_digest_bounds_and_single_operation() {
    let temp = tempfile::tempdir().unwrap();
    let source = fixture(temp.path());
    let before = fs::read(&source).unwrap();
    let digest = sha(&before);
    let snapshot = inspect(&source);
    let good = insertion(&snapshot["snapshot"]);
    assert_eq!(
        apply(&source, &[good.clone()], &"0".repeat(64))["error"]["code"],
        "source_changed"
    );
    let mut bad = good.clone();
    bad["expectedTextSha256"] = json!("0".repeat(64));
    assert_eq!(
        apply(&source, &[bad], &digest)["error"]["code"],
        "source_changed"
    );
    for (field, value) in [
        ("rows", json!(0)),
        ("rows", json!(9)),
        ("rows", json!(true)),
        ("columns", json!(7)),
        ("position", json!("before")),
        ("id", json!("s0:p0")),
        ("text", json!("not a blank table")),
    ] {
        let mut bad = good.clone();
        bad[field] = value;
        assert_eq!(
            apply(&source, &[bad], &digest)["error"]["code"],
            "invalid_request",
            "{field}"
        );
    }
    assert_eq!(
        apply(&source, &[good.clone(), good], &digest)["error"]["code"],
        "invalid_request"
    );
    assert_eq!(fs::read(&source).unwrap(), before);
}

#[test]
fn populated_table_inserts_exact_cells_and_keeps_original_package_and_pdf() {
    let temp = tempfile::tempdir().unwrap();
    let source = fixture(temp.path());
    let source_bytes = fs::read(&source).unwrap();
    let before = inspect(&source);
    let boundary = "나".repeat(120);
    let cells = json!([
        [
            "  한글 & <값>  ",
            "",
            "one two three four five six seven eight nine ten"
        ],
        ["가나다", "행과 열", boundary]
    ]);
    let mut operation = insertion(&before["snapshot"]);
    operation["cells"] = cells.clone();
    let result = apply(&source, &[operation], &sha(&source_bytes));
    assert_eq!(result["status"], "saved", "{result}");
    let output = Path::new(result["sourcePath"].as_str().unwrap());
    assert_eq!(fs::read(&source).unwrap(), source_bytes);
    assert!(
        fs::read(result["pdfPath"].as_str().unwrap())
            .unwrap()
            .starts_with(b"%PDF-")
    );
    assert!(result["pdfPageCount"].as_u64().unwrap() > 0);
    let old = entries(&source);
    let new = entries(output);
    let section = "Contents/section0.xml";
    assert_eq!(
        old.keys().collect::<Vec<_>>(),
        new.keys().collect::<Vec<_>>()
    );
    for (key, bytes) in old.iter().filter(|(key, _)| key.as_str() != section) {
        assert_eq!(new[key], *bytes, "changed untouched entry {key}");
    }
    let old_xml = std::str::from_utf8(&old[section]).unwrap();
    let new_xml = std::str::from_utf8(&new[section]).unwrap();
    let anchor = old_xml.find("INSERT_HERE").unwrap();
    let split = anchor + old_xml[anchor..].find("</hp:p>").unwrap() + "</hp:p>".len();
    assert!(new_xml.starts_with(&old_xml[..split]));
    assert!(new_xml.ends_with(&old_xml[split..]));
    assert!(new_xml.contains("<hp:t>  한글 &amp; &lt;값&gt;  </hp:t>"));
    let reopened = inspect(output);
    let tables = reopened["snapshot"]["tables"].as_array().unwrap();
    assert_eq!(tables.len(), 2);
    for row in 0..2 {
        for col in 0..3 {
            let key = format!("{row},{col}");
            assert_eq!(tables[0]["cells"][&key], cells[row][col]);
            assert_eq!(tables[0]["cellTextDetails"][&key]["canReplace"], true);
        }
    }
    assert_eq!(tables[1]["cells"]["1,0"], "existing");
}

#[test]
fn populated_table_rejects_invalid_matrix_and_text_atomically() {
    let temp = tempfile::tempdir().unwrap();
    let source = fixture(temp.path());
    let before = fs::read(&source).unwrap();
    let source_sha = sha(&before);
    let snapshot = inspect(&source);
    let valid = insertion(&snapshot["snapshot"]);
    for invalid in [
        Value::Null,
        json!([["x", "y", "z"]]),
        json!([["x", "y"], ["", "", ""]]),
        json!([["x", true, "z"], ["", "", ""]]),
        json!([["x", "", ""], ["", "\u{2028}", ""]]),
        json!([["\t", "", ""], ["", "", ""]]),
        json!([["\u{0085}", "", ""], ["", "", ""]]),
        json!([["\u{fffe}", "", ""], ["", "", ""]]),
        json!([["나".repeat(121), "", ""], ["", "", ""]]),
    ] {
        let mut operation = valid.clone();
        operation["cells"] = invalid;
        let result = apply(&source, &[operation], &source_sha);
        assert_eq!(result["error"]["code"], "invalid_request", "{result}");
        assert_eq!(fs::read(&source).unwrap(), before);
        assert!(result.get("sourcePath").is_none());
        assert!(result.get("pdfPath").is_none());
    }
    let work = temp.path().join("work");
    for directory in fs::read_dir(work).into_iter().flatten() {
        let directory = directory.unwrap().path();
        assert!(!directory.join("edited.hwpx").exists());
        assert!(!directory.join("document.pdf").exists());
    }
}

#[test]
fn populated_table_refuses_nonbreaking_content_that_would_overflow_the_pdf_cell() {
    let temp = tempfile::tempdir().unwrap();
    let source = fixture(temp.path());
    let before = fs::read(&source).unwrap();
    let snapshot = inspect(&source);
    let mut operation = insertion(&snapshot["snapshot"]);
    operation["columns"] = json!(6);
    operation["cells"] = json!([
        ["가\u{00a0}".repeat(35), "", "", "", "", ""],
        ["", "", "", "", "", ""]
    ]);
    let result = apply(&source, &[operation], &sha(&before));
    assert_eq!(result["error"]["code"], "incomplete_layout", "{result}");
    assert_eq!(fs::read(&source).unwrap(), before);
    assert!(result.get("sourcePath").is_none());
    assert!(result.get("pdfPath").is_none());
}
