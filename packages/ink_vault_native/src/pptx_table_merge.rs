use super::super::shape_text::{open_tag_end, prefix, qualified_name};
use super::{
    A, ApiResult, Deck, MAX_DIMENSION, Node, PackageEdits, Table, TableLayout, document, edit_xml,
    editable_tables, expected_hash, has_room, invalid, invalid_zip, open_source, path, read_index,
    read_slide_index, require, require_fresh_output, require_unprotected, text_slide_choices,
    unique_child,
};
use crate::error;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::ops::Range;

const MAX_MERGED_RANGES: usize = 512;
const SPAN_ATTRIBUTES: [&str; 4] = ["rowSpan", "gridSpan", "hMerge", "vMerge"];

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    let slide_index = request
        .get("slideIndex")
        .map(read_slide_index)
        .transpose()?;
    if request.len() != 3 + usize::from(slide_index.is_some()) {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide_count = deck.slides.len();
    let reply = if let Some(index) = slide_index {
        let slide = deck.slides.get(index).ok_or_else(invalid)?;
        let xml = document(&deck.xml[&slide.part])?;
        let tables = editable_tables(xml.root_element())?;
        require_range_budget(&tables)?;
        let tables: Vec<_> = tables
            .iter()
            .map(|table| {
                let ranges: Vec<_> = merged_ranges(&table.layout)
                    .map(Rectangle::response)
                    .collect();
                json!({
                    "shapeId":table.id,"name":table.name,
                    "rows":table.layout.rows,"columns":table.layout.columns,"mergedRanges":ranges
                })
            })
            .collect();
        json!({"sourceSha256":sha,"slideCount":slide_count,"slideIndex":index,"tables":tables})
    } else {
        json!({"sourceSha256":sha,"slideCount":slide_count,"slides":text_slide_choices(&deck)})
    };
    open_source(source_path, sha)?;
    Ok(reply)
}

pub(crate) fn edit(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 11 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let slide_index = read_slide_index(request.get("slideIndex").ok_or_else(invalid)?)?;
    let shape_id = read_index(request.get("shapeId"))
        .filter(|&id| id > 0)
        .ok_or_else(invalid)?;
    let action = request
        .get("action")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    let merge = match action {
        "merge" => true,
        "unmerge" => false,
        _ => return Err(invalid()),
    };
    let index = |name| {
        read_index(request.get(name))
            .map(|value| value as usize)
            .filter(|&value| value <= MAX_DIMENSION)
            .ok_or_else(invalid)
    };
    let rectangle = Rectangle {
        row: index("row")?,
        column: index("column")?,
        row_span: index("rowSpan")?,
        column_span: index("columnSpan")?,
    };
    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide = deck.slides.get(slide_index).ok_or_else(invalid)?;
    let xml = &deck.xml[&slide.part];
    let parsed = document(xml)?;
    let tables = editable_tables(parsed.root_element())?;
    let range_count = require_range_budget(&tables)?;
    let table = tables
        .iter()
        .find(|table| table.id == shape_id)
        .ok_or_else(invalid)?;
    let layout = &table.layout;
    if !rectangle.fits(layout) || (merge && range_count == MAX_MERGED_RANGES) {
        return Err(invalid());
    }
    let mut ranges: Vec<_> = merged_ranges(layout).collect();
    if merge {
        if rectangle.cells().any(|(row, col)| {
            let old = &layout.cells[row * layout.columns + col].1;
            old.covered() || old.rows != 1 || old.columns != 1
        }) {
            return Err(invalid());
        }
        if collapses_grid_band(layout, rectangle) {
            return Err(error(
                "unsafe_table_merge",
                "This merge would collapse a grid band during PDF rendering",
            ));
        }
        ranges.push(rectangle);
        ranges.sort_unstable();
    } else {
        let index = ranges
            .iter()
            .position(|value| *value == rectangle)
            .ok_or_else(invalid)?;
        ranges.remove(index);
    }
    let mut replacements = Vec::new();
    for (row, col) in rectangle.cells() {
        let cell = layout.cells[row * layout.columns + col].0;
        for attribute in SPAN_ATTRIBUTES {
            if let Some(old) = cell.attribute_node(attribute) {
                replacements.push((old.range(), String::new()));
            }
        }
        if merge {
            let added = rectangle.cell_attributes(row, col);
            let span = cell.range();
            let raw = &xml[span.clone()];
            let end = open_tag_end(raw).ok_or_else(invalid_zip)?;
            let at = span.start + end - usize::from(raw[..end].ends_with('/'));
            replacements.push((at..at, added));
        }
    }
    if merge {
        move_paragraphs(xml, layout, rectangle, &mut replacements)?;
    }
    let candidate = edit_xml(xml, replacements)?;
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
            let changed = &verified.xml[&slide.part];
            require(
                verified.slides.len() == deck.slides.len()
                    && selected.part == slide.part
                    && selected.identity == slide.identity
                    && selected.hidden == slide.hidden
                    && changed.as_bytes() == edits.changed[&slide.part],
            )?;
            let parsed = document(changed)?;
            let updated = editable_tables(parsed.root_element())?;
            let actual = updated
                .iter()
                .find(|table| table.id == shape_id)
                .ok_or_else(invalid_zip)?;
            require(
                actual.layout.rows == layout.rows
                    && actual.layout.columns == layout.columns
                    && actual.rows.lengths == table.rows.lengths
                    && actual.columns.lengths == table.columns.lengths
                    && actual.rows.extent == table.rows.extent
                    && actual.columns.extent == table.columns.extent
                    && changed[actual.offset.range()] == xml[table.offset.range()]
                    && merged_ranges(&actual.layout).eq(ranges.iter().copied()),
            )
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":slide_index,"shapeId":shape_id,"action":action,
        "row":rectangle.row,"column":rectangle.column,
        "rowSpan":rectangle.row_span,"columnSpan":rectangle.column_span,
        "rows":layout.rows,"columns":layout.columns,
    }))
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Rectangle {
    row: usize,
    column: usize,
    row_span: usize,
    column_span: usize,
}

impl Rectangle {
    fn response(self) -> Value {
        json!({"row":self.row,"column":self.column,"rowSpan":self.row_span,"columnSpan":self.column_span})
    }

    fn fits(self, layout: &TableLayout<'_, '_>) -> bool {
        self.row_span > 0
            && self.column_span > 0
            && self.row_span * self.column_span > 1
            && self.row + self.row_span <= layout.rows
            && self.column + self.column_span <= layout.columns
    }

    fn cells(self) -> impl Iterator<Item = (usize, usize)> {
        (self.row..self.row + self.row_span).flat_map(move |row| {
            (self.column..self.column + self.column_span).map(move |column| (row, column))
        })
    }

    fn cell_attributes(self, row: usize, column: usize) -> String {
        let mut attributes = String::new();
        if row == self.row && self.row_span > 1 {
            write!(&mut attributes, " rowSpan=\"{}\"", self.row_span).unwrap();
        }
        if column == self.column && self.column_span > 1 {
            write!(&mut attributes, " gridSpan=\"{}\"", self.column_span).unwrap();
        }
        if row != self.row {
            attributes.push_str(" vMerge=\"1\"");
        }
        if column != self.column {
            attributes.push_str(" hMerge=\"1\"");
        }
        attributes
    }
}

fn merged_ranges<'a>(layout: &'a TableLayout<'_, '_>) -> impl Iterator<Item = Rectangle> + 'a {
    layout
        .cells
        .iter()
        .enumerate()
        .filter_map(|(index, (_, span))| {
            (!span.covered() && (span.rows != 1 || span.columns != 1)).then_some(Rectangle {
                row: index / layout.columns,
                column: index % layout.columns,
                row_span: span.rows,
                column_span: span.columns,
            })
        })
}

fn require_range_budget(tables: &[Table<'_, '_>]) -> ApiResult<usize> {
    let count = tables
        .iter()
        .flat_map(|table| merged_ranges(&table.layout))
        .take(MAX_MERGED_RANGES + 1)
        .count();
    if count > MAX_MERGED_RANGES {
        return Err(invalid());
    }
    Ok(count)
}

fn collapses_grid_band(layout: &TableLayout<'_, '_>, rectangle: Rectangle) -> bool {
    // Impress drops an interior grid band when every cell in it is covered.
    let mut row_coverage = vec![0; layout.rows];
    let mut column_coverage = vec![0; layout.columns];
    for (index, (_, cell)) in layout.cells.iter().enumerate() {
        if cell.covered() {
            row_coverage[index / layout.columns] += 1;
            column_coverage[index % layout.columns] += 1;
        }
    }
    (rectangle.row.max(1)..rectangle.row + rectangle.row_span).any(|row| {
        row_coverage[row] + rectangle.column_span - usize::from(row == rectangle.row)
            == layout.columns
    }) || (rectangle.column.max(1)..rectangle.column + rectangle.column_span).any(|column| {
        column_coverage[column] + rectangle.row_span - usize::from(column == rectangle.column)
            == layout.rows
    })
}

fn move_paragraphs(
    xml: &str,
    layout: &TableLayout<'_, '_>,
    rectangle: Rectangle,
    edits: &mut Vec<(Range<usize>, String)>,
) -> ApiResult<()> {
    let anchor = layout.cells[rectangle.row * layout.columns + rectangle.column].0;
    let anchor_body = unique_child(anchor, A, "txBody")?;
    let mut moved = String::new();
    let mut target = None;
    for (row, column) in rectangle.cells().skip(1) {
        let cell = layout.cells[row * layout.columns + column].0;
        let Some(body) = unique_child(cell, A, "txBody")? else {
            continue;
        };
        let paragraphs = body_paragraphs(body)?;
        if paragraphs.iter().any(|paragraph| {
            paragraph
                .children()
                .filter(Node::is_element)
                .any(|child| !matches!(child.tag_name().name(), "pPr" | "r" | "br" | "endParaRPr"))
                || paragraph.descendants().any(|node| {
                    node.has_tag_name((A, "hlinkClick")) || node.has_tag_name((A, "hlinkMouseOver"))
                })
        }) {
            return Err(invalid());
        }
        let populated = paragraphs.len() > 1
            || paragraphs.iter().any(|paragraph| {
                paragraph.descendants().any(|node| {
                    node.has_tag_name((A, "br"))
                        || (node.has_tag_name((A, "t"))
                            && node.text().is_some_and(|text| !text.is_empty()))
                })
            });
        if !populated {
            continue;
        }
        if target.is_none() {
            let anchor_body = anchor_body.ok_or_else(invalid)?;
            let end = body_paragraphs(anchor_body)?
                .last()
                .ok_or_else(invalid)?
                .range()
                .end;
            target = Some((end, namespaces(anchor_body), list_style(xml, anchor_body)?));
        }
        let (_, anchor_namespaces, anchor_style) = target.as_ref().ok_or_else(invalid)?;
        if *anchor_namespaces != namespaces(body) || *anchor_style != list_style(xml, body)? {
            return Err(invalid());
        }
        let body_prefix = prefix(qualified_name(&xml[body.range()])?);
        for (index, paragraph) in paragraphs.iter().enumerate() {
            let span = paragraph.range();
            moved.push_str(&xml[span.clone()]);
            let replacement = if index == 0 {
                format!("<{body_prefix}p/>")
            } else {
                String::new()
            };
            edits.push((span, replacement));
        }
    }
    if let Some((at, _, _)) = target {
        edits.push((at..at, moved));
    }
    Ok(())
}

fn body_paragraphs<'a, 'input>(body: Node<'a, 'input>) -> ApiResult<Vec<Node<'a, 'input>>> {
    if body.attributes().len() != 0
        || body
            .children()
            .filter(Node::is_element)
            .any(|node| !matches!(node.tag_name().name(), "bodyPr" | "lstStyle" | "p"))
    {
        return Err(invalid());
    }
    unique_child(body, A, "bodyPr")?;
    Ok(body
        .children()
        .filter(|node| node.has_tag_name((A, "p")))
        .collect())
}

fn list_style<'a>(xml: &'a str, body: Node) -> ApiResult<Option<&'a str>> {
    Ok(unique_child(body, A, "lstStyle")?
        .filter(|style| {
            style.attributes().len() != 0 || style.children().any(|child| child.is_element())
        })
        .map(|style| &xml[style.range()]))
}

fn namespaces<'a, 'input>(node: Node<'a, 'input>) -> BTreeMap<Option<&'a str>, &'a str> {
    node.namespaces().map(|ns| (ns.name(), ns.uri())).collect()
}
