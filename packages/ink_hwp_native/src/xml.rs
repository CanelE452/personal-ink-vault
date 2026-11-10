use crate::engine::{
    Change, InsertionStyles, ParagraphInsertion, ParagraphStructure, TableAnchor, TableAnchors,
    TableInsertion, paragraph_text,
};
use crate::text_ranges::{BOLD_FLAG, BOTTOM_UNDERLINE_FLAG, ITALIC_FLAG, UNDERLINE_KIND_MASK};
use crate::{Result, err, io_error, unsupported};
use hwp_model::{Control, Document, HwpChar, Paragraph};
use quick_xml::{Reader, events::Event};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt::Write as _,
    fs,
    io::{Read, Write},
    path::Path,
};

#[path = "table_structure.rs"]
pub(crate) mod table_structure;

struct Node {
    name: String,
    namespace: Option<String>,
    attrs: BTreeMap<String, String>,
    start: usize,
    body: usize,
    close: usize,
    end: usize,
    empty: bool,
    opaque_body: bool,
    children: Vec<Node>,
}
impl Node {
    fn local(&self) -> &str {
        self.name.rsplit(':').next().unwrap_or(&self.name)
    }
    fn find<'a>(&'a self, name: &str, out: &mut Vec<&'a Node>) {
        for c in &self.children {
            if c.local() == name {
                out.push(c);
            }
            if c.local() != "p" {
                c.find(name, out);
            }
        }
    }
}
fn xml_error() -> crate::ApiError {
    err(
        "unsafe_xml",
        "문서 XML에 허용하지 않는 선언·참조 또는 잘못된 구조가 있습니다.",
    )
}
fn parse(bytes: &[u8], foreign: bool) -> Result<Node> {
    let input = std::str::from_utf8(bytes).map_err(|_| xml_error())?;
    let mut reader = Reader::from_str(input);
    let mut stack: Vec<Node> = Vec::new();
    let mut maps: Vec<BTreeMap<String, String>> = Vec::new();
    let mut root = None;
    let mut events = 0usize;
    loop {
        let start = reader.buffer_position() as usize;
        let event = reader.read_event().map_err(|_| xml_error())?;
        let end = reader.buffer_position() as usize;
        events += 1;
        if events > 100_000 {
            return Err(xml_error());
        }
        match event {
            Event::DocType(_) => return Err(xml_error()),
            Event::GeneralRef(r) => {
                if r.resolve_char_ref().ok().flatten().is_none()
                    && !matches!(&r[..], b"amp" | b"lt" | b"gt" | b"quot" | b"apos")
                {
                    return Err(xml_error());
                }
            }
            Event::Start(ref e) | Event::Empty(ref e) => {
                if stack.len() >= 128 {
                    return Err(xml_error());
                }
                let empty = matches!(event, Event::Empty(_));
                let name = std::str::from_utf8(e.name().as_ref())
                    .map_err(|_| xml_error())?
                    .to_owned();
                let mut attrs = BTreeMap::new();
                let mut namespaces = maps.last().cloned().unwrap_or_default();
                for (attr_index, a) in e.attributes().enumerate() {
                    if attr_index >= 128 {
                        return Err(xml_error());
                    }
                    let a = a.map_err(|_| xml_error())?;
                    let key = std::str::from_utf8(a.key.as_ref())
                        .map_err(|_| xml_error())?
                        .to_owned();
                    let value = a
                        .decoded_and_normalized_value(
                            quick_xml::XmlVersion::Implicit1_0,
                            reader.decoder(),
                        )
                        .map_err(|_| xml_error())?
                        .into_owned();
                    if key == "xmlns" {
                        namespaces.insert(String::new(), value.clone());
                    } else if let Some(p) = key.strip_prefix("xmlns:") {
                        namespaces.insert(p.to_owned(), value.clone());
                    }
                    attrs.insert(key, value);
                }
                if foreign {
                    if !name.contains(':')
                        && namespaces.get("").is_some_and(|uri| {
                            ![
                                "http://www.hancom.co.kr/hwpml/2011/paragraph",
                                "http://www.hancom.co.kr/hwpml/2011/section",
                                "http://www.hancom.co.kr/hwpml/2011/core",
                            ]
                            .contains(&uri.as_str())
                        })
                    {
                        return Err(err(
                            "unsupported_loss",
                            "수정 구역에 지원하지 않는 확장 정보가 있어 원본을 보존했습니다.",
                        ));
                    }
                    for key in std::iter::once(&name)
                        .chain(attrs.keys().filter(|k| !k.starts_with("xmlns")))
                    {
                        if let Some((prefix, _)) = key.split_once(':') {
                            if prefix == "xml" {
                                continue;
                            }
                            let uri = namespaces.get(prefix).ok_or_else(xml_error)?;
                            if ![
                                "http://www.hancom.co.kr/hwpml/2011/paragraph",
                                "http://www.hancom.co.kr/hwpml/2011/section",
                                "http://www.hancom.co.kr/hwpml/2011/core",
                            ]
                            .contains(&uri.as_str())
                            {
                                return Err(err(
                                    "unsupported_loss",
                                    "수정 구역에 지원하지 않는 확장 정보가 있어 원본을 보존했습니다.",
                                ));
                            }
                        }
                    }
                }
                let prefix = name.split_once(':').map_or("", |(prefix, _)| prefix);
                let namespace = namespaces.get(prefix).cloned();
                let node = Node {
                    name,
                    namespace,
                    attrs,
                    start,
                    body: end,
                    close: end,
                    end,
                    empty,
                    opaque_body: false,
                    children: Vec::new(),
                };
                if empty {
                    if let Some(parent) = stack.last_mut() {
                        parent.children.push(node);
                    } else if root.replace(node).is_some() {
                        return Err(xml_error());
                    }
                } else {
                    stack.push(node);
                    maps.push(namespaces);
                }
            }
            Event::End(_) => {
                let mut node = stack.pop().ok_or_else(xml_error)?;
                maps.pop();
                node.close = start;
                node.end = end;
                if let Some(parent) = stack.last_mut() {
                    parent.children.push(node);
                } else if root.replace(node).is_some() {
                    return Err(xml_error());
                }
            }
            Event::Comment(_) | Event::PI(_) => {
                if let Some(node) = stack.last_mut() {
                    node.opaque_body = true;
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if !stack.is_empty() {
        return Err(xml_error());
    }
    root.ok_or_else(xml_error)
}
pub(crate) fn validate(bytes: &[u8], foreign: bool) -> Result<()> {
    parse(bytes, foreign).map(|_| ())
}
fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}
const PARAGRAPH_NS: &str = "http://www.hancom.co.kr/hwpml/2011/paragraph";
const HEADER_NS: &str = "http://www.hancom.co.kr/hwpml/2011/head";
const SECTION_NS: &str = "http://www.hancom.co.kr/hwpml/2011/section";
const EDITABLE_CHARACTER_FLAGS: u32 = BOLD_FLAG | ITALIC_FLAG | UNDERLINE_KIND_MASK;
fn named_nodes<'a>(node: &'a Node, name: &str, out: &mut Vec<&'a Node>) {
    if node.local() == name {
        out.push(node);
    }
    for child in &node.children {
        named_nodes(child, name, out);
    }
}
fn unique_header_child<'a>(node: &'a Node, name: &str) -> Result<&'a Node> {
    let mut values = node.children.iter().filter(|child| child.local() == name);
    let value = values.next().ok_or_else(unsupported)?;
    if values.next().is_some() || value.namespace.as_deref() != Some(HEADER_NS) {
        return Err(unsupported());
    }
    Ok(value)
}
fn style_alignment(style: &Node) -> Result<u8> {
    let mut alignments = Vec::new();
    named_nodes(style, "align", &mut alignments);
    if alignments.len() != 1
        || alignments[0].namespace.as_deref() != Some(HEADER_NS)
        || !style
            .children
            .iter()
            .any(|child| std::ptr::eq(child, alignments[0]))
    {
        return Err(unsupported());
    }
    match alignments[0].attrs.get("horizontal").map(String::as_str) {
        Some("JUSTIFY") => Ok(0),
        Some("LEFT") => Ok(1),
        Some("RIGHT") => Ok(2),
        Some("CENTER") => Ok(3),
        Some("DISTRIBUTE") => Ok(4),
        Some("DISTRIBUTE_SPACE") => Ok(5),
        _ => Err(unsupported()),
    }
}
fn raw_header_parts<'a>(root: &'a Node, document: &Document) -> Result<(&'a Node, Vec<&'a Node>)> {
    if root.local() != "head" || root.namespace.as_deref() != Some(HEADER_NS) {
        return Err(unsupported());
    }
    let references = unique_header_child(root, "refList")?;
    let properties = unique_header_child(references, "paraProperties")?;
    let styles: Vec<_> = properties
        .children
        .iter()
        .filter(|node| node.local() == "paraPr")
        .collect();
    let mut all_styles = Vec::new();
    named_nodes(root, "paraPr", &mut all_styles);
    if styles.is_empty()
        || styles.len() != all_styles.len()
        || styles.len() != document.header.para_shapes.len()
        || properties
            .attrs
            .get("itemCnt")
            .and_then(|value| value.parse::<usize>().ok())
            != Some(styles.len())
    {
        return Err(unsupported());
    }
    for (index, style) in styles.iter().enumerate() {
        if style.namespace.as_deref() != Some(HEADER_NS)
            || style.attrs.get("id") != Some(&index.to_string())
        {
            return Err(unsupported());
        }
        style_alignment(style)?;
    }
    Ok((properties, styles))
}
fn header_parts<'a>(root: &'a Node, document: &Document) -> Result<(&'a Node, Vec<&'a Node>)> {
    let (properties, styles) = raw_header_parts(root, document)?;
    for (style, shape) in styles.iter().zip(&document.header.para_shapes) {
        if style_alignment(style)? != shape.alignment() {
            return Err(unsupported());
        }
    }
    Ok((properties, styles))
}
fn raw_character_parts<'a>(
    root: &'a Node,
    document: &Document,
) -> Result<(&'a Node, Vec<&'a Node>)> {
    if root.local() != "head" || root.namespace.as_deref() != Some(HEADER_NS) {
        return Err(unsupported());
    }
    let references = unique_header_child(root, "refList")?;
    let properties = unique_header_child(references, "charProperties")?;
    let styles: Vec<_> = properties
        .children
        .iter()
        .filter(|node| node.local() == "charPr")
        .collect();
    let mut all_styles = Vec::new();
    named_nodes(root, "charPr", &mut all_styles);
    if properties.empty
        || styles.is_empty()
        || styles.len() != all_styles.len()
        || styles.len() != document.header.char_shapes.len()
        || styles.len() > 65536
        || properties
            .attrs
            .get("itemCnt")
            .and_then(|value| value.parse::<usize>().ok())
            != Some(styles.len())
    {
        return Err(unsupported());
    }
    for (index, style) in styles.iter().enumerate() {
        if style.namespace.as_deref() != Some(HEADER_NS)
            || style.attrs.get("id") != Some(&index.to_string())
        {
            return Err(unsupported());
        }
        character_values(style)?;
    }
    Ok((properties, styles))
}
fn character_switch<'a>(style: &'a Node, name: &str) -> Result<Option<&'a Node>> {
    let mut markers = Vec::new();
    named_nodes(style, name, &mut markers);
    match markers.as_slice() {
        [] => Ok(None),
        [node]
            if node.namespace.as_deref() == Some(HEADER_NS)
                && node.empty
                && node.attrs.is_empty()
                && style
                    .children
                    .iter()
                    .any(|child| std::ptr::eq(child, *node)) =>
        {
            Ok(Some(*node))
        }
        _ => Err(unsupported()),
    }
}
fn character_underline(style: &Node) -> Result<(Option<&Node>, u32)> {
    let mut markers = Vec::new();
    named_nodes(style, "underline", &mut markers);
    let marker = match markers.as_slice() {
        [] => return Ok((None, 0)),
        [node]
            if node.namespace.as_deref() == Some(HEADER_NS)
                && node.children.is_empty()
                && style
                    .children
                    .iter()
                    .any(|child| std::ptr::eq(child, *node)) =>
        {
            *node
        }
        _ => return Err(unsupported()),
    };
    let kind = match marker.attrs.get("type").map(String::as_str) {
        None | Some("NONE") => 0,
        Some("BOTTOM") => BOTTOM_UNDERLINE_FLAG,
        Some("TOP") => UNDERLINE_KIND_MASK,
        _ => return Err(unsupported()),
    };
    Ok((Some(marker), kind))
}
fn character_values(style: &Node) -> Result<(i32, u32, u32)> {
    let height = style
        .attrs
        .get("height")
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|height| *height > 0)
        .ok_or_else(unsupported)?;
    let color = style
        .attrs
        .get("textColor")
        .and_then(|value| value.strip_prefix('#'))
        .filter(|value| value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .and_then(|value| u32::from_str_radix(value, 16).ok())
        .ok_or_else(unsupported)?;
    let color = ((color & 255) << 16) | (color & 0xff00) | ((color >> 16) & 255);
    let bold = u32::from(character_switch(style, "bold")?.is_some()) * BOLD_FLAG;
    let italic = u32::from(character_switch(style, "italic")?.is_some()) * ITALIC_FLAG;
    let (_, underline) = character_underline(style)?;
    Ok((height, bold | italic | underline, color))
}
pub(crate) fn normalize_character_model(source: &Path, document: &mut Document) {
    let Ok(bytes) = zip_xml(source, "Contents/header.xml") else {
        return;
    };
    let Ok(root) = parse(&bytes, false) else {
        return;
    };
    let Ok((_, styles)) = raw_character_parts(&root, document) else {
        return;
    };
    let Ok(values) = styles
        .iter()
        .map(|style| character_values(style))
        .collect::<Result<Vec<_>>>()
    else {
        return;
    };
    for (shape, (height, flags, color)) in document.header.char_shapes.iter_mut().zip(values) {
        shape.base_size = height;
        shape.attr = (shape.attr & !EDITABLE_CHARACTER_FLAGS) | flags;
        shape.text_color = color;
    }
}
pub(crate) fn character_styles_supported(source: &Path, document: &Document) -> bool {
    let check = || -> Result<()> {
        let bytes = zip_xml(source, "Contents/header.xml")?;
        let root = parse(&bytes, false)?;
        let (_, styles) = raw_character_parts(&root, document)?;
        for (style, shape) in styles.into_iter().zip(&document.header.char_shapes) {
            if character_values(style)?
                != (
                    shape.base_size,
                    shape.attr & EDITABLE_CHARACTER_FLAGS,
                    shape.text_color,
                )
            {
                return Err(unsupported());
            }
        }
        Ok(())
    };
    check().is_ok()
}
fn zip_xml(source: &Path, name: &str) -> Result<Vec<u8>> {
    let mut archive = zip::ZipArchive::new(fs::File::open(source).map_err(io_error)?)
        .map_err(|_| unsupported())?;
    let mut entry = archive.by_name(name).map_err(|_| unsupported())?;
    if entry.size() > 2 * 1024 * 1024 {
        return Err(unsupported());
    }
    let mut bytes = Vec::new();
    entry.read_to_end(&mut bytes).map_err(io_error)?;
    Ok(bytes)
}
pub(crate) fn normalize_alignment_model(source: &Path, document: &mut Document) {
    let Ok(bytes) = zip_xml(source, "Contents/header.xml") else {
        return;
    };
    let Ok(root) = parse(&bytes, false) else {
        return;
    };
    let Ok((_, styles)) = raw_header_parts(&root, document) else {
        return;
    };
    let Ok(alignments) = styles
        .iter()
        .map(|style| style_alignment(style))
        .collect::<Result<Vec<_>>>()
    else {
        return;
    };
    // The pinned reader matches attributes by local name. A validated original
    // unqualified alignment takes precedence over foreign shadow attributes.
    for (shape, alignment) in document.header.para_shapes.iter_mut().zip(alignments) {
        shape.attr1 = (shape.attr1 & !(7 << 2)) | (u32::from(alignment) << 2);
    }
}
pub(crate) fn alignment_metadata(
    source: &Path,
    document: &Document,
) -> Result<crate::engine::Alignments> {
    let header = zip_xml(source, "Contents/header.xml")?;
    let root = parse(&header, false)?;
    let (_, styles) = header_parts(&root, document)?;
    let mut result = BTreeMap::new();
    for (si, section) in document.sections.iter().enumerate() {
        let bytes = zip_xml(source, &format!("Contents/section{si}.xml"))?;
        let root = parse(&bytes, false)?;
        if root.local() != "sec" || root.namespace.as_deref() != Some(SECTION_NS) {
            continue;
        }
        let paragraphs: Vec<_> = root
            .children
            .iter()
            .filter(|node| node.local() == "p")
            .collect();
        if paragraphs.len() != section.paragraphs.len() {
            continue;
        }
        for (pi, node) in paragraphs.iter().enumerate() {
            if node.namespace.as_deref() != Some(PARAGRAPH_NS) {
                continue;
            }
            let Some(reference) = node.attrs.get("paraPrIDRef") else {
                continue;
            };
            let index = section.paragraphs[pi].para_shape.0 as usize;
            if reference != &index.to_string() {
                continue;
            }
            if let Some(style) = styles.get(index) {
                result.insert((si, pi), style_alignment(style)?);
            }
        }
    }
    Ok(result)
}

fn section_paragraphs(root: &Node, expected: usize) -> Option<Vec<&Node>> {
    let paragraphs: Vec<_> = root
        .children
        .iter()
        .filter(|node| node.local() == "p")
        .collect();
    if root.local() != "sec"
        || root.namespace.as_deref() != Some(SECTION_NS)
        || paragraphs.len() != expected
        || paragraphs
            .iter()
            .any(|node| node.empty || node.namespace.as_deref() != Some(PARAGRAPH_NS))
        || root
            .children
            .iter()
            .any(|node| node.local() != "p" && contains_paragraph(node))
    {
        return None;
    }
    Some(paragraphs)
}

pub(crate) fn paragraph_structure(source: &Path, doc: &Document) -> Result<ParagraphStructure> {
    let mut result = ParagraphStructure::default();
    for (si, section) in doc.sections.iter().enumerate() {
        let bytes = zip_xml(source, &format!("Contents/section{si}.xml"))?;
        let root = parse(&bytes, false)?;
        let Some(paragraphs) = section_paragraphs(&root, section.paragraphs.len()) else {
            continue;
        };
        for (pi, (node, paragraph)) in paragraphs.iter().zip(&section.paragraphs).enumerate() {
            if pi > 0 && validate_paragraph_deletion(&bytes, node, paragraph, doc).is_ok() {
                result.deletions.insert((si, pi));
            }
            let Some(first_text) = paragraph
                .chars
                .iter()
                .position(|character| matches!(character, HwpChar::Text(_)))
            else {
                continue;
            };
            let point = paragraph.chars[..first_text]
                .iter()
                .map(HwpChar::wchar_width)
                .sum();
            let Ok(character) = crate::text_ranges::style_at(&paragraph.char_shape_runs, point)
            else {
                continue;
            };
            let has_ref = |node: &Node, attr: &str, id: u16| {
                node.attrs.get(attr).and_then(|v| v.parse::<u16>().ok()) == Some(id)
            };
            if (paragraph.para_shape.0 as usize) < doc.header.para_shapes.len()
                && (paragraph.style.0 as usize) < doc.header.styles.len()
                && (character.0 as usize) < doc.header.char_shapes.len()
                && has_ref(node, "paraPrIDRef", paragraph.para_shape.0)
                && has_ref(node, "styleIDRef", paragraph.style.0)
                && node.children.iter().any(|run| {
                    run.local() == "run"
                        && run.namespace.as_deref() == Some(PARAGRAPH_NS)
                        && has_ref(run, "charPrIDRef", character.0)
                })
            {
                result
                    .insertions
                    .insert((si, pi), (paragraph.para_shape, paragraph.style, character));
            }
        }
    }
    Ok(result)
}

fn whitespace_between_elements(bytes: &[u8], node: &Node) -> bool {
    let mut cursor = node.body;
    for child in &node.children {
        if !bytes[cursor..child.start]
            .iter()
            .all(|b| matches!(*b, b' ' | b'\t' | b'\r' | b'\n'))
        {
            return false;
        }
        cursor = child.end;
    }
    bytes[cursor..node.close]
        .iter()
        .all(|b| matches!(*b, b' ' | b'\t' | b'\r' | b'\n'))
}

fn validate_paragraph_deletion(
    bytes: &[u8],
    node: &Node,
    paragraph: &Paragraph,
    doc: &Document,
) -> Result<()> {
    if !paragraph.controls.is_empty()
        || !paragraph.extras.is_empty()
        || paragraph.chars.iter().any(|character| {
            !matches!(
                character,
                HwpChar::Text(_) | HwpChar::CharCtrl(10 | 13) | HwpChar::InlineCtrl { code: 9, .. }
            )
        })
        || node.opaque_body
        || !whitespace_between_elements(bytes, node)
        || node
            .attrs
            .get("id")
            .and_then(|v| v.parse::<u32>().ok())
            .is_none()
        || node.attrs.get("paraPrIDRef") != Some(&paragraph.para_shape.0.to_string())
        || node.attrs.get("styleIDRef") != Some(&paragraph.style.0.to_string())
        || usize::from(paragraph.para_shape.0) >= doc.header.para_shapes.len()
        || usize::from(paragraph.style.0) >= doc.header.styles.len()
        || node.attrs.iter().any(|(key, value)| match key.as_str() {
            "id" | "paraPrIDRef" | "styleIDRef" | "xmlns" => false,
            "pageBreak" | "columnBreak" | "merged" => !matches!(value.as_str(), "0" | "false"),
            _ => !key.starts_with("xmlns:"),
        })
    {
        return Err(unsupported());
    }
    let mut observed = String::new();
    let mut has_run = false;
    for child in &node.children {
        if child.namespace.as_deref() != Some(PARAGRAPH_NS)
            || child.opaque_body
            || !whitespace_between_elements(bytes, child)
        {
            return Err(unsupported());
        }
        match child.local() {
            "linesegarray"
                if ordinary_line_cache(child)
                    && child
                        .children
                        .iter()
                        .all(|line| whitespace_between_elements(bytes, line)) => {}
            "run"
                if child.attrs.keys().all(|key| {
                    key == "charPrIDRef" || key == "xmlns" || key.starts_with("xmlns:")
                }) =>
            {
                has_run = true;
                child
                    .attrs
                    .get("charPrIDRef")
                    .and_then(|value| value.parse::<u16>().ok())
                    .filter(|id| usize::from(*id) < doc.header.char_shapes.len())
                    .ok_or_else(unsupported)?;
                for text in &child.children {
                    if text.local() != "t" {
                        return Err(unsupported());
                    }
                    observed.push_str(&inline_text(bytes, text)?);
                }
            }
            _ => return Err(unsupported()),
        }
    }
    if !has_run || observed != paragraph_text(paragraph) {
        return Err(unsupported());
    }
    Ok(())
}

pub(crate) fn table_insertion_anchors(
    source: &Path,
    doc: &Document,
    styles: &InsertionStyles,
) -> Result<TableAnchors> {
    if styles.is_empty() {
        return Ok(BTreeMap::new());
    }
    let header = zip_xml(source, "Contents/header.xml")?;
    let header = parse(&header, false)?;
    let references = unique_header_child(&header, "refList")?;
    let borders = unique_header_child(references, "borderFills")?;
    if borders.children.len() != doc.header.border_fills.len() {
        return Err(unsupported());
    }
    let border = borders
        .children
        .iter()
        .enumerate()
        .find_map(|(index, fill)| {
            let id = u16::try_from(index + 1).ok()?;
            (fill.local() == "borderFill"
                && fill.namespace.as_deref() == Some(HEADER_NS)
                && fill.attrs.get("id").and_then(|v| v.parse::<u16>().ok()) == Some(id)
                && ["leftBorder", "rightBorder", "topBorder", "bottomBorder"]
                    .iter()
                    .all(|edge| {
                        let mut matching =
                            fill.children.iter().filter(|child| child.local() == *edge);
                        matching.next().is_some_and(|side| {
                            side.namespace.as_deref() == Some(HEADER_NS)
                                && side.attrs.get("type").is_some_and(|kind| kind == "SOLID")
                        }) && matching.next().is_none()
                    }))
            .then_some(id)
        })
        .ok_or_else(unsupported)?;
    let mut result = BTreeMap::new();
    let mut z_order = None;
    for (section_index, section) in doc.sections.iter().enumerate() {
        let bytes = zip_xml(source, &format!("Contents/section{section_index}.xml"))?;
        let root = parse(&bytes, false)?;
        collect_z_order(&root, &mut z_order)?;
        let Some((page_width, page_height)) = single_column_area(&root, section) else {
            continue;
        };
        for (&location, &style) in styles.range((section_index, 0)..=(section_index, usize::MAX)) {
            let (para, _, character) = style;
            let shape = &doc.header.para_shapes[para.0 as usize];
            let character = &doc.header.char_shapes[character.0 as usize];
            let inset = shape
                .margin_left
                .max(0)
                .saturating_add(shape.margin_right.max(0))
                .saturating_add(shape.indent.max(0));
            if shape.head_type() != 0
                || shape.page_break_before()
                || inset > 500
                || !(600..=2400).contains(&character.base_size)
                || character.text_color > 0xffffff
            {
                continue;
            }
            let width = page_width
                .saturating_sub(inset as u32)
                .saturating_sub(566)
                .min(36_000);
            let row_height =
                (u32::try_from(character.base_size).map_err(|_| unsupported())? * 16 / 10 + 400)
                    .max(3_000);
            if width >= 18_000 && row_height * 8 + 1_000 < page_height {
                result.insert(
                    location,
                    TableAnchor {
                        style,
                        border,
                        width,
                        row_height,
                    },
                );
            }
        }
    }
    if z_order == Some(i32::MAX) {
        return Err(unsupported());
    }
    Ok(result)
}

fn single_column_area(root: &Node, section: &hwp_model::Section) -> Option<(u32, u32)> {
    let mut pages = Vec::new();
    let mut columns = Vec::new();
    named_nodes(root, "pagePr", &mut pages);
    named_nodes(root, "colPr", &mut columns);
    let [page] = pages.as_slice() else {
        return None;
    };
    let raw_number = |node: &Node, name: &str| node.attrs.get(name)?.parse::<u32>().ok();
    if page.namespace.as_deref() != Some(PARAGRAPH_NS)
        || columns.len() > 1
        || columns.iter().any(|col| {
            col.namespace.as_deref() != Some(PARAGRAPH_NS) || raw_number(col, "colCount") != Some(1)
        })
    {
        return None;
    }
    let [margin] = page.children.as_slice() else {
        return None;
    };
    if margin.local() != "margin" || margin.namespace.as_deref() != Some(PARAGRAPH_NS) {
        return None;
    }
    let model = section.section_def()?.page?;
    let width = raw_number(page, "width")?;
    let height = raw_number(page, "height")?;
    if !(10_000..=1_000_000).contains(&width)
        || !(10_000..=1_000_000).contains(&height)
        || u32::try_from(model.width.0).ok() != Some(width)
        || u32::try_from(model.height.0).ok() != Some(height)
    {
        return None;
    }
    Some((
        width
            .checked_sub(raw_number(margin, "left")?)?
            .checked_sub(raw_number(margin, "right")?)?
            .checked_sub(raw_number(margin, "gutter")?)?,
        height
            .checked_sub(raw_number(margin, "top")?)?
            .checked_sub(raw_number(margin, "bottom")?)?,
    ))
}

fn contains_paragraph(node: &Node) -> bool {
    node.local() == "p" || node.children.iter().any(contains_paragraph)
}

fn collect_section_ids(node: &Node, ids: &mut BTreeSet<u32>) {
    ids.extend(
        node.attrs
            .iter()
            .filter_map(|(key, value)| match key.rsplit(':').next() {
                Some("id" | "instid" | "instId") => value.parse::<u32>().ok(),
                _ => None,
            }),
    );
    for child in &node.children {
        collect_section_ids(child, ids);
    }
}

fn collect_z_order(node: &Node, order: &mut Option<i32>) -> Result<()> {
    if let Some(value) = node.attrs.get("zOrder") {
        let value = value
            .parse::<i32>()
            .ok()
            .filter(|number| *number >= 0)
            .ok_or_else(unsupported)?;
        *order = Some(order.map_or(value, |previous| previous.max(value)));
    }
    for child in &node.children {
        collect_z_order(child, order)?;
    }
    Ok(())
}

fn table_sibling(source: &Path, doc: &Document, insertion: &TableInsertion) -> Result<String> {
    let mut ids = BTreeSet::new();
    let mut order = None;
    for section in 0..doc.sections.len() {
        let bytes = zip_xml(source, &format!("Contents/section{section}.xml"))?;
        let root = parse(&bytes, false)?;
        collect_section_ids(&root, &mut ids);
        collect_z_order(&root, &mut order)?;
    }
    let mut next = 1u32;
    let mut allocate = || -> Result<u32> {
        while !ids.insert(next) {
            next = next.checked_add(1).ok_or_else(unsupported)?;
        }
        Ok(next)
    };
    let z_order = order.unwrap_or(-1).checked_add(1).ok_or_else(unsupported)?;
    let carrier = allocate()?;
    let table = allocate()?;
    let (para, style, character) = insertion.anchor.style;
    let (para, style, character) = (para.0, style.0, character.0);
    let (rows, columns, border) = (insertion.rows, insertion.columns, insertion.anchor.border);
    let (cell_width, row_height) = (insertion.cell_width(), insertion.anchor.row_height);
    let width = cell_width * u32::from(columns);
    let height = row_height * u32::from(rows);
    let mut xml = format!(
        concat!(
            r#"<hp:p xmlns:hp="{0}" id="{1}" paraPrIDRef="{2}" styleIDRef="{3}" pageBreak="0" columnBreak="0" merged="0"><hp:run charPrIDRef="{4}">"#,
            r#"<hp:tbl id="{5}" zOrder="{6}" numberingType="TABLE" textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0" dropcapstyle="None" pageBreak="CELL" repeatHeader="0" rowCnt="{7}" colCnt="{8}" cellSpacing="0" borderFillIDRef="{9}" noAdjust="0">"#,
            r#"<hp:sz width="{10}" widthRelTo="ABSOLUTE" height="{11}" heightRelTo="ABSOLUTE" protect="0"/>"#,
            r#"<hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA" horzRelTo="PARA" vertAlign="TOP" horzAlign="LEFT" vertOffset="0" horzOffset="0"/>"#,
            r#"<hp:outMargin left="283" right="283" top="283" bottom="283"/><hp:inMargin left="510" right="510" top="141" bottom="141"/>"#,
        ),
        PARAGRAPH_NS,
        carrier,
        para,
        style,
        character,
        table,
        z_order,
        rows,
        columns,
        border,
        width,
        height
    );
    for row in 0..rows {
        xml.push_str("<hp:tr>");
        for column in 0..columns {
            let paragraph = allocate()?;
            let text = escape(insertion.cell_text(row, column));
            write!(xml, concat!(
                r#"<hp:tc name="" header="0" hasMargin="0" protect="0" editable="0" dirty="0" borderFillIDRef="{0}"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">"#,
                r#"<hp:p id="{1}" paraPrIDRef="{2}" styleIDRef="{3}" pageBreak="0" columnBreak="0" merged="0"><hp:run charPrIDRef="{4}"><hp:t>{9}</hp:t></hp:run></hp:p></hp:subList>"#,
                r#"<hp:cellAddr colAddr="{5}" rowAddr="{6}"/><hp:cellSpan colSpan="1" rowSpan="1"/><hp:cellSz width="{7}" height="{8}"/><hp:cellMargin left="510" right="510" top="141" bottom="141"/></hp:tc>"#,
            ), border, paragraph, para, style, character, column, row, cell_width, row_height, text).expect("writing to String is infallible");
        }
        xml.push_str("</hp:tr>");
    }
    xml.push_str("</hp:tbl></hp:run></hp:p>");
    Ok(xml)
}
fn attribute_span(bytes: &[u8], node: &Node, key: &str) -> Result<(usize, usize)> {
    let mut index = node.start + 1 + node.name.len();
    while index < node.body {
        while index < node.body && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        if index >= node.body || matches!(bytes[index], b'/' | b'>') {
            break;
        }
        let name_start = index;
        while index < node.body && !bytes[index].is_ascii_whitespace() && bytes[index] != b'=' {
            index += 1;
        }
        let name_end = index;
        while index < node.body && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        if bytes.get(index) != Some(&b'=') {
            return Err(xml_error());
        }
        index += 1;
        while index < node.body && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        let quote = *bytes.get(index).ok_or_else(xml_error)?;
        if !matches!(quote, b'\'' | b'"') {
            return Err(xml_error());
        }
        index += 1;
        let start = index;
        while index < node.body && bytes[index] != quote {
            index += 1;
        }
        if index >= node.body {
            return Err(xml_error());
        }
        if &bytes[name_start..name_end] == key.as_bytes() {
            return Ok((start, index));
        }
        index += 1;
    }
    Err(unsupported())
}
fn replace_spans(bytes: &[u8], mut patches: Vec<(usize, usize, String)>) -> Result<Vec<u8>> {
    patches.sort_by_key(|patch| (patch.0, patch.1));
    patches.dedup();
    if patches.windows(2).any(|pair| pair[0].1 > pair[1].0) {
        return Err(unsupported());
    }
    let mut output = std::str::from_utf8(bytes)
        .map_err(|_| xml_error())?
        .to_owned();
    for (start, end, value) in patches.into_iter().rev() {
        if start > end
            || end > output.len()
            || !output.is_char_boundary(start)
            || !output.is_char_boundary(end)
        {
            return Err(xml_error());
        }
        output.replace_range(start..end, &value);
    }
    validate(output.as_bytes(), false)?;
    Ok(output.into_bytes())
}
fn alignment_header(
    source: &Path,
    original: &Document,
    edited: &Document,
    changes: &[Change],
) -> Result<Option<Vec<u8>>> {
    if !changes.iter().any(|change| change.alignment.is_some()) {
        return Ok(None);
    }
    let bytes = zip_xml(source, "Contents/header.xml")?;
    let root = parse(&bytes, false)?;
    let (properties, styles) = header_parts(&root, original)?;
    let mut clones = BTreeMap::new();
    for change in changes.iter().filter(|change| change.alignment.is_some()) {
        let old = &original.sections[change.section].paragraphs[change.paragraph];
        let new = &edited.sections[change.section].paragraphs[change.paragraph];
        let index = new.para_shape.0 as usize;
        if index < styles.len() {
            if index != old.para_shape.0 as usize
                || style_alignment(styles[index])? != change.alignment.expect("filtered alignment")
            {
                return Err(unsupported());
            }
            continue;
        }
        let style = *styles
            .get(old.para_shape.0 as usize)
            .ok_or_else(unsupported)?;
        let align = unique_header_child(style, "align")?;
        let id_span = attribute_span(&bytes, style, "id")?;
        let align_span = attribute_span(&bytes, align, "horizontal")?;
        let alignment = match change.alignment.expect("filtered alignment") {
            0 => "JUSTIFY",
            1 => "LEFT",
            2 => "RIGHT",
            3 => "CENTER",
            _ => return Err(unsupported()),
        };
        let raw = replace_spans(
            &bytes[style.start..style.end],
            vec![
                (
                    id_span.0 - style.start,
                    id_span.1 - style.start,
                    index.to_string(),
                ),
                (
                    align_span.0 - style.start,
                    align_span.1 - style.start,
                    alignment.to_owned(),
                ),
            ],
        )?;
        if let Some(existing) = clones.insert(index, raw.clone())
            && existing != raw
        {
            return Err(unsupported());
        }
    }
    if clones.is_empty() {
        return Ok(None);
    }
    if edited.header.para_shapes.len() != styles.len() + clones.len()
        || clones
            .keys()
            .copied()
            .ne(styles.len()..edited.header.para_shapes.len())
    {
        return Err(unsupported());
    }
    let mut additions = String::new();
    for raw in clones.into_values() {
        additions.push_str(std::str::from_utf8(&raw).map_err(|_| xml_error())?);
    }
    let count = attribute_span(&bytes, properties, "itemCnt")?;
    let result = replace_spans(
        &bytes,
        vec![
            (
                count.0,
                count.1,
                edited.header.para_shapes.len().to_string(),
            ),
            (properties.close, properties.close, additions),
        ],
    )?;
    Ok(Some(result))
}
fn character_header(
    bytes: &[u8],
    original: &Document,
    edited: &Document,
    origins: &BTreeMap<u16, u16>,
) -> Result<Vec<u8>> {
    let root = parse(bytes, false)?;
    let (properties, styles) = raw_character_parts(&root, original)?;
    if edited.header.char_shapes.len() < styles.len()
        || edited.header.char_shapes[..styles.len()] != original.header.char_shapes
        || origins.len() != edited.header.char_shapes.len() - styles.len()
        || origins
            .keys()
            .map(|id| usize::from(*id))
            .ne(styles.len()..edited.header.char_shapes.len())
    {
        return Err(unsupported());
    }
    let mut additions = String::new();
    for (id, &origin) in origins {
        let mut source = origin;
        let mut previous = *id;
        while usize::from(source) >= styles.len() {
            if source >= previous {
                return Err(unsupported());
            }
            previous = source;
            source = *origins.get(&source).ok_or_else(unsupported)?;
        }
        let source_index = usize::from(source);
        let old = original
            .header
            .char_shapes
            .get(source_index)
            .ok_or_else(unsupported)?;
        let shape = edited
            .header
            .char_shapes
            .get(usize::from(*id))
            .ok_or_else(unsupported)?;
        let mut expected = old.clone();
        expected.base_size = shape.base_size;
        expected.attr =
            (expected.attr & !EDITABLE_CHARACTER_FLAGS) | (shape.attr & EDITABLE_CHARACTER_FLAGS);
        expected.text_color = shape.text_color;
        if &expected != shape || shape.base_size <= 0 || shape.text_color > 0xffffff {
            return Err(unsupported());
        }
        let node = styles[source_index];
        let (height, old_flags, color) = character_values(node)?;
        let mut patches = Vec::new();
        let mut attribute = |key: &str, value: String| -> Result<()> {
            let span = attribute_span(bytes, node, key)?;
            patches.push((span.0 - node.start, span.1 - node.start, value));
            Ok(())
        };
        attribute("id", id.to_string())?;
        if height != shape.base_size {
            attribute("height", shape.base_size.to_string())?;
        }
        if color != shape.text_color {
            let color = shape.text_color;
            let rgb = ((color & 255) << 16) | (color & 0xff00) | ((color >> 16) & 255);
            attribute("textColor", format!("#{rgb:06X}"))?;
        }
        let mut new_markers = String::new();
        let prefix = node
            .name
            .split_once(':')
            .map(|(prefix, _)| format!("{prefix}:"))
            .unwrap_or_default();
        for (name, flag) in [("bold", BOLD_FLAG), ("italic", ITALIC_FLAG)] {
            if old_flags & flag == shape.attr & flag {
                continue;
            }
            if old_flags & flag != 0 {
                let child = character_switch(node, name)?.ok_or_else(unsupported)?;
                patches.push((
                    child.start - node.start,
                    child.end - node.start,
                    String::new(),
                ));
            } else {
                let _ = write!(new_markers, "<{prefix}{name}/>");
            }
        }
        if old_flags & UNDERLINE_KIND_MASK != shape.attr & UNDERLINE_KIND_MASK {
            let underline = shape.attr & UNDERLINE_KIND_MASK;
            let type_name = match underline {
                0 => "NONE",
                BOTTOM_UNDERLINE_FLAG => "BOTTOM",
                _ => return Err(unsupported()),
            };
            let color = format!("#{:06X}", crate::text_ranges::rgb(shape.text_color));
            if let Some(marker) = character_underline(node)?.0 {
                let mut new_attrs = String::new();
                for (key, value) in [
                    ("type", Some(type_name)),
                    (
                        "shape",
                        (underline != 0
                            && marker
                                .attrs
                                .get("shape")
                                .is_none_or(|value| value == "NONE"))
                        .then_some("SOLID"),
                    ),
                    (
                        "color",
                        (underline != 0 && !marker.attrs.contains_key("color"))
                            .then_some(color.as_str()),
                    ),
                ] {
                    let Some(value) = value else { continue };
                    if marker.attrs.contains_key(key) {
                        let (start, end) = attribute_span(bytes, marker, key)?;
                        patches.push((start - node.start, end - node.start, value.into()));
                    } else {
                        let _ = write!(new_attrs, " {key}=\"{value}\"");
                    }
                }
                if !new_attrs.is_empty() {
                    let end = marker.body - node.start - if marker.empty { 2 } else { 1 };
                    patches.push((end, end, new_attrs));
                }
            } else {
                let _ = write!(
                    new_markers,
                    r#"<{prefix}underline type="{type_name}" shape="SOLID" color="{color}"/>"#
                );
            }
        }
        if !new_markers.is_empty() {
            if node.empty {
                patches.push((
                    node.body - node.start - 2,
                    node.end - node.start,
                    format!(">{new_markers}</{}>", node.name),
                ));
            } else {
                let offset = node
                    .children
                    .iter()
                    .find(|child| {
                        child.namespace.as_deref() == Some(HEADER_NS)
                            && [
                                "underline",
                                "strikeout",
                                "outline",
                                "shadow",
                                "emboss",
                                "engrave",
                                "supscript",
                                "subscript",
                            ]
                            .contains(&child.local())
                    })
                    .map_or(node.close, |child| child.start)
                    - node.start;
                patches.push((offset, offset, new_markers));
            }
        }
        let raw = replace_spans(&bytes[node.start..node.end], patches)?;
        if additions
            .len()
            .checked_add(raw.len())
            .is_none_or(|length| length > 2 * 1024 * 1024)
        {
            return Err(unsupported());
        }
        additions.push_str(std::str::from_utf8(&raw).map_err(|_| xml_error())?);
    }
    let count = attribute_span(bytes, properties, "itemCnt")?;
    let result = replace_spans(
        bytes,
        vec![
            (
                count.0,
                count.1,
                edited.header.char_shapes.len().to_string(),
            ),
            (properties.close, properties.close, additions),
        ],
    )?;
    if result.len() > 2 * 1024 * 1024 {
        return Err(unsupported());
    }
    Ok(result)
}
fn known_inline_whitespace(node: &Node) -> bool {
    if node.namespace.as_deref() != Some(PARAGRAPH_NS)
        || !node.empty
        || node.opaque_body
        || !node.children.is_empty()
    {
        return false;
    }
    match node.local() {
        "lineBreak" => node.attrs.is_empty(),
        "tab" => {
            node.attrs.len() == 3
                && node.attrs.get("width").is_some_and(|value| {
                    value
                        .parse::<u32>()
                        .is_ok_and(|width| width <= i32::MAX as u32)
                })
                && node
                    .attrs
                    .get("leader")
                    .is_some_and(|value| value.parse::<u8>().is_ok_and(|leader| leader <= 3))
                && node.attrs.get("type").is_some_and(|value| {
                    value
                        .parse::<u8>()
                        .is_ok_and(|kind| (1..=4).contains(&kind))
                })
        }
        _ => false,
    }
}
fn authored_text(text: &str, element_name: &str) -> String {
    let prefix = element_name
        .split_once(':')
        .map(|(prefix, _)| format!("{prefix}:"))
        .unwrap_or_default();
    escape(text)
        .replace(
            '\t',
            &format!("<{prefix}tab width=\"4000\" leader=\"0\" type=\"1\"/>"),
        )
        .replace('\n', &format!("<{prefix}lineBreak/>"))
}
fn paragraph_at<'a>(document: &'a Document, change: &Change) -> Result<&'a Paragraph> {
    let paragraph = document
        .sections
        .get(change.section)
        .and_then(|section| section.paragraphs.get(change.paragraph))
        .ok_or_else(unsupported)?;
    if let Some(index) = change.table {
        let Some(Control::Table(table)) = paragraph.controls.get(index) else {
            return Err(unsupported());
        };
        let (row, column) = change.cell.ok_or_else(unsupported)?;
        let mut cells = table
            .cells
            .iter()
            .filter(|cell| cell.row == row && cell.col == column);
        let cell = cells.next().ok_or_else(unsupported)?;
        if cells.next().is_some() || cell.paragraphs.len() != 1 {
            return Err(unsupported());
        }
        Ok(&cell.paragraphs[0])
    } else {
        Ok(paragraph)
    }
}
fn character_id(paragraph: &Paragraph, position: u32) -> Result<u16> {
    paragraph
        .char_shape_runs
        .iter()
        .rev()
        .find(|(start, _)| *start <= position)
        .map(|(_, id)| id.0)
        .ok_or_else(unsupported)
}
fn visible_characters(paragraph: &Paragraph) -> Result<Vec<(char, u16)>> {
    let mut result = Vec::new();
    let mut position = 0u32;
    for value in &paragraph.chars {
        let character = match value {
            HwpChar::Text(character) => Some(*character),
            HwpChar::CharCtrl(10) => Some('\n'),
            HwpChar::InlineCtrl { code: 9, .. } => Some('\t'),
            HwpChar::CharCtrl(13) | HwpChar::ExtCtrl { code: 2, .. } => None,
            _ => return Err(unsupported()),
        };
        if let Some(character) = character {
            result.push((character, character_id(paragraph, position)?));
        }
        position = position
            .checked_add(value.wchar_width())
            .ok_or_else(unsupported)?;
    }
    Ok(result)
}
fn inline_text(bytes: &[u8], node: &Node) -> Result<String> {
    if node.namespace.as_deref() != Some(PARAGRAPH_NS)
        || node.opaque_body
        || node.attrs.iter().any(|(key, value)| {
            key != "xmlns"
                && !key.starts_with("xmlns:")
                && (key != "xml:space" || !["preserve", "default"].contains(&value.as_str()))
        })
        || node
            .children
            .iter()
            .any(|child| !known_inline_whitespace(child))
    {
        return Err(unsupported());
    }
    let input = std::str::from_utf8(&bytes[node.start..node.end]).map_err(|_| xml_error())?;
    let mut reader = Reader::from_str(input);
    let mut result = String::new();
    loop {
        match reader.read_event().map_err(|_| xml_error())? {
            Event::Text(text) => result.push_str(
                &text
                    .xml_content(quick_xml::XmlVersion::Implicit1_0)
                    .map_err(|_| xml_error())?,
            ),
            Event::CData(text) => result.push_str(&text.decode().map_err(|_| xml_error())?),
            Event::GeneralRef(reference) => {
                if let Some(character) = reference.resolve_char_ref().map_err(|_| xml_error())? {
                    result.push(character);
                } else {
                    result.push(match &reference[..] {
                        b"amp" => '&',
                        b"lt" => '<',
                        b"gt" => '>',
                        b"quot" => '"',
                        b"apos" => '\'',
                        _ => return Err(xml_error()),
                    });
                }
            }
            Event::Empty(element) => match element.local_name().as_ref() {
                b"tab" => result.push('\t'),
                b"lineBreak" => result.push('\n'),
                b"t" => {}
                _ => return Err(unsupported()),
            },
            Event::Start(element) if element.local_name().as_ref() == b"t" => {}
            Event::End(element) if element.local_name().as_ref() == b"t" => {}
            Event::Eof => break,
            _ => return Err(unsupported()),
        }
    }
    Ok(result)
}
fn rendered_run(
    bytes: &[u8],
    run: &Node,
    text_node: Option<&Node>,
    id: u16,
    text: &str,
) -> Result<String> {
    let span = attribute_span(bytes, run, "charPrIDRef")?;
    let (text_name, text_open) = if let Some(node) = text_node {
        let open = std::str::from_utf8(&bytes[node.start..node.body]).map_err(|_| xml_error())?;
        let open = if node.empty {
            format!("{}>", open.strip_suffix("/>").ok_or_else(xml_error)?)
        } else {
            open.to_owned()
        };
        (node.name.clone(), open)
    } else {
        let name = run
            .name
            .split_once(':')
            .map_or_else(|| "t".to_owned(), |(prefix, _)| format!("{prefix}:t"));
        let open = format!("<{name} xml:space=\"preserve\">");
        (name, open)
    };
    let body = format!(
        "{text_open}{}</{text_name}>",
        authored_text(text, &text_name)
    );
    let before = std::str::from_utf8(&bytes[run.start..span.0]).map_err(|_| xml_error())?;
    let after = std::str::from_utf8(&bytes[span.1..run.body]).map_err(|_| xml_error())?;
    let raw = if run.empty {
        let after = after.strip_suffix("/>").ok_or_else(xml_error)?;
        format!("{before}{id}{after}>{body}</{}>", run.name)
    } else {
        let close = std::str::from_utf8(&bytes[run.close..run.end]).map_err(|_| xml_error())?;
        format!("{before}{id}{after}{body}{close}")
    };
    if raw.len() > 2 * 1024 * 1024 {
        return Err(unsupported());
    }
    Ok(raw)
}
fn range_patches(
    bytes: &[u8],
    target: &Node,
    original: &Paragraph,
    edited: &Paragraph,
) -> Result<Vec<(usize, usize, String)>> {
    if target.namespace.as_deref() != Some(PARAGRAPH_NS) || target.empty || target.opaque_body {
        return Err(unsupported());
    }
    let mut runs = Vec::new();
    let mut observed = Vec::new();
    let mut template = None;
    let mut saw_text = false;
    for run in &target.children {
        if run.local() == "linesegarray" && run.namespace.as_deref() == Some(PARAGRAPH_NS) {
            continue;
        }
        if run.local() != "run"
            || run.namespace.as_deref() != Some(PARAGRAPH_NS)
            || run.opaque_body
            || run
                .attrs
                .keys()
                .any(|key| key != "charPrIDRef" && key != "xmlns" && !key.starts_with("xmlns:"))
        {
            return Err(unsupported());
        }
        let id = run
            .attrs
            .get("charPrIDRef")
            .and_then(|value| value.parse::<u16>().ok())
            .ok_or_else(unsupported)?;
        if run.attrs.get("charPrIDRef") != Some(&id.to_string()) {
            return Err(unsupported());
        }
        let mut texts = Vec::new();
        let mut controls = false;
        let mut cursor = run.body;
        for child in &run.children {
            if !std::str::from_utf8(&bytes[cursor..child.start])
                .map_err(|_| xml_error())?
                .trim()
                .is_empty()
            {
                return Err(unsupported());
            }
            cursor = child.end;
            if child.namespace.as_deref() != Some(PARAGRAPH_NS) {
                return Err(unsupported());
            }
            match child.local() {
                "t" => {
                    let text = inline_text(bytes, child)?;
                    observed.extend(text.chars().map(|character| (character, id)));
                    texts.push(child);
                    template.get_or_insert((run, child));
                    saw_text = true;
                }
                "secPr" if !saw_text => {
                    controls = true;
                }
                "ctrl"
                    if !saw_text
                        && child.children.len() == 1
                        && child.children[0].local() == "colPr"
                        && child.children[0].namespace.as_deref() == Some(PARAGRAPH_NS) =>
                {
                    controls = true;
                }
                _ => return Err(unsupported()),
            }
        }
        if !std::str::from_utf8(&bytes[cursor..run.close])
            .map_err(|_| xml_error())?
            .trim()
            .is_empty()
        {
            return Err(unsupported());
        }
        runs.push((run, texts, controls));
    }
    if observed != visible_characters(original)? {
        return Err(unsupported());
    }
    let (template_run, template_text) = match template {
        Some((run, text)) => (run, Some(text)),
        None => (runs.last().ok_or_else(unsupported)?.0, None),
    };
    let mut groups: Vec<(u16, String)> = Vec::new();
    for (character, id) in visible_characters(edited)? {
        if groups.last().is_some_and(|(previous, _)| *previous == id) {
            groups.last_mut().expect("checked group").1.push(character);
        } else {
            groups.push((id, character.to_string()));
        }
    }
    let end = edited.chars.iter().try_fold(0u32, |position, value| {
        position
            .checked_add(value.wchar_width())
            .ok_or_else(unsupported)
    })?;
    let final_id = character_id(edited, end)?;
    if groups.last().is_none_or(|(id, _)| *id != final_id) {
        groups.push((final_id, String::new()));
    }
    let mut rendered = String::new();
    for (id, text) in groups {
        let run = rendered_run(bytes, template_run, template_text, id, &text)?;
        if rendered
            .len()
            .checked_add(run.len())
            .is_none_or(|length| length > 2 * 1024 * 1024)
        {
            return Err(unsupported());
        }
        rendered.push_str(&run);
    }
    let mut patches = Vec::new();
    let mut inserted = false;
    for (run, texts, controls) in runs {
        if texts.is_empty() && (template_text.is_some() || run.start != template_run.start) {
            continue;
        }
        let mut replacement = if controls {
            let raw = replace_spans(
                &bytes[run.start..run.end],
                texts
                    .iter()
                    .map(|node| (node.start - run.start, node.end - run.start, String::new()))
                    .collect(),
            )?;
            String::from_utf8(raw).map_err(|_| xml_error())?
        } else {
            String::new()
        };
        if !inserted {
            replacement.push_str(&rendered);
            inserted = true;
        }
        patches.push((run.start, run.end, replacement));
    }
    Ok(patches)
}
fn ordinary_line_cache(node: &Node) -> bool {
    node.attrs.is_empty()
        && !node.opaque_body
        && node.children.iter().all(|line| {
            line.local() == "lineseg"
                && line.namespace.as_deref() == Some(PARAGRAPH_NS)
                && line.children.is_empty()
                && !line.opaque_body
                && line.attrs.keys().all(|key| {
                    [
                        "textpos",
                        "vertpos",
                        "vertsize",
                        "textheight",
                        "baseline",
                        "spacing",
                        "horzpos",
                        "horzsize",
                        "flags",
                    ]
                    .contains(&key.as_str())
                })
        })
}

fn remove_body_paragraph(
    bytes: &[u8],
    doc: &Document,
    section: usize,
    index: usize,
) -> Result<Vec<u8>> {
    let root = parse(bytes, false)?;
    let model = &doc.sections[section].paragraphs;
    let paragraphs = section_paragraphs(&root, model.len()).ok_or_else(unsupported)?;
    let selected = paragraphs
        .get(index)
        .filter(|_| index > 0)
        .ok_or_else(unsupported)?;
    validate_paragraph_deletion(bytes, selected, &model[index], doc)?;
    replace_spans(bytes, vec![(selected.start, selected.end, String::new())])
}

fn patch_section(
    bytes: &[u8],
    doc: &Document,
    edited: &Document,
    section: usize,
    changes: &[Change],
    insertions: &BTreeMap<(usize, usize), ParagraphInsertion>,
    table: Option<(usize, &str)>,
) -> Result<Vec<u8>> {
    let range_targets: BTreeSet<_> = changes
        .iter()
        .filter(|change| change.range.is_some())
        .map(|change| (change.section, change.paragraph, change.table, change.cell))
        .collect();
    let has_text = changes.iter().any(|change| {
        change.section == section
            && change.alignment.is_none()
            && !range_targets.contains(&(
                change.section,
                change.paragraph,
                change.table,
                change.cell,
            ))
    });
    let root = parse(bytes, has_text)?;
    let paras: Vec<_> = root.children.iter().filter(|n| n.local() == "p").collect();
    let section_insertions = insertions.range((section, 0)..=(section, usize::MAX));
    let has_insertions = section_insertions.clone().next().is_some();
    if (has_insertions
        || table.is_some()
        || changes
            .iter()
            .any(|change| change.section == section && change.range.is_some()))
        && (root.local() != "sec"
            || root.namespace.as_deref() != Some(SECTION_NS)
            || paras.len() != doc.sections[section].paragraphs.len())
    {
        return Err(unsupported());
    }
    let mut patches: Vec<(usize, usize, String)> = Vec::new();
    if let Some((index, xml)) = table {
        let anchor = paras.get(index).ok_or_else(unsupported)?;
        if anchor.namespace.as_deref() != Some(PARAGRAPH_NS) || anchor.empty {
            return Err(unsupported());
        }
        patches.push((anchor.end, anchor.end, xml.to_owned()));
    }
    if has_insertions {
        let mut ids = BTreeSet::new();
        collect_section_ids(&root, &mut ids);
        let mut next_id = 1u32;
        for (&(_, index), insertion) in section_insertions {
            let anchor = paras.get(index).ok_or_else(unsupported)?;
            if anchor.namespace.as_deref() != Some(PARAGRAPH_NS) {
                return Err(unsupported());
            }
            while ids.contains(&next_id) {
                next_id = next_id.checked_add(1).ok_or_else(unsupported)?;
            }
            ids.insert(next_id);
            let (paragraph, style, character) = insertion.style;
            let sibling = format!(
                "<hp:p xmlns:hp=\"{PARAGRAPH_NS}\" id=\"{next_id}\" paraPrIDRef=\"{}\" styleIDRef=\"{}\" pageBreak=\"0\" columnBreak=\"0\" merged=\"0\"><hp:run charPrIDRef=\"{}\"><hp:t>{}</hp:t></hp:run></hp:p>",
                paragraph.0,
                style.0,
                character.0,
                escape(&insertion.text),
            );
            patches.push((anchor.end, anchor.end, sibling));
        }
    }
    let mut handled_ranges = BTreeSet::new();
    for change in changes.iter().filter(|c| c.section == section) {
        let range_key = (change.section, change.paragraph, change.table, change.cell);
        let range_target = change.alignment.is_none() && range_targets.contains(&range_key);
        if range_target && !handled_ranges.insert(range_key) {
            continue;
        }
        let para = *paras.get(change.paragraph).ok_or_else(unsupported)?;
        let target = if let Some(control) = change.table {
            let p = doc
                .sections
                .get(section)
                .and_then(|s| s.paragraphs.get(change.paragraph))
                .ok_or_else(unsupported)?;
            let ordinal = p.controls[..control]
                .iter()
                .filter(|c| matches!(c, Control::Table(_)))
                .count();
            let mut tables = Vec::new();
            para.find("tbl", &mut tables);
            let table = *tables.get(ordinal).ok_or_else(unsupported)?;
            if range_target && table.namespace.as_deref() != Some(PARAGRAPH_NS) {
                return Err(unsupported());
            }
            let mut cells = Vec::new();
            table.find("tc", &mut cells);
            let (row, col) = change.cell.ok_or_else(unsupported)?;
            let cell = cells
                .into_iter()
                .find(|cell| {
                    let mut addr = Vec::new();
                    cell.find("cellAddr", &mut addr);
                    addr.first().is_some_and(|a| {
                        a.attrs.get("rowAddr").and_then(|n| n.parse::<u16>().ok()) == Some(row)
                            && a.attrs.get("colAddr").and_then(|n| n.parse::<u16>().ok())
                                == Some(col)
                    })
                })
                .ok_or_else(unsupported)?;
            let sub = cell
                .children
                .iter()
                .find(|n| n.local() == "subList")
                .ok_or_else(unsupported)?;
            if range_target
                && (cell.namespace.as_deref() != Some(PARAGRAPH_NS)
                    || sub.namespace.as_deref() != Some(PARAGRAPH_NS))
            {
                return Err(unsupported());
            }
            let list: Vec<_> = sub.children.iter().filter(|n| n.local() == "p").collect();
            if list.len() != 1 {
                return Err(unsupported());
            }
            list[0]
        } else {
            para
        };
        if change.alignment.is_some() {
            let original = &doc.sections[section].paragraphs[change.paragraph];
            let new_id = edited.sections[section].paragraphs[change.paragraph]
                .para_shape
                .0;
            if target.namespace.as_deref() != Some(PARAGRAPH_NS)
                || target.attrs.get("paraPrIDRef") != Some(&original.para_shape.0.to_string())
            {
                return Err(unsupported());
            }
            if new_id != original.para_shape.0 {
                let span = attribute_span(bytes, target, "paraPrIDRef")?;
                patches.push((span.0, span.1, new_id.to_string()));
            }
        } else if range_target {
            patches.extend(range_patches(
                bytes,
                target,
                paragraph_at(doc, change)?,
                paragraph_at(edited, change)?,
            )?);
        } else {
            let mut texts = Vec::new();
            target.find("t", &mut texts);
            if texts.is_empty() {
                return Err(unsupported());
            }
            for (i, node) in texts.into_iter().enumerate() {
                if node.namespace.as_deref() != Some(PARAGRAPH_NS)
                    || node
                        .children
                        .iter()
                        .any(|child| !known_inline_whitespace(child))
                    || node.opaque_body
                {
                    return Err(err(
                        "unsupported_loss",
                        "글자 영역 안의 확장 정보를 보존할 수 없어 저장을 중단했습니다.",
                    ));
                }
                let replacement = if i == 0 {
                    authored_text(&change.text, &node.name)
                } else {
                    String::new()
                };
                if node.empty {
                    let tag = std::str::from_utf8(&bytes[node.start..node.end])
                        .map_err(|_| xml_error())?;
                    let start_tag = tag.strip_suffix("/>").ok_or_else(xml_error)?;
                    patches.push((
                        node.start,
                        node.end,
                        format!("{start_tag}>{replacement}</{}>", node.name),
                    ));
                } else {
                    patches.push((node.body, node.close, replacement));
                }
            }
        }
        let mut caches = Vec::new();
        if change.alignment.is_some() || range_target {
            caches.extend(target.children.iter().filter(|node| {
                node.local() == "linesegarray" && node.namespace.as_deref() == Some(PARAGRAPH_NS)
            }));
        } else {
            target.find("linesegarray", &mut caches);
        }
        for node in caches {
            if node.namespace.as_deref() != Some(PARAGRAPH_NS) {
                if change.alignment.is_some() || range_target {
                    continue;
                }
                return Err(unsupported());
            }
            if !ordinary_line_cache(node) {
                return Err(err(
                    "unsupported_loss",
                    "줄 배치 정보 안의 확장 정보를 보존할 수 없습니다.",
                ));
            }
            patches.push((node.start, node.end, String::new()));
        }
    }
    let out = replace_spans(bytes, patches)?;
    if (!range_targets.is_empty() || table.is_some()) && out.len() > 2 * 1024 * 1024 {
        return Err(unsupported());
    }
    validate(&out, has_text)?;
    Ok(out)
}
pub(crate) struct StructureEdits<'a> {
    pub paragraphs: &'a BTreeMap<(usize, usize), ParagraphInsertion>,
    pub paragraph_deletion: Option<(usize, usize)>,
    pub table: Option<&'a TableInsertion>,
    pub table_structure: Option<&'a table_structure::Edit>,
}

pub(crate) fn write_package(
    source: &Path,
    output: &Path,
    doc: &Document,
    edited: &Document,
    changes: &[Change],
    character_origins: &BTreeMap<u16, u16>,
    structure: StructureEdits<'_>,
) -> Result<()> {
    let sections: BTreeSet<_> = changes
        .iter()
        .map(|c| c.section)
        .chain(structure.paragraphs.keys().map(|(section, _)| *section))
        .chain(structure.paragraph_deletion.map(|(section, _)| section))
        .chain(structure.table.map(|table| table.location.0))
        .chain(structure.table_structure.map(|edit| edit.section()))
        .collect();
    let mut dirty: BTreeSet<_> = sections
        .iter()
        .map(|section| format!("Contents/section{section}.xml"))
        .collect();
    let mut input = zip::ZipArchive::new(fs::File::open(source).map_err(io_error)?)
        .map_err(|_| unsupported())?;
    // Preflight every dirty XML before creating the edited container.
    let mut rewritten = BTreeMap::new();
    let mut header = alignment_header(source, doc, edited, changes)?;
    if !character_origins.is_empty() {
        let bytes = match header {
            Some(bytes) => bytes,
            None => zip_xml(source, "Contents/header.xml")?,
        };
        header = Some(character_header(&bytes, doc, edited, character_origins)?);
    } else if edited.header.char_shapes != doc.header.char_shapes {
        return Err(unsupported());
    }
    if let Some(header) = header {
        dirty.insert("Contents/header.xml".to_owned());
        rewritten.insert("Contents/header.xml".to_owned(), header);
    }
    let table = structure
        .table
        .map(|table| table_sibling(source, doc, table))
        .transpose()?;
    for section in sections {
        let name = format!("Contents/section{section}.xml");
        let mut entry = input.by_name(&name).map_err(|_| unsupported())?;
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes).map_err(io_error)?;
        if let Some(edit) = structure
            .table_structure
            .filter(|edit| edit.section() == section)
        {
            rewritten.insert(name, edit.rewrite(&bytes)?);
            continue;
        }
        if let Some((_, index)) = structure
            .paragraph_deletion
            .filter(|(id, _)| *id == section)
        {
            rewritten.insert(name, remove_body_paragraph(&bytes, doc, section, index)?);
            continue;
        }
        rewritten.insert(
            name,
            patch_section(
                &bytes,
                doc,
                edited,
                section,
                changes,
                structure.paragraphs,
                structure
                    .table
                    .zip(table.as_deref())
                    .filter(|(target, _)| target.location.0 == section)
                    .map(|(target, xml)| (target.location.1, xml)),
            )?,
        );
    }
    let mut writer = zip::ZipWriter::new(fs::File::create(output).map_err(io_error)?);
    for i in 0..input.len() {
        let entry = input.by_index(i).map_err(|_| unsupported())?;
        if let Some(bytes) = rewritten.get(entry.name()) {
            writer
                .start_file(
                    entry.name(),
                    zip::write::SimpleFileOptions::default()
                        .compression_method(entry.compression()),
                )
                .map_err(io_error)?;
            writer.write_all(bytes).map_err(io_error)?;
        } else {
            writer.raw_copy_file(entry).map_err(io_error)?;
        }
    }
    writer.finish().map_err(io_error)?;
    drop(input);
    let mut before = zip::ZipArchive::new(fs::File::open(source).map_err(io_error)?)
        .map_err(|_| unsupported())?;
    let mut after = zip::ZipArchive::new(fs::File::open(output).map_err(io_error)?)
        .map_err(|_| unsupported())?;
    if before.len() != after.len() {
        return Err(err(
            "unsupported_loss",
            "문서 보관 항목 수가 바뀌어 저장을 중단했습니다.",
        ));
    }
    for i in 0..before.len() {
        let mut a = before.by_index(i).map_err(|_| unsupported())?;
        let mut b = after.by_name(a.name()).map_err(|_| unsupported())?;
        if !dirty.contains(a.name()) {
            let mut x = Vec::new();
            let mut y = Vec::new();
            a.read_to_end(&mut x).map_err(io_error)?;
            b.read_to_end(&mut y).map_err(io_error)?;
            if x != y {
                return Err(err(
                    "unsupported_loss",
                    "비수정 문서 영역이 바뀌어 저장을 중단했습니다.",
                ));
            }
        }
    }
    Ok(())
}
