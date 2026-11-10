//! Inserts one plain WordprocessingML table at a body-block boundary.
use super::{
    ApiResult, Node, Package, PackageEdits, W, children, document, edit, escape, expected_hash,
    invalid, invalid_zip, open_source, requested_path, require, require_fresh_output, single_child,
    unsupported_document, verify_source,
};
use serde_json::{Map, Value, json};
use std::fmt::Write as _;

const MAX_PARAGRAPHS: usize = 512;
const MAX_PREVIEW_UNITS: usize = 160;
const MAX_CELL_UNITS: usize = 400;
const MAX_ROWS: usize = 8;
const MAX_COLUMNS: usize = 6;

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let path = requested_path(request.get("sourcePath"), true)?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(&path, sha)?;
    let package = Package::read(&mut source)?;
    if package.track_revisions {
        return Err(unsupported_document());
    }
    let xml = document(&package.main_xml)?;
    let body = body(xml.root_element())?;
    let paragraphs = children(body, W, "p")
        .take(MAX_PARAGRAPHS)
        .enumerate()
        .map(|(index, paragraph)| json!({"index":index,"text":preview(paragraph)}))
        .collect::<Vec<_>>();
    verify_source(&mut source, &path, sha)?;
    Ok(json!({"sourceSha256":sha,"paragraphs":paragraphs}))
}

pub(crate) fn insert(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 6 {
        return Err(invalid());
    }
    let source_path = requested_path(request.get("sourcePath"), true)?;
    let output_path = requested_path(request.get("outputPath"), true)?;
    if source_path.parent() != output_path.parent() {
        return Err(invalid());
    }
    let sha = expected_hash(request.get("sourceSha256"))?;
    let anchor = match request.get("afterParagraphIndex") {
        Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_u64()
                .and_then(|number| usize::try_from(number).ok())
                .filter(|&index| index < MAX_PARAGRAPHS)
                .ok_or_else(invalid)?,
        ),
        None => return Err(invalid()),
    };
    let cells = parse_cells(request.get("cells"))?;
    let mut source = open_source(&source_path, sha)?;
    require_fresh_output(&output_path)?;
    let package = Package::read(&mut source)?;
    if package.track_revisions {
        return Err(unsupported_document());
    }
    let xml = document(&package.main_xml)?;
    let body_node = body(xml.root_element())?;
    let block_index = match anchor {
        Some(index) => {
            let paragraph = children(body_node, W, "p").nth(index).ok_or_else(invalid)?;
            body_node
                .children()
                .filter(Node::is_element)
                .position(|node| node == paragraph)
                .ok_or_else(invalid_zip)?
                + 1
        }
        None => 0,
    };
    let table_index = body_node
        .children()
        .filter(Node::is_element)
        .take(block_index)
        .filter(|node| node.has_tag_name((W, "tbl")))
        .count();
    let table = table_xml(&cells);
    let replacement = place_table(&package.main_xml, body_node, block_index, table)?;
    let mut edits = PackageEdits::default();
    edits.changed.insert(package.main_part.clone(), replacement);
    let output_sha = package.write_candidate(
        source,
        (&source_path, &output_path),
        sha,
        &edits,
        |written| {
            let xml = document(&written.main_xml)?;
            let body = body(xml.root_element())?;
            let inserted = children(body, W, "tbl")
                .nth(table_index)
                .ok_or_else(invalid_zip)?;
            require(body.children().filter(Node::is_element).nth(block_index) == Some(inserted))?;
            verify_cells(inserted, &cells)
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"afterParagraphIndex":anchor,
        "rows":cells.len(),"columns":cells[0].len(),"tableIndex":table_index,
    }))
}

fn body<'a, 'input>(root: Node<'a, 'input>) -> ApiResult<Node<'a, 'input>> {
    let body = single_child(root, W, "body")?;
    let mut sections = children(body, W, "sectPr");
    if let Some(section) = sections.next() {
        require(body.children().filter(Node::is_element).last() == Some(section))?;
    }
    Ok(body)
}

pub(super) fn preview(paragraph: Node<'_, '_>) -> String {
    let characters = paragraph
        .descendants()
        .filter_map(|node| {
            let text = match node.tag_name().name() {
                "t" if node.has_tag_name((W, "t")) => node.text()?,
                "tab" | "br" if node.tag_name().namespace() == Some(W) => " ",
                _ => return None,
            };
            node.ancestors()
                .skip(1)
                .find(|ancestor| {
                    ancestor.has_tag_name((W, "p"))
                        || ancestor.has_tag_name((W, "del"))
                        || ancestor.has_tag_name((W, "moveFrom"))
                })
                .filter(|&owner| owner == paragraph)
                .map(|_| text)
        })
        .flat_map(str::chars);
    let mut result = String::new();
    let mut units = 0;
    let mut space = false;
    for character in characters {
        if character.is_whitespace() || character.is_control() {
            space = !result.is_empty();
            continue;
        }
        units += character.len_utf16() + usize::from(space);
        if units > MAX_PREVIEW_UNITS {
            break;
        }
        if space {
            result.push(' ');
        }
        result.push(character);
        space = false;
    }
    result
}

fn parse_cells(input: Option<&Value>) -> ApiResult<Vec<Vec<&str>>> {
    let rows = input
        .and_then(Value::as_array)
        .filter(|rows| (1..=MAX_ROWS).contains(&rows.len()))
        .ok_or_else(invalid)?;
    let columns = rows[0]
        .as_array()
        .map(Vec::len)
        .filter(|count| (1..=MAX_COLUMNS).contains(count))
        .ok_or_else(invalid)?;
    let mut result = Vec::with_capacity(rows.len());
    for row in rows {
        let row = row
            .as_array()
            .filter(|row| row.len() == columns)
            .ok_or_else(invalid)?;
        let mut values = Vec::with_capacity(columns);
        for cell in row {
            let text = cell.as_str().ok_or_else(invalid)?;
            if text.encode_utf16().count() > MAX_CELL_UNITS
                || text.chars().any(|character| {
                    character.is_control()
                        || matches!(character, '\u{2028}' | '\u{2029}' | '\u{fffe}' | '\u{ffff}')
                })
            {
                return Err(invalid());
            }
            values.push(text);
        }
        result.push(values);
    }
    Ok(result)
}

fn table_xml(cells: &[Vec<&str>]) -> String {
    let columns = cells[0].len();
    let grid_width = 8640 / columns;
    let cell_width = 5000 / columns;
    let mut table = format!(
        "<w:tbl xmlns:w=\"{W}\"><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>"
    );
    for border in ["top", "left", "bottom", "right", "insideH", "insideV"] {
        write!(
            table,
            "<w:{border} w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
        )
        .expect("write to String");
    }
    table.push_str("</w:tblBorders></w:tblPr><w:tblGrid>");
    for _ in 0..columns {
        write!(table, "<w:gridCol w:w=\"{grid_width}\"/>").expect("write to String");
    }
    table.push_str("</w:tblGrid>");
    for row in cells {
        table.push_str("<w:tr>");
        for text in row {
            write!(
                table,
                "<w:tc><w:tcPr><w:tcW w:w=\"{cell_width}\" w:type=\"pct\"/></w:tcPr>"
            )
            .expect("write to String");
            if text.is_empty() {
                table.push_str("<w:p/>");
            } else {
                write!(
                    table,
                    "<w:p><w:r><w:t xml:space=\"preserve\">{}</w:t></w:r></w:p>",
                    escape(text)
                )
                .expect("write to String");
            }
            table.push_str("</w:tc>");
        }
        table.push_str("</w:tr>");
    }
    table.push_str("</w:tbl>");
    table
}

fn place_table(
    xml: &str,
    body: Node<'_, '_>,
    block_index: usize,
    table: String,
) -> ApiResult<Vec<u8>> {
    let mut blocks = body.children().filter(Node::is_element);
    let (range, replacement) = if block_index > 0 {
        let at = blocks
            .nth(block_index - 1)
            .ok_or_else(invalid_zip)?
            .range()
            .end;
        (at..at, table)
    } else if let Some(first) = blocks.next() {
        let at = first.range().start;
        (at..at, table)
    } else {
        let range = body.range();
        let raw = &xml[range.clone()];
        if let Some(closing) = raw.rfind("</") {
            let at = range.start + closing;
            (at..at, table)
        } else {
            require(raw.ends_with("/>"))?;
            let name_end = raw[1..]
                .find(|c: char| c.is_ascii_whitespace() || matches!(c, '/' | '>'))
                .ok_or_else(invalid_zip)?
                + 1;
            let name = &raw[1..name_end];
            (range.end - 2..range.end, format!(">{table}</{name}>"))
        }
    };
    edit(xml, vec![(range, replacement)])
}

fn verify_cells(table: Node<'_, '_>, expected: &[Vec<&str>]) -> ApiResult<()> {
    let grid = single_child(table, W, "tblGrid")?;
    require(children(grid, W, "gridCol").count() == expected[0].len())?;
    let mut rows = children(table, W, "tr");
    for row in expected {
        let mut cells = children(rows.next().ok_or_else(invalid_zip)?, W, "tc");
        for &value in row {
            let paragraph = single_child(cells.next().ok_or_else(invalid_zip)?, W, "p")?;
            let text = if value.is_empty() {
                require(paragraph.first_element_child().is_none())?;
                ""
            } else {
                let run = single_child(paragraph, W, "r")?;
                single_child(run, W, "t")?.text().ok_or_else(invalid_zip)?
            };
            require(text == value)?;
        }
        require(cells.next().is_none())?;
    }
    require(rows.next().is_none())
}
