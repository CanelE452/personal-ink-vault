use crate::hwp_body::{SectionPatch, collect_ids, open_editable, read_section, write_sections};
use crate::{Result, err, invalid, text, unsupported};
use hwp_model::{Control, Document, HwpChar, LineSeg, Paragraph, Section, Table};
use hwp5::record::{RecordNode, tag};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::path::Path;

const MAX_ROWS: usize = 64;
const MAX_COLUMNS: usize = 32;
const MAX_CELLS: usize = 512;
const MAX_EXTENT: i32 = 1_000_000;

pub(crate) struct Edit {
    section: usize,
    paragraph: usize,
    patch: SectionPatch,
    table: Table,
    line: LineSeg,
}

impl Edit {
    pub(crate) fn prepare(source: &Path, doc: &Document, operation: &Value) -> Result<Self> {
        if operation.as_object().is_none_or(|fields| fields.len() != 4)
            || operation["op"] != "tableStructure"
        {
            return Err(invalid());
        }
        let (section, paragraph) = location(text(operation, "id")?).ok_or_else(invalid)?;
        let insert = match text(operation, "action")? {
            "insertRow" => true,
            "deleteRow" => false,
            "insertColumn" | "deleteColumn" => return Err(unsupported()),
            _ => return Err(invalid()),
        };
        let index = operation["index"]
            .as_u64()
            .and_then(|n| usize::try_from(n).ok())
            .ok_or_else(invalid)?;
        let mut container = open_editable(source, doc)?;
        let (bytes, mut roots) = read_section(&mut container, section)?;
        let model = doc.sections.get(section).ok_or_else(invalid)?;
        let (root, carrier) = find_carrier(&roots, model, paragraph).ok_or_else(unsupported)?;
        let grid = Grid::read(carrier, model, paragraph, doc).ok_or_else(unsupported)?;
        if index >= grid.heights.len() + usize::from(insert) {
            return Err(invalid());
        }
        if (insert && !grid.can_insert()) || (!insert && grid.heights.len() == 1) {
            return Err(unsupported());
        }

        let mut used = BTreeSet::new();
        if insert {
            collect_ids(&roots, &mut used);
            for other in (0..doc.sections.len()).filter(|&other| other != section) {
                let (_, other_roots) = read_section(&mut container, other)?;
                collect_ids(&other_roots, &mut used);
            }
        }
        let (table, line, changed) = grid.change(carrier, insert, index, &mut used)?;
        roots[root] = changed;
        let (parsed, _) = hwp5::body_text::parse_section(&roots);
        let mut expected = model.clone();
        expected.paragraphs[paragraph].controls[0] = Control::Table(table.clone());
        expected.paragraphs[paragraph].line_segs[0] = line;
        if parsed != expected {
            return Err(mismatch());
        }
        Ok(Self {
            section,
            paragraph,
            patch: SectionPatch::new(Sha256::digest(bytes).into(), &roots)?,
            table,
            line,
        })
    }

    pub(crate) fn apply_expected(&self, doc: &mut Document) -> Result<()> {
        let carrier = doc
            .sections
            .get_mut(self.section)
            .and_then(|section| section.paragraphs.get_mut(self.paragraph))
            .ok_or_else(mismatch)?;
        let ([Control::Table(table)], [line]) = (
            carrier.controls.as_mut_slice(),
            carrier.line_segs.as_mut_slice(),
        ) else {
            return Err(mismatch());
        };
        *table = self.table.clone();
        *line = self.line;
        Ok(())
    }

    pub(crate) fn verify(&self, doc: &Document) -> Result<()> {
        let carrier = doc
            .sections
            .get(self.section)
            .and_then(|section| section.paragraphs.get(self.paragraph))
            .ok_or_else(mismatch)?;
        if !matches!(carrier.controls.as_slice(), [Control::Table(table)] if table == &self.table)
            || carrier.line_segs.as_slice() != [self.line]
        {
            return Err(mismatch());
        }
        Ok(())
    }

    pub(crate) fn write(&self, source: &Path, output: &Path, expected: &Document) -> Result<()> {
        self.verify(expected)?;
        write_sections(source, output, expected, [(self.section, &self.patch)])
    }
}

pub(crate) fn mark_snapshot(source: &Path, doc: &Document, snapshot: &mut Value) {
    let Some(tables) = snapshot["tables"]
        .as_array_mut()
        .filter(|tables| !tables.is_empty())
    else {
        return;
    };
    let Ok(mut container) = open_editable(source, doc) else {
        return;
    };
    for (section, model) in doc.sections.iter().enumerate() {
        if !model
            .paragraphs
            .iter()
            .any(|paragraph| matches!(paragraph.controls.as_slice(), [Control::Table(_)]))
        {
            continue;
        }
        let Ok((_, roots)) = read_section(&mut container, section) else {
            continue;
        };
        for item in tables.iter_mut() {
            let Some((section_id, paragraph)) = item["id"].as_str().and_then(location) else {
                continue;
            };
            if section_id != section {
                continue;
            }
            let Some(grid) = find_carrier(&roots, model, paragraph)
                .and_then(|(_, carrier)| Grid::read(carrier, model, paragraph, doc))
            else {
                continue;
            };
            let can_insert = grid.can_insert();
            let can_delete = grid.heights.len() > 1;
            if can_insert || can_delete {
                item["structure"] = json!({"rows":grid.heights.len(),"columns":grid.table.cols,
                    "canInsertRow":can_insert,"canDeleteRow":can_delete,
                    "canInsertColumn":false,"canDeleteColumn":false});
            }
        }
    }
}

struct Grid<'a> {
    table: &'a Table,
    heights: Vec<i32>,
    line: LineSeg,
    available: i32,
}

impl<'a> Grid<'a> {
    fn read(
        carrier: &RecordNode,
        section: &'a Section,
        paragraph: usize,
        doc: &Document,
    ) -> Option<Self> {
        let model = section.paragraphs.get(paragraph)?;
        let [Control::Table(table)] = model.controls.as_slice() else {
            return None;
        };
        let [
            HwpChar::ExtCtrl {
                code: 11,
                ctrl_id,
                ctrl_index: Some(0),
                ..
            },
            HwpChar::CharCtrl(13),
        ] = model.chars.as_slice()
        else {
            return None;
        };
        let [line] = model.line_segs.as_slice() else {
            return None;
        };
        let [para_text, char_shape, line_seg, table_node] = carrier.children.as_slice() else {
            return None;
        };
        let placement = table.placement.as_ref()?;
        if ctrl_id != b"tbl "
            || !model.extras.is_empty()
            || !matches!(model.header.tail.as_slice(), [] | [0, 0])
            || model.header.break_type != 0
            || model.header.ctrl_mask != 1 << 11
            || para_text.tag != tag::PARA_TEXT
            || para_text.data.len() != 18
            || char_shape.tag != tag::PARA_CHAR_SHAPE
            || line_seg.tag != tag::PARA_LINE_SEG
            || [&para_text, &char_shape, &line_seg]
                .iter()
                .any(|node| !node.children.is_empty())
            || !placement.treat_as_char
            || !placement.affect_line_spacing
            || placement.vert_offset != 0
            || placement.horz_offset != 0
            || placement.out_margins != [0; 4]
            || table.attr != 0
            || table.cell_spacing != 0
            || table.caption.is_some()
            || !table.extras.is_empty()
            || !matches!(table.table_tail.as_slice(), [] | [0, 0])
            || table_node.tag != tag::CTRL_HEADER
            || table_node.data.len() < 36
            || table_node.data.get(..4)? != b" lbt"
            || table_node.data[4..] != table.common_data
            || i32_at(&table_node.data, 20)? != placement.height
            || line_seg.data.len() != 36
            || line.text_start != 0
            || line.v_pos < 0
            || line.line_spacing < 0
            || line.col_start != 0
            || line.flags != 0x60000
            || line.line_height != placement.height
            || line.text_height != placement.height
            || line.baseline_gap != baseline(placement.height)
        {
            return None;
        }
        let (rows, cols) = (usize::from(table.rows), usize::from(table.cols));
        if !(1..=MAX_ROWS).contains(&rows)
            || !(1..=MAX_COLUMNS).contains(&cols)
            || rows * cols > MAX_CELLS
            || table.cells.len() != rows * cols
            || table.row_cell_counts.len() != rows
            || table.row_cell_counts.iter().any(|&n| n != table.cols)
            || table_node.children.len() != 1 + 2 * rows * cols
        {
            return None;
        }
        let table_record = &table_node.children[0];
        if table_record.tag != tag::TABLE
            || !table_record.children.is_empty()
            || table_record.data.len() != 20 + 2 * rows + table.table_tail.len()
            || u16_at(&table_record.data, 4)? != table.rows
            || u16_at(&table_record.data, 6)? != table.cols
        {
            return None;
        }
        let mut heights = Vec::with_capacity(rows);
        let mut widths = vec![0; cols];
        for (i, (cell, pair)) in table
            .cells
            .iter()
            .zip(table_node.children[1..].chunks_exact(2))
            .enumerate()
        {
            let (row, col) = (i / cols, i % cols);
            let [paragraph] = cell.paragraphs.as_slice() else {
                return None;
            };
            let [list, raw] = pair else { return None };
            if usize::from(cell.row) != row
                || usize::from(cell.col) != col
                || cell.row_span != 1
                || cell.col_span != 1
                || cell.list_attr & !0x60 != 0
                || !(1..=MAX_EXTENT).contains(&cell.width.0)
                || !(1..=MAX_EXTENT).contains(&cell.height.0)
                || cell.header_tail.len() != 13
                || i32_at(&cell.header_tail, 0)? != cell.width.0
                || cell.header_tail[4..] != [0; 9]
                || list.tag != tag::LIST_HEADER
                || !list.children.is_empty()
                || list.data.len() != 47
                || i32_at(&list.data, 0)? != 1
                || u16_at(&list.data, 10)? != cell.row
                || !plain_cell(raw, paragraph, doc)
            {
                return None;
            }
            if row == 0 {
                widths[col] = cell.width.0;
            }
            if col == 0 {
                heights.push(cell.height.0);
            }
            if widths[col] != cell.width.0 || heights[row] != cell.height.0 {
                return None;
            }
        }
        let width: i32 = widths.iter().sum();
        let height: i32 = heights.iter().sum();
        let page = section.section_def()?.page?;
        let mut available = page
            .height
            .0
            .checked_sub(page.margin_top.0)?
            .checked_sub(page.margin_header.0)?
            .checked_sub(page.margin_bottom.0)?
            .checked_sub(page.margin_footer.0)?
            .checked_sub(line.v_pos)?;
        if let Some(next) = section
            .paragraphs
            .get(paragraph + 1)
            .and_then(|p| p.line_segs.first())
            .filter(|next| next.v_pos > line.v_pos)
        {
            available = available.min(next.v_pos - line.v_pos);
        }
        if width != placement.width
            || height != placement.height
            || width > line.seg_width.checked_add(1)?
            || height > MAX_EXTENT
            || height > available
        {
            return None;
        }
        Some(Self {
            table,
            heights,
            line: *line,
            available,
        })
    }

    fn can_insert(&self) -> bool {
        self.heights.len() < MAX_ROWS
            && (self.heights.len() + 1) * usize::from(self.table.cols) <= MAX_CELLS
            && self.line.line_height + self.heights.iter().copied().max().unwrap_or_default()
                <= self.available.min(MAX_EXTENT)
    }

    fn change(
        &self,
        carrier: &RecordNode,
        insert: bool,
        index: usize,
        ids: &mut BTreeSet<u32>,
    ) -> Result<(Table, LineSeg, RecordNode)> {
        let cols = usize::from(self.table.cols);
        let start = index * cols;
        let mut table = self.table.clone();
        let mut changed = carrier.clone();
        let table_node = &mut changed.children[3];
        let mut line = self.line;
        if insert {
            let neighbor = index.min(self.heights.len() - 1);
            let mut new_cells = table.cells[neighbor * cols..(neighbor + 1) * cols].to_vec();
            let mut new_records = table_node.children
                [1 + 2 * neighbor * cols..1 + 2 * (neighbor + 1) * cols]
                .to_vec();
            let mut next = 1u32;
            for (cell, raw_pair) in new_cells.iter_mut().zip(new_records.chunks_exact_mut(2)) {
                while !ids.insert(next) {
                    next = next.checked_add(1).ok_or_else(unsupported)?;
                }
                let para = &mut cell.paragraphs[0];
                para.chars.clear();
                para.char_shape_runs.truncate(1);
                para.header.instance_id = next;
                let raw = &mut raw_pair[1];
                raw.data[..4].copy_from_slice(&0x8000_0001u32.to_le_bytes());
                raw.data[12..14].copy_from_slice(&1u16.to_le_bytes());
                raw.data[18..22].copy_from_slice(&next.to_le_bytes());
                raw.children.retain(|node| node.tag != tag::PARA_TEXT);
                raw.children[0].data.truncate(8);
            }
            table.cells.splice(start..start, new_cells);
            table_node
                .children
                .splice(1 + 2 * start..1 + 2 * start, new_records);
            table.row_cell_counts.insert(index, table.cols);
            table.rows += 1;
            line.line_height += self.heights[neighbor];
        } else {
            table.cells.drain(start..start + cols);
            table_node
                .children
                .drain(1 + 2 * start..1 + 2 * (start + cols));
            table.row_cell_counts.remove(index);
            table.rows -= 1;
            line.line_height -= self.heights[index];
        }
        line.text_height = line.line_height;
        line.baseline_gap = baseline(line.line_height);
        table.placement.as_mut().ok_or_else(mismatch)?.height = line.line_height;
        table.common_data[16..20].copy_from_slice(&line.line_height.to_le_bytes());
        table_node.data[20..24].copy_from_slice(&line.line_height.to_le_bytes());
        let table_record = &mut table_node.children[0].data;
        table_record[4..6].copy_from_slice(&table.rows.to_le_bytes());
        table_record.splice(
            18..18 + 2 * self.heights.len(),
            table.row_cell_counts.iter().flat_map(|n| n.to_le_bytes()),
        );
        for (i, (cell, pair)) in table
            .cells
            .iter_mut()
            .zip(table_node.children[1..].chunks_exact_mut(2))
            .enumerate()
            .skip(start)
        {
            cell.row = (i / cols) as u16;
            pair[0].data[10..12].copy_from_slice(&cell.row.to_le_bytes());
        }
        let cache = &mut changed.children[2].data;
        cache[8..12].copy_from_slice(&line.line_height.to_le_bytes());
        cache[12..16].copy_from_slice(&line.text_height.to_le_bytes());
        cache[16..20].copy_from_slice(&line.baseline_gap.to_le_bytes());
        Ok((table, line, changed))
    }
}

fn plain_cell(raw: &RecordNode, para: &Paragraph, doc: &Document) -> bool {
    if raw.tag != tag::PARA_HEADER
        || !matches!(raw.data.len(), 22 | 24)
        || para.header.chars_flags != 0x80
        || para.header.ctrl_mask != 0
        || para.header.break_type != 0
        || !matches!(para.header.tail.as_slice(), [] | [0, 0])
        || !para.controls.is_empty()
        || !para.extras.is_empty()
        || usize::from(para.para_shape.0) >= doc.header.para_shapes.len()
        || usize::from(para.style.0) >= doc.header.styles.len()
        || para.line_segs.len() != 1
        || para.char_shape_runs.first().is_none_or(|run| run.0 != 0)
        || para
            .char_shape_runs
            .iter()
            .any(|run| usize::from(run.1.0) >= doc.header.char_shapes.len())
        || raw.children.iter().any(|node| !node.children.is_empty())
    {
        return false;
    }
    let tail = match raw.children.as_slice() {
        [content, rest @ ..] if content.tag == tag::PARA_TEXT => {
            let Some((HwpChar::CharCtrl(13), chars)) = para.chars.split_last() else {
                return false;
            };
            if chars.is_empty()
                || !chars.iter().all(|c| matches!(c, HwpChar::Text(_)))
                || content.data.len() as u32 != para.wchar_len() * 2
            {
                return false;
            }
            rest
        }
        rest if para.chars.is_empty() => rest,
        _ => return false,
    };
    matches!(tail, [shape, line] if shape.tag == tag::PARA_CHAR_SHAPE
        && shape.data.len() == 8 * para.char_shape_runs.len()
        && line.tag == tag::PARA_LINE_SEG && line.data.len() == 36)
        && u16_at(&raw.data, 12).map(usize::from) == Some(para.char_shape_runs.len())
        && u16_at(&raw.data, 14) == Some(0)
        && u16_at(&raw.data, 16) == Some(1)
        && u32_at(&raw.data, 0).map(|n| n & 0x7fff_ffff) == Some(para.wchar_len().max(1))
}

fn find_carrier<'a>(
    roots: &'a [RecordNode],
    section: &Section,
    paragraph: usize,
) -> Option<(usize, &'a RecordNode)> {
    let is_para = |node: &&RecordNode| node.tag == tag::PARA_HEADER;
    if roots.iter().filter(is_para).count() != section.paragraphs.len() {
        return None;
    }
    roots
        .iter()
        .enumerate()
        .filter(|(_, node)| is_para(node))
        .nth(paragraph)
}

fn location(id: &str) -> Option<(usize, usize)> {
    let (section, paragraph) = id
        .strip_prefix('s')?
        .strip_suffix(":t0")?
        .split_once(":p")?;
    let (section, paragraph) = (
        section.parse::<usize>().ok()?,
        paragraph.parse::<usize>().ok()?,
    );
    (id == format!("s{section}:p{paragraph}:t0")).then_some((section, paragraph))
}

fn baseline(height: i32) -> i32 {
    (i64::from(height) * 85 / 100) as i32
}

fn u16_at(data: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(data.get(at..at + 2)?.try_into().ok()?))
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

fn i32_at(data: &[u8], at: usize) -> Option<i32> {
    u32_at(data, at).map(|value| value as i32)
}

fn mismatch() -> crate::ApiError {
    err(
        "semantic_mismatch",
        "저장한 한글 표의 행·셀 또는 원본 보존 내용을 확인하지 못했습니다.",
    )
}
