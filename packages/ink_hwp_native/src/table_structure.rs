use super::{
    Node, PARAGRAPH_NS, SECTION_NS, attribute_span, collect_section_ids, known_inline_whitespace,
    parse, replace_spans, xml_error, zip_xml,
};
use crate::{Result, err, invalid, text, unsupported};
use hwp_model::{Cell, Control, Document, Paragraph, Table};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

const MAX_ROWS: usize = 64;
const MAX_COLUMNS: usize = 32;
const MAX_CELLS: usize = 512;
const MAX_EXTENT: i32 = 1_000_000;

type Location = (usize, usize, usize);
type Patch = (usize, usize, String);

#[derive(Clone, Copy)]
enum Action {
    InsertRow,
    DeleteRow,
    InsertColumn,
    DeleteColumn,
}

impl Action {
    fn row(self) -> bool {
        matches!(self, Self::InsertRow | Self::DeleteRow)
    }

    fn insert(self) -> bool {
        matches!(self, Self::InsertRow | Self::InsertColumn)
    }
}

pub(crate) struct Edit {
    location: Location,
    table: Table,
    carrier_cache_removed: bool,
    xml_hash: [u8; 32],
    patches: Vec<Patch>,
    narrowed: Vec<usize>,
}

impl Edit {
    pub(crate) fn prepare(source: &Path, doc: &Document, operation: &Value) -> Result<Self> {
        if operation.as_object().is_none_or(|object| object.len() != 4) {
            return Err(invalid());
        }
        let location = location(text(operation, "id")?).ok_or_else(invalid)?;
        let action = match text(operation, "action")? {
            "insertRow" => Action::InsertRow,
            "deleteRow" => Action::DeleteRow,
            "insertColumn" => Action::InsertColumn,
            "deleteColumn" => Action::DeleteColumn,
            _ => return Err(invalid()),
        };
        let index = operation["index"]
            .as_u64()
            .and_then(|v| usize::try_from(v).ok())
            .ok_or_else(invalid)?;
        let (section, paragraph, control) = location;
        let model = doc.sections.get(section).ok_or_else(invalid)?;
        let bytes = section_xml(source, section)?;
        let root = parse(&bytes, false)?;
        let carriers = section_paragraphs(&root, model.paragraphs.len()).ok_or_else(unsupported)?;
        let carrier = *carriers.get(paragraph).ok_or_else(invalid)?;
        let (table_node, table) = paragraph_tables(carrier, &model.paragraphs[paragraph])
            .and_then(|tables| {
                tables.into_iter().find_map(|(candidate, node, table)| {
                    (candidate == control).then_some((node, table))
                })
            })
            .ok_or_else(unsupported)?;
        let grid = Grid::read(&bytes, carrier, table_node, table, doc).ok_or_else(unsupported)?;
        let band_count = if action.row() {
            grid.rows.len()
        } else {
            grid.widths.len()
        };
        if index >= band_count + usize::from(action.insert()) {
            return Err(invalid());
        }
        if !grid.supports(action) {
            return Err(unsupported());
        }
        let mut ids = BTreeSet::new();
        if action.insert() {
            collect_section_ids(&root, &mut ids);
            for other in (0..doc.sections.len()).filter(|&other| other != section) {
                let other = parse(&section_xml(source, other)?, false)?;
                collect_section_ids(&other, &mut ids);
            }
        }
        let mut next_id = 1u32;
        let allocate = || -> Result<u32> {
            while !ids.insert(next_id) {
                next_id = next_id.checked_add(1).ok_or_else(unsupported)?;
            }
            Ok(next_id)
        };
        let mut narrowed = Vec::new();
        let (table, patches, carrier_cache_removed) =
            grid.plan(&bytes, action, index, allocate, &mut narrowed)?;
        Ok(Self {
            location,
            table,
            carrier_cache_removed,
            xml_hash: Sha256::digest(&bytes).into(),
            patches,
            narrowed,
        })
    }

    pub(crate) fn section(&self) -> usize {
        self.location.0
    }

    pub(crate) fn rewrite(&self, bytes: &[u8]) -> Result<Vec<u8>> {
        if self.xml_hash != <[u8; 32]>::from(Sha256::digest(bytes)) {
            return Err(err("source_changed", "표가 있는 문서 구역이 바뀌었습니다."));
        }
        let output = replace_spans(bytes, self.patches.clone())?;
        if output.len() > 2 * 1024 * 1024 {
            return Err(unsupported());
        }
        Ok(output)
    }

    pub(crate) fn apply_expected(&self, doc: &mut Document) -> Result<()> {
        let (section, paragraph, control) = self.location;
        let carrier = &mut doc.sections[section].paragraphs[paragraph];
        let Some(Control::Table(table)) = carrier.controls.get_mut(control) else {
            return Err(mismatch());
        };
        *table = self.table.clone();
        if self.carrier_cache_removed {
            carrier.line_segs.clear();
        }
        Ok(())
    }

    pub(crate) fn verify(&self, doc: &Document) -> Result<()> {
        let (section, paragraph, control) = self.location;
        let carrier = doc
            .sections
            .get(section)
            .and_then(|s| s.paragraphs.get(paragraph))
            .ok_or_else(mismatch)?;
        if !matches!(carrier.controls.get(control), Some(Control::Table(table)) if table == &self.table)
            || (self.carrier_cache_removed && !carrier.line_segs.is_empty())
        {
            return Err(mismatch());
        }
        Ok(())
    }

    pub(crate) fn validate_render_width(
        &self,
        doc: &Document,
        fonts: &mut hwp_render::FontStore,
    ) -> Result<()> {
        for &index in &self.narrowed {
            let cell = &self.table.cells[index];
            let inner_width = (cell.width.0 - horizontal_margins(&self.table, cell)) as f32 / 100.0;
            if cell.paragraphs.iter().any(|paragraph| {
                !crate::engine::cell_content_fits(doc, fonts, paragraph, inner_width, false)
            }) {
                return Err(err(
                    "incomplete_layout",
                    "새 열 때문에 좁아지는 기존 셀의 내용이 기존 줄에 들어가지 않습니다.",
                ));
            }
        }
        Ok(())
    }
}

fn mismatch() -> crate::ApiError {
    err(
        "semantic_mismatch",
        "저장한 표의 행·열과 셀 내용이 편집 결과와 일치하지 않습니다.",
    )
}

pub(crate) fn mark_snapshot(source: &Path, doc: &Document, snapshot: &mut Value) {
    let Some(tables) = snapshot["tables"]
        .as_array_mut()
        .filter(|tables| !tables.is_empty())
    else {
        return;
    };
    let mut supported = BTreeMap::new();
    for (si, section) in doc.sections.iter().enumerate() {
        if !section
            .paragraphs
            .iter()
            .flat_map(|p| &p.controls)
            .any(|control| matches!(control, Control::Table(_)))
        {
            continue;
        }
        let Ok(bytes) = section_xml(source, si) else {
            continue;
        };
        let Ok(root) = parse(&bytes, false) else {
            continue;
        };
        let Some(carriers) = section_paragraphs(&root, section.paragraphs.len()) else {
            continue;
        };
        for (pi, (carrier, paragraph)) in carriers.into_iter().zip(&section.paragraphs).enumerate()
        {
            let Some(tables) = paragraph_tables(carrier, paragraph) else {
                continue;
            };
            for (ci, node, model) in tables {
                if let Some(grid) = Grid::read(&bytes, carrier, node, model, doc) {
                    supported.insert(format!("s{si}:p{pi}:t{ci}"), grid.capabilities());
                }
            }
        }
    }
    for table in tables {
        if let Some(capability) = table["id"].as_str().and_then(|id| supported.remove(id)) {
            table["structure"] = capability;
        }
    }
}

fn location(id: &str) -> Option<Location> {
    let (section, rest) = id.split_once(":p")?;
    let (paragraph, control) = rest.split_once(":t")?;
    let section = section.strip_prefix('s')?.parse::<usize>().ok()?;
    let paragraph = paragraph.parse::<usize>().ok()?;
    let control = control.parse::<usize>().ok()?;
    (id == format!("s{section}:p{paragraph}:t{control}")).then_some((section, paragraph, control))
}

fn section_xml(source: &Path, section: usize) -> Result<Vec<u8>> {
    zip_xml(source, &format!("Contents/section{section}.xml"))
}

fn section_paragraphs(root: &Node, count: usize) -> Option<Vec<&Node>> {
    let paragraphs: Vec<_> = root
        .children
        .iter()
        .filter(|node| node.local() == "p")
        .collect();
    (root.local() == "sec"
        && root.namespace.as_deref() == Some(SECTION_NS)
        && paragraphs.len() == count
        && paragraphs.iter().all(|node| tagged(node, "p")))
    .then_some(paragraphs)
}

fn paragraph_tables<'a>(
    carrier: &'a Node,
    paragraph: &'a Paragraph,
) -> Option<Vec<(usize, &'a Node, &'a Table)>> {
    let typed: Vec<_> = paragraph
        .controls
        .iter()
        .enumerate()
        .filter_map(|(index, control)| match control {
            Control::Table(table) => Some((index, table)),
            _ => None,
        })
        .collect();
    let mut found = Vec::new();
    carrier.find("tbl", &mut found);
    let direct = carrier
        .children
        .iter()
        .filter(|node| tagged(node, "run"))
        .flat_map(|run| run.children.iter().filter(|node| tagged(node, "tbl")));
    if found.len() != typed.len()
        || !found
            .iter()
            .map(|node| node.start)
            .eq(direct.map(|node| node.start))
    {
        return None;
    }
    Some(
        typed
            .into_iter()
            .zip(found)
            .map(|((index, table), node)| (index, node, table))
            .collect(),
    )
}

struct Grid<'a> {
    node: &'a Node,
    size: &'a Node,
    carrier_cache: Option<&'a Node>,
    model: &'a Table,
    rows: Vec<Row<'a>>,
    widths: Vec<i32>,
    heights: Vec<i32>,
}

struct Row<'a> {
    node: &'a Node,
    cells: Vec<CellXml<'a>>,
}

struct CellXml<'a> {
    node: &'a Node,
    sub: &'a Node,
    address: &'a Node,
    size: &'a Node,
    caches: Vec<&'a Node>,
}

impl<'a> Grid<'a> {
    fn read(
        bytes: &[u8],
        carrier: &'a Node,
        node: &'a Node,
        model: &'a Table,
        doc: &Document,
    ) -> Option<Self> {
        let (rows, cols) = (usize::from(model.rows), usize::from(model.cols));
        let placement = model.placement.as_ref()?;
        if !(1..=MAX_ROWS).contains(&rows)
            || !(1..=MAX_COLUMNS).contains(&cols)
            || rows * cols > MAX_CELLS
            || model.cells.len() != rows * cols
            || model.row_cell_counts != vec![model.cols; rows]
            || model.cell_spacing != 0
            || model.caption.is_some()
            || (model.repeat_header() && model.cells.iter().any(Cell::is_header))
            || !placement.treat_as_char
            || !placement.flow_with_text
            || placement.hold_anchor
            || !structural_content(bytes, node)
            || !attrs(
                node,
                &[
                    "id",
                    "zOrder",
                    "numberingType",
                    "textWrap",
                    "textFlow",
                    "lock",
                    "dropcapstyle",
                    "pageBreak",
                    "repeatHeader",
                    "rowCnt",
                    "colCnt",
                    "cellSpacing",
                    "borderFillIDRef",
                    "noAdjust",
                ],
            )
            || !zero(node, "lock")
            || raw(node, "repeatHeader").unwrap_or("0")
                != if model.repeat_header() { "1" } else { "0" }
            || number::<usize>(node, "rowCnt") != Some(rows)
            || number::<usize>(node, "colCnt") != Some(cols)
            || !node.children.iter().all(|child| {
                child.namespace.as_deref() == Some(PARAGRAPH_NS)
                    && matches!(
                        child.local(),
                        "sz" | "pos" | "outMargin" | "inMargin" | "tr"
                    )
            })
        {
            return None;
        }
        let size = one(node, "sz")?;
        let position = one(node, "pos")?;
        if !size.empty
            || !position.empty
            || !zero(size, "protect")
            || !zero(position, "allowOverlap")
            || !attrs(
                size,
                &["width", "widthRelTo", "height", "heightRelTo", "protect"],
            )
            || !attrs(
                position,
                &[
                    "treatAsChar",
                    "affectLSpacing",
                    "flowWithText",
                    "allowOverlap",
                    "holdAnchorAndSO",
                    "vertRelTo",
                    "horzRelTo",
                    "vertAlign",
                    "horzAlign",
                    "vertOffset",
                    "horzOffset",
                ],
            )
            || raw(size, "widthRelTo") != Some("ABSOLUTE")
            || raw(size, "heightRelTo") != Some("ABSOLUTE")
            || !(1..=MAX_EXTENT).contains(&placement.width)
            || !(1..=MAX_EXTENT).contains(&placement.height)
            || number(size, "width") != Some(placement.width)
            || number(size, "height") != Some(placement.height)
            || !["outMargin", "inMargin"].iter().all(|name| {
                let mut margins = node.children.iter().filter(|child| tagged(child, name));
                margins.next().is_none_or(margin) && margins.next().is_none()
            })
        {
            return None;
        }
        let mut grid = Self {
            node,
            size,
            carrier_cache: carrier_cache(bytes, carrier)?,
            model,
            rows: Vec::with_capacity(rows),
            widths: vec![0; cols],
            heights: vec![0; rows],
        };
        for (row, row_node) in node
            .children
            .iter()
            .filter(|node| tagged(node, "tr"))
            .enumerate()
        {
            if row >= rows
                || row_node.children.len() != cols
                || !attrs(row_node, &[])
                || !structural_content(bytes, row_node)
            {
                return None;
            }
            let mut cells = Vec::with_capacity(cols);
            for (col, cell_node) in row_node.children.iter().enumerate() {
                let cell = &model.cells[row * cols + col];
                let cell_xml = read_cell(bytes, cell_node, cell, row, col, doc)?;
                if row == 0 {
                    grid.widths[col] = cell.width.0;
                }
                if col == 0 {
                    grid.heights[row] = cell.height.0;
                }
                if grid.widths[col] != cell.width.0 || grid.heights[row] != cell.height.0 {
                    return None;
                }
                cells.push(cell_xml);
            }
            grid.rows.push(Row {
                node: row_node,
                cells,
            });
        }
        (grid.rows.len() == rows
            && grid.widths.iter().sum::<i32>() == placement.width
            && grid.heights.iter().sum::<i32>() == placement.height)
            .then_some(grid)
    }

    fn supports(&self, action: Action) -> bool {
        let (rows, cols) = (self.rows.len(), self.widths.len());
        match action {
            Action::InsertRow => {
                rows < MAX_ROWS
                    && (rows + 1) * cols <= MAX_CELLS
                    && self.heights.iter().sum::<i32>()
                        + self.heights.iter().copied().max().unwrap_or(0)
                        <= MAX_EXTENT
            }
            Action::DeleteRow => rows > 1,
            Action::InsertColumn => {
                cols < MAX_COLUMNS
                    && rows * (cols + 1) <= MAX_CELLS
                    && self
                        .model
                        .cells
                        .iter()
                        .all(|cell| cell.width.0 / 2 >= horizontal_margins(self.model, cell) + 500)
            }
            Action::DeleteColumn => cols > 1,
        }
    }

    fn capabilities(&self) -> Value {
        json!({"rows":self.rows.len(),"columns":self.widths.len(),
            "canInsertRow":self.supports(Action::InsertRow),"canDeleteRow":self.supports(Action::DeleteRow),
            "canInsertColumn":self.supports(Action::InsertColumn),"canDeleteColumn":self.supports(Action::DeleteColumn)})
    }

    fn plan(
        &self,
        bytes: &[u8],
        action: Action,
        index: usize,
        mut allocate: impl FnMut() -> Result<u32>,
        narrowed: &mut Vec<usize>,
    ) -> Result<(Table, Vec<Patch>, bool)> {
        let (old_rows, old_cols) = (self.rows.len(), self.widths.len());
        let mut widths = self.widths.clone();
        let mut heights = self.heights.clone();
        let mut patches = Vec::new();
        match action {
            Action::InsertRow => heights.insert(index, heights[index.min(old_rows - 1)]),
            Action::DeleteRow => {
                heights.remove(index);
                patches.push(remove(self.rows[index].node));
            }
            Action::InsertColumn => {
                let neighbor = index.min(old_cols - 1);
                let half = widths[neighbor] / 2;
                widths[neighbor] -= half;
                widths.insert(index, half);
            }
            Action::DeleteColumn => {
                let removed = widths.remove(index);
                let neighbor = index.min(widths.len() - 1);
                widths[neighbor] += removed;
                patches.extend(self.rows.iter().map(|row| remove(row.cells[index].node)));
            }
        }
        let mut table = self.model.clone();
        table.rows = heights.len() as u16;
        table.cols = widths.len() as u16;
        table.row_cell_counts = vec![table.cols; heights.len()];
        table.cells.clear();
        let carrier_cache_removed = action.row() && self.carrier_cache.is_some();
        if action.row() {
            let height = heights.iter().sum::<i32>();
            table.placement.as_mut().ok_or_else(unsupported)?.height = height;
            patches.push(attr(bytes, self.node, "rowCnt", table.rows)?);
            patches.push(attr(bytes, self.size, "height", height)?);
            patches.extend(self.carrier_cache.map(remove));
        } else {
            patches.push(attr(bytes, self.node, "colCnt", table.cols)?);
        }
        for row in 0..heights.len() {
            let (old_row, new_row) = if action.row() {
                origin(row, index, old_rows, action.insert())
            } else {
                (row, false)
            };
            let row_xml = &self.rows[old_row];
            let mut added_row_cells = String::new();
            for (col, &width) in widths.iter().enumerate() {
                let (old_col, new_col) = if action.row() {
                    (col, false)
                } else {
                    origin(col, index, old_cols, action.insert())
                };
                let cell_xml = &row_xml.cells[old_col];
                let mut cell = self.model.cells[old_row * old_cols + old_col].clone();
                let mut cell_edits = Vec::new();
                if row != old_row {
                    cell_edits.push(attr(bytes, cell_xml.address, "rowAddr", row)?);
                }
                if col != old_col {
                    cell_edits.push(attr(bytes, cell_xml.address, "colAddr", col)?);
                }
                if width != cell.width.0 {
                    cell_edits.push(attr(bytes, cell_xml.size, "width", width)?);
                }
                cell.row = row as u16;
                cell.col = col as u16;
                let changed_width = width != cell.width.0;
                let shrunk = width < cell.width.0;
                cell.width.0 = width;
                if new_row || new_col {
                    let paragraph = blank_paragraph(&cell.paragraphs[0]);
                    let text = paragraph_xml(&paragraph, allocate()?);
                    cell.paragraphs = vec![paragraph];
                    cell_edits.push((cell_xml.sub.body, cell_xml.sub.close, text));
                    let xml = cell_xml.rewrite(bytes, cell_edits)?;
                    if new_row {
                        added_row_cells.push_str(&xml);
                    } else {
                        let at = boundary(&row_xml.cells, index, |cell| cell.node);
                        patches.push((at, at, xml));
                    }
                } else {
                    if shrunk {
                        narrowed.push(table.cells.len());
                    }
                    if changed_width {
                        cell_edits.extend(cell_xml.caches.iter().map(|cache| remove(cache)));
                        for paragraph in &mut cell.paragraphs {
                            paragraph.line_segs.clear();
                        }
                    }
                    patches.extend(cell_edits);
                }
                table.cells.push(cell);
            }
            if new_row {
                let node = row_xml.node;
                let text =
                    |start, end| std::str::from_utf8(&bytes[start..end]).map_err(|_| xml_error());
                let xml = format!(
                    "{}{added_row_cells}{}",
                    text(node.start, node.body)?,
                    text(node.close, node.end)?
                );
                let at = boundary(&self.rows, index, |row| row.node);
                patches.push((at, at, xml));
            }
        }
        Ok((table, patches, carrier_cache_removed))
    }
}

fn origin(output: usize, index: usize, old_count: usize, insert: bool) -> (usize, bool) {
    if insert && output == index {
        return (index.min(old_count - 1), true);
    }
    if insert {
        (output - usize::from(output > index), false)
    } else {
        (output + usize::from(output >= index), false)
    }
}

fn boundary<'a, T>(items: &'a [T], index: usize, node: impl Fn(&'a T) -> &'a Node) -> usize {
    if let Some(item) = items.get(index) {
        node(item).start
    } else {
        node(&items[items.len() - 1]).end
    }
}

impl CellXml<'_> {
    fn rewrite(&self, bytes: &[u8], patches: Vec<Patch>) -> Result<String> {
        let offset = self.node.start;
        let patches = patches
            .into_iter()
            .map(|(start, end, text)| (start - offset, end - offset, text))
            .collect();
        String::from_utf8(replace_spans(&bytes[offset..self.node.end], patches)?)
            .map_err(|_| xml_error())
    }
}

fn blank_paragraph(model: &Paragraph) -> Paragraph {
    Paragraph {
        para_shape: model.para_shape,
        style: model.style,
        char_shape_runs: vec![(0, model.char_shape_runs[0].1)],
        ..Default::default()
    }
}

fn paragraph_xml(model: &Paragraph, id: u32) -> String {
    format!(
        concat!(
            r#"<hp:p xmlns:hp="{0}" id="{1}" paraPrIDRef="{2}" styleIDRef="{3}" pageBreak="0" columnBreak="0" merged="0">"#,
            r#"<hp:run charPrIDRef="{4}"><hp:t/></hp:run></hp:p>"#
        ),
        PARAGRAPH_NS, id, model.para_shape.0, model.style.0, model.char_shape_runs[0].1.0
    )
}

fn horizontal_margins(table: &Table, cell: &Cell) -> i32 {
    let table_has_margins = table
        .inner_margins
        .iter()
        .any(|&margin| margin > 0 && margin != u16::MAX);
    let cell_has_margins = cell.margins.iter().any(|&margin| margin > 0);
    let margin = |side| {
        let table_margin = table.inner_margins[side];
        let fallback = if table_has_margins && table_margin != u16::MAX {
            table_margin
        } else {
            510
        };
        let explicit = cell.margins[side];
        i32::from(if cell_has_margins && explicit != u16::MAX {
            explicit
        } else {
            fallback
        })
    };
    margin(0) + margin(1)
}

fn read_cell<'a>(
    bytes: &[u8],
    node: &'a Node,
    model: &Cell,
    row: usize,
    col: usize,
    doc: &Document,
) -> Option<CellXml<'a>> {
    if !tagged(node, "tc")
        || !structural_content(bytes, node)
        || !attrs(
            node,
            &[
                "name",
                "header",
                "hasMargin",
                "protect",
                "editable",
                "dirty",
                "borderFillIDRef",
            ],
        )
        || !raw(node, "name").is_none_or(str::is_empty)
        || !zero(node, "protect")
        || raw(node, "header").unwrap_or("0") != if model.is_header() { "1" } else { "0" }
        || model.row as usize != row
        || model.col as usize != col
        || model.row_span != 1
        || model.col_span != 1
        || !(1..=MAX_EXTENT).contains(&model.width.0)
        || !(1..=MAX_EXTENT).contains(&model.height.0)
    {
        return None;
    }
    let [sub, address, span, size, margins] = node.children.as_slice() else {
        return None;
    };
    if !tagged(sub, "subList")
        || !tagged(address, "cellAddr")
        || !tagged(span, "cellSpan")
        || !tagged(size, "cellSz")
        || !tagged(margins, "cellMargin")
        || !margin(margins)
        || !address.empty
        || !span.empty
        || !size.empty
        || !structural_content(bytes, sub)
        || !attrs(address, &["rowAddr", "colAddr"])
        || !attrs(span, &["rowSpan", "colSpan"])
        || !attrs(size, &["width", "height"])
        || !attrs(
            sub,
            &[
                "id",
                "textDirection",
                "lineWrap",
                "vertAlign",
                "linkListIDRef",
                "linkListNextIDRef",
                "textWidth",
                "textHeight",
                "hasTextRef",
                "hasNumRef",
            ],
        )
        || !raw(sub, "id").is_none_or(|id| id.is_empty() || id == "0")
        || !raw(sub, "textDirection").is_none_or(|direction| direction == "HORIZONTAL")
        || ![
            "linkListIDRef",
            "linkListNextIDRef",
            "textWidth",
            "textHeight",
            "hasTextRef",
            "hasNumRef",
        ]
        .iter()
        .all(|name| zero(sub, name))
        || number(address, "rowAddr") != Some(row)
        || number(address, "colAddr") != Some(col)
        || number::<u16>(span, "rowSpan") != Some(1)
        || number::<u16>(span, "colSpan") != Some(1)
        || number(size, "width") != Some(model.width.0)
        || number(size, "height") != Some(model.height.0)
        || model.paragraphs.is_empty()
        || sub.children.len() != model.paragraphs.len()
    {
        return None;
    }
    let mut caches = Vec::new();
    for (paragraph, model) in sub.children.iter().zip(&model.paragraphs) {
        if !tagged(paragraph, "p")
            || !structural_content(bytes, paragraph)
            || !model.controls.is_empty()
            || !model.extras.is_empty()
            || !attrs(
                paragraph,
                &[
                    "id",
                    "paraPrIDRef",
                    "styleIDRef",
                    "pageBreak",
                    "columnBreak",
                    "merged",
                ],
            )
            || !["pageBreak", "columnBreak", "merged"]
                .iter()
                .all(|name| zero(paragraph, name))
            || number(paragraph, "paraPrIDRef") != Some(model.para_shape.0)
            || number(paragraph, "styleIDRef") != Some(model.style.0)
            || usize::from(model.para_shape.0) >= doc.header.para_shapes.len()
            || usize::from(model.style.0) >= doc.header.styles.len()
            || !model.char_shape_runs.first().is_some_and(|(start, id)| {
                *start == 0 && usize::from(id.0) < doc.header.char_shapes.len()
            })
        {
            return None;
        }
        for child in &paragraph.children {
            if tagged(child, "linesegarray") && safe_cache(bytes, child) {
                caches.push(child);
            } else if !tagged(child, "run")
                || !structural_content(bytes, child)
                || !attrs(child, &["charPrIDRef"])
                || !number::<usize>(child, "charPrIDRef")
                    .is_some_and(|id| id < doc.header.char_shapes.len())
                || !child.children.iter().all(|node| {
                    tagged(node, "t")
                        && !node.opaque_body
                        && attrs(node, &["xml:space"])
                        && node.children.iter().all(known_inline_whitespace)
                })
            {
                return None;
            }
        }
    }
    Some(CellXml {
        node,
        sub,
        address,
        size,
        caches,
    })
}

fn carrier_cache<'a>(bytes: &[u8], carrier: &'a Node) -> Option<Option<&'a Node>> {
    let mut caches = carrier
        .children
        .iter()
        .filter(|node| node.local() == "linesegarray");
    let cache = caches.next();
    (caches.next().is_none()
        && cache.is_none_or(|node| tagged(node, "linesegarray") && safe_cache(bytes, node)))
    .then_some(cache)
}

fn safe_cache(bytes: &[u8], node: &Node) -> bool {
    attrs(node, &[])
        && structural_content(bytes, node)
        && node.children.iter().all(|child| {
            tagged(child, "lineseg")
                && child.empty
                && attrs(
                    child,
                    &[
                        "textpos",
                        "vertpos",
                        "vertsize",
                        "textheight",
                        "baseline",
                        "spacing",
                        "horzpos",
                        "horzsize",
                        "flags",
                    ],
                )
        })
}

fn tagged(node: &Node, tag: &str) -> bool {
    node.local() == tag && node.namespace.as_deref() == Some(PARAGRAPH_NS)
}

fn one<'a>(node: &'a Node, name: &str) -> Option<&'a Node> {
    let mut children = node.children.iter().filter(|child| tagged(child, name));
    let child = children.next()?;
    children.next().is_none().then_some(child)
}

fn margin(node: &Node) -> bool {
    node.empty && attrs(node, &["left", "right", "top", "bottom"])
}

fn raw<'a>(node: &'a Node, key: &str) -> Option<&'a str> {
    node.attrs.get(key).map(String::as_str)
}

fn zero(node: &Node, key: &str) -> bool {
    raw(node, key).is_none_or(|value| value == "0")
}

fn number<T: std::str::FromStr>(node: &Node, key: &str) -> Option<T> {
    raw(node, key)?.parse().ok()
}

fn attrs(node: &Node, allowed: &[&str]) -> bool {
    node.attrs
        .keys()
        .all(|key| key == "xmlns" || key.starts_with("xmlns:") || allowed.contains(&key.as_str()))
}

fn structural_content(bytes: &[u8], node: &Node) -> bool {
    if node.opaque_body {
        return false;
    }
    let mut end = node.body;
    for child in &node.children {
        if !bytes[end..child.start].iter().all(u8::is_ascii_whitespace) {
            return false;
        }
        end = child.end;
    }
    bytes[end..node.close].iter().all(u8::is_ascii_whitespace)
}

fn attr(bytes: &[u8], node: &Node, name: &str, value: impl ToString) -> Result<Patch> {
    let (start, end) = attribute_span(bytes, node, name)?;
    Ok((start, end, value.to_string()))
}

fn remove(node: &Node) -> Patch {
    (node.start, node.end, String::new())
}
