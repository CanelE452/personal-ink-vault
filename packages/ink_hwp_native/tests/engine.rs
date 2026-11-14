use ink_hwp_native::request_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};
use tempfile::TempDir;

fn hash(path: &Path) -> String {
    Sha256::digest(fs::read(path).unwrap())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn call(value: Value) -> Value {
    request_json(&value.to_string())
}
fn fonts() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build/native/fonts")
}
fn fixture(ext: &str) -> (TempDir, PathBuf) {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join(format!("original.{ext}"));
    let doc = hwp_convert::from_markdown(
        "ORIGINAL_PARAGRAPH\n\n| COL_A | COL_B |\n| --- | --- |\n| ORIGINAL_CELL | OTHER_CELL |\n",
    );
    if ext == "hwp" {
        hwp5::write_document_with_report(&doc, &source, &hwp5::WriteOptions::default()).unwrap();
    } else {
        hwpx::write_document(&doc, &source).unwrap();
    }
    (temp, source)
}
fn inspect(path: &Path) -> Value {
    call(json!({"mode":"inspect","sourcePath":path}))
}
fn operation(source: &Path, text: &str, cell: bool) -> Value {
    let snapshot = inspect(source);
    assert!(snapshot.get("error").is_none(), "{snapshot}");
    if cell {
        json!({"op":"tableCellText", "tableId":snapshot["snapshot"]["tables"][0]["id"], "cell":"1,0", "text":text})
    } else {
        let item = snapshot["snapshot"]["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["text"] == "ORIGINAL_PARAGRAPH")
            .unwrap();
        json!({"op":"paragraphText","id":item["id"],"text":text})
    }
}
fn apply(source: &Path, output: &Path, operations: Vec<Value>) -> Value {
    call(
        json!({"mode":"apply","sourcePath":source,"outputDirectory":output,"fontDirectories":[fonts()],"expectedSourceSha256":hash(source),"sessionId":"test-session","operations":operations}),
    )
}
fn rewrite_zip(path: &Path, transform: impl Fn(&str, Vec<u8>) -> Vec<u8>) {
    let mut input = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    let out = path.with_extension("rewrite");
    let mut writer = zip::ZipWriter::new(fs::File::create(&out).unwrap());
    for i in 0..input.len() {
        let mut entry = input.by_index(i).unwrap();
        let name = entry.name().to_owned();
        let mut bytes = Vec::new();
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
    drop(input);
    fs::rename(out, path).unwrap();
}

#[test]
fn invalid_json_is_structured() {
    assert_eq!(request_json("{")["error"]["code"], "invalid_json");
}
#[test]
fn supported_files_are_inspected_as_word() {
    for ext in ["hwp", "hwpx"] {
        let (_temp, source) = fixture(ext);
        let response = inspect(&source);
        assert_eq!(response["snapshot"]["kind"], "word", "{response}");
        assert_eq!(response["snapshot"]["tables"].as_array().unwrap().len(), 1);
    }
}
#[test]
fn actual_both_format_edits_save_new_original_and_pdf() {
    assert!(
        fonts().join("NotoSansCJKkr-Regular.otf").is_file(),
        "Run prepare-hwp-fonts first"
    );
    for ext in ["hwp", "hwpx"] {
        let (temp, source) = fixture(ext);
        let before = hash(&source);
        let a = operation(&source, "NEW_PARAGRAPH", false);
        let b = operation(&source, "NEW_CELL", true);
        let result = apply(&source, &temp.path().join("work"), vec![a, b]);
        if let Some(w) = result["error"]["workingDirectory"].as_str() {
            eprintln!(
                "DIAGNOSTICS {:?}",
                fs::read_to_string(Path::new(w).join("diagnostics.json"))
            );
        }
        assert_eq!(result["status"], "saved", "{result}");
        assert_eq!(hash(&source), before);
        let output = Path::new(result["sourcePath"].as_str().unwrap());
        assert_ne!(output, source);
        assert_eq!(hash(output), result["sourceSha256"]);
        let reopened = inspect(output);
        assert!(reopened.to_string().contains("NEW_PARAGRAPH"));
        assert!(reopened.to_string().contains("NEW_CELL"));
        let pdf = fs::read(result["pdfPath"].as_str().unwrap()).unwrap();
        assert!(pdf.starts_with(b"%PDF-"));
        assert!(result["pdfPageCount"].as_u64().unwrap() > 0);
    }
}
#[test]
fn long_body_reflows_but_long_cell_is_refused_and_working_original_retained() {
    for ext in ["hwp", "hwpx"] {
        let (temp, source) = fixture(ext);
        let long = "REFLOW_WORD ".repeat(500);
        let op = operation(&source, &long, false);
        let result = apply(&source, &temp.path().join("longbody"), vec![op]);
        if let Some(w) = result["error"]["workingDirectory"].as_str() {
            eprintln!(
                "DIAGNOSTICS {:?}",
                fs::read_to_string(Path::new(w).join("diagnostics.json"))
            );
        }
        assert_eq!(result["status"], "saved", "{result}");
        assert!(result["pdfPageCount"].as_u64().unwrap() > 1);
        let op = operation(&source, &"CELL_WORD ".repeat(400), true);
        let failed = apply(&source, &temp.path().join("longcell"), vec![op]);
        assert_eq!(failed["error"]["code"], "incomplete_layout", "{failed}");
        let working = failed["error"]["workingSourcePath"].as_str().unwrap();
        assert!(Path::new(working).is_file());
        assert_ne!(hash(Path::new(working)), hash(&source));
    }
}
#[test]
fn stale_source_and_unsupported_operations_are_refused() {
    let (temp, source) = fixture("hwp");
    let response = call(
        json!({"mode":"apply","sourcePath":source,"outputDirectory":temp.path().join("work"),"expectedSourceSha256":"0".repeat(64),"sessionId":"x","operations":[{"op":"shapeText"}]}),
    );
    assert_eq!(response["error"]["code"], "source_changed");
    let result = apply(
        &source,
        &temp.path().join("other"),
        vec![json!({"op":"paragraphStyle","id":"s0:p0","bold":true})],
    );
    assert_eq!(result["error"]["code"], "unsupported_operation");
}
#[test]
fn hwpx_foreign_attribute_and_doctype_are_refused() {
    let (temp, source) = fixture("hwpx");
    let op = operation(&source, "NEW_PARAGRAPH", false);
    rewrite_zip(&source, |name, bytes| {
        if name == "Contents/section0.xml" {
            String::from_utf8(bytes)
                .unwrap()
                .replacen(
                    "<hs:sec ",
                    "<hs:sec xmlns:owned=\"urn:ink-test\" owned:sentinel=\"KEEP\" ",
                    1,
                )
                .into_bytes()
        } else {
            bytes
        }
    });
    let response = apply(&source, &temp.path().join("foreign"), vec![op]);
    assert_eq!(response["error"]["code"], "unsupported_loss", "{response}");
    rewrite_zip(&source, |name, bytes| {
        if name == "Contents/section0.xml" {
            let text = String::from_utf8(bytes).unwrap();
            let pos = text.find("?>").map_or(0, |p| p + 2);
            format!(
                "{}<!DOCTYPE sec [<!ENTITY owned SYSTEM 'file:///nonexistent-owned-marker'>]>{}",
                &text[..pos],
                &text[pos..]
            )
            .into_bytes()
        } else {
            bytes
        }
    });
    assert_eq!(inspect(&source)["error"]["code"], "unsafe_xml");
}

#[test]
fn hwpx_text_nodes_must_not_drop_unknown_children() {
    for child in [
        "<owned xmlns=\"urn:ink-test\" marker=\"KEEP\"/>",
        "<hp:owned marker=\"KEEP\"/>",
    ] {
        let (temp, source) = fixture("hwpx");
        let op = operation(&source, "NEW_PARAGRAPH", false);
        rewrite_zip(&source, |name, bytes| {
            if name == "Contents/section0.xml" {
                String::from_utf8(bytes)
                    .unwrap()
                    .replacen(
                        "ORIGINAL_PARAGRAPH</hp:t>",
                        &format!("ORIGINAL_PARAGRAPH{child}</hp:t>"),
                        1,
                    )
                    .into_bytes()
            } else {
                bytes
            }
        });
        let response = apply(&source, &temp.path().join("opaque"), vec![op]);
        assert_eq!(response["error"]["code"], "unsupported_loss", "{response}");
    }
}

#[test]
fn hwpx_known_inline_whitespace_can_be_replaced_without_changing_other_entries() {
    let (temp, source) = fixture("hwpx");
    rewrite_zip(&source, |name, bytes| {
        if name == "Contents/section0.xml" {
            String::from_utf8(bytes).unwrap().replacen(
                "ORIGINAL_PARAGRAPH</hp:t>",
                "ORIGINAL<hp:tab width=\"4000\" leader=\"0\" type=\"1\"/>PARAGRAPH<hp:lineBreak/>TAIL</hp:t>",
                1,
            ).into_bytes()
        } else {
            bytes
        }
    });
    let before = hash(&source);
    let opened = inspect(&source);
    assert_eq!(
        opened["snapshot"]["paragraphs"][0]["text"],
        "ORIGINAL\tPARAGRAPH\nTAIL"
    );
    let result = apply(
        &source,
        &temp.path().join("changed"),
        vec![json!({
            "op":"paragraphText", "id":"s0:p0", "text":"EDITED_INLINE_WHITESPACE"
        })],
    );
    assert_eq!(result["status"], "saved", "{result}");
    assert_eq!(hash(&source), before);
    let output = Path::new(result["sourcePath"].as_str().unwrap());
    assert_eq!(
        inspect(output)["snapshot"]["paragraphs"][0]["text"],
        "EDITED_INLINE_WHITESPACE"
    );
    let mut old = zip::ZipArchive::new(fs::File::open(&source).unwrap()).unwrap();
    let mut new = zip::ZipArchive::new(fs::File::open(output).unwrap()).unwrap();
    for index in 0..old.len() {
        let mut entry = old.by_index(index).unwrap();
        if entry.name() == "Contents/section0.xml" || entry.name() == "Preview/PrvText.txt" {
            continue;
        }
        let mut previous = Vec::new();
        entry.read_to_end(&mut previous).unwrap();
        let mut current = Vec::new();
        new.by_name(entry.name())
            .unwrap()
            .read_to_end(&mut current)
            .unwrap();
        assert_eq!(previous, current, "{} changed", entry.name());
    }
}

#[test]
fn replacement_tabs_and_line_breaks_reopen_as_semantic_whitespace() {
    for ext in ["hwp", "hwpx"] {
        let (temp, source) = fixture(ext);
        let before = hash(&source);
        let result = apply(
            &source,
            &temp.path().join("changed"),
            vec![operation(
                &source,
                "EDITED\tTAB\nLINE\r\nPAIR\rRETURN",
                false,
            )],
        );
        assert_eq!(result["status"], "saved", "{result}");
        assert_eq!(hash(&source), before);
        let output = Path::new(result["sourcePath"].as_str().unwrap());
        assert_eq!(
            inspect(output)["snapshot"]["paragraphs"][0]["text"],
            "EDITED\tTAB\nLINE\nPAIR\nRETURN"
        );
        if ext == "hwpx" {
            let mut package = zip::ZipArchive::new(fs::File::open(output).unwrap()).unwrap();
            let mut section = String::new();
            package
                .by_name("Contents/section0.xml")
                .unwrap()
                .read_to_string(&mut section)
                .unwrap();
            assert!(section.contains("<hp:tab width=\"4000\" leader=\"0\" type=\"1\"/>"));
            assert!(section.contains("<hp:lineBreak/>"));
        }
    }
}

#[test]
fn known_inline_whitespace_never_discards_unknown_attributes_or_structure() {
    for child in [
        "<hp:lineBreak keep=\"KEEP\"/>",
        "<hp:tab width=\"4000\" leader=\"0\" type=\"1\" keep=\"KEEP\"/>",
        "<hp:tab width=\"invalid\" leader=\"0\" type=\"1\"/>",
        "<hp:tab width=\"4000\" leader=\"0\" type=\"1\">KEEP</hp:tab>",
        "<hp:lineBreak><!--KEEP--></hp:lineBreak>",
        "<hc:lineBreak/>",
        "<hp:lineBreak xmlns:hp=\"http://www.hancom.co.kr/hwpml/2011/core\"/>",
    ] {
        let (temp, source) = fixture("hwpx");
        rewrite_zip(&source, |name, bytes| {
            if name == "Contents/section0.xml" {
                String::from_utf8(bytes)
                    .unwrap()
                    .replacen(
                        "ORIGINAL_PARAGRAPH</hp:t>",
                        &format!("ORIGINAL_PARAGRAPH{child}</hp:t>"),
                        1,
                    )
                    .into_bytes()
            } else {
                bytes
            }
        });
        let before = hash(&source);
        let response = apply(
            &source,
            &temp.path().join("refused"),
            vec![json!({
                "op":"paragraphText", "id":"s0:p0", "text":"NEW_PARAGRAPH"
            })],
        );
        assert_eq!(
            response["error"]["code"], "unsupported_loss",
            "{child}: {response}"
        );
        assert_eq!(hash(&source), before);
    }
}

#[test]
fn replacement_non_whitespace_control_characters_stay_refused() {
    let (temp, source) = fixture("hwpx");
    for value in ["X\u{0000}Y", "X\u{0001}Y", "X\u{000b}Y", "X\u{007f}Y"] {
        let response = apply(
            &source,
            &temp.path().join("refused"),
            vec![operation(&source, value, false)],
        );
        assert_eq!(response["error"]["code"], "unsupported_text", "{response}");
    }
}

#[test]
fn authored_inline_controls_use_the_existing_paragraph_namespace_prefix() {
    let (temp, source) = fixture("hwpx");
    rewrite_zip(&source, |name, bytes| {
        if name == "Contents/section0.xml" {
            String::from_utf8(bytes)
                .unwrap()
                .replace("xmlns:hp=", "xmlns:p=")
                .replace("hp:", "p:")
                .into_bytes()
        } else {
            bytes
        }
    });
    let result = apply(
        &source,
        &temp.path().join("alias"),
        vec![operation(&source, "ALIAS\tTAB\nLINE", false)],
    );
    assert_eq!(result["status"], "saved", "{result}");
    let output = Path::new(result["sourcePath"].as_str().unwrap());
    assert_eq!(
        inspect(output)["snapshot"]["paragraphs"][0]["text"],
        "ALIAS\tTAB\nLINE"
    );
    let mut package = zip::ZipArchive::new(fs::File::open(output).unwrap()).unwrap();
    let mut section = String::new();
    package
        .by_name("Contents/section0.xml")
        .unwrap()
        .read_to_string(&mut section)
        .unwrap();
    assert!(section.contains("<p:tab width=\"4000\" leader=\"0\" type=\"1\"/>"));
    assert!(section.contains("<p:lineBreak/>"));
    assert!(!section.contains("<hp:"));
}

#[test]
fn declared_zip_expansion_is_rejected_before_inflation() {
    let (_temp, source) = fixture("hwpx");
    let mut data = fs::read(&source).unwrap();
    let marker = b"PK\x01\x02";
    let at = data.windows(4).position(|b| b == marker).unwrap();
    data[at + 24..at + 28].copy_from_slice(&(40u32 * 1024 * 1024).to_le_bytes());
    fs::write(&source, data).unwrap();
    assert_eq!(inspect(&source)["error"]["code"], "resource_limit");
}

#[test]
fn protected_hwp_is_never_decrypted_or_edited() {
    let (_temp, source) = fixture("hwp");
    let mut data = fs::read(&source).unwrap();
    let at = data
        .windows(17)
        .position(|b| b == b"HWP Document File")
        .unwrap();
    let flags = u32::from_le_bytes(data[at + 36..at + 40].try_into().unwrap()) | (1 << 4);
    data[at + 36..at + 40].copy_from_slice(&flags.to_le_bytes());
    fs::write(&source, data).unwrap();
    assert_eq!(inspect(&source)["error"]["code"], "protected_document");
}

#[test]
fn ffi_null_invalid_utf8_and_owned_free_are_safe() {
    use std::ffi::CStr;
    unsafe {
        for input in [std::ptr::null(), c"{".as_ptr(), [0xffu8, 0].as_ptr().cast()] {
            let result = ink_hwp_native::ink_hwp_request(input);
            let value: Value =
                serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()).unwrap();
            assert!(value["error"]["code"].is_string());
            ink_hwp_native::ink_hwp_free(result);
        }
        ink_hwp_native::ink_hwp_free(std::ptr::null_mut());
    }
}

#[test]
fn rewritten_hwp_recomputes_removed_inline_control_mask() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("tab.hwp");
    let mut doc = hwp_convert::from_markdown("ORIGINAL_PARAGRAPH");
    let p = &mut doc.sections[0].paragraphs[0];
    p.chars.insert(
        1,
        hwp_model::HwpChar::InlineCtrl {
            code: 9,
            payload: vec![0; 12],
        },
    );
    p.header.ctrl_mask = 1 << 9;
    hwp5::write_document_with_report(&doc, &source, &hwp5::WriteOptions::default()).unwrap();
    assert_ne!(
        hwp5::read_document(&source).unwrap().document.sections[0].paragraphs[0]
            .header
            .ctrl_mask
            & (1 << 9),
        0
    );
    let response = apply(
        &source,
        &temp.path().join("mask"),
        vec![json!({"op":"paragraphText","id":"s0:p0","text":"NEW_PARAGRAPH"})],
    );
    assert_eq!(response["status"], "saved", "{response}");
    let output = Path::new(response["sourcePath"].as_str().unwrap());
    assert_eq!(
        hwp5::read_document(output).unwrap().document.sections[0].paragraphs[0]
            .header
            .ctrl_mask
            & (1 << 9),
        0
    );
}
