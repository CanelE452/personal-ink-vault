use ink_hwp_native::request_json;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};
use tempfile::TempDir;

const SYMBOLS_SHA: &str = "7d5fb73b7ca67a6798101741f5d280a3d016a56a197afcd4199dbb57b4b82a21";

fn fonts() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build/native/fonts")
}
fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn write(ext: &str, temp: &TempDir) -> PathBuf {
    let source = temp.path().join(format!("original.{ext}"));
    let doc = hwp_convert::from_markdown(
        "PDF_PARAGRAPH 한글 문단\n\n| COL_A | COL_B |\n| --- | --- |\n| 셀 | 값 |\n",
    );
    if ext == "hwp" {
        hwp5::write_document_with_report(&doc, &source, &hwp5::WriteOptions::default()).unwrap();
    } else {
        hwpx::write_document(&doc, &source).unwrap();
    }
    source
}

#[test]
fn pdf_mode_renders_hwp_and_hwpx_with_rhwp() {
    for ext in ["hwp", "hwpx"] {
        let temp = TempDir::new().unwrap();
        let source = write(ext, &temp);
        let output = temp.path().join("out");
        let result = request_json(
            &json!({"mode":"pdf","sourcePath":source,"outputDirectory":output,"fontDirectories":[fonts()]})
                .to_string(),
        );
        assert_eq!(result["status"], "previewed", "{ext}: {result}");
        let pdf = fs::read(result["pdfPath"].as_str().unwrap()).unwrap();
        assert!(pdf.starts_with(b"%PDF-"), "{ext}");
        assert_eq!(result["pdfSha256"], hash(&pdf), "{ext}");
        assert_eq!(result["sourceSha256"], hash(&fs::read(&source).unwrap()), "{ext}");
        assert!(result["pdfPageCount"].as_u64().unwrap() >= 1, "{ext}");
        assert!(result["engineVersion"].as_str().unwrap().contains("rhwp.0.9.0"), "{ext}");
        assert!(Path::new(result["pdfPath"].as_str().unwrap()).starts_with(&output), "{ext}");
        let work = Path::new(result["workingDirectory"].as_str().unwrap());
        let symbols = fs::read(work.join("fallback-fonts/NotoSansSymbols2-Regular.ttf")).unwrap();
        assert_eq!(hash(&symbols), SYMBOLS_SHA, "{ext}: the pinned symbol fallback font");
    }
}

#[test]
fn pdf_mode_refuses_a_directory_without_the_pinned_font() {
    let temp = TempDir::new().unwrap();
    let source = write("hwpx", &temp);
    let result = request_json(
        &json!({"mode":"pdf","sourcePath":source,"outputDirectory":temp.path().join("out"),"fontDirectories":[temp.path()]})
            .to_string(),
    );
    assert_eq!(result["error"]["code"], "fonts_unavailable", "{result}");
}

#[test]
fn pdf_mode_reports_an_unreadable_document() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("broken.hwp");
    fs::write(&source, b"not a hwp document").unwrap();
    let result = request_json(
        &json!({"mode":"pdf","sourcePath":source,"outputDirectory":temp.path().join("out"),"fontDirectories":[fonts()]})
            .to_string(),
    );
    assert_eq!(result["error"]["code"], "unsupported_parse", "{result}");
}
