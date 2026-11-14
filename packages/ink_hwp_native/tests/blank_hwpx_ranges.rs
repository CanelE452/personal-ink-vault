use hwp_model::HwpChar;
use ink_hwp_native::request_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use tempfile::TempDir;
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

const SECTION: &str = "Contents/section0.xml";
const INPUT: &str = "첫 입력 😀\t& <다음>";

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn section(path: &Path) -> String {
    let mut archive = ZipArchive::new(File::open(path).unwrap()).unwrap();
    let mut xml = String::new();
    archive
        .by_name(SECTION)
        .unwrap()
        .read_to_string(&mut xml)
        .unwrap();
    xml
}

fn fixture(temp: &TempDir, rewrite: impl FnOnce(&str) -> String) -> PathBuf {
    let template = temp.path().join("template.hwpx");
    let document = hwp_convert::from_markdown("FIRST_BODY\n\nSECOND_BODY\n\nUNCHANGED_BODY\n");
    hwpx::write_document(&document, &template).unwrap();
    let changed = rewrite(&section(&template));
    let source = temp.path().join("original.hwpx");
    let mut archive = ZipArchive::new(File::open(template).unwrap()).unwrap();
    let mut output = ZipWriter::new(File::create(&source).unwrap());
    for index in 0..archive.len() {
        let entry = archive.by_index(index).unwrap();
        if entry.name() == SECTION {
            output
                .start_file(
                    SECTION,
                    SimpleFileOptions::default().compression_method(entry.compression()),
                )
                .unwrap();
            output.write_all(changed.as_bytes()).unwrap();
        } else {
            output.raw_copy_file(entry).unwrap();
        }
    }
    output.finish().unwrap();
    source
}

fn apply(temp: &TempDir, source: &Path, paragraph: usize) -> Value {
    replace(temp, source, paragraph, "", INPUT)
}

fn replace(temp: &TempDir, source: &Path, paragraph: usize, before: &str, after: &str) -> Value {
    let sha256 = hash(&fs::read(source).unwrap());
    request_json(
        &json!({
            "mode": "apply",
            "sourcePath": source,
            "outputDirectory": temp.path().join("out"),
            "expectedSourceSha256": sha256,
            "sessionId": "blank-hwpx",
            "fontDirectories": [Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build/native/fonts")],
            "operations": [{
                "op": "textReplace",
                "targetKind": "paragraph",
                "id": format!("s0:p{paragraph}"),
                "startUtf16": 0,
                "endUtf16": before.encode_utf16().count(),
                "expectedTextSha256": hash(before.as_bytes()),
                "text": after
            }]
        })
        .to_string(),
    )
}

fn assert_saved(temp: &TempDir, source: &Path, paragraph: usize) -> String {
    let original = fs::read(source).unwrap();
    let result = apply(temp, source, paragraph);
    assert_eq!(result["status"], "saved", "{result}");
    let output = Path::new(result["sourcePath"].as_str().unwrap());
    let reopened = hwpx::read_document(output).unwrap().document;
    let typed: String = reopened.sections[0].paragraphs[paragraph]
        .chars
        .iter()
        .filter_map(|value| match value {
            HwpChar::Text(c) => Some(*c),
            HwpChar::InlineCtrl { code: 9, .. } => Some('\t'),
            _ => None,
        })
        .collect();
    assert_eq!(typed, INPUT);
    assert_eq!(fs::read(source).unwrap(), original);
    assert!(
        fs::read(result["pdfPath"].as_str().unwrap())
            .unwrap()
            .starts_with(b"%PDF-")
    );
    let xml = section(output);
    assert!(xml.contains("UNCHANGED_BODY"));
    xml
}

#[test]
fn first_input_expands_empty_runs_and_preserves_control_only_runs() {
    let aliased =
        "<piv:run xmlns:piv='http://www.hancom.co.kr/hwpml/2011/paragraph' charPrIDRef='0'>";
    for (empty, typed_prefix) in [
        (
            "<hp:run charPrIDRef=\"0\"/>".into(),
            "<hp:run charPrIDRef=\"0\"><hp:t".into(),
        ),
        (format!("{aliased} </piv:run>"), format!("{aliased}<piv:t")),
    ] {
        let temp = TempDir::new().unwrap();
        let source = fixture(&temp, |xml| {
            let run = "<hp:run charPrIDRef=\"0\"><hp:t xml:space=\"preserve\">SECOND_BODY</hp:t></hp:run>";
            assert!(xml.contains(run));
            xml.replace(run, &empty)
        });
        assert!(assert_saved(&temp, &source, 1).contains(&typed_prefix));
    }

    let temp = TempDir::new().unwrap();
    let source = fixture(&temp, |xml| {
        let text = "<hp:t xml:space=\"preserve\">FIRST_BODY</hp:t>";
        assert!(xml.contains(text));
        xml.replace(text, "")
    });
    let original = section(&source);
    let start = original.find("<hp:run ").unwrap();
    let end = original.find("</hp:run>").unwrap() + "</hp:run>".len();
    let control_run = &original[start..end];
    assert!(control_run.contains("<hp:secPr") && control_run.contains("<hp:colPr"));
    assert!(assert_saved(&temp, &source, 0).contains(control_run));
}

#[test]
fn multiple_blank_runs_stay_editable_after_the_first_save() {
    let temp = TempDir::new().unwrap();
    let empty_run = "<hp:run charPrIDRef=\"0\"/>";
    let source = fixture(&temp, |xml| {
        let run = "<hp:run charPrIDRef=\"0\"><hp:t xml:space=\"preserve\">SECOND_BODY</hp:t></hp:run>";
        assert!(xml.contains(run));
        xml.replace(run, &empty_run.repeat(2))
    });
    let original = fs::read(&source).unwrap();
    let inserted = apply(&temp, &source, 1);
    assert_eq!(inserted["status"], "saved", "{inserted}");
    let written = Path::new(inserted["sourcePath"].as_str().unwrap());
    assert!(section(written).contains(empty_run));
    let cleared = replace(&temp, written, 1, INPUT, "");
    assert_eq!(cleared["status"], "saved", "{cleared}");
    let cleared_path = Path::new(cleared["sourcePath"].as_str().unwrap());
    let retyped = apply(&temp, cleared_path, 1);
    assert_eq!(retyped["status"], "saved", "{retyped}");
    assert_eq!(fs::read(&source).unwrap(), original);
}

#[test]
fn foreign_element_in_a_blank_run_is_not_overwritten() {
    let temp = TempDir::new().unwrap();
    let source = fixture(&temp, |xml| {
        let text = "<hp:t xml:space=\"preserve\">SECOND_BODY</hp:t>";
        assert!(xml.contains(text));
        xml.replace(text, "<ext:note xmlns:ext=\"urn:example\"/>")
    });
    let original = fs::read(&source).unwrap();
    let result = apply(&temp, &source, 1);
    assert!(result.get("error").is_some(), "{result}");
    assert_eq!(fs::read(source).unwrap(), original);
}
