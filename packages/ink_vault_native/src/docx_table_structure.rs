//! Changes the grid of one regular, direct WordprocessingML body table.
use super::body_text::{Ranges, body_flow_table_count, ordered_children, paragraph::inspect_marks};
use super::table::preview;
use super::{
    ApiResult, Attribute, Node, Package, PackageEdits, R, W, children, document, edit, escape,
    expected_hash, invalid, invalid_zip, open_source, requested_path, require,
    require_fresh_output, single_child, unsupported_document, verify_source,
};
use serde_json::{Map, Value, json};
use std::{collections::BTreeSet, fmt::Write as _, ops::Range};

const MAX_TABLES: usize = 512;
const MAX_ROWS: usize = 64;
const MAX_COLUMNS: usize = 32;
const MAX_CELLS: usize = 512;
const MAX_WIDTH: u32 = 1_000_000;

type Element<'a, 'input> = Node<'a, 'input>;
type XmlEdit = (Range<usize>, String);

struct Width<'a, 'input> {
    attribute: Attribute<'a, 'input>,
    value: u32,
}

impl<'a, 'input> Width<'a, 'input> {
    fn read(node: Element<'a, 'input>) -> Option<Self> {
        let attribute = node.attribute_node((W, "w"))?;
        let value = attribute.value().parse().ok()?;
        (1..=MAX_WIDTH)
            .contains(&value)
            .then_some(Self { attribute, value })
    }

    fn set(&self, value: u32) -> XmlEdit {
        (self.attribute.range_value(), value.to_string())
    }
}

struct Column<'a, 'input> {
    node: Element<'a, 'input>,
    width: Width<'a, 'input>,
}

struct Cell<'a, 'input> {
    node: Element<'a, 'input>,
    width: Option<Width<'a, 'input>>,
}

struct Row<'a, 'input> {
    node: Element<'a, 'input>,
    cells: Vec<Cell<'a, 'input>>,
}

struct Table<'a, 'input> {
    node: Element<'a, 'input>,
    grid: Vec<Column<'a, 'input>>,
    rows: Vec<Row<'a, 'input>>,
    width_kind: Option<&'a str>,
}

impl<'a, 'input> Table<'a, 'input> {
    fn read(node: Element<'a, 'input>) -> Option<Self> {
        if !ordered_children(node, &["tblPr", "tblGrid"], "tr") || !regular_markup(node) {
            return None;
        }
        let grid_node = single_child(node, W, "tblGrid").ok()?;
        if !ordered_children(grid_node, &[], "gridCol") {
            return None;
        }
        let grid = children(grid_node, W, "gridCol")
            .take(MAX_COLUMNS + 1)
            .map(|node| {
                if node.first_element_child().is_some() {
                    return None;
                }
                Some(Column {
                    node,
                    width: Width::read(node)?,
                })
            })
            .collect::<Option<Vec<_>>>()?;
        let row_nodes = children(node, W, "tr")
            .take(MAX_ROWS + 1)
            .collect::<Vec<_>>();
        if !valid_shape(row_nodes.len(), grid.len()) {
            return None;
        }
        let mut width_kind = None;
        let mut rows: Vec<Row<'_, '_>> = Vec::with_capacity(row_nodes.len());
        for row in row_nodes {
            if !ordered_children(row, &["trPr"], "tc") {
                return None;
            }
            let mut cells = Vec::with_capacity(grid.len());
            for cell in children(row, W, "tc").take(grid.len() + 1) {
                if !ordered_children(cell, &["tcPr"], "p") {
                    return None;
                }
                let properties = children(cell, W, "tcPr").next();
                if properties
                    .is_some_and(|properties| children(properties, W, "gridSpan").count() > 1)
                {
                    return None;
                }
                let preferred = properties
                    .into_iter()
                    .flat_map(|properties| children(properties, W, "tcW"))
                    .collect::<Vec<_>>();
                let width = match preferred.as_slice() {
                    [] => None,
                    [preferred] if preferred.first_element_child().is_none() => {
                        let kind = preferred.attribute((W, "type"))?;
                        match kind {
                            "auto" if preferred.attribute((W, "w")) == Some("0") => None,
                            "dxa" | "pct" if width_kind.is_none_or(|current| current == kind) => {
                                width_kind = Some(kind);
                                Some(Width::read(*preferred)?)
                            }
                            _ => return None,
                        }
                    }
                    _ => return None,
                };
                cells.push(Cell { node: cell, width });
            }
            if cells.len() != grid.len() {
                return None;
            }
            rows.push(Row { node: row, cells });
        }
        // One column model must describe all physical rows before we can split or join it.
        for row in &rows {
            for (cell, first) in row.cells.iter().zip(&rows[0].cells) {
                if cell.width.is_some() != width_kind.is_some()
                    || width_value(&cell.width) != width_value(&first.width)
                {
                    return None;
                }
            }
        }
        Some(Self {
            node,
            grid,
            rows,
            width_kind,
        })
    }

    fn preview(&self) -> String {
        self.rows
            .iter()
            .flat_map(|row| &row.cells)
            .flat_map(|cell| children(cell.node, W, "p"))
            .map(preview)
            .find(|text| !text.is_empty())
            .unwrap_or_default()
    }

    fn preferred_widths(&self) -> Vec<u32> {
        self.rows[0]
            .cells
            .iter()
            .filter_map(|cell| width_value(&cell.width))
            .collect()
    }
}

fn width_value(width: &Option<Width<'_, '_>>) -> Option<u32> {
    width.as_ref().map(|width| width.value)
}

fn valid_shape(rows: usize, columns: usize) -> bool {
    (1..=MAX_ROWS).contains(&rows)
        && (1..=MAX_COLUMNS).contains(&columns)
        && rows * columns <= MAX_CELLS
}

fn regular_markup(table: Element<'_, '_>) -> bool {
    table.descendants().filter(Node::is_element).all(|node| {
        if node.tag_name().namespace() != Some(W)
            || node
                .attributes()
                .any(|attribute| attribute.namespace() == Some(R))
            || node.children().any(|child| child.is_pi())
        {
            return false;
        }
        let name = node.tag_name().name();
        match name {
            "tbl" => node == table,
            "gridSpan" => {
                node.attribute((W, "val")) == Some("1")
                    && node
                        .parent()
                        .is_some_and(|parent| parent.has_tag_name((W, "tcPr")))
            }
            "tblCellSpacing" => node.attribute((W, "w")) == Some("0"),
            "vMerge" | "hMerge" | "gridBefore" | "gridAfter" | "wBefore" | "wAfter" | "tblpPr"
            | "tblHeader" | "bidiVisual" | "sdt" | "customXml" | "smartTag" | "sectPr" | "ins"
            | "del" | "moveFrom" | "moveTo" | "cellIns" | "cellDel" | "cellMerge" | "fldChar"
            | "fldSimple" | "instrText" | "delInstrText" | "hyperlink" | "drawing" | "pict"
            | "object" | "subDoc" | "contentPart" | "altChunk" | "bookmarkStart"
            | "bookmarkEnd" | "permStart" | "permEnd" | "commentReference" | "proofErr"
            | "annotationRef" | "footnoteReference" | "endnoteReference" => false,
            _ => {
                !name.ends_with("Change")
                    && !name.ends_with("RangeStart")
                    && !name.ends_with("RangeEnd")
            }
        }
    })
}

fn body_tables<'a, 'input>(
    package: &Package,
    root: Element<'a, 'input>,
) -> ApiResult<Vec<(usize, Table<'a, 'input>)>> {
    if package.track_revisions {
        return Err(unsupported_document());
    }
    let body = single_child(root, W, "body")?;
    if let Some(section) = children(body, W, "sectPr").next() {
        require(body.last_element_child() == Some(section))?;
    }
    let mut ranges = Ranges::default();
    let mut marks = BTreeSet::new();
    let mut ordinal = 0;
    let mut tables = Vec::new();
    for block in body.children().filter(Node::is_element) {
        let boundary_closed = marks.is_empty();
        let excluded = ranges.inspect(block)?;
        inspect_marks(block, &mut marks)?;
        if ordinal < MAX_TABLES
            && block.has_tag_name((W, "tbl"))
            && !excluded
            && boundary_closed
            && marks.is_empty()
            && let Some(table) = Table::read(block)
        {
            tables.push((ordinal, table));
        }
        ordinal += body_flow_table_count(block)?;
    }
    if !ranges.is_closed() || !marks.is_empty() {
        return Err(unsupported_document());
    }
    Ok(tables)
}

#[derive(Clone, Copy)]
enum Action {
    InsertRow,
    DeleteRow,
    InsertColumn,
    DeleteColumn,
}

impl Action {
    fn read(value: Option<&Value>) -> ApiResult<Self> {
        match value.and_then(Value::as_str) {
            Some("insertRow") => Ok(Self::InsertRow),
            Some("deleteRow") => Ok(Self::DeleteRow),
            Some("insertColumn") => Ok(Self::InsertColumn),
            Some("deleteColumn") => Ok(Self::DeleteColumn),
            _ => Err(invalid()),
        }
    }

    fn is_insert(self) -> bool {
        matches!(self, Self::InsertRow | Self::InsertColumn)
    }

    fn is_row(self) -> bool {
        matches!(self, Self::InsertRow | Self::DeleteRow)
    }
}

struct Change {
    action: Action,
    index: usize,
    anchor: Option<usize>,
    rows: Vec<Option<usize>>,
    columns: Vec<Option<usize>>,
    grid_widths: Vec<u32>,
    cell_widths: Vec<u32>,
}

impl Change {
    fn new(
        table: &Table<'_, '_>,
        action: Action,
        index: usize,
        anchor: Option<usize>,
    ) -> ApiResult<Self> {
        let mut rows = (0..table.rows.len()).map(Some).collect::<Vec<_>>();
        let mut columns = (0..table.grid.len()).map(Some).collect::<Vec<_>>();
        let band = if action.is_row() {
            &mut rows
        } else {
            &mut columns
        };
        let count = band.len();
        if action.is_insert()
            && anchor
                .is_some_and(|anchor| anchor < count && (index == anchor || index == anchor + 1))
        {
            band.insert(index, None);
        } else if !action.is_insert() && anchor.is_none() && count > 1 && index < count {
            band.remove(index);
        } else {
            return Err(invalid());
        }
        if !valid_shape(rows.len(), columns.len()) {
            return Err(invalid());
        }
        let mut grid_widths = table
            .grid
            .iter()
            .map(|column| column.width.value)
            .collect::<Vec<_>>();
        let mut cell_widths = table.preferred_widths();
        if !action.is_row() {
            adjust_widths(&mut grid_widths, index, anchor)?;
            if !cell_widths.is_empty() {
                adjust_widths(&mut cell_widths, index, anchor)?;
            }
        }
        Ok(Self {
            action,
            index,
            anchor,
            rows,
            columns,
            grid_widths,
            cell_widths,
        })
    }

    fn edits(&self, table: &Table<'_, '_>, source: &str) -> Vec<XmlEdit> {
        match self.action {
            Action::InsertRow => {
                let offset = insertion_offset(&table.rows, self.index, |row| row.node.range());
                let anchor = &table.rows[self.anchor.expect("row insertion has an anchor")];
                let (name, mut row) = styled_element_start(anchor.node, "tr");
                if let Some(properties) = children(anchor.node, W, "trPr").next() {
                    row.push_str(&source[properties.range()]);
                }
                for (column, cell) in anchor.cells.iter().enumerate() {
                    row.push_str(&self.blank_cell(cell, source, column));
                }
                write!(row, "</{name}>").expect("write to String");
                vec![(offset..offset, row)]
            }
            Action::DeleteRow => vec![(table.rows[self.index].node.range(), String::new())],
            Action::InsertColumn | Action::DeleteColumn => self.column_edits(table, source),
        }
    }

    fn column_edits(&self, table: &Table<'_, '_>, source: &str) -> Vec<XmlEdit> {
        let mut edits = Vec::new();
        if self.action.is_insert() {
            let offset = insertion_offset(&table.grid, self.index, |column| column.node.range());
            edits.push((
                offset..offset,
                format!(
                    "<w:gridCol xmlns:w=\"{W}\" w:w=\"{}\"/>",
                    self.grid_widths[self.index]
                ),
            ));
        } else {
            edits.push((table.grid[self.index].node.range(), String::new()));
        }
        for (new, old) in self.columns.iter().enumerate() {
            if let Some(old) = *old {
                let width = &table.grid[old].width;
                if width.value != self.grid_widths[new] {
                    edits.push(width.set(self.grid_widths[new]));
                }
            }
        }
        for row in &table.rows {
            if let Some(anchor) = self.anchor {
                let offset = insertion_offset(&row.cells, self.index, |cell| cell.node.range());
                edits.push((
                    offset..offset,
                    self.blank_cell(&row.cells[anchor], source, self.index),
                ));
            } else {
                edits.push((row.cells[self.index].node.range(), String::new()));
            }
            for (new, old) in self.columns.iter().enumerate() {
                if let Some(old) = *old
                    && let Some(width) = &row.cells[old].width
                    && width.value != self.cell_widths[new]
                {
                    edits.push(width.set(self.cell_widths[new]));
                }
            }
        }
        edits
    }

    fn blank_cell(&self, anchor: &Cell<'_, '_>, source: &str, column: usize) -> String {
        let (name, mut cell) = styled_element_start(anchor.node, "tc");
        if let Some(properties) = children(anchor.node, W, "tcPr").next() {
            let range = properties.range();
            if let Some(width) = &anchor.width {
                let width_range = width.attribute.range_value();
                cell.push_str(&source[range.start..width_range.start]);
                write!(cell, "{}", self.cell_widths[column]).expect("write to String");
                cell.push_str(&source[width_range.end..range.end]);
            } else {
                cell.push_str(&source[range]);
            }
        }
        if let Some(paragraph) = children(anchor.node, W, "p").next() {
            let (paragraph_name, paragraph_start) = styled_element_start(paragraph, "p");
            cell.push_str(&paragraph_start);
            if let Some(properties) = children(paragraph, W, "pPr").next()
                && children(properties, W, "numPr").next().is_none()
            {
                cell.push_str(&source[properties.range()]);
            }
            write!(cell, "</{paragraph_name}>").expect("write to String");
        }
        write!(cell, "</{name}>").expect("write to String");
        cell
    }

    fn verify(
        &self,
        before: &Table<'_, '_>,
        after: &Table<'_, '_>,
        source: &str,
        output: &str,
    ) -> ApiResult<()> {
        let original = before.node.range();
        let changed = after.node.range();
        require(source[..original.start] == output[..changed.start])?;
        require(source[original.end..] == output[changed.end..])?;
        require(after.rows.len() == self.rows.len() && after.grid.len() == self.columns.len())?;
        require(after.width_kind == before.width_kind)?;
        require(
            after
                .grid
                .iter()
                .map(|column| column.width.value)
                .eq(self.grid_widths.iter().copied()),
        )?;
        require(after.preferred_widths() == self.cell_widths)?;
        for (row, original_row) in after.rows.iter().zip(&self.rows) {
            for (cell, original_column) in row.cells.iter().zip(&self.columns) {
                if let (Some(row), Some(column)) = (*original_row, *original_column) {
                    let original = &before.rows[row].cells[column];
                    require(cell_slices(source, original) == cell_slices(output, cell))?;
                } else {
                    let mut paragraphs = children(cell.node, W, "p");
                    let paragraph = paragraphs.next().ok_or_else(invalid_zip)?;
                    require(
                        paragraph
                            .children()
                            .all(|node| node.has_tag_name((W, "pPr")))
                            && paragraphs.next().is_none(),
                    )?;
                }
            }
        }
        Ok(())
    }
}

fn adjust_widths(widths: &mut Vec<u32>, index: usize, anchor: Option<usize>) -> ApiResult<()> {
    if let Some(anchor) = anchor {
        // Duplicate the anchor's share and re-fit the cumulative column boundaries to the old total.
        let total = widths.iter().map(|&width| u64::from(width)).sum::<u64>();
        let duplicated = widths[anchor];
        widths.insert(index, duplicated);
        let mut cumulative = 0;
        let mut prior = 0;
        for width in widths.iter_mut() {
            cumulative += u64::from(*width);
            let position = cumulative * total / (total + u64::from(duplicated));
            *width = (position - prior) as u32;
            prior = position;
        }
    } else {
        // Give every survivor an equal share of the removed width, including its rounding remainder.
        let removed = widths.remove(index);
        let count = widths.len() as u32;
        let mut prior = 0;
        for (column, width) in widths.iter_mut().enumerate() {
            let cumulative = removed * (column as u32 + 1) / count;
            *width += cumulative - prior;
            prior = cumulative;
        }
    }
    if widths.iter().any(|width| !(1..=MAX_WIDTH).contains(width)) {
        return Err(unsupported_document());
    }
    Ok(())
}

// A copied property can use a prefix declared only on its anchor. Bind that same
// context on the fresh element while avoiding any alias already used by the source.
fn styled_element_start(anchor: Element<'_, '_>, local: &str) -> (String, String) {
    let mut alias = "piv".to_owned();
    while anchor
        .namespaces()
        .any(|namespace| namespace.name() == Some(&alias))
    {
        alias.push('_');
    }
    let name = format!("{alias}:{local}");
    let mut start = format!("<{name} xmlns:{alias}=\"{W}\"");
    for namespace in anchor
        .namespaces()
        .filter(|namespace| namespace.name() != Some("xml"))
    {
        if let Some(prefix) = namespace.name() {
            write!(start, " xmlns:{prefix}=\"{}\"", escape(namespace.uri()))
                .expect("write to String");
        } else {
            write!(start, " xmlns=\"{}\"", escape(namespace.uri())).expect("write to String");
        }
    }
    start.push('>');
    (name, start)
}

fn insertion_offset<T>(band: &[T], index: usize, range: impl Fn(&T) -> Range<usize>) -> usize {
    if index < band.len() {
        range(&band[index]).start
    } else {
        range(&band[band.len() - 1]).end
    }
}

fn cell_slices<'a>(xml: &'a str, cell: &Cell<'_, '_>) -> (&'a str, &'a str) {
    let whole = cell.node.range();
    if let Some(width) = &cell.width {
        let width = width.attribute.range_value();
        (&xml[whole.start..width.start], &xml[width.end..whole.end])
    } else {
        (&xml[whole], "")
    }
}

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let path = requested_path(request.get("sourcePath"), true)?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(&path, sha)?;
    let package = Package::read(&mut source)?;
    let xml = document(&package.main_xml)?;
    let tables = body_tables(&package, xml.root_element())?
        .iter()
        .map(|(index, table)| {
            json!({
                "tableIndex":index,"rowCount":table.rows.len(),"columnCount":table.grid.len(),
                "preview":table.preview(),
            })
        })
        .collect::<Vec<_>>();
    verify_source(&mut source, &path, sha)?;
    Ok(json!({"sourceSha256":sha,"tables":tables}))
}

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    let action = Action::read(request.get("action"))?;
    if request.len() != 7 + usize::from(action.is_insert()) {
        return Err(invalid());
    }
    let source_path = requested_path(request.get("sourcePath"), true)?;
    let output_path = requested_path(request.get("outputPath"), true)?;
    if source_path.parent() != output_path.parent() {
        return Err(invalid());
    }
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = request
        .get("index")
        .and_then(Value::as_u64)
        .filter(|&value| value <= MAX_ROWS as u64)
        .ok_or_else(invalid)? as usize;
    let table_index = request
        .get("tableIndex")
        .and_then(Value::as_u64)
        .filter(|&value| value < MAX_TABLES as u64)
        .ok_or_else(invalid)? as usize;
    let anchor = if action.is_insert() {
        Some(
            request
                .get("anchorIndex")
                .and_then(Value::as_u64)
                .filter(|&value| value < MAX_ROWS as u64)
                .ok_or_else(invalid)? as usize,
        )
    } else {
        None
    };
    let mut source = open_source(&source_path, sha)?;
    require_fresh_output(&output_path)?;
    let package = Package::read(&mut source)?;
    let xml = document(&package.main_xml)?;
    let (_, table) = body_tables(&package, xml.root_element())?
        .into_iter()
        .find(|(ordinal, _)| *ordinal == table_index)
        .ok_or_else(unsupported_document)?;
    let change = Change::new(&table, action, index, anchor)?;
    let mut edits = PackageEdits::default();
    edits.changed.insert(
        package.main_part.clone(),
        edit(&package.main_xml, change.edits(&table, &package.main_xml))?,
    );
    let output_sha = package.write_candidate(
        source,
        (&source_path, &output_path),
        sha,
        &edits,
        |written| {
            let xml = document(&written.main_xml)?;
            let (_, edited) = body_tables(written, xml.root_element())?
                .into_iter()
                .find(|(ordinal, _)| *ordinal == table_index)
                .ok_or_else(invalid_zip)?;
            change.verify(&table, &edited, &package.main_xml, &written.main_xml)
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"tableIndex":table_index,
        "rowCount":change.rows.len(),"columnCount":change.columns.len(),
    }))
}
