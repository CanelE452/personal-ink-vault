//! PDF for handwriting: rhwp lays out and renders every page of the original.
//! This path does not go through the structured editor's strict checks, so documents
//! the editor cannot change can still be imported as PDF.
use crate::engine::{FONT_SHA, file_hash, hash};
use crate::{ApiError, Result, err, invalid, io_error};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub(crate) const ENGINE_VERSION: &str = "ink_hwp_native/0.1.0+rhwp.0.9.0-dev.4cf97fe5";
const FONT_FAMILY: &str = "Noto Sans CJK KR";
const MAX_PAGES: u32 = 512;
/// Fallback for symbols Noto Sans CJK KR lacks (check marks, pointers, bullets); pinned in fonts/symbols.json.
const SYMBOL_FONT: &[u8] = include_bytes!("../fonts/NotoSansSymbols2-Regular.ttf");

pub(crate) fn render(request: &Value, source_hash: &str, bytes: &[u8], work: &Path) -> Result<Value> {
    let mut font_paths = font_dirs(request)?;
    let fallback = work.join("fallback-fonts");
    fs::create_dir_all(&fallback).map_err(io_error)?;
    fs::write(fallback.join("NotoSansSymbols2-Regular.ttf"), SYMBOL_FONT).map_err(io_error)?;
    font_paths.push(fallback);
    let doc = rhwp::DocumentCore::from_bytes(bytes).map_err(open_error)?;
    let pages = doc.page_count();
    if pages == 0 {
        return Err(err(
            "incomplete_layout",
            "문서에서 표시할 쪽을 찾지 못했습니다.",
        ));
    }
    if pages > MAX_PAGES {
        return Err(err("resource_limit", "문서 쪽 수가 지원 범위를 넘습니다."));
    }
    let options = rhwp::renderer::pdf::PdfExportOptions {
        fallback_serif: FONT_FAMILY.to_owned(),
        fallback_sans: FONT_FAMILY.to_owned(),
        fallback_mono: FONT_FAMILY.to_owned(),
        font_paths,
        ..Default::default()
    };
    let pdf = doc
        .render_document_pdf_native_with_options(&options)
        .map_err(|_| {
            err(
                "render_failed",
                "문서 PDF를 만들지 못했습니다. 원본은 보관됩니다.",
            )
        })?;
    let path = work.join("document.pdf");
    fs::write(&path, &pdf).map_err(io_error)?;
    Ok(json!({
        "status": "previewed",
        "sourceSha256": source_hash,
        "pdfPath": path,
        "pdfSha256": hash(&pdf),
        "pdfPageCount": pages,
        "engineVersion": ENGINE_VERSION,
        "fontPolicy": "bundled_noto_sans_cjk_kr+noto_sans_symbols2",
        "workingDirectory": work,
    }))
}

/// Every directory must hold the pinned Noto Sans CJK KR; other fonts there (symbols) are used as fallbacks.
fn font_dirs(request: &Value) -> Result<Vec<PathBuf>> {
    let dirs = request["fontDirectories"]
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= 8)
        .ok_or_else(|| err("fonts_unavailable", "문서 글꼴을 준비하지 못했습니다."))?;
    dirs.iter()
        .map(|dir| {
            let dir = PathBuf::from(dir.as_str().ok_or_else(invalid)?);
            if file_hash(&dir.join("NotoSansCJKkr-Regular.otf")).ok().as_deref() != Some(FONT_SHA) {
                return Err(err(
                    "fonts_unavailable",
                    "문서 글꼴 파일을 확인하지 못했습니다.",
                ));
            }
            Ok(dir)
        })
        .collect()
}

fn open_error(error: rhwp::HwpError) -> ApiError {
    match error {
        rhwp::HwpError::ResourceLimit(_) => {
            err("resource_limit", "문서 크기가 지원 범위를 넘습니다.")
        }
        _ => err(
            "unsupported_parse",
            "문서를 읽지 못했습니다. 암호가 걸렸거나 손상된 문서일 수 있습니다.",
        ),
    }
}
