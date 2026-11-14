use hwp_model::{CharShape, CharShapeId, Control, Document, HwpChar, Paragraph};
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

const TARGET: &str = "앞\t😀e\u{301}👩\u{200d}💻한글뒤";
const CELL: &str = "셀😀e\u{301}한글";

#[derive(Clone)]
struct Target {
    kind: &'static str,
    id: String,
    cell: Option<String>,
    text: String,
}

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn call(request: Value) -> Value {
    request_json(&request.to_string())
}

fn inspect(source: &Path) -> Value {
    let result = call(json!({"mode":"inspect", "sourcePath":source}));
    assert!(
        result.get("error").is_none(),
        "Fixture must reach inspect: {result}"
    );
    result["snapshot"].clone()
}

fn load(source: &Path) -> Document {
    if source.extension().unwrap() == "hwp" {
        hwp5::read_document(source).unwrap().document
    } else {
        hwpx::read_document(source).unwrap().document
    }
}

fn text(p: &Paragraph) -> String {
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

fn visible_width(c: &HwpChar) -> u32 {
    match c {
        HwpChar::Text(c) => c.len_utf16() as u32,
        HwpChar::CharCtrl(10) | HwpChar::InlineCtrl { code: 9, .. } => 1,
        _ => 0,
    }
}

fn raw_boundary(p: &Paragraph, offset: u32) -> u32 {
    let (mut visible, mut raw) = (0, 0);
    for c in &p.chars {
        if visible == offset {
            return raw;
        }
        visible += visible_width(c);
        raw += c.wchar_width();
    }
    assert_eq!(visible, offset);
    raw
}

fn seed(p: &mut Paragraph, value: &str, a: CharShapeId, b: CharShapeId, middle: u32, end: u32) {
    let prefix: Vec<_> = p
        .chars
        .iter()
        .filter(|c| matches!(c, HwpChar::ExtCtrl { code: 2, .. }))
        .cloned()
        .collect();
    p.chars = prefix;
    p.chars.extend(value.chars().map(|c| match c {
        '\t' => HwpChar::InlineCtrl {
            code: 9,
            payload: vec![0; 12],
        },
        '\n' => HwpChar::CharCtrl(10),
        c => HwpChar::Text(c),
    }));
    p.chars.push(HwpChar::CharCtrl(13));
    p.char_shape_runs = vec![
        (0, a),
        (raw_boundary(p, middle), b),
        (raw_boundary(p, end), a),
    ];
    p.line_segs.clear();
}

fn fixture(ext: &str) -> (TempDir, PathBuf) {
    fixture_with_underlines(ext, 1, 1)
}

fn fixture_with_underlines(ext: &str, first: u32, second: u32) -> (TempDir, PathBuf) {
    let directory = TempDir::new().unwrap();
    let source = directory.path().join(format!("original.{ext}"));
    let mut doc = hwp_convert::from_markdown(
        "placeholder\n\n다른 문단 보존\n\n| 가 | 나 |\n| --- | --- |\n| placeholder cell | 다른 셀 보존 |\n",
    );
    let mut a = doc.header.char_shapes[0].clone();
    a.attr = ((a.attr | 1) & !0xfe) | (first << 2);
    a.base_size = 1100;
    a.text_color = 0x00332211;
    if first != 0 && first != second {
        a.attr |= 1 << 4;
        a.underline_color = 0x00112233;
    }
    let mut b = a.clone();
    b.attr = ((b.attr | 2) & !0xfd) | (second << 2);
    b.base_size = 1400;
    b.text_color = 0x00665544;
    let aid = CharShapeId(doc.header.char_shapes.len() as u16);
    doc.header.char_shapes.push(a);
    let bid = CharShapeId(doc.header.char_shapes.len() as u16);
    doc.header.char_shapes.push(b);
    seed(&mut doc.sections[0].paragraphs[0], TARGET, aid, bid, 4, 11);
    doc.sections[0].paragraphs[1].char_shape_runs = vec![(0, aid)];
    let mut found = false;
    for p in &mut doc.sections[0].paragraphs {
        for control in &mut p.controls {
            if let Control::Table(table) = control {
                for cell in &mut table.cells {
                    if cell.paragraphs.len() == 1 && text(&cell.paragraphs[0]) == "placeholder cell"
                    {
                        seed(&mut cell.paragraphs[0], CELL, aid, bid, 3, 5);
                        found = true;
                    }
                }
            }
        }
    }
    assert!(
        found,
        "Synthetic table cell must exist before the API is exercised"
    );
    doc.metadata.title = Some("선택 글자 서식 보존".into());
    if ext == "hwp" {
        doc.hwp5_xml_template.push((
            "/XMLTemplate/Keep.xml".into(),
            b"<keep exact=\"YES\"/>".to_vec(),
        ));
        doc.header.extras.push(hwp_model::OpaqueRecord {
            tag: 0x3e0,
            data: b"KEEP_RAW_DOCINFO".to_vec(),
            children: vec![],
        });
        hwp5::write_document_with_report(&doc, &source, &hwp5::WriteOptions::default()).unwrap();
    } else {
        doc.hwpx_extra_entries.push((
            "DocOptions/Keep.xml".into(),
            b"<keep exact=\"YES\"/>".to_vec(),
        ));
        hwpx::write_document(&doc, &source).unwrap();
    }
    let reopened = load(&source);
    assert_eq!(text(&reopened.sections[0].paragraphs[0]), TARGET);
    (directory, source)
}

fn target(snapshot: &Value, cell: bool) -> Target {
    if cell {
        for table in snapshot["tables"].as_array().unwrap() {
            for (key, value) in table["cells"].as_object().unwrap() {
                if value == CELL {
                    return Target {
                        kind: "cell",
                        id: table["id"].as_str().unwrap().into(),
                        cell: Some(key.clone()),
                        text: CELL.into(),
                    };
                }
            }
        }
        panic!("Synthetic cell must be exposed by inspect");
    }
    let p = snapshot["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["text"] == TARGET)
        .unwrap();
    Target {
        kind: "paragraph",
        id: p["id"].as_str().unwrap().into(),
        cell: None,
        text: TARGET.into(),
    }
}

fn location(target: &Target) -> (usize, usize, Option<usize>) {
    let parts: Vec<_> = target.id.split(':').collect();
    (
        parts[0].strip_prefix('s').unwrap().parse().unwrap(),
        parts[1].strip_prefix('p').unwrap().parse().unwrap(),
        parts
            .get(2)
            .map(|part| part.strip_prefix('t').unwrap().parse().unwrap()),
    )
}

fn paragraph<'a>(doc: &'a Document, target: &Target) -> &'a Paragraph {
    let (s, p, control) = location(target);
    let parent = &doc.sections[s].paragraphs[p];
    if let Some(control) = control {
        let Control::Table(table) = &parent.controls[control] else {
            panic!("Expected table");
        };
        let (r, c) = target.cell.as_ref().unwrap().split_once(',').unwrap();
        let cell = table
            .cells
            .iter()
            .find(|cell| cell.row.to_string() == r && cell.col.to_string() == c)
            .unwrap();
        assert_eq!(cell.paragraphs.len(), 1);
        &cell.paragraphs[0]
    } else {
        parent
    }
}

fn paragraph_mut<'a>(doc: &'a mut Document, target: &Target) -> &'a mut Paragraph {
    let (s, p, control) = location(target);
    let parent = &mut doc.sections[s].paragraphs[p];
    if let Some(control) = control {
        let Control::Table(table) = &mut parent.controls[control] else {
            panic!("Expected table");
        };
        let (r, c) = target.cell.as_ref().unwrap().split_once(',').unwrap();
        let cell = table
            .cells
            .iter_mut()
            .find(|cell| cell.row.to_string() == r && cell.col.to_string() == c)
            .unwrap();
        assert_eq!(cell.paragraphs.len(), 1);
        &mut cell.paragraphs[0]
    } else {
        parent
    }
}

fn styles(doc: &Document, target: &Target) -> Vec<CharShape> {
    let p = paragraph(doc, target);
    let mut result = Vec::new();
    let mut raw = 0;
    for c in &p.chars {
        let id = p
            .char_shape_runs
            .iter()
            .rev()
            .find(|(start, _)| *start <= raw)
            .unwrap()
            .1;
        result.extend(std::iter::repeat_n(
            doc.header.char_shapes[id.0 as usize].clone(),
            visible_width(c) as usize,
        ));
        raw += c.wchar_width();
    }
    assert_eq!(result.len(), text(p).encode_utf16().count());
    result
}

fn colorref(rgb: u32) -> u32 {
    ((rgb & 255) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 255)
}

fn operation(target: &Target, op: &str, start: usize, end: usize) -> Value {
    let mut result = json!({"op":op, "targetKind":target.kind, "id":target.id,
        "startUtf16":start, "endUtf16":end, "expectedTextSha256":hash(target.text.as_bytes())});
    if let Some(cell) = &target.cell {
        result["cell"] = json!(cell);
    }
    result
}

fn style_operation(target: &Target, start: usize, end: usize) -> Value {
    let mut result = operation(target, "textStyle", start, end);
    result["bold"] = json!(true);
    result["color"] = json!(0x123456);
    result["fontSize"] = json!(17.5);
    result
}

fn apply(source: &Path, output: &Path, operations: Vec<Value>) -> Value {
    call(
        json!({"mode":"apply", "sourcePath":source, "outputDirectory":output,
        "expectedSourceSha256":hash(&fs::read(source).unwrap()), "sessionId":"range-style-test",
        "fontDirectories":[Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build/native/fonts")],
        "operations":operations}),
    )
}

fn saved(reply: &Value, source: &Path) -> PathBuf {
    assert_eq!(
        reply["status"], "saved",
        "Range operation must reach real save: {reply}"
    );
    let output = PathBuf::from(reply["sourcePath"].as_str().unwrap());
    assert_ne!(output, source);
    assert_eq!(output.extension(), source.extension());
    assert_eq!(reply["sourceSha256"], hash(&fs::read(&output).unwrap()));
    assert!(
        fs::read(reply["pdfPath"].as_str().unwrap())
            .unwrap()
            .starts_with(b"%PDF-")
    );
    assert!(reply["pdfPageCount"].as_u64().unwrap() > 0);
    output
}

fn assert_isolation(before: &Document, after: &Document, target: &Target) {
    let mut expected = before.clone();
    *paragraph_mut(&mut expected, target) = paragraph(after, target).clone();
    if target.cell.is_some() {
        let (s, p, _) = location(target);
        expected.sections[s].paragraphs[p].line_segs =
            after.sections[s].paragraphs[p].line_segs.clone();
    }
    assert_eq!(
        expected.sections, after.sections,
        "Non-target paragraph/cell/control payload changed"
    );
    assert_eq!(before.metadata, after.metadata);
    assert_eq!(before.bin_streams, after.bin_streams);
    assert_eq!(before.hwp5_xml_template, after.hwp5_xml_template);
    assert_eq!(before.hwp5_doc_history, after.hwp5_doc_history);
    assert_eq!(before.hwpx_extra_entries, after.hwpx_extra_entries);
    let mut old = before.header.clone();
    let mut new = after.header.clone();
    assert!(
        new.char_shapes.starts_with(&old.char_shapes),
        "Existing styles must remain unmodified"
    );
    old.char_shapes.clear();
    new.char_shapes.clear();
    if old.id_mappings_counts.len() > 9 && new.id_mappings_counts.len() > 9 {
        old.id_mappings_counts[9] = 0;
        new.id_mappings_counts[9] = 0;
    }
    assert_eq!(old, new, "Unrelated header data changed");
}

fn assert_details(snapshot: &Value, target: &Target, doc: &Document) {
    let details = if let Some(cell) = &target.cell {
        &snapshot["tables"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["id"] == target.id)
            .unwrap()["cellTextDetails"][cell]
    } else {
        &snapshot["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["id"] == target.id)
            .unwrap()["textDetails"]
    };
    assert!(
        details.is_object(),
        "Editable HWP text must expose actual range details: {details}"
    );
    assert_eq!(details["textSha256"], hash(target.text.as_bytes()));
    assert_eq!(details["utf16Length"], target.text.encode_utf16().count());
    assert_eq!(
        details["canReplace"], true,
        "Adding style must not disable existing text editing"
    );
    assert_eq!(details["canStyle"], true);
    assert_eq!(details["truncated"], false);
    assert_eq!(details["protectedRanges"], json!([]));
    let expected = styles(doc, target);
    let mut cursor = 0;
    for run in details["runs"].as_array().unwrap() {
        let start = run["startUtf16"].as_u64().unwrap() as usize;
        let end = run["endUtf16"].as_u64().unwrap() as usize;
        assert_eq!(start, cursor);
        assert!(start < end && end <= expected.len());
        for value in &expected[start..end] {
            assert_eq!(run["bold"], value.is_bold());
            assert_eq!(run["italic"], value.is_italic());
            assert_eq!(run["underline"], value.has_underline());
            assert_eq!(run["color"], colorref(value.text_color));
            assert_eq!(
                run["fontSize"].as_f64().unwrap(),
                value.base_size as f64 / 100.0
            );
        }
        cursor = end;
    }
    assert_eq!(cursor, expected.len());
}

#[test]
fn inspect_exposes_real_range_runs_and_keeps_paragraph_and_cell_replace_enabled() {
    for ext in ["hwp", "hwpx"] {
        let (_directory, source) = fixture(ext);
        let snapshot = inspect(&source);
        let doc = load(&source);
        for cell in [false, true] {
            assert_details(&snapshot, &target(&snapshot, cell), &doc);
        }
    }
}

#[test]
fn three_properties_change_only_selected_utf16_units_and_isolate_shared_styles() {
    for ext in ["hwp", "hwpx"] {
        for cell in [false, true] {
            let (directory, source) = fixture(ext);
            let original = fs::read(&source).unwrap();
            let target = target(&inspect(&source), cell);
            let before = load(&source);
            let start = if cell { 1 } else { 2 };
            let end = target.text.encode_utf16().count() - 1;
            let reply = apply(
                &source,
                &directory.path().join("style"),
                vec![style_operation(&target, start, end)],
            );
            let output = saved(&reply, &source);
            let after = load(&output);
            let mut expected = styles(&before, &target);
            for style in &mut expected[start..end] {
                style.attr |= 2;
                style.text_color = colorref(0x123456);
                style.base_size = 1750;
            }
            assert_eq!(
                styles(&after, &target),
                expected,
                "Visible UTF16 offsets must not be used as raw WCHAR offsets"
            );
            let mut expected_paragraph = paragraph(&before, &target).clone();
            expected_paragraph.char_shape_runs = paragraph(&after, &target).char_shape_runs.clone();
            expected_paragraph.line_segs.clear();
            assert_eq!(&expected_paragraph, paragraph(&after, &target));
            assert_isolation(&before, &after, &target);
            assert_details(&inspect(&output), &target, &after);
            assert_eq!(fs::read(&source).unwrap(), original);
        }
    }
}

#[test]
fn omitted_properties_preserve_existing_values_and_explicit_false_is_applied() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let target = target(&inspect(&source), false);
        let before = load(&source);
        let mut op = operation(&target, "textStyle", 6, 11);
        op["bold"] = json!(false);
        let output = saved(
            &apply(&source, &directory.path().join("bold-off"), vec![op]),
            &source,
        );
        let mut expected = styles(&before, &target);
        for style in &mut expected[6..11] {
            style.attr &= !2;
        }
        assert_eq!(styles(&load(&output), &target), expected);
    }
}

#[test]
fn italic_can_be_applied_and_cleared_only_in_selected_paragraphs_and_cells() {
    for ext in ["hwp", "hwpx"] {
        for cell in [false, true] {
            let (directory, source) = fixture(ext);
            let source_bytes = fs::read(&source).unwrap();
            let selected = target(&inspect(&source), cell);
            let original = load(&source);
            let original_styles = styles(&original, &selected);
            let (start, end) = if cell { (1, 6) } else { (2, 13) };
            assert!(original_styles[start..end].iter().any(CharShape::is_bold));
            assert!(
                original_styles[start..end]
                    .iter()
                    .all(CharShape::has_underline)
            );
            assert!(original_styles[start..end].iter().any(CharShape::is_italic));
            assert!(
                original_styles[start..end]
                    .iter()
                    .any(|style| !style.is_italic())
            );

            let mut current = source.clone();
            let mut previous = original;
            for (label, italic) in [("italic-on", true), ("italic-off", false)] {
                let mut op = operation(&selected, "textStyle", start, end);
                op["italic"] = json!(italic);
                let output = saved(
                    &apply(&current, &directory.path().join(label), vec![op]),
                    &current,
                );
                let after = load(&output);
                let mut expected = original_styles.clone();
                for style in &mut expected[start..end] {
                    style.attr = (style.attr & !1) | u32::from(italic);
                }
                assert_eq!(styles(&after, &selected), expected);
                assert_eq!(text(paragraph(&after, &selected)), selected.text);
                assert_isolation(&previous, &after, &selected);
                assert_details(&inspect(&output), &selected, &after);
                current = output;
                previous = after;
            }
            assert_eq!(fs::read(&source).unwrap(), source_bytes);
        }
    }
}

#[test]
fn underline_changes_only_the_selected_utf16_range_in_body_and_cell() {
    for ext in ["hwp", "hwpx"] {
        for cell in [false, true] {
            let (directory, source) = fixture_with_underlines(ext, 1, 0);
            let source_bytes = fs::read(&source).unwrap();
            let selected = target(&inspect(&source), cell);
            let (start, end) = if cell { (1, 6) } else { (2, 13) };
            let original = load(&source);
            let original_styles = styles(&original, &selected);
            assert!(original_styles[start..end].iter().any(CharShape::has_underline));
            assert!(original_styles[start..end].iter().any(|style| !style.has_underline()));

            let mut current = source.clone();
            let mut previous = original;
            for (label, enabled) in [("on", true), ("off", false), ("on-again", true)] {
                let mut op = operation(&selected, "textStyle", start, end);
                op["underline"] = json!(enabled);
                let output = saved(
                    &apply(&current, &directory.path().join(label), vec![op]),
                    &current,
                );
                let after = load(&output);
                for (index, (before, actual)) in original_styles.iter().zip(styles(&after, &selected)).enumerate() {
                    if (start..end).contains(&index) {
                        assert_eq!(actual.has_underline(), enabled);
                        assert_eq!(actual.underline_color, before.underline_color);
                        assert_eq!(actual.attr & !0xfc, before.attr & !0xfc);
                        if enabled && before.has_underline() {
                            assert_eq!(actual.underline_shape_code(), before.underline_shape_code());
                        }
                        assert_eq!(actual.text_color, before.text_color);
                        assert_eq!(actual.base_size, before.base_size);
                    } else {
                        assert_eq!(&actual, before);
                    }
                }
                assert_eq!(text(paragraph(&after, &selected)), selected.text);
                assert_isolation(&previous, &after, &selected);
                assert_details(&inspect(&output), &selected, &after);
                current = output;
                previous = after;
            }
            assert_eq!(fs::read(&source).unwrap(), source_bytes);
        }
    }
}

#[test]
fn underline_preserves_overlines_and_refuses_to_overwrite_them() {
    for (ext, other) in [("hwp", 2), ("hwp", 3), ("hwpx", 3)] {
        let (directory, source) = fixture_with_underlines(ext, 1, other);
        let source_bytes = fs::read(&source).unwrap();
        let selected = target(&inspect(&source), false);
        let original = load(&source);
        let original_styles = styles(&original, &selected);
        assert!(original_styles[2..13].iter().any(|style| u32::from(style.underline_kind()) == other));
        let mut op = operation(&selected, "textStyle", 2, 13);
        op["underline"] = json!(true);
        let rejected = apply(&source, &directory.path().join("rejected"), vec![op.clone()]);
        assert_eq!(rejected["error"]["code"], "unsupported_structure", "{rejected}");
        op["underline"] = json!(false);
        let output = saved(&apply(&source, &directory.path().join("cleared"), vec![op]), &source);
        let after = load(&output);
        let actual = styles(&after, &selected);
        for (before, after) in original_styles[2..13].iter().zip(&actual[2..13]) {
            assert_eq!(after.underline_kind(), if before.has_underline() { 0 } else { before.underline_kind() });
        }
        assert_isolation(&original, &after, &selected);
        assert_eq!(fs::read(&source).unwrap(), source_bytes);
    }
}

#[test]
fn ordered_replacement_then_style_uses_current_digest_and_preserves_surrounding_runs() {
    for ext in ["hwp", "hwpx"] {
        for cell in [false, true] {
            let (directory, source) = fixture(ext);
            let target = target(&inspect(&source), cell);
            let before = load(&source);
            let old_styles = styles(&before, &target);
            let (start, end) = if cell { (1, 3) } else { (2, 4) };
            let mut replace = operation(&target, "textReplace", start, end);
            replace["text"] = json!("새😀");
            let old_units: Vec<_> = target.text.encode_utf16().collect();
            let mut units = old_units[..start].to_vec();
            units.extend("새😀".encode_utf16());
            units.extend(&old_units[end..]);
            let next_text = String::from_utf16(&units).unwrap();
            let next = Target {
                text: next_text.clone(),
                ..target.clone()
            };
            let style = style_operation(&next, start, start + 3);
            let reply = apply(
                &source,
                &directory.path().join("replace-style"),
                vec![replace, style],
            );
            let output = saved(&reply, &source);
            let after = load(&output);
            assert_eq!(text(paragraph(&after, &target)), next_text);
            let mut inserted = old_styles[start].clone();
            inserted.attr |= 2;
            inserted.text_color = colorref(0x123456);
            inserted.base_size = 1750;
            let expected: Vec<_> = old_styles[..start]
                .iter()
                .cloned()
                .chain(std::iter::repeat_n(inserted, 3))
                .chain(old_styles[end..].iter().cloned())
                .collect();
            assert_eq!(styles(&after, &target), expected);
            assert_isolation(&before, &after, &target);
            assert_details(&inspect(&output), &next, &after);
        }
    }
}

#[test]
fn ordered_style_then_insert_and_delete_keep_runs_and_reject_stale_later_digest() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let target = target(&inspect(&source), false);
        let before = load(&source);
        let mut insert = operation(&target, "textReplace", 6, 6);
        insert["text"] = json!("추가");
        let mut units: Vec<_> = target.text.encode_utf16().collect();
        units.splice(6..6, "추가".encode_utf16());
        let inserted = Target {
            text: String::from_utf16(&units).unwrap(),
            ..target.clone()
        };
        let mut delete = operation(&inserted, "textReplace", 6, 8);
        delete["text"] = json!("");
        let reply = apply(
            &source,
            &directory.path().join("insert-delete"),
            vec![
                style_operation(&target, 6, 11),
                insert.clone(),
                delete.clone(),
            ],
        );
        let output = saved(&reply, &source);
        let mut expected = styles(&before, &target);
        for style in &mut expected[6..11] {
            style.attr |= 2;
            style.text_color = colorref(0x123456);
            style.base_size = 1750;
        }
        assert_eq!(text(paragraph(&load(&output), &target)), target.text);
        assert_eq!(styles(&load(&output), &target), expected);
        delete["expectedTextSha256"] = json!(hash(target.text.as_bytes()));
        let failed = apply(
            &source,
            &directory.path().join("stale-after-insert"),
            vec![insert, delete],
        );
        assert_eq!(failed["error"]["code"], "source_changed", "{failed}");
        assert!(failed["error"].get("workingSourcePath").is_none());
    }
}

#[test]
fn empty_single_paragraph_cell_retains_a_typing_origin_then_inserts_and_styles_unicode() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let mut target = target(&inspect(&source), true);
        let mut document = load(&source);
        let empty = paragraph_mut(&mut document, &target);
        let id = empty.char_shape_runs[0].1;
        empty.chars.clear();
        if ext == "hwp" {
            empty.chars.push(HwpChar::CharCtrl(13));
        }
        empty.char_shape_runs = vec![(0, id)];
        empty.line_segs.clear();
        if ext == "hwp" {
            hwp5::write_document_with_report(&document, &source, &hwp5::WriteOptions::default())
                .unwrap();
        } else {
            hwpx::write_document(&document, &source).unwrap();
        }
        target.text.clear();
        let snapshot = inspect(&source);
        let table = snapshot["tables"]
            .as_array()
            .unwrap()
            .iter()
            .find(|table| table["id"] == target.id)
            .unwrap();
        let details = &table["cellTextDetails"][target.cell.as_ref().unwrap()];
        assert_eq!(
            details["canReplace"],
            true,
            "Empty legacy cell must remain editable: format={ext}; paragraph={:?}; snapshot={snapshot}",
            paragraph(&load(&source), &target)
        );
        assert_eq!(details["runs"].as_array().unwrap().len(), 1);
        assert_eq!(details["runs"][0]["startUtf16"], 0);
        assert_eq!(details["runs"][0]["endUtf16"], 0);
        let mut insert = operation(&target, "textReplace", 0, 0);
        insert["text"] = json!("가😀");
        let next = Target {
            text: "가😀".into(),
            ..target.clone()
        };
        let output = saved(
            &apply(
                &source,
                &directory.path().join("empty-insert"),
                vec![insert, style_operation(&next, 0, 3)],
            ),
            &source,
        );
        let after = load(&output);
        assert_eq!(text(paragraph(&after, &target)), "가😀");
        for style in styles(&after, &target) {
            assert!(style.is_bold());
            assert_eq!(style.base_size, 1750);
            assert_eq!(style.text_color, colorref(0x123456));
        }
    }
}

#[test]
fn hwp_empty_body_can_be_filled_cleared_and_edited_again() {
    let (directory, source) = fixture("hwp");
    let mut target = target(&inspect(&source), false);
    let mut document = load(&source);
    let first = paragraph_mut(&mut document, &target);
    first
        .chars
        .retain(|c| matches!(c, HwpChar::ExtCtrl { code: 2, .. } | HwpChar::CharCtrl(13)));
    first.char_shape_runs.truncate(1);
    first.line_segs.clear();
    hwp5::write_document_with_report(&document, &source, &hwp5::WriteOptions::default()).unwrap();
    let source_bytes = fs::read(&source).unwrap();
    let neighboring_text = text(&load(&source).sections[0].paragraphs[1]);
    let blank = inspect(&source)["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == target.id)
        .expect("The empty first body paragraph should be visible")
        .clone();
    assert_eq!(blank["text"], "");
    assert_eq!(blank["textDetails"]["canReplace"], true);
    assert_eq!(blank["textDetails"]["runs"][0]["endUtf16"], 0);
    let alignment = blank["paragraphFormat"]["alignment"].as_str().unwrap();

    let mut input = source.clone();
    let mut current_text = "";
    for (step, replacement) in ["가😀", "", "다시 입력"].into_iter().enumerate() {
        target.text = current_text.into();
        let mut edit = operation(&target, "textReplace", 0, current_text.encode_utf16().count());
        edit["text"] = json!(replacement);
        let reply = apply(&input, &directory.path().join(format!("blank-{step}")), vec![edit]);
        let output = saved(&reply, &input);
        let reopened = inspect(&output);
        let row = reopened["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == target.id)
            .expect("The original paragraph ID survives saving and reopening");
        assert_eq!(row["text"], replacement);
        assert_eq!(row["paragraphFormat"]["alignment"], alignment);
        assert_eq!(row["textDetails"]["canReplace"], true);
        assert_eq!(row["textDetails"]["utf16Length"], replacement.encode_utf16().count());
        assert_eq!(text(&load(&output).sections[0].paragraphs[1]), neighboring_text);
        input = output;
        current_text = replacement;
    }
    assert_eq!(fs::read(&source).unwrap(), source_bytes);
}

#[test]
fn range_contract_rejects_unknown_fields_bad_types_bounds_and_split_graphemes() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let original = fs::read(&source).unwrap();
        let target = target(&inspect(&source), false);
        let good = style_operation(&target, 2, 13);
        let mut invalid = vec![];
        for (key, value) in [
            ("italic", Value::Null),
            ("italic", json!(1)),
            ("italic", json!("true")),
            ("underline", Value::Null),
            ("underline", json!(1)),
            ("underline", json!("true")),
            ("fontFamily", json!("Arial")),
            ("format", json!({"bold":true})),
            ("bold", Value::Null),
            ("bold", json!(1)),
            ("color", json!(-1)),
            ("color", json!(0x1000000)),
            ("color", json!("#123456")),
            ("fontSize", json!(0)),
            ("fontSize", json!(400.01)),
            ("fontSize", json!("17.5")),
            ("fontSize", Value::Null),
            ("targetKind", json!("shape")),
            ("cell", json!("0,0")),
            ("expectedTextSha256", json!("bad")),
            ("startUtf16", json!(-1)),
            ("endUtf16", json!(1000000)),
            ("startUtf16", json!(2.5)),
        ] {
            let mut op = good.clone();
            op[key] = value;
            invalid.push(op);
        }
        let mut empty = good.clone();
        for key in ["bold", "color", "fontSize"] {
            empty.as_object_mut().unwrap().remove(key);
        }
        invalid.push(empty);
        let mut replace = operation(&target, "textReplace", 2, 4);
        replace["text"] = json!("대체");
        replace["italic"] = json!(true);
        invalid.push(replace);
        for (start, end) in [(2, 2), (4, 2), (3, 4), (4, 5), (7, 11), (6, 9)] {
            let mut op = good.clone();
            op["startUtf16"] = json!(start);
            op["endUtf16"] = json!(end);
            invalid.push(op);
        }
        for (index, op) in invalid.into_iter().enumerate() {
            let result = apply(
                &source,
                &directory.path().join(format!("invalid-{index}")),
                vec![op],
            );
            assert_eq!(
                result["error"]["code"], "invalid_request",
                "Invalid range/style {index}: {result}"
            );
            assert!(result.get("sourcePath").is_none());
            assert!(result["error"].get("workingSourcePath").is_none());
        }
        let mut stale = good;
        stale["expectedTextSha256"] = json!(hash(b"another paragraph"));
        let result = apply(&source, &directory.path().join("stale"), vec![stale]);
        assert_eq!(result["error"]["code"], "source_changed", "{result}");
        assert_eq!(fs::read(&source).unwrap(), original);
    }
}

#[test]
fn original_alignment_and_legacy_text_edit_on_other_targets_still_work_with_range_style() {
    for ext in ["hwp", "hwpx"] {
        let (directory, source) = fixture(ext);
        let snapshot = inspect(&source);
        let target = target(&snapshot, false);
        let other = snapshot["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["text"] == "다른 문단 보존")
            .unwrap();
        let result = apply(
            &source,
            &directory.path().join("legacy-and-range"),
            vec![
                style_operation(&target, 2, 13),
                json!({"op":"paragraphText", "id":other["id"], "text":"기존 글자 편집 유지"}),
                json!({"op":"paragraphFormat", "id":target.id,
                "expectedTextSha256":hash(target.text.as_bytes()), "alignment":"right"}),
            ],
        );
        let output = saved(&result, &source);
        let after = inspect(&output);
        assert!(
            after["paragraphs"]
                .as_array()
                .unwrap()
                .iter()
                .any(|p| p["text"] == "기존 글자 편집 유지")
        );
        let styled = after["paragraphs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["id"] == target.id)
            .unwrap();
        assert_eq!(styled["paragraphFormat"]["alignment"], "right");
        assert_eq!(styled["text"], TARGET);
    }
}

fn docinfo(path: &Path) -> Vec<(usize, u16, Vec<u8>)> {
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
    let mut input = hwp5::Hwp5Container::open(path).unwrap();
    let raw = input.read_record_stream("/DocInfo").unwrap();
    let mut result = vec![];
    walk(
        &hwp5::record::scan_stream(&raw, hwp5::record::ScanMode::Strict)
            .unwrap()
            .roots,
        0,
        &mut result,
    );
    result
}

#[test]
fn hwp_style_clones_change_only_three_raw_fields_count_and_target_body() {
    let (directory, source) = fixture("hwp");
    let target = target(&inspect(&source), false);
    let before = docinfo(&source);
    let reply = apply(
        &source,
        &directory.path().join("raw-hwp"),
        vec![style_operation(&target, 2, 13)],
    );
    let output = saved(&reply, &source);
    let after = docinfo(&output);
    let tag = hwp5::record::tag::CHAR_SHAPE;
    let old: Vec<_> = before.iter().filter(|(_, t, _)| *t == tag).collect();
    let new: Vec<_> = after.iter().filter(|(_, t, _)| *t == tag).collect();
    assert!(new.len() > old.len());
    assert_eq!(&new[..old.len()], old.as_slice());
    for clone in &new[old.len()..] {
        assert!(
            old.iter().any(|source| {
                let mut expected = source.2.clone();
                let attr = u32::from_le_bytes(expected[46..50].try_into().unwrap());
                expected[42..46].copy_from_slice(&1750i32.to_le_bytes());
                expected[46..50].copy_from_slice(&(attr | 2).to_le_bytes());
                expected[52..56].copy_from_slice(&colorref(0x123456).to_le_bytes());
                clone.2 == expected
            }),
            "New style must be a raw source clone with only requested fields changed"
        );
    }
    let normalize = |records: &[(usize, u16, Vec<u8>)]| {
        records
            .iter()
            .filter(|(_, t, _)| *t != tag)
            .map(|(depth, tag, bytes)| {
                let mut bytes = bytes.clone();
                if *tag == hwp5::record::tag::ID_MAPPINGS {
                    bytes[36..40].fill(0);
                }
                (*depth, *tag, bytes)
            })
            .collect::<Vec<_>>()
    };
    assert_eq!(normalize(&before), normalize(&after));
    let count = |records: &[(usize, u16, Vec<u8>)]| {
        let data = &records
            .iter()
            .find(|(_, t, _)| *t == hwp5::record::tag::ID_MAPPINGS)
            .unwrap()
            .2;
        u32::from_le_bytes(data[36..40].try_into().unwrap())
    };
    assert_eq!(
        count(&after) - count(&before),
        (new.len() - old.len()) as u32
    );
    let streams = |path: &Path| {
        let mut input = hwp5::Hwp5Container::open(path).unwrap();
        input
            .list_streams()
            .into_iter()
            .map(|entry| {
                let bytes = input.read_stream_raw(&entry.path).unwrap();
                (entry.path, bytes)
            })
            .collect::<BTreeMap<_, _>>()
    };
    let old_streams = streams(&source);
    let new_streams = streams(&output);
    assert_eq!(
        old_streams.keys().collect::<Vec<_>>(),
        new_streams.keys().collect::<Vec<_>>()
    );
    for (name, bytes) in old_streams {
        if !["/DocInfo", "/BodyText/Section0", "/PrvText"].contains(&name.as_str()) {
            assert_eq!(
                bytes, new_streams[&name],
                "Unrelated raw HWP stream changed: {name}"
            );
        }
    }
}

fn zip_entries(path: &Path) -> BTreeMap<String, (zip::CompressionMethod, Vec<u8>)> {
    let mut archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    (0..archive.len())
        .map(|i| {
            let mut entry = archive.by_index(i).unwrap();
            let mut bytes = vec![];
            entry.read_to_end(&mut bytes).unwrap();
            (entry.name().to_owned(), (entry.compression(), bytes))
        })
        .collect()
}

fn xml_blocks(xml: &str, local: &[u8]) -> Vec<String> {
    let mut reader = Reader::from_str(xml);
    let mut stack = vec![];
    let mut result = vec![];
    loop {
        let start = reader.buffer_position() as usize;
        match reader.read_event().unwrap() {
            Event::Start(e) if e.local_name().as_ref() == local => stack.push(start),
            Event::Empty(e) if e.local_name().as_ref() == local => {
                result.push(xml[start..reader.buffer_position() as usize].into())
            }
            Event::End(e) if e.local_name().as_ref() == local => {
                result.push(xml[stack.pop().unwrap()..reader.buffer_position() as usize].into())
            }
            Event::Eof => break,
            _ => {}
        }
    }
    result
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
        _ => panic!("Expected XML start"),
    }
}

fn normalize_char_style(mut xml: String) -> String {
    for key in ["id", "height", "textColor"] {
        let value = attribute(&xml, key.as_bytes());
        xml = xml.replacen(&format!(" {key}=\"{value}\""), &format!(" {key}=\"*\""), 1);
    }
    xml.replace("<hh:bold/>", "").replace("<hh:italic/>", "")
}

fn replace_hwpx_header(source: &Path, header: &str) {
    let temporary = source.with_extension("temporary.hwpx");
    let mut writer = zip::ZipWriter::new(fs::File::create(&temporary).unwrap());
    for (name, (method, bytes)) in zip_entries(source) {
        writer
            .start_file(
                &name,
                zip::write::SimpleFileOptions::default().compression_method(method),
            )
            .unwrap();
        writer
            .write_all(if name == "Contents/header.xml" {
                header.as_bytes()
            } else {
                &bytes
            })
            .unwrap();
    }
    writer.finish().unwrap();
    fs::rename(temporary, source).unwrap();
}

#[test]
fn hwpx_rejects_ambiguous_italic_markers_without_changing_source() {
    for marker in [
        "<hh:italic/><hh:italic/>",
        "<hh:italic hidden=\"vendor-data\"/>",
        "<x:italic xmlns:x=\"urn:vendor\"/>",
        "<x:metadata xmlns:x=\"urn:vendor\"><hh:italic/></x:metadata>",
    ] {
        let (directory, source) = fixture("hwpx");
        let selected = target(&inspect(&source), false);
        let header =
            String::from_utf8(zip_entries(&source)["Contents/header.xml"].1.clone()).unwrap();
        assert!(header.contains("<hh:italic/>"));
        replace_hwpx_header(&source, &header.replacen("<hh:italic/>", marker, 1));
        let original = fs::read(&source).unwrap();
        let mut op = operation(&selected, "textStyle", 2, 13);
        op["italic"] = json!(false);
        let reply = apply(&source, &directory.path().join("rejected"), vec![op]);
        assert_eq!(reply["error"]["code"], "unsupported_structure", "{reply}");
        assert_eq!(fs::read(&source).unwrap(), original);
    }
}

#[test]
fn hwpx_clones_raw_character_styles_and_preserves_extensions_other_xml_and_zip_methods() {
    let (directory, source) = fixture("hwpx");
    let entries = zip_entries(&source);
    let header = String::from_utf8(entries["Contents/header.xml"].1.clone()).unwrap();
    let header = header
        .replace(
            "<hh:charPr ",
            "<hh:charPr xmlns:v=\"urn:vendor\" v:textColor=\"SHADOW\" v:keep=\"EXACT_STYLE\" ",
        )
        .replace(
            "</hh:charPr>",
            "<v:metadata xmlns:v=\"urn:vendor\" value=\"KEEP\"/></hh:charPr>",
        );
    replace_hwpx_header(&source, &header);
    let before = zip_entries(&source);
    let target = target(&inspect(&source), false);
    let mut style = style_operation(&target, 2, 13);
    style["italic"] = json!(true);
    let output = saved(
        &apply(&source, &directory.path().join("raw-hwpx"), vec![style]),
        &source,
    );
    let after = zip_entries(&output);
    assert_eq!(
        before.keys().collect::<Vec<_>>(),
        after.keys().collect::<Vec<_>>()
    );
    for (name, (method, bytes)) in &before {
        assert_eq!(
            method, &after[name].0,
            "ZIP compression method changed: {name}"
        );
        if !["Contents/header.xml", "Contents/section0.xml"].contains(&name.as_str()) {
            assert_eq!(bytes, &after[name].1, "Unrelated ZIP entry changed: {name}");
        }
    }
    let new_header = std::str::from_utf8(&after["Contents/header.xml"].1).unwrap();
    let old_styles = xml_blocks(&header, b"charPr");
    let new_styles = xml_blocks(new_header, b"charPr");
    assert!(new_styles.len() > old_styles.len());
    assert_eq!(&new_styles[..old_styles.len()], old_styles.as_slice());
    for clone in &new_styles[old_styles.len()..] {
        assert_eq!(attribute(clone, b"height"), "1750");
        assert_eq!(attribute(clone, b"textColor"), "#123456");
        assert_eq!(xml_blocks(clone, b"bold").len(), 1);
        assert_eq!(xml_blocks(clone, b"italic").len(), 1);
        assert!(old_styles.iter().any(|old| normalize_char_style(old.clone()) == normalize_char_style(clone.clone())),
            "Only id and requested properties may change in the cloned raw XML");
        assert!(clone.contains("v:textColor=\"SHADOW\""));
        assert!(clone.contains("value=\"KEEP\""));
    }
    let mut expected_header = header.replacen(
        &format!("<hh:charProperties itemCnt=\"{}\">", old_styles.len()),
        &format!("<hh:charProperties itemCnt=\"{}\">", new_styles.len()),
        1,
    );
    expected_header = expected_header.replacen(
        "</hh:charProperties>",
        &format!(
            "{}</hh:charProperties>",
            new_styles[old_styles.len()..].concat()
        ),
        1,
    );
    assert_eq!(new_header, expected_header);
    let old_section = std::str::from_utf8(&before["Contents/section0.xml"].1).unwrap();
    let new_section = std::str::from_utf8(&after["Contents/section0.xml"].1).unwrap();
    let old_paragraphs = xml_blocks(old_section, b"p");
    let new_paragraphs = xml_blocks(new_section, b"p");
    assert_eq!(old_paragraphs.len(), new_paragraphs.len());
    for (old, new) in old_paragraphs.iter().zip(&new_paragraphs).skip(1) {
        assert_eq!(old, new);
    }
}
