use crate::text_ranges::{self, HwpCharacters, RangeEdit};
use crate::{Result, err, invalid, io_error, text, unsupported};
use hwp_model::{CharShapeId, Control, Document, HwpChar, ParaShapeId, Paragraph, StyleId};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};
const MAX_FILE: u64 = 64 * 1024 * 1024;
const MAX_TABLE_CELL_UNITS: usize = 120;
pub(crate) const FONT_SHA: &str =
    "6bcb2a0703aa137e874fc2dffa85f6c21ba9a67fa329e81b8c801663af7e992a";
static SEQUENCE: AtomicU64 = AtomicU64::new(0);
pub(crate) fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
pub(crate) fn file_hash(path: &Path) -> Result<String> {
    Ok(hash(&fs::read(path).map_err(io_error)?))
}
pub(crate) fn dispatch(request: &Value) -> Result<Value> {
    let mode = text(request, "mode")?;
    if !["inspect", "apply", "pdf"].contains(&mode) {
        return Err(err(
            "unsupported_operation",
            "지원하지 않는 문서 작업입니다.",
        ));
    }
    let source = fs::canonicalize(text(request, "sourcePath")?).map_err(io_error)?;
    let ext = source
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    if !["hwp", "hwpx"].contains(&ext.as_str()) {
        return Err(err(
            "unsupported_format",
            "HWP5 또는 HWPX 문서만 열 수 있습니다.",
        ));
    }
    if fs::metadata(&source).map_err(io_error)?.len() > MAX_FILE {
        return Err(err("resource_limit", "문서 크기가 지원 범위를 넘습니다."));
    }
    let bytes = fs::read(&source).map_err(io_error)?;
    let source_hash = hash(&bytes);
    if mode == "apply" && text(request, "expectedSourceSha256")? != source_hash {
        return Err(err(
            "source_changed",
            "원본 판본이 바뀌었습니다. 문서를 다시 열어 주세요.",
        ));
    }
    let base = request["outputDirectory"]
        .as_str()
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    fs::create_dir_all(&base).map_err(io_error)?;
    let mut work = None;
    for _ in 0..32 {
        let candidate = base.join(format!(
            "ink-hwp-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        match fs::create_dir(&candidate) {
            Ok(()) => {
                work = Some(candidate);
                break;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(io_error(e)),
        }
    }
    let work = work.ok_or_else(|| err("file_error", "문서 작업 폴더를 만들지 못했습니다."))?;
    let result = if mode == "pdf" {
        crate::rhwp_pdf::render(request, &source_hash, &bytes, &work)
    } else {
        execute(request, mode, &source, &source_hash, &bytes, &ext, &work)
    };
    result.map_err(|mut e| {
        e.work = Some(work);
        e
    })
}
fn load(path: &Path, ext: &str) -> Result<Document> {
    let (doc, warnings) = if ext == "hwp" {
        let mut container = hwp5::Hwp5Container::open(path).map_err(|_| unsupported())?;
        if container.file_header().attributes & 0x6796 != 0 {
            return Err(err(
                "protected_document",
                "암호·배포·서명·보호 문서는 지원하지 않습니다.",
            ));
        }
        let mut text_bytes = 0usize;
        for name in container.body_sections() {
            let raw = container
                .read_record_stream_bounded(&name, 16 * 1024 * 1024)
                .map_err(|_| unsupported())?;
            let scan = hwp5::record::scan_stream(&raw, hwp5::record::ScanMode::Strict)
                .map_err(|_| unsupported())?;
            let mut pending: Vec<_> = scan.roots.iter().collect();
            while let Some(node) = pending.pop() {
                if node.tag == hwp5::record::tag::PARA_TEXT {
                    text_bytes = text_bytes.saturating_add(node.data.len());
                }
                if text_bytes > 2 * 1024 * 1024 {
                    return Err(err(
                        "resource_limit",
                        "문서의 글자 수가 지원 범위를 넘습니다.",
                    ));
                }
                pending.extend(&node.children);
            }
        }
        let snapshot = hwp5::read::BoundedReadSnapshot::open(
            path,
            hwp5::read::BoundedReadLimits {
                max_streams: 4096,
                max_total_stream_name_bytes: 1024 * 1024,
                max_stream_bytes: 16 * 1024 * 1024,
                max_total_materialized_bytes: 32 * 1024 * 1024,
                max_records: 200_000,
                max_record_depth: 64,
            },
        )
        .map_err(|_| unsupported())?;
        let r = snapshot.read_document().map_err(|_| unsupported())?;
        (r.document, r.warnings)
    } else {
        let limits = hwpx::PackageLimits {
            max_entries: 4096,
            max_total_name_bytes: 1024 * 1024,
            max_entry_uncompressed_bytes: 32 * 1024 * 1024,
            max_total_uncompressed_bytes: 32 * 1024 * 1024,
            max_xml_uncompressed_bytes: 2 * 1024 * 1024,
            ..Default::default()
        };
        let package_error = |e| match e {
            hwpx::HwpxError::PackageLimit(_) => {
                err("resource_limit", "압축 문서의 크기가 지원 범위를 넘습니다.")
            }
            _ => unsupported(),
        };
        let mut package =
            hwpx::HwpxPackage::open_with_limits(path, &limits).map_err(package_error)?;
        if package.has_encryption_marker().map_err(|_| unsupported())? {
            return Err(err(
                "protected_document",
                "암호·보호 문서는 지원하지 않습니다.",
            ));
        }
        for entry in package.entries().map_err(package_error)? {
            let bytes = package.read_entry(&entry.name).map_err(package_error)?;
            if entry.name.to_ascii_lowercase().ends_with(".xml") || entry.name.ends_with(".hpf") {
                crate::xml::validate(&bytes, false)?;
            }
        }
        let r = hwpx::read_document(path).map_err(|_| unsupported())?;
        let mut document = r.document;
        crate::xml::normalize_alignment_model(path, &mut document);
        crate::xml::normalize_character_model(path, &mut document);
        (document, r.warnings)
    };
    if !warnings.is_empty() {
        return Err(err(
            "unsupported_parse",
            "문서에 완전히 읽지 못한 부분이 있어 편집을 중단했습니다.",
        ));
    }
    let mut pending: Vec<_> = doc.sections.iter().flat_map(|s| &s.paragraphs).collect();
    let mut chars = 0usize;
    while let Some(p) = pending.pop() {
        chars = chars.saturating_add(p.chars.len());
        if chars > 500_000 {
            return Err(err(
                "resource_limit",
                "문서의 글자 수가 지원 범위를 넘습니다.",
            ));
        }
        for control in &p.controls {
            match control {
                Control::Table(table) => {
                    pending.extend(table.cells.iter().flat_map(|c| &c.paragraphs))
                }
                Control::Generic(g) => {
                    pending.extend(g.paragraph_lists.iter().flat_map(|p| &p.paragraphs))
                }
                _ => {}
            }
        }
    }
    let mut pixels = 0u64;
    for binary in &doc.bin_streams {
        let mut reader = image::ImageReader::new(std::io::Cursor::new(&binary.data))
            .with_guessed_format()
            .map_err(|_| unsupported())?;
        let mut limits = image::Limits::default();
        limits.max_alloc = Some(16 * 1024 * 1024);
        reader.limits(limits);
        let (width, height) = reader.into_dimensions().map_err(|_| {
            err(
                "unsupported_assets",
                "문서의 첨부 개체를 안전하게 표시할 수 없습니다.",
            )
        })?;
        let size = u64::from(width) * u64::from(height);
        pixels = pixels.saturating_add(size);
        if size > 4_000_000 || pixels > 16_000_000 {
            return Err(err(
                "resource_limit",
                "문서 이미지의 크기가 지원 범위를 넘습니다.",
            ));
        }
    }
    Ok(doc)
}
fn execute(
    request: &Value,
    mode: &str,
    source: &Path,
    source_hash: &str,
    bytes: &[u8],
    ext: &str,
    work: &Path,
) -> Result<Value> {
    let captured = work.join(format!("source.{ext}"));
    fs::write(&captured, bytes).map_err(io_error)?;
    let mut original = load(&captured, ext)?;
    let alignments = alignment_metadata(&captured, ext, &original);
    let paragraph_structure = document_paragraph_structure(&captured, ext, &original);
    let mut characters = if ext == "hwp" {
        HwpCharacters::new(&captured, &original).ok()
    } else {
        None
    };
    let range_supported = if ext == "hwp" {
        characters.is_some()
    } else {
        crate::xml::character_styles_supported(&captured, &original)
    };
    let table_anchors = if ext == "hwpx" && range_supported {
        crate::xml::table_insertion_anchors(&captured, &original, &paragraph_structure.insertions)
            .unwrap_or_default()
    } else {
        BTreeMap::new()
    };
    if file_hash(source)? != source_hash {
        return Err(err("source_changed", "원본 판본이 바뀌었습니다."));
    }
    if mode == "inspect" {
        let mut model = snapshot(
            &original,
            source_hash,
            &alignments,
            range_supported,
            range_supported || ext == "hwpx",
        );
        mark_paragraph_structure(&mut model, &paragraph_structure);
        mark_table_insertion_anchors(&mut model, &table_anchors);
        if ext == "hwp" {
            crate::hwp_table_rows::mark_snapshot(&captured, &original, &mut model);
        } else {
            crate::xml::table_structure::mark_snapshot(&captured, &original, &mut model);
        }
        if request["preview"].as_bool().unwrap_or(false) {
            let (pdf, pages, diagnostics) = render(&mut original, request, work, None, None)?;
            model["previewPdfPath"] = json!(pdf);
            model["previewPageCount"] = json!(pages);
            model["previewPdfSha256"] = json!(file_hash(&pdf)?);
            model["diagnostics"] = diagnostics;
        }
        return Ok(json!({"snapshot":model,"workingDirectory":work}));
    }
    let session = text(request, "sessionId")?;
    if session.trim().is_empty() || session.len() > 128 {
        return Err(invalid());
    }
    let ops = request["operations"]
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= 128)
        .ok_or_else(invalid)?;
    let paragraph_deletion = if ops.iter().any(|op| op["op"] == "paragraphDelete") {
        if ops.len() != 1 {
            return Err(invalid());
        }
        Some(parse_paragraph_deletion(
            &ops[0],
            &original,
            &paragraph_structure,
        )?)
    } else {
        None
    };
    let table_insertion = if ops.iter().any(|op| op["op"] == "tableInsert") {
        if ops.len() != 1 {
            return Err(invalid());
        }
        if ext != "hwpx" {
            return Err(err(
                "unsupported_operation",
                "표 추가는 HWPX에서 지원합니다.",
            ));
        }
        Some(TableInsertion::parse(&ops[0], &original, &table_anchors)?)
    } else {
        None
    };
    let (hwpx_table_structure, hwp_table_rows) =
        if ops.iter().any(|op| op["op"] == "tableStructure") {
            if ops.len() != 1 {
                return Err(invalid());
            }
            if ext == "hwp" {
                (
                    None,
                    Some(crate::hwp_table_rows::Edit::prepare(
                        &captured, &original, &ops[0],
                    )?),
                )
            } else {
                (
                    Some(crate::xml::table_structure::Edit::prepare(
                        &captured, &original, &ops[0],
                    )?),
                    None,
                )
            }
        } else {
            (None, None)
        };
    let mut changes = Vec::new();
    let mut seen = BTreeSet::new();
    let mut insertions = BTreeMap::new();
    let mut insertion_ids = BTreeSet::new();
    for op in ops {
        if matches!(
            op["op"].as_str(),
            Some("tableInsert" | "tableStructure" | "paragraphDelete")
        ) {
            continue;
        }
        if op["op"] == "paragraphInsert" {
            let (id, insertion) =
                ParagraphInsertion::parse(op, &original, &paragraph_structure.insertions)?;
            if !insertion_ids.insert(id)
                || insertions.insert(insertion.location, insertion).is_some()
            {
                return Err(invalid());
            }
            continue;
        }
        let change = Change::parse(op)?;
        if change.range.is_none() && !seen.insert(change.key()) {
            return Err(invalid());
        }
        changes.push(change);
    }
    for change in &changes {
        change.validate_alignment(&original, &alignments)?;
        if change.range.is_none() && change.alignment.is_none() {
            change.validate_legacy_target(&original)?;
        }
    }
    if changes.iter().any(|c| c.range.is_some()) && !range_supported {
        return Err(unsupported());
    }
    if ext == "hwp"
        && !range_supported
        && changes
            .iter()
            .any(|c| c.range.is_none() && c.alignment.is_none())
    {
        return Err(unsupported());
    }
    for change in changes.iter().filter(|c| c.range.is_some()) {
        if changes.iter().any(|other| {
            other.range.is_none()
                && other.alignment.is_none()
                && other.section == change.section
                && other.paragraph == change.paragraph
                && other.table == change.table
                && other.cell == change.cell
        }) {
            return Err(invalid());
        }
    }
    let mut edited = original.clone();
    if let Some(edit) = &hwpx_table_structure {
        edit.apply_expected(&mut edited)?;
    }
    if let Some(edit) = &hwp_table_rows {
        edit.apply_expected(&mut edited)?;
    }
    let mut allocations = BTreeMap::new();
    let mut character_origins = BTreeMap::new();
    let mut hwp_alignment =
        if ext == "hwp" && changes.iter().any(|change| change.alignment.is_some()) {
            Some(HwpAlignmentPlan::new(&captured, &original)?)
        } else {
            None
        };
    let mut expected_alignments = alignments.clone();
    for change in &changes {
        change.apply(
            &mut edited,
            ext == "hwpx",
            &mut allocations,
            hwp_alignment.as_mut(),
            characters.as_mut(),
            &mut character_origins,
        )?;
        if let Some(alignment) = change.alignment {
            expected_alignments.insert((change.section, change.paragraph), alignment);
        }
    }
    let output = work.join(format!("edited.{ext}"));
    let hwp_insert = ext == "hwp" && !insertions.is_empty();
    let intermediate = (hwp_insert && !changes.is_empty()).then(|| work.join("text-edited.hwp"));
    let text_output = intermediate.as_deref().unwrap_or(&output);
    if let Some(edit) = &hwp_table_rows {
        edit.write(&captured, &output, &edited)?;
    } else if let Some(location) = paragraph_deletion
        && ext == "hwp"
    {
        crate::hwp_paragraphs::delete(&captured, &output, &mut edited, location)?;
    } else if ext == "hwp" && (!hwp_insert || !changes.is_empty()) {
        let report = hwp5::rewrite_document_with_report(
            &captured,
            &original,
            &edited,
            text_output,
            &hwp5::WriteOptions {
                preserve_linesegs: true,
                ..Default::default()
            },
        )
        .map_err(|_| unsupported())?;
        if !report.preservation.is_lossless() {
            return Err(err(
                "unsupported_loss",
                "원본 구조를 보존할 수 없어 저장을 중단했습니다.",
            ));
        }
        if let Some(plan) = &hwp_alignment {
            plan.write_docinfo(text_output)?;
        }
        if changes.iter().any(|change| change.range.is_some()) {
            let plan = characters.as_ref().ok_or_else(unsupported)?;
            plan.write_docinfo(
                text_output,
                changes.iter().any(|change| change.alignment.is_some()),
            )?;
            plan.verify(text_output, &edited)?;
        }
        preserve_hwp(&captured, text_output, &original, &edited, &changes)?;
    } else if ext == "hwpx" {
        crate::xml::write_package(
            &captured,
            &output,
            &original,
            &edited,
            &changes,
            &character_origins,
            crate::xml::StructureEdits {
                paragraphs: &insertions,
                paragraph_deletion,
                table: table_insertion.as_ref(),
                table_structure: hwpx_table_structure.as_ref(),
            },
        )?;
    }
    if let Some((section, paragraph)) = paragraph_deletion {
        if ext == "hwpx" {
            edited.sections[section].paragraphs.remove(paragraph);
        }
        for ((s, p), alignment) in expected_alignments.split_off(&(section, paragraph)) {
            if (s, p) != (section, paragraph) {
                expected_alignments.insert((s, p - usize::from(s == section)), alignment);
            }
        }
    }
    if hwp_insert {
        let base = intermediate.as_deref().unwrap_or(&captured);
        let materialized = intermediate
            .as_deref()
            .map(|path| load(path, ext))
            .transpose()?;
        let edit = crate::hwp_paragraphs::Edit::prepare(
            base,
            materialized.as_ref().unwrap_or(&original),
            &insertions,
        )?;
        edit.apply_expected(&mut edited)?;
        edit.write(base, &output, &edited)?;
    }
    for (&(section, paragraph), insertion) in insertions.iter().rev() {
        if !hwp_insert {
            hwp_convert::insert_paragraph_at(
                &mut edited,
                &hwp_convert::SegmentPath {
                    section,
                    indices: vec![paragraph],
                },
                false,
                &insertion.text,
                insertion.style,
            )
            .map_err(|_| unsupported())?;
        }
        shift_alignments(&mut expected_alignments, section, paragraph);
        if let Some(alignment) = alignments.get(&(section, paragraph)) {
            expected_alignments.insert((section, paragraph + 1), *alignment);
        }
    }
    let mut reopened = load(&output, ext)?;
    if let Some(edit) = &hwpx_table_structure {
        edit.verify(&reopened)?;
    }
    if let Some(edit) = &hwp_table_rows {
        edit.verify(&reopened)?;
    }
    if let Some(insertion) = &table_insertion {
        insertion.validate_and_insert(&mut edited, &reopened)?;
        shift_alignments(
            &mut expected_alignments,
            insertion.location.0,
            insertion.location.1,
        );
    }
    let edited_hash = file_hash(&output)?;
    let reopened_alignments = alignment_metadata(&output, ext, &reopened);
    let reopened_range_supported = if ext == "hwp" {
        HwpCharacters::new(&output, &reopened).is_ok()
    } else {
        crate::xml::character_styles_supported(&output, &reopened)
    };
    if snapshot(
        &edited,
        &edited_hash,
        &expected_alignments,
        range_supported,
        range_supported || ext == "hwpx",
    ) != snapshot(
        &reopened,
        &edited_hash,
        &reopened_alignments,
        reopened_range_supported,
        reopened_range_supported || ext == "hwpx",
    ) {
        return Err(err(
            "semantic_mismatch",
            "저장한 문서의 문단·표 내용이 편집 결과와 일치하지 않습니다.",
        ));
    }
    let (pdf, pages, diagnostics) = render(
        &mut reopened,
        request,
        work,
        table_insertion.as_ref(),
        hwpx_table_structure.as_ref(),
    )?;
    if file_hash(source)? != source_hash {
        return Err(err("source_changed", "작업 중 원본 판본이 바뀌었습니다."));
    }
    let mut result = snapshot(
        &reopened,
        &edited_hash,
        &reopened_alignments,
        reopened_range_supported,
        reopened_range_supported || ext == "hwpx",
    );
    let structure = document_paragraph_structure(&output, ext, &reopened);
    mark_paragraph_structure(&mut result, &structure);
    if ext == "hwp" {
        crate::hwp_table_rows::mark_snapshot(&output, &reopened, &mut result);
    } else {
        crate::xml::table_structure::mark_snapshot(&output, &reopened, &mut result);
        if reopened_range_supported {
            let anchors =
                crate::xml::table_insertion_anchors(&output, &reopened, &structure.insertions)
                    .unwrap_or_default();
            mark_table_insertion_anchors(&mut result, &anchors);
        }
    }
    Ok(
        json!({"status":"saved","sessionId":session,"sourcePath":output,"sourceSha256":edited_hash,"pdfPath":pdf,"pdfSha256":file_hash(&pdf)?,"pdfPageCount":pages,"engineVersion":"ink_hwp_native/0.1.0+hwp-cli.4e6e8c2","snapshot":result,"diagnostics":diagnostics,"workingDirectory":work,"embeddedPreviewUpdated":false,"fontPolicy":"bundled_noto_sans_cjk_kr"}),
    )
}

fn document_paragraph_structure(source: &Path, ext: &str, doc: &Document) -> ParagraphStructure {
    if ext == "hwp" {
        crate::hwp_paragraphs::structure(source, doc).unwrap_or_default()
    } else {
        crate::xml::paragraph_structure(source, doc).unwrap_or_default()
    }
}

pub(crate) type InsertionStyles = BTreeMap<(usize, usize), (ParaShapeId, StyleId, CharShapeId)>;

#[derive(Default)]
pub(crate) struct ParagraphStructure {
    pub insertions: InsertionStyles,
    pub deletions: BTreeSet<(usize, usize)>,
}

#[derive(Clone, Copy)]
pub(crate) struct TableAnchor {
    pub style: (ParaShapeId, StyleId, CharShapeId),
    pub border: u16,
    pub width: u32,
    pub row_height: u32,
}

pub(crate) type TableAnchors = BTreeMap<(usize, usize), TableAnchor>;

pub(crate) struct TableInsertion {
    pub location: (usize, usize),
    pub anchor: TableAnchor,
    pub rows: u16,
    pub columns: u16,
    cells: Option<Vec<String>>,
}

impl TableInsertion {
    fn parse(op: &Value, document: &Document, anchors: &TableAnchors) -> Result<Self> {
        let fields = [
            "op",
            "id",
            "referenceId",
            "position",
            "expectedTextSha256",
            "rows",
            "columns",
        ];
        let values = op.as_object().ok_or_else(invalid)?;
        let id = text(op, "id")?;
        if values.len() != fields.len() + usize::from(values.contains_key("cells"))
            || !fields.iter().all(|key| values.contains_key(*key))
            || text(op, "position")? != "after"
            || id.is_empty()
            || id.len() > 128
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b':'))
            || paragraph_location(id).is_some()
        {
            return Err(invalid());
        }
        let bounded = |name, max| {
            op[name]
                .as_u64()
                .filter(|value| (1..=max).contains(value))
                .and_then(|value| u16::try_from(value).ok())
                .ok_or_else(invalid)
        };
        let rows = bounded("rows", 8)?;
        let columns = bounded("columns", 6)?;
        let cells = if let Some(cells) = values.get("cells") {
            let cells = cells
                .as_array()
                .filter(|cells| cells.len() == usize::from(rows))
                .ok_or_else(invalid)?;
            let mut contents = Vec::with_capacity(usize::from(rows) * usize::from(columns));
            for row in cells {
                let row = row
                    .as_array()
                    .filter(|row| row.len() == usize::from(columns))
                    .ok_or_else(invalid)?;
                for cell in row {
                    let text = cell.as_str().ok_or_else(invalid)?;
                    if text.encode_utf16().count() > MAX_TABLE_CELL_UNITS
                        || text.chars().any(|c| {
                            c.is_control()
                                || matches!(c, '\u{2028}' | '\u{2029}' | '\u{fffe}' | '\u{ffff}')
                        })
                    {
                        return Err(invalid());
                    }
                    contents.push(text.to_owned());
                }
            }
            Some(contents)
        } else {
            None
        };
        let location = paragraph_location(text(op, "referenceId")?).ok_or_else(invalid)?;
        let anchor = *anchors.get(&location).ok_or_else(unsupported)?;
        let paragraph = &document.sections[location.0].paragraphs[location.1];
        let paragraph_text = paragraph_text(paragraph);
        if !plain(paragraph) || paragraph_text.is_empty() {
            return Err(unsupported());
        }
        let digest = text(op, "expectedTextSha256")?;
        if digest.len() != 64
            || !digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(invalid());
        }
        if digest != hash(paragraph_text.as_bytes()) {
            return Err(err("source_changed", "문단 내용이 바뀌었습니다."));
        }
        Ok(Self {
            location,
            anchor,
            rows,
            columns,
            cells,
        })
    }

    pub fn cell_width(&self) -> u32 {
        self.anchor.width / u32::from(self.columns)
    }

    pub fn cell_text(&self, row: u16, column: u16) -> &str {
        self.cells.as_ref().map_or("", |cells| {
            cells[usize::from(row) * usize::from(self.columns) + usize::from(column)].as_str()
        })
    }

    fn validate_and_insert(&self, expected: &mut Document, reopened: &Document) -> Result<()> {
        let mismatch = || {
            err(
                "semantic_mismatch",
                "저장한 표 구조가 편집 결과와 일치하지 않습니다.",
            )
        };
        let (section, paragraph) = self.location;
        let section_after = reopened.sections.get(section).ok_or_else(mismatch)?;
        let original = &mut expected.sections[section].paragraphs;
        if section_after.paragraphs.len() != original.len() + 1 {
            return Err(mismatch());
        }
        let carrier = &section_after.paragraphs[paragraph + 1];
        let [Control::Table(table)] = carrier.controls.as_slice() else {
            return Err(mismatch());
        };
        let (shape, style, char_shape) = self.anchor.style;
        let width = self.cell_width();
        let placement = table.placement.as_ref().ok_or_else(mismatch)?;
        if !paragraph_text(carrier).is_empty()
            || (carrier.para_shape, carrier.style) != (shape, style)
            || carrier.char_shape_runs.as_slice() != [(0, char_shape)]
            || table.rows != self.rows
            || table.cols != self.columns
            || table.border_fill.0 != self.anchor.border
            || table.caption.is_some()
            || table.cell_spacing != 0
            || !placement.treat_as_char
            || !placement.flow_with_text
            || placement.width != (width * u32::from(self.columns)) as i32
            || placement.height != (self.anchor.row_height * u32::from(self.rows)) as i32
            || table.row_cell_counts != vec![self.columns; usize::from(self.rows)]
            || table.cells.len() != usize::from(self.rows) * usize::from(self.columns)
        {
            return Err(mismatch());
        }
        for (index, cell) in table.cells.iter().enumerate() {
            let [text] = cell.paragraphs.as_slice() else {
                return Err(mismatch());
            };
            let columns = usize::from(self.columns);
            if usize::from(cell.row) != index / columns
                || usize::from(cell.col) != index % columns
                || cell.row_span != 1
                || cell.col_span != 1
                || cell.is_header()
                || cell.width.0 != width as i32
                || cell.height.0 != self.anchor.row_height as i32
                || cell.border_fill.0 != self.anchor.border
                || paragraph_text(text) != self.cell_text(cell.row, cell.col)
                || (text.para_shape, text.style) != (shape, style)
                || text.char_shape_runs.as_slice() != [(0, char_shape)]
                || text_ranges::details(text, reopened).is_none()
            {
                return Err(mismatch());
            }
        }
        original.insert(paragraph + 1, carrier.clone());
        Ok(())
    }

    fn validate_render_width(
        &self,
        document: &Document,
        store: &mut hwp_render::FontStore,
    ) -> Result<()> {
        let Some(contents) = &self.cells else {
            return Ok(());
        };
        let (section, paragraph) = self.location;
        let [Control::Table(table)] = document.sections[section].paragraphs[paragraph + 1]
            .controls
            .as_slice()
        else {
            return Err(unsupported());
        };
        for (cell, text) in table.cells.iter().zip(contents) {
            if text.is_empty() {
                continue;
            }
            let paragraph = &cell.paragraphs[0];
            let inner_width =
                ((cell.width.0 as f32 - f32::from(cell.margins[0]) - f32::from(cell.margins[1]))
                    / 100.0)
                    .max(4.0);
            if !cell_content_fits(document, store, paragraph, inner_width, true) {
                return Err(err(
                    "incomplete_layout",
                    "새 표에서 셀 너비를 넘는 글자가 있습니다. 내용을 줄이거나 열 수를 줄이세요.",
                ));
            }
        }
        Ok(())
    }
}

pub(crate) fn cell_content_fits(
    document: &Document,
    fonts: &mut hwp_render::FontStore,
    paragraph: &Paragraph,
    inner_width: f32,
    allow_wrapping: bool,
) -> bool {
    use hwp_render::shape::{InlineItem, shape_range};
    let Some(shape) = document
        .header
        .para_shapes
        .get(paragraph.para_shape.0 as usize)
    else {
        return false;
    };
    let mut issues = hwp_render::RenderIssueAccumulator::new();
    let items = shape_range(
        fonts,
        document,
        paragraph,
        (0, paragraph.wchar_len()),
        &mut issues,
    );
    let (mut line, mut width, mut widest) = (0.0f32, 0.0f32, 0.0f32);
    for item in items {
        match item {
            InlineItem::Run(run) => {
                line += run.width_pt;
                widest = run
                    .glyphs
                    .iter()
                    .fold(widest, |width, glyph| width.max(glyph.x_advance));
            }
            InlineItem::LineBreak(_) => {
                width = width.max(line);
                line = 0.0;
            }
            InlineItem::Tab if !allow_wrapping => return false,
            InlineItem::Tab => (),
        }
    }
    width = width.max(line);
    let margin = |value: i32| value.max(0) as f32 / 200.0;
    let available = (inner_width - margin(shape.margin_left) - margin(shape.margin_right)).max(4.0);
    // Match the renderer's first-line and hanging indents.
    let wrapping_width = if matches!(shape.alignment(), 2 | 3) && width <= available {
        available
    } else {
        available - (shape.indent.unsigned_abs() as f32 / 200.0).min(available * 0.8)
    };
    let has_nbsp = paragraph
        .chars
        .iter()
        .any(|c| matches!(c, HwpChar::Text('\u{00a0}')));
    widest <= wrapping_width && ((allow_wrapping && !has_nbsp) || width <= wrapping_width)
}

fn shift_alignments(alignments: &mut Alignments, section: usize, paragraph: usize) {
    let affected = alignments.split_off(&(section, paragraph + 1));
    for ((other_section, other_paragraph), alignment) in affected {
        alignments.insert(
            (
                other_section,
                other_paragraph + usize::from(other_section == section),
            ),
            alignment,
        );
    }
}

pub(crate) struct ParagraphInsertion {
    location: (usize, usize),
    pub text: String,
    pub style: (ParaShapeId, StyleId, CharShapeId),
}

fn paragraph_location(id: &str) -> Option<(usize, usize)> {
    let (section, paragraph) = id.split_once(':')?;
    let section = section.strip_prefix('s')?.parse::<usize>().ok()?;
    let paragraph = paragraph.strip_prefix('p')?.parse::<usize>().ok()?;
    (id == format!("s{section}:p{paragraph}")).then_some((section, paragraph))
}

fn parse_paragraph_deletion(
    op: &Value,
    source: &Document,
    structure: &ParagraphStructure,
) -> Result<(usize, usize)> {
    let fields = ["op", "id", "expectedTextSha256"];
    let map = op.as_object().ok_or_else(invalid)?;
    if map.len() != fields.len() || !fields.iter().all(|field| map.contains_key(*field)) {
        return Err(invalid());
    }
    let location = paragraph_location(text(op, "id")?).ok_or_else(invalid)?;
    if !structure.deletions.contains(&location) {
        return Err(unsupported());
    }
    let paragraph = &source.sections[location.0].paragraphs[location.1];
    verify_paragraph_text(op, &paragraph_text(paragraph))?;
    Ok(location)
}

fn verify_paragraph_text(op: &Value, value: &str) -> Result<()> {
    let digest = text(op, "expectedTextSha256")?;
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(invalid());
    }
    if digest != hash(value.as_bytes()) {
        return Err(err("source_changed", "문단 내용이 바뀌었습니다."));
    }
    Ok(())
}

impl ParagraphInsertion {
    fn parse(op: &Value, source: &Document, styles: &InsertionStyles) -> Result<(String, Self)> {
        let fields = [
            "op",
            "id",
            "referenceId",
            "position",
            "expectedTextSha256",
            "text",
        ];
        let map = op.as_object().ok_or_else(invalid)?;
        if map.len() != fields.len()
            || !fields.iter().all(|field| map.contains_key(*field))
            || text(op, "position")? != "after"
        {
            return Err(invalid());
        }
        let id = text(op, "id")?;
        if id.is_empty() || id.encode_utf16().count() > 256 || paragraph_location(id).is_some() {
            return Err(invalid());
        }
        let location = paragraph_location(text(op, "referenceId")?).ok_or_else(invalid)?;
        let style = *styles.get(&location).ok_or_else(unsupported)?;
        let anchor = &source.sections[location.0].paragraphs[location.1];
        let anchor_text = paragraph_text(anchor);
        if !plain(anchor) || anchor_text.is_empty() {
            return Err(unsupported());
        }
        verify_paragraph_text(op, &anchor_text)?;
        let value = text(op, "text")?;
        if value
            .trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}')
            .is_empty()
            || value.encode_utf16().count() > 4096
            || value
                .chars()
                .any(|c| c < ' ' || matches!(c, '\u{fffe}' | '\u{ffff}'))
        {
            return Err(invalid());
        }
        Ok((
            id.to_owned(),
            Self {
                location,
                text: value.to_owned(),
                style,
            },
        ))
    }
}

fn mark_paragraph_structure(snapshot: &mut Value, structure: &ParagraphStructure) {
    if let Some(paragraphs) = snapshot["paragraphs"].as_array_mut() {
        for paragraph in paragraphs {
            if let Some(location) = paragraph["id"].as_str().and_then(paragraph_location) {
                if structure.insertions.contains_key(&location) {
                    paragraph["structure"]["canInsertAfter"] = json!(true);
                }
                if structure.deletions.contains(&location) {
                    paragraph["structure"]["canDelete"] = json!(true);
                }
            }
        }
    }
}
fn mark_table_insertion_anchors(snapshot: &mut Value, anchors: &TableAnchors) {
    let mut supported = false;
    if let Some(paragraphs) = snapshot["paragraphs"].as_array_mut() {
        for paragraph in paragraphs {
            if paragraph["id"]
                .as_str()
                .and_then(paragraph_location)
                .is_some_and(|location| anchors.contains_key(&location))
            {
                paragraph["tableInsertAnchor"] = json!(true);
                supported = true;
            }
        }
    }
    if supported {
        snapshot["supportsHwpTableInsert"] = json!(true);
    }
}
pub(crate) fn paragraph_text(p: &Paragraph) -> String {
    p.chars
        .iter()
        .filter_map(|c| match c {
            HwpChar::Text(c) => Some(*c),
            HwpChar::CharCtrl(10) => Some('\n'),
            HwpChar::InlineCtrl { code: 9, .. } => Some('\t'),
            _ => None,
        })
        .collect()
}
fn plain(p: &Paragraph) -> bool {
    p.extras.is_empty()&&p.controls.iter().all(|c|matches!(c,Control::SectionDef(_))||matches!(c,Control::Generic(g) if g.ctrl_id==*b"cold" && g.paragraph_lists.is_empty()))&&p.chars.iter().all(|c|matches!(c,HwpChar::Text(_)|HwpChar::CharCtrl(10|13)|HwpChar::InlineCtrl{code:9,..}|HwpChar::ExtCtrl{code:2,..}))
}
fn replace_paragraph(p: &mut Paragraph, value: &str) -> Result<()> {
    if !plain(p) {
        return Err(unsupported());
    }
    let prefix: Vec<_> = p
        .chars
        .iter()
        .filter(|c| matches!(c, HwpChar::ExtCtrl { code: 2, .. }))
        .cloned()
        .collect();
    let shape = p.char_shape_runs.first().map(|v| v.1).unwrap_or_default();
    p.chars = prefix;
    p.chars
        .extend(value.chars().map(|character| match character {
            '\n' => HwpChar::CharCtrl(10),
            '\t' => HwpChar::InlineCtrl {
                code: 9,
                payload: vec![0; 12],
            },
            other => HwpChar::Text(other),
        }));
    p.chars.push(HwpChar::CharCtrl(13));
    p.char_shape_runs = vec![(0, shape)];
    p.line_segs.clear();
    p.header.ctrl_mask = 0;
    Ok(())
}
pub(crate) type Alignments = BTreeMap<(usize, usize), u8>;
fn alignment_metadata(path: &Path, ext: &str, doc: &Document) -> Alignments {
    if ext == "hwpx" {
        let mut metadata = crate::xml::alignment_metadata(path, doc).unwrap_or_default();
        metadata.retain(|(si, pi), _| {
            doc.sections
                .get(*si)
                .and_then(|section| section.paragraphs.get(*pi))
                .is_some_and(plain)
        });
        return metadata;
    }
    let Ok(records) = docinfo_records(path) else {
        return BTreeMap::new();
    };
    let shapes: Vec<_> = records
        .iter()
        .filter(|(_, tag, _)| *tag == hwp5::record::tag::PARA_SHAPE)
        .collect();
    let mappings: Vec<_> = records
        .iter()
        .filter(|(_, tag, _)| *tag == hwp5::record::tag::ID_MAPPINGS)
        .collect();
    if shapes.len() != doc.header.para_shapes.len()
        || mappings.len() != 1
        || mappings[0].2.len() < 56
        || u32::from_le_bytes(mappings[0].2[52..56].try_into().expect("checked mapping")) as usize
            != shapes.len()
    {
        return BTreeMap::new();
    }
    let mut result = BTreeMap::new();
    for (si, section) in doc.sections.iter().enumerate() {
        for (pi, paragraph) in section.paragraphs.iter().enumerate() {
            let index = paragraph.para_shape.0 as usize;
            if !plain(paragraph) {
                continue;
            }
            let (Some(shape), Some(raw)) = (doc.header.para_shapes.get(index), shapes.get(index))
            else {
                continue;
            };
            if raw.2.len() >= 4 {
                let alignment =
                    ((u32::from_le_bytes(raw.2[..4].try_into().expect("checked shape")) >> 2) & 7)
                        as u8;
                if alignment <= 5 && alignment == shape.alignment() {
                    result.insert((si, pi), alignment);
                }
            }
        }
    }
    result
}
fn snapshot(
    doc: &Document,
    hash: &str,
    alignments: &Alignments,
    range_supported: bool,
    legacy_document_supported: bool,
) -> Value {
    let mut paragraphs = Vec::new();
    let mut tables = Vec::new();
    for (si, section) in doc.sections.iter().enumerate() {
        for (pi, p) in section.paragraphs.iter().enumerate() {
            if plain(p) {
                let mut value = json!({"id":format!("s{si}:p{pi}"),"text":paragraph_text(p)});
                if let Some(alignment) = alignments.get(&(si, pi)) {
                    value["paragraphFormat"] = json!({"alignment":match alignment { 0 => "justify", 1 => "left", 2 => "right", 3 => "center", _ => "other" }});
                }
                if range_supported && let Some(details) = text_ranges::details(p, doc) {
                    value["textDetails"] = details;
                } else if !legacy_document_supported || !text_ranges::legacy_supported(p, doc) {
                    value["textDetails"] = text_ranges::readonly_details(p);
                }
                paragraphs.push(value);
            }
            for (ci, ctrl) in p.controls.iter().enumerate() {
                if let Control::Table(table) = ctrl {
                    let cells: BTreeMap<_, _> = table
                        .cells
                        .iter()
                        .map(|c| {
                            (
                                format!("{},{}", c.row, c.col),
                                c.paragraphs
                                    .iter()
                                    .map(paragraph_text)
                                    .collect::<Vec<_>>()
                                    .join("\n"),
                            )
                        })
                        .collect();
                    let mut value = json!({"id":format!("s{si}:p{pi}:t{ci}"),"cells":cells});
                    let details: BTreeMap<_, _> = table
                        .cells
                        .iter()
                        .filter_map(|cell| {
                            if cell.paragraphs.len() != 1 {
                                return None;
                            }
                            let paragraph = &cell.paragraphs[0];
                            let details = if range_supported {
                                text_ranges::details(paragraph, doc)
                            } else {
                                None
                            };
                            let details = details.or_else(|| {
                                (!legacy_document_supported
                                    || !text_ranges::legacy_supported(paragraph, doc))
                                .then(|| text_ranges::readonly_details(paragraph))
                            })?;
                            Some((format!("{},{}", cell.row, cell.col), details))
                        })
                        .collect();
                    value["cellTextDetails"] = json!(details);
                    tables.push(value);
                }
            }
        }
    }
    json!({"kind":"word","sourceSha256":hash,"paragraphs":paragraphs,"tables":tables,"slides":[]})
}
pub(crate) struct Change {
    pub section: usize,
    pub paragraph: usize,
    pub table: Option<usize>,
    pub cell: Option<(u16, u16)>,
    pub text: String,
    pub alignment: Option<u8>,
    pub range: Option<RangeEdit>,
    expected_text_sha256: Option<String>,
}
impl Change {
    fn parse(v: &Value) -> Result<Self> {
        let operation = text(v, "op")?;
        let range = if matches!(operation, "textStyle" | "textReplace") {
            Some(RangeEdit::parse(v)?)
        } else {
            None
        };
        let (id, table) = match operation {
            "paragraphText" => (text(v, "id")?, false),
            "tableCellText" => (text(v, "tableId")?, true),
            "paragraphFormat" => (text(v, "id")?, false),
            "textStyle" | "textReplace" => (text(v, "id")?, text(v, "targetKind")? == "cell"),
            _ => {
                return Err(err(
                    "unsupported_operation",
                    "이 HWP 편집 작업은 지원하지 않습니다.",
                ));
            }
        };
        let format = v["op"] == "paragraphFormat";
        let (alignment, expected_text_sha256) = if format {
            let object = v.as_object().ok_or_else(invalid)?;
            if object.len() != 4
                || object.keys().any(|key| {
                    !["op", "id", "alignment", "expectedTextSha256"].contains(&key.as_str())
                })
            {
                return Err(invalid());
            }
            let alignment = match text(v, "alignment")? {
                "justify" => 0,
                "left" => 1,
                "right" => 2,
                "center" => 3,
                _ => return Err(invalid()),
            };
            let digest = text(v, "expectedTextSha256")?;
            if digest.len() != 64
                || !digest
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
            {
                return Err(invalid());
            }
            (Some(alignment), Some(digest.to_owned()))
        } else {
            (None, None)
        };
        let parts: Vec<_> = id.split(':').collect();
        if parts.len() != if table { 3 } else { 2 } {
            return Err(invalid());
        }
        let number = |index: usize, prefix: &str| {
            parts[index]
                .strip_prefix(prefix)
                .and_then(|v| v.parse::<usize>().ok())
                .ok_or_else(invalid)
        };
        let cell = if table {
            let p: Vec<_> = text(v, "cell")?.split(',').collect();
            if p.len() != 2 {
                return Err(invalid());
            }
            Some((
                p[0].parse().map_err(|_| invalid())?,
                p[1].parse().map_err(|_| invalid())?,
            ))
        } else {
            None
        };
        let value = if format || range.is_some() {
            ""
        } else {
            text(v, "text")?
        };
        if value.len() > 1024 * 1024
            || value
                .chars()
                .any(|character| character.is_control() && !matches!(character, '\t' | '\n' | '\r'))
        {
            return Err(err(
                "unsupported_text",
                "탭과 줄바꿈 외의 제어 문자는 입력할 수 없습니다.",
            ));
        }
        Ok(Self {
            section: number(0, "s")?,
            paragraph: number(1, "p")?,
            table: if table { Some(number(2, "t")?) } else { None },
            cell,
            text: value.replace("\r\n", "\n").replace('\r', "\n"),
            alignment,
            range,
            expected_text_sha256,
        })
    }
    fn key(&self) -> (usize, usize, Option<usize>, Option<(u16, u16)>, bool) {
        (
            self.section,
            self.paragraph,
            self.table,
            self.cell,
            self.alignment.is_some(),
        )
    }
    fn validate_alignment(&self, original: &Document, metadata: &Alignments) -> Result<()> {
        let Some(expected) = &self.expected_text_sha256 else {
            return Ok(());
        };
        let paragraph = original
            .sections
            .get(self.section)
            .and_then(|s| s.paragraphs.get(self.paragraph))
            .ok_or_else(invalid)?;
        if !plain(paragraph) || !metadata.contains_key(&(self.section, self.paragraph)) {
            return Err(unsupported());
        }
        if hash(paragraph_text(paragraph).as_bytes()) != *expected {
            return Err(err(
                "source_changed",
                "문단의 원문이 바뀌었습니다. 문서를 다시 열어 주세요.",
            ));
        }
        Ok(())
    }
    fn validate_legacy_target(&self, document: &Document) -> Result<()> {
        let parent = document
            .sections
            .get(self.section)
            .and_then(|s| s.paragraphs.get(self.paragraph))
            .ok_or_else(invalid)?;
        let paragraph = if let Some(index) = self.table {
            let Some(Control::Table(table)) = parent.controls.get(index) else {
                return Err(invalid());
            };
            let (row, col) = self.cell.ok_or_else(invalid)?;
            let cell = table
                .cells
                .iter()
                .find(|c| c.row == row && c.col == col)
                .ok_or_else(invalid)?;
            if cell.paragraphs.len() != 1 {
                return Err(unsupported());
            }
            &cell.paragraphs[0]
        } else {
            parent
        };
        if !text_ranges::legacy_supported(paragraph, document) {
            return Err(unsupported());
        }
        Ok(())
    }
    fn apply(
        &self,
        doc: &mut Document,
        hwpx: bool,
        allocations: &mut BTreeMap<(u16, u8), u16>,
        hwp_alignment: Option<&mut HwpAlignmentPlan>,
        characters: Option<&mut HwpCharacters>,
        character_origins: &mut BTreeMap<u16, u16>,
    ) -> Result<()> {
        let p = doc
            .sections
            .get_mut(self.section)
            .and_then(|s| s.paragraphs.get_mut(self.paragraph))
            .ok_or_else(invalid)?;
        if let Some(alignment) = self.alignment {
            let source_shape = p.para_shape.0;
            let mut shape = doc
                .header
                .para_shapes
                .get(source_shape as usize)
                .cloned()
                .ok_or_else(unsupported)?;
            let old_alignment = shape.alignment();
            shape.attr1 = (shape.attr1 & !(7 << 2)) | (u32::from(alignment) << 2);
            let id = if old_alignment == alignment {
                source_shape
            } else if hwpx {
                if let Some(id) = allocations.get(&(source_shape, alignment)) {
                    *id
                } else {
                    let id = u16::try_from(doc.header.para_shapes.len()).map_err(|_| {
                        err("resource_limit", "문단 서식 수가 지원 범위를 넘습니다.")
                    })?;
                    doc.header.para_shapes.push(shape);
                    allocations.insert((source_shape, alignment), id);
                    id
                }
            } else {
                let id = hwp_alignment
                    .ok_or_else(unsupported)?
                    .allocate(source_shape, alignment)?;
                if id as usize == doc.header.para_shapes.len() {
                    doc.header.para_shapes.push(shape);
                } else if doc.header.para_shapes.get(id as usize) != Some(&shape) {
                    return Err(unsupported());
                }
                id
            };
            p.para_shape = hwp_model::ParaShapeId(id);
            p.line_segs.clear();
            return Ok(());
        }
        if let Some(range) = &self.range {
            if let Some(index) = self.table {
                let Some(Control::Table(table)) = p.controls.get_mut(index) else {
                    return Err(invalid());
                };
                let (row, col) = self.cell.ok_or_else(invalid)?;
                let cell = table
                    .cells
                    .iter_mut()
                    .find(|c| c.row == row && c.col == col)
                    .ok_or_else(invalid)?;
                if cell.paragraphs.len() != 1 {
                    return Err(unsupported());
                }
                range.apply(
                    &mut cell.paragraphs[0],
                    &mut doc.header.char_shapes,
                    characters,
                    character_origins,
                )?;
                p.line_segs.clear();
                return Ok(());
            }
            return range.apply(
                p,
                &mut doc.header.char_shapes,
                characters,
                character_origins,
            );
        }
        if let Some(index) = self.table {
            let Some(Control::Table(table)) = p.controls.get_mut(index) else {
                return Err(invalid());
            };
            let (row, col) = self.cell.ok_or_else(invalid)?;
            let cell = table
                .cells
                .iter_mut()
                .find(|c| c.row == row && c.col == col)
                .ok_or_else(invalid)?;
            if cell.paragraphs.len() != 1 {
                return Err(unsupported());
            }
            replace_paragraph(&mut cell.paragraphs[0], &self.text)
        } else {
            replace_paragraph(p, &self.text)
        }
    }
}
struct HwpAlignmentPlan {
    source_nodes: Vec<hwp5::record::RecordNode>,
    shapes: Vec<hwp5::record::RecordNode>,
    original_count: usize,
    compressed: bool,
}
impl HwpAlignmentPlan {
    fn mapping_mut(
        nodes: &mut [hwp5::record::RecordNode],
    ) -> Option<&mut hwp5::record::RecordNode> {
        for node in nodes {
            if node.tag == hwp5::record::tag::ID_MAPPINGS {
                return Some(node);
            }
            if let Some(mapping) = Self::mapping_mut(&mut node.children) {
                return Some(mapping);
            }
        }
        None
    }
    fn new(source: &Path, document: &Document) -> Result<Self> {
        fn count(nodes: &[hwp5::record::RecordNode], tag: u16) -> usize {
            nodes
                .iter()
                .map(|node| usize::from(node.tag == tag) + count(&node.children, tag))
                .sum()
        }
        let mut container = hwp5::Hwp5Container::open(source).map_err(|_| unsupported())?;
        let compressed = container.file_header().is_compressed();
        let raw = container
            .read_record_stream_bounded("/DocInfo", 16 * 1024 * 1024)
            .map_err(|_| unsupported())?;
        let mut source_nodes = hwp5::record::scan_stream(&raw, hwp5::record::ScanMode::Strict)
            .map_err(|_| unsupported())?
            .roots;
        let original_count = document.header.para_shapes.len();
        if count(&source_nodes, hwp5::record::tag::ID_MAPPINGS) != 1
            || count(&source_nodes, hwp5::record::tag::PARA_SHAPE) != original_count
        {
            return Err(unsupported());
        }
        let mapping = Self::mapping_mut(&mut source_nodes).ok_or_else(unsupported)?;
        if mapping.data.len() < 56
            || u32::from_le_bytes(mapping.data[52..56].try_into().expect("checked count")) as usize
                != original_count
        {
            return Err(unsupported());
        }
        let shapes: Vec<_> = mapping
            .children
            .iter()
            .filter(|node| node.tag == hwp5::record::tag::PARA_SHAPE)
            .cloned()
            .collect();
        if shapes.len() != original_count {
            return Err(unsupported());
        }
        Ok(Self {
            source_nodes,
            shapes,
            original_count,
            compressed,
        })
    }
    fn allocate(&mut self, source: u16, alignment: u8) -> Result<u16> {
        let mut raw = self
            .shapes
            .get(source as usize)
            .cloned()
            .ok_or_else(unsupported)?;
        if source as usize >= self.original_count || raw.data.len() < 4 {
            return Err(unsupported());
        }
        let attr = u32::from_le_bytes(raw.data[..4].try_into().expect("checked shape"));
        raw.data[..4]
            .copy_from_slice(&((attr & !(7 << 2)) | (u32::from(alignment) << 2)).to_le_bytes());
        if let Some(index) = self.shapes.iter().position(|shape| *shape == raw) {
            return u16::try_from(index).map_err(|_| unsupported());
        }
        let id = u16::try_from(self.shapes.len())
            .map_err(|_| err("resource_limit", "문단 서식 수가 지원 범위를 넘습니다."))?;
        self.shapes.push(raw);
        Ok(id)
    }
    fn write_docinfo(&self, output: &Path) -> Result<()> {
        let mut nodes = self.source_nodes.clone();
        let mapping = Self::mapping_mut(&mut nodes).ok_or_else(unsupported)?;
        let insertion = mapping
            .children
            .iter()
            .rposition(|node| node.tag == hwp5::record::tag::PARA_SHAPE)
            .map(|index| index + 1)
            .ok_or_else(unsupported)?;
        mapping.children.splice(
            insertion..insertion,
            self.shapes[self.original_count..].iter().cloned(),
        );
        mapping.data[52..56].copy_from_slice(
            &u32::try_from(self.shapes.len())
                .map_err(|_| unsupported())?
                .to_le_bytes(),
        );
        let raw = hwp5::record::RecordNode::serialize_forest(&nodes);
        let current = {
            let mut container = hwp5::Hwp5Container::open(output).map_err(|_| unsupported())?;
            if container.file_header().is_compressed() != self.compressed {
                return Err(unsupported());
            }
            container
                .read_record_stream_bounded("/DocInfo", 16 * 1024 * 1024)
                .map_err(|_| unsupported())?
        };
        if current == raw {
            return Ok(());
        }
        let encoded = if self.compressed {
            hwp5::codec::compress(&raw)
        } else {
            raw
        };
        let mut container = cfb::open_rw(output).map_err(io_error)?;
        container
            .create_stream("/DocInfo")
            .map_err(io_error)?
            .write_all(&encoded)
            .map_err(io_error)?;
        container.flush().map_err(io_error)?;
        Ok(())
    }
}
fn docinfo_records(path: &Path) -> Result<Vec<(usize, u16, Vec<u8>)>> {
    fn walk(
        nodes: &[hwp5::record::RecordNode],
        depth: usize,
        records: &mut Vec<(usize, u16, Vec<u8>)>,
    ) {
        for node in nodes {
            records.push((depth, node.tag, node.data.clone()));
            walk(&node.children, depth + 1, records);
        }
    }
    let mut container = hwp5::Hwp5Container::open(path).map_err(|_| unsupported())?;
    let bytes = container
        .read_record_stream_bounded("/DocInfo", 16 * 1024 * 1024)
        .map_err(|_| unsupported())?;
    let scan = hwp5::record::scan_stream(&bytes, hwp5::record::ScanMode::Strict)
        .map_err(|_| unsupported())?;
    let mut records = Vec::new();
    walk(&scan.roots, 0, &mut records);
    Ok(records)
}
fn verify_docinfo_alignment(
    before: &Path,
    after: &Path,
    original: &Document,
    edited: &Document,
    changes: &[Change],
) -> Result<()> {
    let character_changes = changes.iter().any(|change| change.range.is_some());
    let loss = || {
        err(
            "unsupported_loss",
            "원본 문단 서식과 비수정 정보를 보존할 수 없어 저장을 중단했습니다.",
        )
    };
    let old = docinfo_records(before)?;
    let new = docinfo_records(after)?;
    let shapes = |records: &[(usize, u16, Vec<u8>)]| {
        records
            .iter()
            .filter(|(_, tag, _)| *tag == hwp5::record::tag::PARA_SHAPE)
            .cloned()
            .collect::<Vec<_>>()
    };
    let old_shapes = shapes(&old);
    let new_shapes = shapes(&new);
    if old_shapes.len() != original.header.para_shapes.len()
        || new_shapes.len() != edited.header.para_shapes.len()
        || !new_shapes.starts_with(&old_shapes)
        || !edited
            .header
            .para_shapes
            .starts_with(&original.header.para_shapes)
    {
        return Err(loss());
    }
    for change in changes.iter().filter(|change| change.alignment.is_some()) {
        let source = &original.sections[change.section].paragraphs[change.paragraph];
        let target = &edited.sections[change.section].paragraphs[change.paragraph];
        let mut expected = old_shapes
            .get(source.para_shape.0 as usize)
            .cloned()
            .ok_or_else(loss)?;
        if expected.2.len() < 4 {
            return Err(loss());
        }
        let attr = u32::from_le_bytes(expected.2[..4].try_into().expect("checked shape"));
        expected.2[..4].copy_from_slice(
            &((attr & !(7 << 2)) | (u32::from(change.alignment.expect("filtered alignment")) << 2))
                .to_le_bytes(),
        );
        if new_shapes.get(target.para_shape.0 as usize) != Some(&expected) {
            return Err(loss());
        }
    }
    for (index, record) in new_shapes.iter().enumerate().skip(old_shapes.len()) {
        let mut matched = false;
        for change in changes.iter().filter(|change| change.alignment.is_some()) {
            let source = &original.sections[change.section].paragraphs[change.paragraph];
            let target = &edited.sections[change.section].paragraphs[change.paragraph];
            if target.para_shape.0 as usize != index {
                continue;
            }
            let mut expected = old_shapes
                .get(source.para_shape.0 as usize)
                .cloned()
                .ok_or_else(loss)?;
            if expected.2.len() < 4 {
                return Err(loss());
            }
            let attr = u32::from_le_bytes(expected.2[..4].try_into().expect("checked shape"));
            expected.2[..4].copy_from_slice(
                &((attr & !(7 << 2))
                    | (u32::from(change.alignment.expect("filtered alignment")) << 2))
                    .to_le_bytes(),
            );
            if *record != expected {
                return Err(loss());
            }
            matched = true;
        }
        if !matched {
            return Err(loss());
        }
    }
    let normalize = |records: Vec<(usize, u16, Vec<u8>)>,
                     count: usize,
                     character_count: usize|
     -> Result<Vec<(usize, u16, Vec<u8>)>> {
        let mut result = Vec::new();
        let mut mappings = 0;
        for (depth, tag, mut data) in records {
            if tag == hwp5::record::tag::PARA_SHAPE
                || (character_changes && tag == hwp5::record::tag::CHAR_SHAPE)
            {
                continue;
            }
            if tag == hwp5::record::tag::ID_MAPPINGS {
                mappings += 1;
                if data.len() < 56
                    || u32::from_le_bytes(data[52..56].try_into().expect("checked count")) as usize
                        != count
                {
                    return Err(loss());
                }
                data[52..56].fill(0);
                if character_changes {
                    if u32::from_le_bytes(data[36..40].try_into().expect("checked character count"))
                        as usize
                        != character_count
                    {
                        return Err(loss());
                    }
                    data[36..40].fill(0);
                }
            }
            result.push((depth, tag, data));
        }
        if mappings != 1 {
            return Err(loss());
        }
        Ok(result)
    };
    if normalize(old, old_shapes.len(), original.header.char_shapes.len())?
        != normalize(new, new_shapes.len(), edited.header.char_shapes.len())?
    {
        return Err(loss());
    }
    Ok(())
}
fn preserve_hwp(
    before: &Path,
    after: &Path,
    original: &Document,
    edited: &Document,
    changes: &[Change],
) -> Result<()> {
    let mut a = hwp5::Hwp5Container::open(before).map_err(|_| unsupported())?;
    let mut b = hwp5::Hwp5Container::open(after).map_err(|_| unsupported())?;
    let mut dirty: BTreeSet<_> = changes
        .iter()
        .map(|c| format!("/BodyText/Section{}", c.section))
        .collect();
    if changes
        .iter()
        .any(|change| change.alignment.is_some() || change.range.is_some())
    {
        verify_docinfo_alignment(before, after, original, edited, changes)?;
        dirty.insert("/DocInfo".to_owned());
    }
    if a.list_storages() != b.list_storages()
        || a.list_streams()
            .iter()
            .any(|s| !b.list_streams().iter().any(|t| t.path == s.path))
        || b.list_streams()
            .iter()
            .any(|s| s.path != "/PrvText" && !a.list_streams().iter().any(|t| t.path == s.path))
    {
        return Err(err(
            "unsupported_loss",
            "원본 보관 요소가 바뀌어 저장을 중단했습니다.",
        ));
    }
    for entry in a.list_streams() {
        if entry.path != "/PrvText"
            && !dirty.contains(&entry.path)
            && a.read_stream_raw(&entry.path).map_err(|_| unsupported())?
                != b.read_stream_raw(&entry.path).map_err(|_| unsupported())?
        {
            return Err(err(
                "unsupported_loss",
                "원본의 비수정 영역이 바뀌어 저장을 중단했습니다.",
            ));
        }
    }
    Ok(())
}
fn render(
    doc: &mut Document,
    request: &Value,
    work: &Path,
    table_insertion: Option<&TableInsertion>,
    table_structure: Option<&crate::xml::table_structure::Edit>,
) -> Result<(PathBuf, usize, Value)> {
    let dirs = request["fontDirectories"]
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= 8)
        .ok_or_else(|| err("fonts_unavailable", "문서 글꼴을 준비하지 못했습니다."))?;
    let mut store = hwp_render::FontStore::new_isolated();
    for dir in dirs {
        let file = Path::new(dir.as_str().ok_or_else(invalid)?).join("NotoSansCJKkr-Regular.otf");
        if file_hash(&file)? != FONT_SHA {
            return Err(err(
                "fonts_unavailable",
                "문서 글꼴 파일을 확인하지 못했습니다.",
            ));
        }
        store
            .load_file(&file)
            .map_err(|_| err("fonts_unavailable", "문서 글꼴을 읽지 못했습니다."))?;
    }
    let original_fonts = doc.header.fonts.clone();
    let mut substitutions = 0usize;
    for faces in &mut doc.header.fonts {
        for face in faces {
            if face.name != "Noto Sans CJK KR" {
                substitutions += 1;
            }
            face.name = "Noto Sans CJK KR".to_owned();
            face.alt_name = None;
        }
    }
    if let Some(table) = table_insertion
        && let Err(error) = table.validate_render_width(doc, &mut store)
    {
        doc.header.fonts = original_fonts;
        return Err(error);
    }
    if let Some(edit) = table_structure
        && let Err(error) = edit.validate_render_width(doc, &mut store)
    {
        doc.header.fonts = original_fonts;
        return Err(error);
    }
    let mut issues = hwp_render::RenderIssueAccumulator::new();
    let mut budget = hwp_render::layout::LayoutBudget::certification();
    budget.max_pages = 512;
    budget.max_display_items = 250_000;
    let layout_result =
        hwp_render::layout::layout_document_bounded(doc, &mut store, &mut issues, &budget);
    doc.header.fonts = original_fonts;
    let list = layout_result.map_err(|_| {
        err(
            "incomplete_layout",
            "문서의 전체 쪽 배치를 만들지 못했습니다.",
        )
    })?;
    let count = list.pages.len();
    let complete_fonts = store.resolutions_complete;
    issues.absorb(store.issues.finish());
    let pdf = hwp_render::pdf::render_pdf(&list, &mut issues)
        .map_err(|_| err("render_failed", "문서 PDF를 만들지 못했습니다."))?;
    let report = issues.finish();
    let mut diagnostics = json!(
        report
            .issues
            .iter()
            .map(|i| json!({"code":i.code.as_str(),"severity":i.severity.as_str(),"count":i.count}))
            .collect::<Vec<_>>()
    );
    if substitutions > 0 {
        diagnostics.as_array_mut().expect("diagnostics array").push(
            json!({"code":"bundled_font_substitution","severity":"warning","count":substitutions}),
        );
    }
    fs::write(work.join("diagnostics.json"), diagnostics.to_string()).map_err(io_error)?;
    let path = work.join("document.pdf");
    fs::write(&path, pdf).map_err(io_error)?;
    if count == 0
        || !complete_fonts
        || report.has_required_failure()
        || report.font_coverage().missing > 0
        || report
            .issues
            .iter()
            .any(|i| i.code.as_str().contains("clipped"))
    {
        return Err(err(
            "incomplete_layout",
            "문서의 일부를 표시하지 못해 저장을 중단했습니다. 수정 작업 파일은 보관됩니다.",
        ));
    }
    Ok((path, count, diagnostics))
}
