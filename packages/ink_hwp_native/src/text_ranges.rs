use crate::{Result, err, invalid, io_error, text, unsupported};
use hwp_model::{CharShape, CharShapeId, Control, Document, HwpChar, Paragraph};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Write,
    path::Path,
};
use unicode_segmentation::UnicodeSegmentation;

const MAX_TEXT: usize = 1024 * 1024;
pub(crate) const ITALIC_FLAG: u32 = 1;
pub(crate) const BOLD_FLAG: u32 = 1 << 1;
pub(crate) const UNDERLINE_KIND_MASK: u32 = 3 << 2;
pub(crate) const BOTTOM_UNDERLINE_FLAG: u32 = 1 << 2;

fn digest(value: &str) -> String {
    Sha256::digest(value.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub(crate) fn rgb(value: u32) -> u32 {
    ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255)
}

#[derive(Clone)]
pub(crate) struct Style {
    bold: Option<bool>,
    italic: Option<bool>,
    underline: Option<bool>,
    size: Option<i32>,
    color: Option<u32>,
}

impl Style {
    fn parse(value: &Value) -> Result<Self> {
        let bold = value
            .get("bold")
            .map(|v| v.as_bool().ok_or_else(invalid))
            .transpose()?;
        let italic = value
            .get("italic")
            .map(|v| v.as_bool().ok_or_else(invalid))
            .transpose()?;
        let underline = value
            .get("underline")
            .map(|v| v.as_bool().ok_or_else(invalid))
            .transpose()?;
        let color = value
            .get("color")
            .map(|v| {
                v.as_u64()
                    .filter(|n| *n <= 0xffffff)
                    .map(|v| rgb(v as u32))
                    .ok_or_else(invalid)
            })
            .transpose()?;
        let size = value
            .get("fontSize")
            .map(|v| {
                let points = v
                    .as_f64()
                    .filter(|v| v.is_finite() && (1.0..=400.0).contains(v))
                    .ok_or_else(invalid)?;
                let units = points * 100.0;
                if (units - units.round()).abs() > 0.000001 {
                    return Err(invalid());
                }
                Ok(units.round() as i32)
            })
            .transpose()?;
        if bold.is_none() && italic.is_none() && underline.is_none() && size.is_none() && color.is_none() {
            return Err(invalid());
        }
        Ok(Self {
            bold,
            italic,
            underline,
            size,
            color,
        })
    }

    fn apply(&self, shape: &CharShape) -> Result<CharShape> {
        let mut result = shape.clone();
        if let Some(bold) = self.bold {
            result.attr = (result.attr & !BOLD_FLAG) | (u32::from(bold) * BOLD_FLAG);
        }
        if let Some(italic) = self.italic {
            result.attr = (result.attr & !ITALIC_FLAG) | (u32::from(italic) * ITALIC_FLAG);
        }
        match (self.underline, shape.attr & UNDERLINE_KIND_MASK) {
            (Some(true), 0) => result.attr |= BOTTOM_UNDERLINE_FLAG,
            (Some(false), BOTTOM_UNDERLINE_FLAG) => result.attr &= !UNDERLINE_KIND_MASK,
            (Some(true), kind) if kind != BOTTOM_UNDERLINE_FLAG => {
                return Err(err(
                    "unsupported_structure",
                    "윗줄이나 가운데 선이 있는 글자에는 아래 밑줄을 함께 적용할 수 없습니다.",
                ));
            }
            _ => {}
        }
        if let Some(size) = self.size {
            result.base_size = size;
        }
        if let Some(color) = self.color {
            result.text_color = color;
        }
        Ok(result)
    }
}

#[derive(Clone)]
pub(crate) struct RangeEdit {
    start: u32,
    end: u32,
    expected: String,
    style: Option<Style>,
    replacement: Option<String>,
}

impl RangeEdit {
    pub(crate) fn parse(value: &Value) -> Result<Self> {
        let op = text(value, "op")?;
        let fields = value.as_object().ok_or_else(invalid)?;
        let table = match text(value, "targetKind")? {
            "paragraph" => false,
            "cell" => true,
            _ => return Err(invalid()),
        };
        let allowed = [
            "op",
            "targetKind",
            "id",
            "startUtf16",
            "endUtf16",
            "expectedTextSha256",
        ];
        if fields.keys().any(|key| {
            !allowed.contains(&key.as_str())
                && !(table && key == "cell")
                && !(op == "textStyle"
                    && ["bold", "italic", "underline", "color", "fontSize"].contains(&key.as_str()))
                && !(op == "textReplace" && key == "text")
        }) {
            return Err(invalid());
        }
        let offset = |key| {
            value[key]
                .as_u64()
                .filter(|n| *n <= MAX_TEXT as u64)
                .map(|n| n as u32)
                .ok_or_else(invalid)
        };
        let (start, end) = (offset("startUtf16")?, offset("endUtf16")?);
        if start > end || (op == "textStyle" && start == end) {
            return Err(invalid());
        }
        let expected = text(value, "expectedTextSha256")?;
        if expected.len() != 64
            || !expected
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(invalid());
        }
        let (style, replacement) = if op == "textStyle" {
            (Some(Style::parse(value)?), None)
        } else if op == "textReplace" {
            let value = text(value, "text")?;
            if value.len() > MAX_TEXT
                || value
                    .chars()
                    .any(|c| c.is_control() && !matches!(c, '\t' | '\n' | '\r'))
            {
                return Err(invalid());
            }
            (None, Some(value.replace("\r\n", "\n").replace('\r', "\n")))
        } else {
            return Err(invalid());
        };
        Ok(Self {
            start,
            end,
            expected: expected.into(),
            style,
            replacement,
        })
    }

    pub(crate) fn apply(
        &self,
        paragraph: &mut Paragraph,
        shapes: &mut Vec<CharShape>,
        raw: Option<&mut HwpCharacters>,
        origins: &mut BTreeMap<u16, u16>,
    ) -> Result<()> {
        let projection = Projection::new(paragraph, shapes)?;
        if digest(&projection.text) != self.expected {
            return Err(err(
                "source_changed",
                "문단의 원문이 바뀌었습니다. 문서를 다시 열어 주세요.",
            ));
        }
        let mut boundary = BTreeSet::from([0]);
        let mut position = 0u32;
        for grapheme in projection.text.graphemes(true) {
            position += grapheme.encode_utf16().count() as u32;
            boundary.insert(position);
        }
        if !boundary.contains(&self.start) || !boundary.contains(&self.end) {
            return Err(invalid());
        }
        let &(start_raw, start_char) =
            projection.boundaries.get(&self.start).ok_or_else(invalid)?;
        let &(end_raw, end_char) = projection.boundaries.get(&self.end).ok_or_else(invalid)?;
        if let Some(style) = &self.style {
            let mut raw = raw;
            let mut allocated = BTreeMap::new();
            let mut points: BTreeSet<_> =
                paragraph.char_shape_runs.iter().map(|(p, _)| *p).collect();
            points.extend([start_raw, end_raw]);
            let mut runs = Vec::new();
            for point in points
                .into_iter()
                .filter(|point| *point < paragraph.wchar_len())
            {
                let source = style_at(&paragraph.char_shape_runs, point)?;
                let id = if start_raw <= point && point < end_raw {
                    if let Some(id) = allocated.get(&source) {
                        *id
                    } else {
                        let original = shapes.get(source.0 as usize).ok_or_else(unsupported)?;
                        let changed = style.apply(original)?;
                        let id = if changed == *original {
                            source
                        } else if let Some(raw) = raw.as_deref_mut() {
                            let id = raw.allocate(source.0, &changed)?;
                            if id as usize == shapes.len() {
                                shapes.push(changed);
                            } else if shapes.get(id as usize) != Some(&changed) {
                                return Err(unsupported());
                            }
                            CharShapeId(id)
                        } else {
                            let existing = origins
                                .iter()
                                .find(|(id, base)| {
                                    **base == source.0
                                        && shapes.get(**id as usize) == Some(&changed)
                                })
                                .map(|(id, _)| *id);
                            let id = if let Some(id) = existing {
                                id
                            } else {
                                let id = u16::try_from(shapes.len()).map_err(|_| {
                                    err("resource_limit", "글자 서식 수가 지원 범위를 넘습니다.")
                                })?;
                                shapes.push(changed);
                                origins.insert(id, source.0);
                                id
                            };
                            CharShapeId(id)
                        };
                        allocated.insert(source, id);
                        id
                    }
                } else {
                    source
                };
                push_run(&mut runs, point, id);
            }
            paragraph.char_shape_runs = runs;
        } else if let Some(replacement) = &self.replacement {
            let inherited = style_at(
                &paragraph.char_shape_runs,
                if self.start > 0 {
                    start_raw - 1
                } else {
                    start_raw
                },
            )?;
            let inserted: Vec<_> = replacement
                .chars()
                .map(|c| match c {
                    '\t' => HwpChar::InlineCtrl {
                        code: 9,
                        payload: vec![0; 12],
                    },
                    '\n' => HwpChar::CharCtrl(10),
                    c => HwpChar::Text(c),
                })
                .collect();
            let inserted_width: u32 = inserted.iter().map(HwpChar::wchar_width).sum();
            let delta = i64::from(inserted_width) - i64::from(end_raw - start_raw);
            let mut points = BTreeMap::new();
            for &(point, id) in &paragraph.char_shape_runs {
                if point < start_raw {
                    points.insert(point, id);
                }
            }
            if inserted_width > 0 {
                points.insert(start_raw, inherited);
            }
            points.insert(
                start_raw + inserted_width,
                style_at(&paragraph.char_shape_runs, end_raw)?,
            );
            for &(point, id) in &paragraph.char_shape_runs {
                if point >= end_raw {
                    points.insert(
                        u32::try_from(i64::from(point) + delta).map_err(|_| invalid())?,
                        id,
                    );
                }
            }
            points.entry(0).or_insert(inherited);
            paragraph.chars.splice(start_char..end_char, inserted);
            let total = paragraph.wchar_len();
            let mut runs = Vec::new();
            for (point, id) in points {
                if point < total {
                    push_run(&mut runs, point, id);
                }
            }
            if runs.is_empty() {
                runs.push((0, inherited));
            }
            paragraph.char_shape_runs = runs;
        }
        paragraph.line_segs.clear();
        Projection::new(paragraph, shapes)?;
        Ok(())
    }
}

fn push_run(runs: &mut Vec<(u32, CharShapeId)>, point: u32, id: CharShapeId) {
    if runs.last().is_none_or(|(_, previous)| *previous != id) {
        runs.push((point, id));
    }
}

pub(crate) fn style_at(runs: &[(u32, CharShapeId)], point: u32) -> Result<CharShapeId> {
    runs.iter()
        .rev()
        .find(|(start, _)| *start <= point)
        .map(|(_, id)| *id)
        .ok_or_else(unsupported)
}

struct Projection {
    text: String,
    boundaries: BTreeMap<u32, (u32, usize)>,
    runs: Vec<(u32, u32, CharShapeId)>,
}

impl Projection {
    fn new(paragraph: &Paragraph, shapes: &[CharShape]) -> Result<Self> {
        if !paragraph.extras.is_empty() || paragraph.chars.len() > MAX_TEXT ||
            !paragraph.controls.iter().all(|c| matches!(c, Control::SectionDef(_)) ||
                matches!(c, Control::Generic(g) if g.ctrl_id == *b"cold" && g.paragraph_lists.is_empty())) {
            return Err(unsupported());
        }
        let mut text = String::new();
        let mut boundaries = BTreeMap::new();
        let mut raw_boundaries = BTreeSet::from([0]);
        let mut runs: Vec<(u32, u32, CharShapeId)> = Vec::new();
        let (mut raw, mut visible) = (0u32, 0u32);
        boundaries.insert(0, (0, 0));
        for (index, c) in paragraph.chars.iter().enumerate() {
            let value = match c {
                HwpChar::Text(c) => Some(*c),
                HwpChar::CharCtrl(10) => Some('\n'),
                HwpChar::InlineCtrl { code: 9, payload } if payload.len() == 12 => Some('\t'),
                HwpChar::ExtCtrl { code: 2, .. } if visible == 0 => None,
                HwpChar::CharCtrl(13) if index + 1 == paragraph.chars.len() => None,
                _ => return Err(unsupported()),
            };
            if let Some(value) = value {
                let id = style_at(&paragraph.char_shape_runs, raw)?;
                if id.0 as usize >= shapes.len() {
                    return Err(unsupported());
                }
                let end = visible + value.len_utf16() as u32;
                if let Some(last) = runs.last_mut().filter(|last| last.2 == id) {
                    last.1 = end;
                } else {
                    runs.push((visible, end, id));
                }
                text.push(value);
                visible = end;
                raw += c.wchar_width();
                boundaries.insert(visible, (raw, index + 1));
            } else {
                raw += c.wchar_width();
                if matches!(c, HwpChar::ExtCtrl { code: 2, .. }) {
                    boundaries.insert(0, (raw, index + 1));
                }
            }
            raw_boundaries.insert(raw);
        }
        if text.len() > MAX_TEXT
            || paragraph.char_shape_runs.first().map(|v| v.0) != Some(0)
            || paragraph
                .char_shape_runs
                .windows(2)
                .any(|pair| pair[0].0 >= pair[1].0)
            || paragraph.char_shape_runs.iter().any(|(p, id)| {
                (*p >= raw && !(raw == 0 && *p == 0))
                    || !raw_boundaries.contains(p)
                    || id.0 as usize >= shapes.len()
            })
        {
            return Err(unsupported());
        }
        Ok(Self {
            text,
            boundaries,
            runs,
        })
    }
}

pub(crate) fn details(paragraph: &Paragraph, document: &Document) -> Option<Value> {
    let projection = Projection::new(paragraph, &document.header.char_shapes).ok()?;
    let mut runs = Vec::new();
    let mut projected_runs = projection.runs;
    if projected_runs.is_empty() {
        let id = style_at(&paragraph.char_shape_runs, projection.boundaries.get(&0)?.0).ok()?;
        projected_runs.push((0, 0, id));
    }
    for (start, end, id) in projected_runs {
        let shape = document.header.char_shapes.get(id.0 as usize)?;
        if shape.base_size <= 0 || shape.text_color > 0xffffff {
            return None;
        }
        runs.push(json!({"startUtf16":start,"endUtf16":end,"fontSize":f64::from(shape.base_size)/100.0,
            "bold":shape.is_bold(),"italic":shape.is_italic(),"underline":shape.has_underline(),"color":rgb(shape.text_color)}));
    }
    Some(
        json!({"utf16Length":projection.text.encode_utf16().count(),"textSha256":digest(&projection.text),
        "canReplace":true,"canStyle":true,"truncated":false,"runs":runs,"protectedRanges":[]}),
    )
}

pub(crate) fn readonly_details(paragraph: &Paragraph) -> Value {
    let value: String = paragraph
        .chars
        .iter()
        .filter_map(|c| match c {
            HwpChar::Text(c) => Some(*c),
            HwpChar::CharCtrl(10) => Some('\n'),
            HwpChar::InlineCtrl { code: 9, .. } => Some('\t'),
            _ => None,
        })
        .collect();
    json!({"utf16Length":value.encode_utf16().count(),"textSha256":digest(&value),
        "canReplace":false,"canStyle":false,"truncated":false,"runs":[],"protectedRanges":[]})
}

pub(crate) fn legacy_supported(paragraph: &Paragraph, document: &Document) -> bool {
    if !paragraph.extras.is_empty() || !paragraph.controls.iter().all(|c|
        matches!(c, Control::SectionDef(_)) ||
        matches!(c, Control::Generic(g) if g.ctrl_id == *b"cold" && g.paragraph_lists.is_empty())) {
        return false;
    }
    let mut boundaries = BTreeSet::from([0]);
    let mut raw = 0u32;
    for c in &paragraph.chars {
        if !matches!(
            c,
            HwpChar::Text(_)
                | HwpChar::CharCtrl(10 | 13)
                | HwpChar::InlineCtrl { code: 9, .. }
                | HwpChar::ExtCtrl { code: 2, .. }
        ) {
            return false;
        }
        raw += c.wchar_width();
        boundaries.insert(raw);
    }
    paragraph
        .char_shape_runs
        .first()
        .is_some_and(|run| run.0 == 0)
        && !paragraph
            .char_shape_runs
            .windows(2)
            .any(|pair| pair[0].0 >= pair[1].0)
        && paragraph.char_shape_runs.iter().all(|(point, id)| {
            boundaries.contains(point)
                && (*point < raw || (raw == 0 && *point == 0))
                && (id.0 as usize) < document.header.char_shapes.len()
        })
}

pub(crate) struct HwpCharacters {
    source_nodes: Vec<hwp5::record::RecordNode>,
    shapes: Vec<hwp5::record::RecordNode>,
    original_count: usize,
    compressed: bool,
    by_data: BTreeMap<Vec<u8>, u16>,
}

fn mapping_mut(nodes: &mut [hwp5::record::RecordNode]) -> Option<&mut hwp5::record::RecordNode> {
    for node in nodes {
        if node.tag == hwp5::record::tag::ID_MAPPINGS {
            return Some(node);
        }
        if let Some(found) = mapping_mut(&mut node.children) {
            return Some(found);
        }
    }
    None
}

impl HwpCharacters {
    pub(crate) fn new(source: &Path, doc: &Document) -> Result<Self> {
        let mut input = hwp5::Hwp5Container::open(source).map_err(|_| unsupported())?;
        let compressed = input.file_header().is_compressed();
        let bytes = input
            .read_record_stream_bounded("/DocInfo", 16 * 1024 * 1024)
            .map_err(|_| unsupported())?;
        let mut nodes = hwp5::record::scan_stream(&bytes, hwp5::record::ScanMode::Strict)
            .map_err(|_| unsupported())?
            .roots;
        let mapping = mapping_mut(&mut nodes).ok_or_else(unsupported)?;
        let shapes: Vec<_> = mapping
            .children
            .iter()
            .filter(|node| node.tag == hwp5::record::tag::CHAR_SHAPE)
            .cloned()
            .collect();
        if mapping.data.len() < 40
            || shapes.len() != doc.header.char_shapes.len()
            || shapes.len() > u16::MAX as usize
            || u32::from_le_bytes(mapping.data[36..40].try_into().expect("checked count")) as usize
                != shapes.len()
        {
            return Err(unsupported());
        }
        let mut by_data = BTreeMap::new();
        for (index, node) in shapes.iter().enumerate() {
            let shape = &doc.header.char_shapes[index];
            if node.data.len() < 56
                || !node.children.is_empty()
                || i32::from_le_bytes(node.data[42..46].try_into().expect("checked shape"))
                    != shape.base_size
                || u32::from_le_bytes(node.data[46..50].try_into().expect("checked shape"))
                    != shape.attr
                || u32::from_le_bytes(node.data[52..56].try_into().expect("checked shape"))
                    != shape.text_color
            {
                return Err(unsupported());
            }
            by_data.entry(node.data.clone()).or_insert(index as u16);
        }
        validate_raw_runs(&mut input, doc)?;
        Ok(Self {
            original_count: shapes.len(),
            shapes,
            source_nodes: nodes,
            compressed,
            by_data,
        })
    }

    fn allocate(&mut self, source: u16, changed: &CharShape) -> Result<u16> {
        let mut node = self
            .shapes
            .get(source as usize)
            .cloned()
            .ok_or_else(unsupported)?;
        node.data[42..46].copy_from_slice(&changed.base_size.to_le_bytes());
        node.data[46..50].copy_from_slice(&changed.attr.to_le_bytes());
        node.data[52..56].copy_from_slice(&changed.text_color.to_le_bytes());
        if let Some(id) = self.by_data.get(&node.data) {
            return Ok(*id);
        }
        let id = u16::try_from(self.shapes.len())
            .map_err(|_| err("resource_limit", "글자 서식 수가 지원 범위를 넘습니다."))?;
        self.by_data.insert(node.data.clone(), id);
        self.shapes.push(node);
        Ok(id)
    }

    pub(crate) fn write_docinfo(
        &self,
        output: &Path,
        paragraph_styles_changed: bool,
    ) -> Result<()> {
        let mut input = hwp5::Hwp5Container::open(output).map_err(|_| unsupported())?;
        if input.file_header().is_compressed() != self.compressed {
            return Err(unsupported());
        }
        let bytes = input
            .read_record_stream_bounded("/DocInfo", 16 * 1024 * 1024)
            .map_err(|_| unsupported())?;
        drop(input);
        let mut nodes = if paragraph_styles_changed {
            hwp5::record::scan_stream(&bytes, hwp5::record::ScanMode::Strict)
                .map_err(|_| unsupported())?
                .roots
        } else {
            self.source_nodes.clone()
        };
        let mapping = mapping_mut(&mut nodes).ok_or_else(unsupported)?;
        let indices: Vec<_> = mapping
            .children
            .iter()
            .enumerate()
            .filter(|(_, node)| node.tag == hwp5::record::tag::CHAR_SHAPE)
            .map(|(i, _)| i)
            .collect();
        if indices.len() != self.original_count || mapping.data.len() < 40 {
            return Err(unsupported());
        }
        for (index, position) in indices.iter().enumerate() {
            mapping.children[*position] = self.shapes[index].clone();
        }
        let insertion = indices.last().ok_or_else(unsupported)? + 1;
        mapping.children.splice(
            insertion..insertion,
            self.shapes[self.original_count..].iter().cloned(),
        );
        mapping.data[36..40].copy_from_slice(
            &u32::try_from(self.shapes.len())
                .map_err(|_| unsupported())?
                .to_le_bytes(),
        );
        let raw = hwp5::record::RecordNode::serialize_forest(&nodes);
        let encoded = if self.compressed {
            hwp5::codec::compress(&raw)
        } else {
            raw
        };
        let mut output = cfb::open_rw(output).map_err(io_error)?;
        output
            .create_stream("/DocInfo")
            .map_err(io_error)?
            .write_all(&encoded)
            .map_err(io_error)?;
        output.flush().map_err(io_error)?;
        Ok(())
    }

    pub(crate) fn verify(&self, output: &Path, document: &Document) -> Result<()> {
        let actual = Self::new(output, document)?;
        if actual.compressed != self.compressed || actual.shapes != self.shapes {
            return Err(unsupported());
        }
        Ok(())
    }
}

fn validate_raw_runs(input: &mut hwp5::Hwp5Container, document: &Document) -> Result<()> {
    fn raw<'a>(nodes: &'a [hwp5::record::RecordNode], out: &mut Vec<&'a hwp5::record::RecordNode>) {
        for node in nodes {
            if node.tag == hwp5::record::tag::PARA_HEADER {
                out.push(node);
            }
            raw(&node.children, out);
        }
    }
    fn model<'a>(paragraphs: &'a [Paragraph], out: &mut Vec<&'a Paragraph>) {
        for paragraph in paragraphs {
            out.push(paragraph);
            for control in &paragraph.controls {
                match control {
                    Control::Table(table) => {
                        for cell in &table.cells {
                            model(&cell.paragraphs, out);
                        }
                    }
                    Control::Generic(generic) => {
                        for list in &generic.paragraph_lists {
                            model(&list.paragraphs, out);
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    for (section, content) in document.sections.iter().enumerate() {
        let bytes = input
            .read_record_stream_bounded(&format!("/BodyText/Section{section}"), 32 * 1024 * 1024)
            .map_err(|_| unsupported())?;
        let nodes = hwp5::record::scan_stream(&bytes, hwp5::record::ScanMode::Strict)
            .map_err(|_| unsupported())?
            .roots;
        let mut records = Vec::new();
        raw(&nodes, &mut records);
        let mut paragraphs = Vec::new();
        model(&content.paragraphs, &mut paragraphs);
        if records.len() != paragraphs.len() {
            return Err(unsupported());
        }
        for (record, paragraph) in records.into_iter().zip(paragraphs) {
            let runs: Vec<_> = record
                .children
                .iter()
                .filter(|node| node.tag == hwp5::record::tag::PARA_CHAR_SHAPE)
                .collect();
            if runs.len() != 1 || !runs[0].children.is_empty() || runs[0].data.len() % 8 != 0 {
                return Err(unsupported());
            }
            let mut values = Vec::new();
            for bytes in runs[0].data.as_chunks::<8>().0 {
                let start = u32::from_le_bytes(bytes[..4].try_into().expect("checked run"));
                let id = u32::from_le_bytes(bytes[4..].try_into().expect("checked run"));
                if id > u16::MAX as u32 || id as usize >= document.header.char_shapes.len() {
                    return Err(unsupported());
                }
                values.push((start, CharShapeId(id as u16)));
            }
            if values != paragraph.char_shape_runs
                || values.first().map(|v| v.0) != Some(0)
                || values.windows(2).any(|pair| pair[0].0 >= pair[1].0)
                || values.iter().any(|(p, _)| {
                    *p >= paragraph.wchar_len()
                        && !(paragraph.wchar_len() == 0 && values.len() == 1 && *p == 0)
                })
            {
                return Err(unsupported());
            }
        }
    }
    Ok(())
}
