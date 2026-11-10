use super::shape_text::{
    MAX_RUNS, MAX_SLIDE_UNITS, RunKey, bounded_name, editable_text, open_tag_end, prefix,
    qualified_name, read_changes, read_index, read_slide_index, require_unprotected, text_edit,
    text_slide_choices, unique_child,
};
use super::text_box::{has_room, shape_tree};
use super::{
    A, Deck, P, R, document, edit, escape, expected_hash, ignorable_or_element, open_source, path,
    require, require_fresh_output, unsigned,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid};
use roxmltree::Node;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::ops::Range;

const TABLE_URI: &str = "http://schemas.openxmlformats.org/drawingml/2006/table";
pub(super) const MAX_DIMENSION: usize = 256;

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    let index = request
        .get("slideIndex")
        .map(read_slide_index)
        .transpose()?;
    if request.len() != 3 + usize::from(index.is_some()) {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide_count = deck.slides.len();
    let reply = if let Some(index) = index {
        let slide = deck.slides.get(index).ok_or_else(invalid)?;
        let parsed = document(&deck.xml[&slide.part])?;
        let tables: Vec<_> = editable_tables(parsed.root_element())?
            .iter()
            .map(Table::response)
            .collect();
        json!({"sourceSha256":sha,"slideCount":slide_count,"slideIndex":index,"tables":tables})
    } else {
        json!({"sourceSha256":sha,"slideCount":slide_count,"slides":text_slide_choices(&deck)})
    };
    open_source(source_path, sha)?;
    Ok(reply)
}

pub(crate) fn replace(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 9 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = read_slide_index(request.get("slideIndex").ok_or_else(invalid)?)?;
    let shape_id = read_index(request.get("shapeId"))
        .filter(|id| *id > 0)
        .ok_or_else(invalid)?;
    let coordinate = |field| {
        read_index(request.get(field))
            .map(|index| index as usize)
            .filter(|&index| index < MAX_DIMENSION)
            .ok_or_else(invalid)
    };
    let row = coordinate("row")?;
    let column = coordinate("column")?;
    let changes = read_changes(request.get("changes"))?;

    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide = deck.slides.get(index).ok_or_else(invalid)?;
    let xml = &deck.xml[&slide.part];
    let parsed = document(xml)?;
    let tables = editable_tables(parsed.root_element())?;
    let cell = tables
        .iter()
        .find(|table| table.id == shape_id)
        .and_then(|table| {
            table
                .cells
                .iter()
                .find(|cell| (cell.row, cell.column) == (row, column))
        })
        .ok_or_else(invalid)?;
    let mut replacements = Vec::new();
    for (&key, &value) in &changes {
        let run = cell
            .runs
            .iter()
            .find(|run| run.key == key)
            .ok_or_else(invalid)?;
        if run.text != value {
            replacements.push(match &run.target {
                TextTarget::Existing(span) => text_edit(xml, span.clone(), value)?,
                TextTarget::Empty { paragraph, ending } => {
                    insert_empty_run(xml, paragraph.clone(), ending.clone(), value)?
                }
            });
        }
    }
    if replacements.is_empty() {
        return Err(invalid());
    }
    let changed = edit(xml, replacements)?;
    require(has_room(
        &deck,
        xml,
        changed.len().saturating_sub(xml.len()),
    ))?;
    let mut edits = PackageEdits::default();
    edits.changed.insert(slide.part.clone(), changed);
    let output_sha = deck.write_candidate(
        source,
        (source_path, output_path),
        sha,
        &edits,
        |verified| {
            let selected = verified.slides.get(index).ok_or_else(invalid_zip)?;
            require(
                verified.slides.len() == deck.slides.len()
                    && selected.part == slide.part
                    && selected.identity == slide.identity
                    && selected.hidden == slide.hidden,
            )?;
            let candidate = document(&verified.xml[&slide.part])?;
            let updated = editable_tables(candidate.root_element())?;
            verify_cells(&tables, &updated, (shape_id, row, column), &changes)
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":index,"shapeId":shape_id,"row":row,"column":column,
    }))
}

struct Table<'a> {
    id: u32,
    name: &'a str,
    rows: usize,
    columns: usize,
    cells: Vec<Cell<'a>>,
}

impl Table<'_> {
    fn response(&self) -> Value {
        let cells: Vec<_> = self
            .cells
            .iter()
            .map(|cell| {
                let runs: Vec<_> = cell.runs.iter().map(|run| {
                json!({"paragraphIndex":run.key.0,"runIndex":run.key.1,"text":run.text})
            }).collect();
                json!({"row":cell.row,"column":cell.column,"runs":runs})
            })
            .collect();
        json!({"shapeId":self.id,"name":self.name,"rows":self.rows,"columns":self.columns,"cells":cells})
    }
}

struct Cell<'a> {
    row: usize,
    column: usize,
    runs: Vec<CellRun<'a>>,
}

struct CellRun<'a> {
    key: RunKey,
    text: &'a str,
    target: TextTarget,
}

enum TextTarget {
    Existing(Range<usize>),
    Empty {
        paragraph: Range<usize>,
        ending: Option<Range<usize>>,
    },
}

fn editable_tables<'a, 'input>(root: Node<'a, 'input>) -> ApiResult<Vec<Table<'a>>> {
    let tree = shape_tree(root)?;
    let mut identities = BTreeMap::new();
    for identity in tree
        .descendants()
        .filter(|node| node.has_tag_name((P, "cNvPr")))
    {
        let id = unsigned(identity.attribute("id").ok_or_else(invalid_zip)?)?;
        identities
            .entry(id)
            .and_modify(|unique| *unique = false)
            .or_insert(true);
    }
    let mut tables = Vec::new();
    let mut run_count = 0;
    let mut text_units = 0;
    for frame in tree
        .children()
        .filter(|node| node.has_tag_name((P, "graphicFrame")))
    {
        let Some((identity, table)) = table_in_frame(frame) else {
            continue;
        };
        let id = unsigned(identity.attribute("id").ok_or_else(invalid_zip)?)?;
        if id == 0 || identities.get(&id) != Some(&true) {
            continue;
        }
        let Some(layout) = table_layout(table) else {
            continue;
        };
        let mut cells = Vec::new();
        for (position, (node, merge)) in layout.cells.into_iter().enumerate() {
            if merge.covered() || merge.rows != 1 || merge.columns != 1 {
                continue;
            }
            let runs = cell_runs(node)?;
            if !runs.is_empty() {
                run_count += runs.len();
                text_units += runs
                    .iter()
                    .map(|run| run.text.encode_utf16().count())
                    .sum::<usize>();
                require(run_count <= MAX_RUNS && text_units <= MAX_SLIDE_UNITS)?;
                cells.push(Cell {
                    row: position / layout.columns,
                    column: position % layout.columns,
                    runs,
                });
            }
        }
        if !cells.is_empty() {
            tables.push(Table {
                id,
                name: bounded_name(identity.attribute("name").unwrap_or("")),
                rows: layout.rows,
                columns: layout.columns,
                cells,
            });
        }
    }
    Ok(tables)
}

pub(super) fn table_in_frame<'a, 'input>(
    frame: Node<'a, 'input>,
) -> Option<(Node<'a, 'input>, Node<'a, 'input>)> {
    let graphic = unique_child(frame, A, "graphic").ok()??;
    let data = unique_child(graphic, A, "graphicData").ok()??;
    if data.attribute("uri") != Some(TABLE_URI)
        || data.children().filter(Node::is_element).count() != 1
    {
        return None;
    }
    let table = unique_child(data, A, "tbl").ok()??;
    let properties = unique_child(frame, P, "nvGraphicFramePr").ok()??;
    let identity = unique_child(properties, P, "cNvPr").ok()??;
    Some((identity, table))
}

pub(super) struct TableLayout<'a, 'input> {
    pub(super) rows: usize,
    pub(super) columns: usize,
    pub(super) cells: Vec<(Node<'a, 'input>, Merge)>,
}

pub(super) struct Merge {
    pub(super) rows: usize,
    pub(super) columns: usize,
    horizontal: bool,
    vertical: bool,
}

impl Merge {
    fn read(node: Node) -> Option<Self> {
        let span = |key| {
            node.attribute(key)
                .unwrap_or("1")
                .parse()
                .ok()
                .filter(|value| (1..=MAX_DIMENSION).contains(value))
        };
        let flag = |key| match node.attribute(key) {
            None | Some("0" | "false") => Some(false),
            Some("1" | "true") => Some(true),
            _ => None,
        };
        Some(Self {
            rows: span("rowSpan")?,
            columns: span("gridSpan")?,
            horizontal: flag("hMerge")?,
            vertical: flag("vMerge")?,
        })
    }

    pub(super) fn covered(&self) -> bool {
        self.horizontal || self.vertical
    }
}

pub(super) fn table_layout<'a, 'input>(table: Node<'a, 'input>) -> Option<TableLayout<'a, 'input>> {
    let grid = unique_child(table, A, "tblGrid").ok()??;
    unique_child(table, A, "tblPr").ok()?;
    if !grid
        .children()
        .filter(Node::is_element)
        .all(|node| node.has_tag_name((A, "gridCol")))
        || !table.children().filter(Node::is_element).all(|node| {
            node.has_tag_name((A, "tblGrid"))
                || node.has_tag_name((A, "tblPr"))
                || node.has_tag_name((A, "tr"))
        })
    {
        return None;
    }
    let columns = grid.children().filter(Node::is_element).count();
    let rows = table
        .children()
        .filter(|node| node.has_tag_name((A, "tr")))
        .count();
    if !(1..=MAX_DIMENSION).contains(&rows) || !(1..=MAX_DIMENSION).contains(&columns) {
        return None;
    }
    let mut cells = Vec::with_capacity(rows * columns);
    for row in table.children().filter(|node| node.has_tag_name((A, "tr"))) {
        let count_before = cells.len();
        let mut children = row.children().filter(Node::is_element);
        for node in children.by_ref().take(columns) {
            if !node.has_tag_name((A, "tc")) {
                return None;
            }
            cells.push((node, Merge::read(node)?));
        }
        if cells.len() - count_before != columns
            || children
                .next()
                .is_some_and(|node| !node.has_tag_name((A, "extLst")))
            || children.next().is_some()
        {
            return None;
        }
    }
    let layout = TableLayout {
        rows,
        columns,
        cells,
    };
    valid_partition(&layout).then_some(layout)
}

fn valid_partition(layout: &TableLayout<'_, '_>) -> bool {
    let (rows, columns) = (layout.rows, layout.columns);
    let mut owners = vec![None; layout.cells.len()];
    for (position, (_, merge)) in layout.cells.iter().enumerate() {
        let (row, column) = (position / columns, position % columns);
        if row + merge.rows > rows || column + merge.columns > columns {
            return false;
        }
        if merge.covered() {
            continue;
        }
        for y in row..row + merge.rows {
            for x in column..column + merge.columns {
                if owners[y * columns + x].replace(position).is_some() {
                    return false;
                }
            }
        }
    }
    layout
        .cells
        .iter()
        .zip(owners)
        .enumerate()
        .all(|(position, ((_, merge), owner))| {
            let Some(owner) = owner else {
                return false;
            };
            if !merge.covered() {
                return position == owner;
            }
            let (row, column) = (position / columns, position % columns);
            let (anchor_row, anchor_column) = (owner / columns, owner % columns);
            let anchor = &layout.cells[owner].1;
            merge.horizontal == (column > anchor_column)
                && merge.vertical == (row > anchor_row)
                && row + merge.rows <= anchor_row + anchor.rows
                && column + merge.columns <= anchor_column + anchor.columns
        })
}

fn cell_runs<'a>(cell: Node<'a, '_>) -> ApiResult<Vec<CellRun<'a>>> {
    let Some(body) = unique_child(cell, A, "txBody").ok().flatten() else {
        return Ok(Vec::new());
    };
    if !body.children().filter(Node::is_element).all(|node| {
        node.has_tag_name((A, "bodyPr"))
            || node.has_tag_name((A, "lstStyle"))
            || node.has_tag_name((A, "p"))
    }) {
        return Ok(Vec::new());
    }
    let mut runs = Vec::new();
    for (paragraph_index, paragraph) in body
        .children()
        .filter(|node| node.has_tag_name((A, "p")))
        .enumerate()
    {
        let mut items = paragraph
            .children()
            .filter(|node| node.has_tag_name((A, "r")))
            .peekable();
        if items.peek().is_none() {
            if let Some(target) = empty_paragraph(paragraph) {
                runs.push(CellRun {
                    key: (paragraph_index as u32, 0),
                    text: "",
                    target,
                });
                require(runs.len() <= MAX_RUNS)?;
            }
            continue;
        }
        for (run_index, node) in items.enumerate() {
            if let Ok(Some(text)) = editable_text(node) {
                runs.push(CellRun {
                    key: (paragraph_index as u32, run_index as u32),
                    text: text.text().unwrap_or(""),
                    target: TextTarget::Existing(text.range()),
                });
                require(runs.len() <= MAX_RUNS)?;
            }
        }
    }
    Ok(runs)
}

fn empty_paragraph(paragraph: Node) -> Option<TextTarget> {
    if !paragraph.children().all(ignorable_or_element) {
        return None;
    }
    let mut children = paragraph.children().filter(Node::is_element).peekable();
    if children
        .peek()
        .is_some_and(|node| node.has_tag_name((A, "pPr")))
    {
        children.next();
    }
    let ending = children.next();
    if children.next().is_some()
        || ending.is_some_and(|node| {
            !node.has_tag_name((A, "endParaRPr"))
                || node.descendants().any(|item| {
                    item.has_tag_name((A, "hlinkClick"))
                        || item.has_tag_name((A, "hlinkMouseOver"))
                        || item.has_tag_name((A, "extLst"))
                        || item.attributes().any(|attr| attr.namespace() == Some(R))
                })
        })
    {
        return None;
    }
    Some(TextTarget::Empty {
        paragraph: paragraph.range(),
        ending: ending.map(|node| node.range()),
    })
}

fn insert_empty_run(
    xml: &str,
    paragraph: Range<usize>,
    ending: Option<Range<usize>>,
    value: &str,
) -> ApiResult<(Range<usize>, String)> {
    let raw = xml.get(paragraph.clone()).ok_or_else(invalid_zip)?;
    let name = qualified_name(raw)?;
    let ns = prefix(name);
    let properties = ending
        .as_ref()
        .map(|span| -> ApiResult<_> {
            let raw = xml.get(span.clone()).ok_or_else(invalid_zip)?;
            let end_name = qualified_name(raw)?;
            let end_ns = prefix(end_name);
            let start = 1 + end_name.len();
            Ok(if let Some(close) = raw.rfind("</") {
                format!("<{end_ns}rPr{}</{end_ns}rPr>", &raw[start..close])
            } else {
                format!("<{end_ns}rPr{}", &raw[start..])
            })
        })
        .transpose()?
        .unwrap_or_default();
    let text = escape(value);
    let run = format!("<{ns}r>{properties}<{ns}t xml:space=\"preserve\">{text}</{ns}t></{ns}r>");
    let opening_end = open_tag_end(raw).ok_or_else(invalid_zip)?;
    if raw.as_bytes().get(opening_end.wrapping_sub(1)) == Some(&b'/') {
        return Ok((
            paragraph.start + opening_end - 1..paragraph.start + opening_end + 1,
            format!(">{run}</{name}>"),
        ));
    }
    let position = if let Some(ending) = ending {
        ending.start
    } else {
        paragraph.start + raw.rfind("</").ok_or_else(invalid_zip)?
    };
    Ok((position..position, run))
}

fn verify_cells(
    before: &[Table<'_>],
    after: &[Table<'_>],
    target: (u32, usize, usize),
    changes: &BTreeMap<RunKey, &str>,
) -> ApiResult<()> {
    require(before.len() == after.len())?;
    for (before, after) in before.iter().zip(after) {
        require(
            (
                before.id,
                before.name,
                before.rows,
                before.columns,
                before.cells.len(),
            ) == (
                after.id,
                after.name,
                after.rows,
                after.columns,
                after.cells.len(),
            ),
        )?;
        for (previous, next) in before.cells.iter().zip(&after.cells) {
            require(
                (previous.row, previous.column, previous.runs.len())
                    == (next.row, next.column, next.runs.len()),
            )?;
            for (previous_run, next_run) in previous.runs.iter().zip(&next.runs) {
                let expected = if (before.id, previous.row, previous.column) == target {
                    changes
                        .get(&previous_run.key)
                        .copied()
                        .unwrap_or(previous_run.text)
                } else {
                    previous_run.text
                };
                require(previous_run.key == next_run.key && expected == next_run.text)?;
            }
        }
    }
    Ok(())
}
