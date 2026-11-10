use super::shape_geometry::drawing_flag;
use super::shape_text::{
    MAX_RUNS, bounded_name, read_index, read_slide_index, require_unprotected, text_slide_choices,
    unique_child,
};
use super::table_cell_text::{MAX_DIMENSION, TableLayout, table_in_frame, table_layout};
use super::text_box::{has_room, shape_tree};
use super::{
    A, Deck, P, document, edit as edit_xml, expected_hash, open_source, path, require,
    require_fresh_output, unsigned,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid};
use roxmltree::{Attribute, Node};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::ops::Range;

#[path = "pptx_table_merge.rs"]
pub(crate) mod merge;

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
        let xml = document(&deck.xml[&slide.part])?;
        let tables = editable_tables(xml.root_element())?;
        let tables: Vec<_> = tables.iter().map(Table::response).collect();
        json!({"sourceSha256":sha,"slideCount":slide_count,"slideIndex":index,"tables":tables})
    } else {
        json!({"sourceSha256":sha,"slideCount":slide_count,"slides":text_slide_choices(&deck)})
    };
    open_source(source_path, sha)?;
    Ok(reply)
}

pub(crate) fn edit(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 8 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let slide_index = read_slide_index(request.get("slideIndex").ok_or_else(invalid)?)?;
    let shape_id = read_index(request.get("shapeId"))
        .filter(|&id| id > 0)
        .ok_or_else(invalid)?;
    let index = read_index(request.get("index"))
        .map(|index| index as usize)
        .filter(|&index| index < MAX_DIMENSION)
        .ok_or_else(invalid)?;
    let action = request
        .get("action")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    let (axis, change) = match action {
        "insertRowBefore" => (Axis::Row, Change::Insert(index)),
        "insertRowAfter" => (Axis::Row, Change::Insert(index + 1)),
        "insertColumnBefore" => (Axis::Column, Change::Insert(index)),
        "insertColumnAfter" => (Axis::Column, Change::Insert(index + 1)),
        "deleteRow" => (Axis::Row, Change::Delete(index)),
        "deleteColumn" => (Axis::Column, Change::Delete(index)),
        _ => return Err(invalid()),
    };
    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide = deck.slides.get(slide_index).ok_or_else(invalid)?;
    let xml = &deck.xml[&slide.part];
    let parsed = document(xml)?;
    let tables = editable_tables(parsed.root_element())?;
    let table = tables
        .iter()
        .find(|table| table.id == shape_id)
        .ok_or_else(invalid)?;
    let layout = table.axis(axis);
    let length = *layout.lengths.get(index).ok_or_else(invalid)?;
    let extent = match change {
        Change::Insert(gap) if layout.can_insert(gap) => layout.extent + length,
        Change::Delete(index) if layout.can_delete(index) => layout.extent - length,
        _ => return Err(invalid()),
    };
    let plan = Plan {
        axis,
        change,
        length,
        extent,
    };
    let candidate = edit_xml(xml, table.replacements(plan))?;
    require(has_room(
        &deck,
        xml,
        candidate.len().saturating_sub(xml.len()),
    ))?;
    let mut edits = PackageEdits::default();
    edits.changed.insert(slide.part.clone(), candidate);
    let output_sha = deck.write_candidate(
        source,
        (source_path, output_path),
        sha,
        &edits,
        |verified| {
            let selected = verified.slides.get(slide_index).ok_or_else(invalid_zip)?;
            require(
                verified.slides.len() == deck.slides.len()
                    && selected.part == slide.part
                    && selected.identity == slide.identity
                    && selected.hidden == slide.hidden,
            )?;
            let changed_xml = &verified.xml[&slide.part];
            let parsed = document(changed_xml)?;
            let updated = editable_tables(parsed.root_element())?;
            let actual = updated
                .iter()
                .find(|table| table.id == shape_id)
                .ok_or_else(invalid_zip)?;
            table.verify(xml, actual, changed_xml, plan)
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":slide_index,"shapeId":shape_id,"action":action,"index":index,
        "rows":plan.count(Axis::Row, table.layout.rows),
        "columns":plan.count(Axis::Column, table.layout.columns),
    }))
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Axis {
    Row,
    Column,
}

#[derive(Clone, Copy)]
enum Change {
    Insert(usize),
    Delete(usize),
}

impl Change {
    fn splice(self, nodes: &[Node], inserted: String) -> (Range<usize>, String) {
        match self {
            Self::Insert(gap) => {
                let at = if gap == nodes.len() {
                    nodes[gap - 1].range().end
                } else {
                    nodes[gap].range().start
                };
                (at..at, inserted)
            }
            Self::Delete(index) => (nodes[index].range(), String::new()),
        }
    }
}

#[derive(Clone, Copy)]
struct Plan {
    axis: Axis,
    change: Change,
    length: i64,
    extent: i64,
}

impl Plan {
    fn count(self, axis: Axis, count: usize) -> usize {
        if axis != self.axis {
            return count;
        }
        match self.change {
            Change::Insert(_) => count + 1,
            Change::Delete(_) => count - 1,
        }
    }

    fn previous(self, axis: Axis, index: usize) -> Option<usize> {
        if axis != self.axis {
            return Some(index);
        }
        match self.change {
            Change::Insert(gap) if index == gap => None,
            Change::Insert(gap) => Some(index - usize::from(index > gap)),
            Change::Delete(removed) => Some(index + usize::from(index >= removed)),
        }
    }
}

struct AxisLayout<'a, 'input> {
    bands: Vec<Node<'a, 'input>>,
    lengths: Vec<i64>,
    extent: i64,
    extent_range: Range<usize>,
    blocked_gaps: Vec<bool>,
    blocked_deletions: Vec<bool>,
}

impl<'a, 'input> AxisLayout<'a, 'input> {
    fn read(
        bands: Vec<Node<'a, 'input>>,
        size_attr: &str,
        extent: Attribute,
        layout: &TableLayout<'_, '_>,
        axis: Axis,
    ) -> Option<Self> {
        let lengths: Vec<_> = bands
            .iter()
            .map(|&band| {
                if band.attributes().len() != 1 {
                    return None;
                }
                positive_dimension(band.attribute(size_attr)?)
            })
            .collect::<Option<_>>()?;
        let count = lengths.len();
        let mut blocked_gaps = vec![false; count + 1];
        let mut blocked_deletions = vec![false; count];
        for (position, (_, merge)) in layout.cells.iter().enumerate() {
            if merge.covered() {
                continue;
            }
            let (start, span) = match axis {
                Axis::Row => (position / layout.columns, merge.rows),
                Axis::Column => (position % layout.columns, merge.columns),
            };
            if span > 1 {
                blocked_gaps[start + 1..start + span].fill(true);
                blocked_deletions[start..start + span].fill(true);
            }
        }
        Some(Self {
            bands,
            lengths,
            extent: positive_dimension(extent.value())?,
            extent_range: extent.range_value(),
            blocked_gaps,
            blocked_deletions,
        })
    }

    fn can_insert(&self, gap: usize) -> bool {
        self.lengths.len() < MAX_DIMENSION
            && self.blocked_gaps.get(gap) == Some(&false)
            && [
                gap.checked_sub(1).and_then(|i| self.lengths.get(i)),
                self.lengths.get(gap),
            ]
            .into_iter()
            .flatten()
            .all(|&length| self.extent + length <= i64::from(i32::MAX))
    }

    fn can_delete(&self, index: usize) -> bool {
        self.lengths.len() > 1
            && self.blocked_deletions.get(index) == Some(&false)
            && self.extent > self.lengths[index]
    }

    fn gaps(&self) -> Vec<usize> {
        (0..=self.lengths.len())
            .filter(|&gap| self.can_insert(gap))
            .collect()
    }

    fn deletions(&self) -> Vec<usize> {
        (0..self.lengths.len())
            .filter(|&index| self.can_delete(index))
            .collect()
    }
}

struct Table<'a, 'input> {
    id: u32,
    name: &'a str,
    frame: Node<'a, 'input>,
    offset: Node<'a, 'input>,
    layout: TableLayout<'a, 'input>,
    rows: AxisLayout<'a, 'input>,
    columns: AxisLayout<'a, 'input>,
}

impl<'a, 'input> Table<'a, 'input> {
    fn read(
        id: u32,
        identity: Node<'a, 'input>,
        frame: Node<'a, 'input>,
        table: Node<'a, 'input>,
    ) -> Option<Self> {
        if !frame.children().filter(Node::is_element).all(|node| {
            node.has_tag_name((P, "nvGraphicFramePr"))
                || node.has_tag_name((P, "xfrm"))
                || node.has_tag_name((A, "graphic"))
        }) || table
            .descendants()
            .filter(Node::is_element)
            .any(|node| node.tag_name().namespace() != Some(A) || node.has_tag_name((A, "extLst")))
        {
            return None;
        }
        let nv = identity.parent()?;
        let properties = unique_child(nv, P, "nvPr").ok()??;
        if properties
            .children()
            .any(|node| node.has_tag_name((P, "ph")))
        {
            return None;
        }
        let frame_properties = unique_child(nv, P, "cNvGraphicFramePr").ok()??;
        let locks = unique_child(frame_properties, A, "graphicFrameLocks").ok()?;
        for lock in ["noSelect", "noDrilldown", "noResize", "noChangeAspect"] {
            if drawing_flag(locks, lock).ok()? {
                return None;
            }
        }
        let transform = unique_child(frame, P, "xfrm").ok()??;
        if transform
            .attribute("rot")
            .is_some_and(|rot| rot.trim().parse::<i32>() != Ok(0))
            || drawing_flag(Some(transform), "flipH").ok()?
            || drawing_flag(Some(transform), "flipV").ok()?
            || transform.children().filter(Node::is_element).count() != 2
            || !transform
                .attributes()
                .all(|a| a.namespace().is_none() && matches!(a.name(), "rot" | "flipH" | "flipV"))
        {
            return None;
        }
        let offset = unique_child(transform, A, "off").ok()??;
        let extent = unique_child(transform, A, "ext").ok()??;
        if offset.attributes().len() != 2 || extent.attributes().len() != 2 {
            return None;
        }
        for key in ["x", "y"] {
            offset.attribute(key)?.trim().parse::<i32>().ok()?;
        }
        let layout = table_layout(table)?;
        let grid = unique_child(table, A, "tblGrid").ok()??;
        if table.attributes().len() != 0
            || grid.attributes().len() != 0
            || layout.cells.iter().any(|(cell, _)| {
                !cell.attributes().all(|attr| {
                    attr.namespace().is_none()
                        && matches!(
                            attr.name(),
                            "rowSpan" | "gridSpan" | "hMerge" | "vMerge" | "id"
                        )
                })
            })
        {
            return None;
        }
        let rows = table
            .children()
            .filter(|node| node.has_tag_name((A, "tr")))
            .collect();
        let columns = grid.children().filter(Node::is_element).collect();
        let rows = AxisLayout::read(rows, "h", extent.attribute_node("cy")?, &layout, Axis::Row)?;
        let columns = AxisLayout::read(
            columns,
            "w",
            extent.attribute_node("cx")?,
            &layout,
            Axis::Column,
        )?;
        Some(Self {
            id,
            name: bounded_name(identity.attribute("name").unwrap_or("")),
            frame,
            offset,
            layout,
            rows,
            columns,
        })
    }

    fn axis(&self, axis: Axis) -> &AxisLayout<'a, 'input> {
        match axis {
            Axis::Row => &self.rows,
            Axis::Column => &self.columns,
        }
    }

    fn response(&self) -> Value {
        json!({"shapeId":self.id,"name":self.name,"rows":self.layout.rows,"columns":self.layout.columns,
            "rowInsertGaps":self.rows.gaps(),"columnInsertGaps":self.columns.gaps(),
            "rowDelete":self.rows.deletions(),"columnDelete":self.columns.deletions()})
    }

    fn replacements(&self, plan: Plan) -> Vec<(Range<usize>, String)> {
        let axis = self.axis(plan.axis);
        let inserted = match (plan.axis, plan.change) {
            (Axis::Row, Change::Insert(_)) => blank_row(plan.length, self.layout.columns),
            (Axis::Column, Change::Insert(_)) => blank_column(plan.length),
            (_, Change::Delete(_)) => String::new(),
        };
        let mut result = vec![
            (axis.extent_range.clone(), plan.extent.to_string()),
            plan.change.splice(&axis.bands, inserted),
        ];
        if plan.axis == Axis::Column {
            let cell = match plan.change {
                Change::Insert(_) => blank_cell(),
                Change::Delete(_) => String::new(),
            };
            for row in self.layout.cells.chunks_exact(self.layout.columns) {
                let cells: Vec<_> = row.iter().map(|(node, _)| *node).collect();
                result.push(plan.change.splice(&cells, cell.clone()));
            }
        }
        result
    }

    fn verify(&self, old: &str, actual: &Table<'_, '_>, new: &str, plan: Plan) -> ApiResult<()> {
        require(
            self.id == actual.id
                && self.name == actual.name
                && old[..self.frame.range().start] == new[..actual.frame.range().start]
                && old[self.frame.range().end..] == new[actual.frame.range().end..]
                && old[self.offset.range()] == new[actual.offset.range()],
        )?;
        for axis in [Axis::Row, Axis::Column] {
            let before = self.axis(axis);
            let after = actual.axis(axis);
            let expected_extent = if axis == plan.axis {
                plan.extent
            } else {
                before.extent
            };
            require(
                after.extent == expected_extent
                    && after.lengths.len() == plan.count(axis, before.lengths.len()),
            )?;
            for (index, node) in after.bands.iter().enumerate() {
                if let Some(source) = plan.previous(axis, index) {
                    require(after.lengths[index] == before.lengths[source])?;
                    if axis == Axis::Column || plan.axis == Axis::Row {
                        require(new[node.range()] == old[before.bands[source].range()])?;
                    }
                } else {
                    require(after.lengths[index] == plan.length)?;
                }
            }
        }
        let blank = blank_cell();
        for (position, (cell, _)) in actual.layout.cells.iter().enumerate() {
            let row = plan.previous(Axis::Row, position / actual.layout.columns);
            let column = plan.previous(Axis::Column, position % actual.layout.columns);
            let expected = match (row, column) {
                (Some(row), Some(column)) => {
                    &old[self.layout.cells[row * self.layout.columns + column]
                        .0
                        .range()]
                }
                _ => blank.as_str(),
            };
            require(&new[cell.range()] == expected)?;
        }
        Ok(())
    }
}

fn positive_dimension(value: &str) -> Option<i64> {
    value
        .trim()
        .parse::<i32>()
        .ok()
        .filter(|&value| value > 0)
        .map(i64::from)
}

fn blank_row(height: i64, columns: usize) -> String {
    format!(
        "<a:tr xmlns:a=\"{A}\" h=\"{height}\">{}</a:tr>",
        blank_cell().repeat(columns)
    )
}

fn blank_column(width: i64) -> String {
    format!("<a:gridCol xmlns:a=\"{A}\" w=\"{width}\"/>")
}

fn blank_cell() -> String {
    format!(
        "<a:tc xmlns:a=\"{A}\"><a:txBody><a:bodyPr/><a:lstStyle/><a:p/></a:txBody><a:tcPr/></a:tc>"
    )
}

fn editable_tables<'a, 'input>(root: Node<'a, 'input>) -> ApiResult<Vec<Table<'a, 'input>>> {
    let tree = shape_tree(root)?;
    let mut ids = BTreeSet::new();
    let mut duplicates = BTreeSet::new();
    for identity in tree
        .descendants()
        .filter(|node| node.has_tag_name((P, "cNvPr")))
    {
        let id = unsigned(identity.attribute("id").ok_or_else(invalid_zip)?)?;
        if !ids.insert(id) {
            duplicates.insert(id);
        }
    }
    let targeted: BTreeSet<_> = root
        .descendants()
        .filter(|node| node.has_tag_name((P, "spTgt")))
        .filter_map(|node| node.attribute("spid").and_then(|id| unsigned(id).ok()))
        .collect();
    let mut tables = Vec::new();
    for frame in tree
        .children()
        .filter(|node| node.has_tag_name((P, "graphicFrame")))
    {
        let Some((identity, table)) = table_in_frame(frame) else {
            continue;
        };
        let id = unsigned(identity.attribute("id").ok_or_else(invalid_zip)?)?;
        if id == 0 || duplicates.contains(&id) || targeted.contains(&id) {
            continue;
        }
        if let Some(table) = Table::read(id, identity, frame, table) {
            require(tables.len() < MAX_RUNS)?;
            tables.push(table);
        }
    }
    Ok(tables)
}
