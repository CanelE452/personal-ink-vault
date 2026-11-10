use crate::engine::{ParagraphInsertion, ParagraphStructure};
use crate::hwp_body::{SectionPatch, collect_ids, open_editable, read_section, write_sections};
use crate::{Result, err, unsupported};
use hwp_model::{
    CharShapeId, Control, Document, HwpChar, ParaHeaderInfo, ParaShapeId, Paragraph, StyleId,
};
use hwp5::record::{RecordNode, tag};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

const TERMINAL: u32 = 0x8000_0000;

pub(crate) struct Edit {
    sections: BTreeMap<usize, SectionPatch>,
    additions: BTreeMap<(usize, usize), Paragraph>,
}

pub(crate) fn structure(source: &Path, doc: &Document) -> Result<ParagraphStructure> {
    let mut container = open_editable(source, doc)?;
    let mut structure = ParagraphStructure::default();
    for (section, model) in doc.sections.iter().enumerate() {
        let Ok((_, roots)) = read_section(&mut container, section) else {
            continue;
        };
        if !matches_section(&roots, &model.paragraphs) {
            continue;
        }
        for (index, (raw, paragraph)) in roots.iter().zip(&model.paragraphs).enumerate() {
            if let Some(style) = anchor_style(raw, paragraph, doc, index == 0) {
                if paragraph
                    .chars
                    .iter()
                    .any(|c| matches!(c, HwpChar::Text(_)))
                {
                    structure.insertions.insert((section, index), style);
                }
                if can_delete_position(&model.paragraphs, index) {
                    structure.deletions.insert((section, index));
                }
            }
        }
    }
    Ok(structure)
}

fn can_delete_position(paragraphs: &[Paragraph], index: usize) -> bool {
    index > 0 && (index + 1 < paragraphs.len() || paragraphs[index - 1].header.chars_flags == 0)
}

pub(crate) fn delete(
    source: &Path,
    output: &Path,
    expected: &mut Document,
    (section, index): (usize, usize),
) -> Result<()> {
    let mut container = open_editable(source, expected)?;
    let (original, mut roots) = read_section(&mut container, section)?;
    drop(container);
    let model = expected.sections.get(section).ok_or_else(unsupported)?;
    if !matches_section(&roots, &model.paragraphs)
        || index >= roots.len()
        || !can_delete_position(&model.paragraphs, index)
        || anchor_style(&roots[index], &model.paragraphs[index], expected, false).is_none()
    {
        return Err(unsupported());
    }
    let model = &mut expected.sections[section];
    roots.remove(index);
    model.paragraphs.remove(index);
    if index == roots.len() {
        roots[index - 1].data[3] |= 0x80;
        model.paragraphs[index - 1].header.chars_flags |= 0x80;
    }
    if hwp5::body_text::parse_section(&roots).0 != *model {
        return Err(mismatch());
    }
    let patch = SectionPatch::new(Sha256::digest(original).into(), &roots)?;
    write_sections(source, output, expected, [(section, &patch)])
}

impl Edit {
    pub(crate) fn prepare(
        source: &Path,
        doc: &Document,
        operations: &BTreeMap<(usize, usize), ParagraphInsertion>,
    ) -> Result<Self> {
        let mut container = open_editable(source, doc)?;
        let mut ids = BTreeSet::new();
        let mut pending = BTreeMap::new();
        for section in 0..doc.sections.len() {
            let (original, roots) = read_section(&mut container, section)?;
            collect_ids(&roots, &mut ids);
            if operations
                .range((section, 0)..=(section, usize::MAX))
                .next()
                .is_some()
            {
                pending.insert(section, (Sha256::digest(original).into(), roots));
            }
        }
        let mut sections = BTreeMap::new();
        let mut additions = BTreeMap::new();
        let mut next = 0u32;
        for (section, (before_sha256, mut roots)) in pending {
            let model = &doc.sections[section];
            if !matches_section(&roots, &model.paragraphs) {
                return Err(unsupported());
            }
            let mut expected = model.clone();
            for (&(_, anchor), operation) in
                operations.range((section, 0)..=(section, usize::MAX)).rev()
            {
                let old = model.paragraphs.get(anchor).ok_or_else(unsupported)?;
                let raw = roots.get_mut(anchor).ok_or_else(unsupported)?;
                if anchor_style(raw, old, doc, anchor == 0).is_none() {
                    return Err(unsupported());
                }
                loop {
                    next = next.checked_add(1).ok_or_else(unsupported)?;
                    if ids.insert(next) {
                        break;
                    }
                }
                let paragraph = inserted_paragraph(old, operation, next);
                let node = inserted_record(raw, &paragraph, &operation.text);
                raw.data[3] &= 0x7f;
                roots.insert(anchor + 1, node);
                insert_expected(&mut expected.paragraphs, anchor, paragraph.clone())?;
                additions.insert((section, anchor), paragraph);
            }
            if hwp5::body_text::parse_section(&roots).0 != expected {
                return Err(mismatch());
            }
            sections.insert(section, SectionPatch::new(before_sha256, &roots)?);
        }
        if additions.len() != operations.len() {
            return Err(mismatch());
        }
        Ok(Self {
            sections,
            additions,
        })
    }

    pub(crate) fn apply_expected(&self, doc: &mut Document) -> Result<()> {
        for (&(section, anchor), paragraph) in self.additions.iter().rev() {
            let paragraphs = &mut doc
                .sections
                .get_mut(section)
                .ok_or_else(mismatch)?
                .paragraphs;
            insert_expected(paragraphs, anchor, paragraph.clone())?;
        }
        Ok(())
    }

    pub(crate) fn write(&self, source: &Path, output: &Path, expected: &Document) -> Result<()> {
        write_sections(
            source,
            output,
            expected,
            self.sections.iter().map(|(&id, patch)| (id, patch)),
        )
    }
}

fn insert_expected(
    paragraphs: &mut Vec<Paragraph>,
    anchor: usize,
    paragraph: Paragraph,
) -> Result<()> {
    paragraphs
        .get_mut(anchor)
        .ok_or_else(mismatch)?
        .header
        .chars_flags &= !0x80;
    paragraphs.insert(anchor + 1, paragraph);
    Ok(())
}

fn matches_section(roots: &[RecordNode], paragraphs: &[Paragraph]) -> bool {
    roots.len() == paragraphs.len()
        && roots
            .iter()
            .zip(paragraphs)
            .enumerate()
            .all(|(index, (root, paragraph))| {
                let terminal = index + 1 == paragraphs.len();
                root.tag == tag::PARA_HEADER
                    && root
                        .data
                        .get(3)
                        .is_some_and(|flags| (flags & 0x80 != 0) == terminal)
                    && (paragraph.header.chars_flags == 0x80) == terminal
            })
}

fn anchor_style(
    raw: &RecordNode,
    para: &Paragraph,
    doc: &Document,
    first: bool,
) -> Option<(ParaShapeId, StyleId, CharShapeId)> {
    let header = &para.header;
    let layout = first && !para.controls.is_empty();
    if !matches!(raw.data.len(), 22 | 24)
        || !matches!(header.tail.as_slice(), [] | [0, 0])
        || !para.extras.is_empty()
        || (!layout
            && (header.ctrl_mask != 0 || header.break_type != 0 || !para.controls.is_empty()))
        || (layout
            && (header.ctrl_mask & !4 != 0
                || header.break_type & !3 != 0
                || !layout_controls(&para.controls)))
        || usize::from(para.para_shape.0) >= doc.header.para_shapes.len()
        || usize::from(para.style.0) >= doc.header.styles.len()
        || para.chars.iter().any(|c| {
            !matches!(
                c,
                HwpChar::Text(_) | HwpChar::CharCtrl(10 | 13) | HwpChar::InlineCtrl { code: 9, .. }
            ) && !(layout && matches!(c, HwpChar::ExtCtrl { code: 2, .. }))
        })
        || (!para.chars.is_empty() && para.chars.last() != Some(&HwpChar::CharCtrl(13)))
        || u32_at(&raw.data, 0)? & !TERMINAL != para.wchar_len().max(1)
    {
        return None;
    }
    let mut children = raw.children.as_slice();
    if let [text, rest @ ..] = children
        && text.tag == tag::PARA_TEXT
    {
        if !text.children.is_empty() || text.data.len() as u32 != para.wchar_len() * 2 {
            return None;
        }
        children = rest;
    } else if !para.chars.is_empty() {
        return None;
    }
    let [shape, rest @ ..] = children else {
        return None;
    };
    children = rest;
    let [(0, _), ..] = para.char_shape_runs.as_slice() else {
        return None;
    };
    if shape.tag != tag::PARA_CHAR_SHAPE
        || !shape.children.is_empty()
        || shape.data.len() != para.char_shape_runs.len() * 8
        || usize::from(u16_at(&raw.data, 12)?) != para.char_shape_runs.len()
        || u16_at(&raw.data, 14)? != 0
        || !shape
            .data
            .chunks_exact(8)
            .zip(&para.char_shape_runs)
            .all(|(run, (offset, id))| {
                u32_at(run, 0) == Some(*offset)
                    && u32_at(run, 4) == Some(u32::from(id.0))
                    && usize::from(id.0) < doc.header.char_shapes.len()
            })
    {
        return None;
    }
    if let [line, rest @ ..] = children
        && line.tag == tag::PARA_LINE_SEG
    {
        if !line.children.is_empty() || line.data.len() != para.line_segs.len() * 36 {
            return None;
        }
        children = rest;
    }
    if usize::from(u16_at(&raw.data, 16)?) != para.line_segs.len()
        || children.len() != para.controls.len()
        || children.iter().any(|node| node.tag != tag::CTRL_HEADER)
    {
        return None;
    }
    let first_text = para
        .chars
        .iter()
        .position(|c| matches!(c, HwpChar::Text(_)));
    let offset = first_text.map_or(0, |index| {
        para.chars[..index].iter().map(HwpChar::wchar_width).sum()
    });
    let character = crate::text_ranges::style_at(&para.char_shape_runs, offset).ok()?;
    Some((para.para_shape, para.style, character))
}

fn layout_controls(controls: &[Control]) -> bool {
    matches!(controls, [Control::SectionDef(_)])
        || matches!(controls, [Control::SectionDef(_), Control::Generic(column)]
            if column.ctrl_id == *b"cold" && column.paragraph_lists.is_empty())
}

fn inserted_paragraph(
    anchor: &Paragraph,
    operation: &ParagraphInsertion,
    instance_id: u32,
) -> Paragraph {
    let (para_shape, style, character) = operation.style;
    Paragraph {
        para_shape,
        style,
        chars: operation
            .text
            .chars()
            .map(HwpChar::Text)
            .chain([HwpChar::CharCtrl(13)])
            .collect(),
        char_shape_runs: vec![(0, character)],
        header: ParaHeaderInfo {
            chars_flags: anchor.header.chars_flags,
            instance_id,
            tail: anchor.header.tail.clone(),
            ..ParaHeaderInfo::default()
        },
        ..Paragraph::default()
    }
}

fn inserted_record(anchor: &RecordNode, paragraph: &Paragraph, text: &str) -> RecordNode {
    let mut header = anchor.data.clone();
    let nchars = paragraph.wchar_len() | (u32::from(paragraph.header.chars_flags) << 24);
    header[..4].copy_from_slice(&nchars.to_le_bytes());
    header[4..8].fill(0);
    header[8..10].copy_from_slice(&paragraph.para_shape.0.to_le_bytes());
    header[10] = paragraph.style.0 as u8;
    header[11] = 0;
    header[12..14].copy_from_slice(&1u16.to_le_bytes());
    header[14..18].fill(0);
    header[18..22].copy_from_slice(&paragraph.header.instance_id.to_le_bytes());
    let mut shape = vec![0; 4];
    shape.extend(u32::from(paragraph.char_shape_runs[0].1.0).to_le_bytes());
    RecordNode {
        tag: tag::PARA_HEADER,
        data: header,
        children: vec![
            RecordNode {
                tag: tag::PARA_TEXT,
                data: text
                    .encode_utf16()
                    .chain([13])
                    .flat_map(u16::to_le_bytes)
                    .collect(),
                children: Vec::new(),
            },
            RecordNode {
                tag: tag::PARA_CHAR_SHAPE,
                data: shape,
                children: Vec::new(),
            },
        ],
    }
}

fn u16_at(data: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(data.get(at..at + 2)?.try_into().ok()?))
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

fn mismatch() -> crate::ApiError {
    err(
        "semantic_mismatch",
        "저장한 한글 문단과 원본 보존 내용을 확인하지 못했습니다.",
    )
}
