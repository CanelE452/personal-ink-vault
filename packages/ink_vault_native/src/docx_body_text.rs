use super::{
    ApiResult, MC, Node, Package, PackageEdits, W, children, document, edit, escape, expected_hash,
    invalid, invalid_zip, open_source, requested_path, require, require_fresh_output, single_child,
    unsupported_document, verify_source,
};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;

#[path = "docx_paragraph.rs"]
pub(crate) mod paragraph;

#[path = "docx_find_replace.rs"]
pub(crate) mod find_replace;

const XML: &str = "http://www.w3.org/XML/1998/namespace";
const MAX_INDEX: usize = 512;
const MAX_RUNS: usize = 400;
const MAX_RUN_UNITS: usize = 2_000;
const MAX_TOTAL_UNITS: usize = 150_000;

type CellAddress = [usize; 3];

enum TextSlot<'a, 'input> {
    Existing(Node<'a, 'input>),
    EmptyParagraph(Node<'a, 'input>),
}

struct Target<'a, 'input> {
    cell: Option<CellAddress>,
    paragraph: usize,
    run: usize,
    slot: TextSlot<'a, 'input>,
    text: &'a str,
}

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    let table_cells = match (request.len(), request.get("tableCells")) {
        (3, None) => false,
        (4, Some(Value::Bool(true))) => true,
        _ => return Err(invalid()),
    };
    let path = requested_path(request.get("sourcePath"), true)?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(&path, sha)?;
    let package = Package::read(&mut source)?;
    let xml = document(&package.main_xml)?;
    let mut regions = BTreeMap::<Option<CellAddress>, BTreeMap<usize, Vec<Value>>>::new();
    for target in targets(&package, xml.root_element(), table_cells)? {
        regions
            .entry(target.cell)
            .or_default()
            .entry(target.paragraph)
            .or_default()
            .push(json!({"runIndex":target.run,"text":target.text}));
    }
    verify_source(&mut source, &path, sha)?;
    if table_cells {
        let cells = regions
            .into_iter()
            .map(|(address, paragraphs)| {
                let [table, row, cell] = address.ok_or_else(invalid_zip)?;
                Ok(json!({
                    "tableIndex":table,"rowIndex":row,"cellIndex":cell,
                    "paragraphs":paragraph_entries(paragraphs),
                }))
            })
            .collect::<ApiResult<Vec<_>>>()?;
        Ok(json!({"sourceSha256":sha,"cells":cells}))
    } else {
        let paragraphs = paragraph_entries(regions.remove(&None).unwrap_or_default());
        Ok(json!({"sourceSha256":sha,"paragraphs":paragraphs}))
    }
}

fn paragraph_entries(paragraphs: BTreeMap<usize, Vec<Value>>) -> Vec<Value> {
    paragraphs
        .into_iter()
        .map(|(index, runs)| json!({"paragraphIndex":index,"runs":runs}))
        .collect()
}

pub(crate) fn replace(request: &Map<String, Value>) -> ApiResult<Value> {
    let cell = match request.len() {
        7 => None,
        10 => Some([
            index(request.get("tableIndex"))?,
            index(request.get("rowIndex"))?,
            index(request.get("cellIndex"))?,
        ]),
        _ => return Err(invalid()),
    };
    let source_path = requested_path(request.get("sourcePath"), true)?;
    let output_path = requested_path(request.get("outputPath"), true)?;
    if source_path.parent() != output_path.parent() {
        return Err(invalid());
    }
    let sha = expected_hash(request.get("sourceSha256"))?;
    let paragraph = index(request.get("paragraphIndex"))?;
    let run = index(request.get("runIndex"))?;
    let replacement = request
        .get("text")
        .and_then(Value::as_str)
        .filter(|value| valid_text(value))
        .ok_or_else(invalid)?;
    let mut source = open_source(&source_path, sha)?;
    require_fresh_output(&output_path)?;
    let package = Package::read(&mut source)?;
    let xml = document(&package.main_xml)?;
    let selected = targets(&package, xml.root_element(), cell.is_some())?
        .into_iter()
        .find(|target| target.cell == cell && target.paragraph == paragraph && target.run == run)
        .filter(|target| target.text != replacement)
        .ok_or_else(invalid)?;

    let updated = match selected.slot {
        TextSlot::Existing(node) => replace_text(&package.main_xml, node, replacement)?,
        TextSlot::EmptyParagraph(node) => fill_paragraph(&package.main_xml, node, replacement)?,
    };
    let mut edits = PackageEdits::default();
    edits.changed.insert(package.main_part.clone(), updated);
    let output_sha = package.write_candidate(
        source,
        (&source_path, &output_path),
        sha,
        &edits,
        |written| {
            let xml = document(&written.main_xml)?;
            let mut container = single_child(xml.root_element(), W, "body")?;
            if let Some([table, row, cell]) = cell {
                let table = direct_table_at(container, table)?;
                let row = children(table, W, "tr").nth(row).ok_or_else(invalid_zip)?;
                container = children(row, W, "tc").nth(cell).ok_or_else(invalid_zip)?;
            }
            let paragraph = children(container, W, "p")
                .nth(paragraph)
                .ok_or_else(invalid_zip)?;
            let run = children(paragraph, W, "r")
                .nth(run)
                .ok_or_else(invalid_zip)?;
            let text = ordinary_text(run).ok_or_else(invalid_zip)?;
            require(text.text().unwrap_or_default() == replacement)?;
            require(!edge_space(replacement) || text.attribute((XML, "space")) == Some("preserve"))
        },
    )?;
    let mut reply = json!({"sourceSha256":sha,"outputSha256":output_sha,"paragraphIndex":paragraph,"runIndex":run});
    if let Some([table, row, cell]) = cell {
        reply["tableIndex"] = json!(table);
        reply["rowIndex"] = json!(row);
        reply["cellIndex"] = json!(cell);
    }
    Ok(reply)
}

fn index(value: Option<&Value>) -> ApiResult<usize> {
    value
        .and_then(Value::as_u64)
        .and_then(|number| usize::try_from(number).ok())
        .filter(|&number| number < MAX_INDEX)
        .ok_or_else(invalid)
}

fn valid_text(value: &str) -> bool {
    value.encode_utf16().count() <= MAX_RUN_UNITS && valid_text_chars(value)
}

fn valid_text_chars(value: &str) -> bool {
    !value.chars().any(|character| {
        character.is_control()
            || matches!(character, '\u{2028}' | '\u{2029}' | '\u{fffe}' | '\u{ffff}')
    })
}

fn targets<'a, 'input>(
    package: &Package,
    root: Node<'a, 'input>,
    table_cells: bool,
) -> ApiResult<Vec<Target<'a, 'input>>> {
    if package.track_revisions {
        return Err(unsupported_document());
    }
    let body = single_child(root, W, "body")?;
    let mut catalog = Catalog::default();
    let mut paragraph = 0;
    let mut table = 0;
    for block in body.children().filter(Node::is_element) {
        if table_cells && block.has_tag_name((W, "tbl")) {
            catalog.table(block, table)?;
            table += 1;
        } else {
            if table_cells {
                table += body_flow_table_count(block)?;
            }
            let excluded = catalog.ranges.inspect(block)?;
            if !table_cells && block.has_tag_name((W, "p")) {
                if !excluded {
                    catalog.paragraph(block, None, paragraph);
                }
                paragraph += 1;
            }
        }
    }
    if !catalog.ranges.fields.is_empty() || !catalog.ranges.revisions.is_empty() {
        return Err(unsupported_document());
    }
    Ok(catalog.targets)
}

fn direct_table_at<'a, 'input>(
    body: Node<'a, 'input>,
    table_index: usize,
) -> ApiResult<Node<'a, 'input>> {
    let mut ordinal = 0;
    for block in body.children().filter(Node::is_element) {
        if block.has_tag_name((W, "tbl")) && ordinal == table_index {
            return Ok(block);
        }
        ordinal += body_flow_table_count(block)?;
    }
    Err(invalid_zip())
}

pub(super) fn body_flow_table_count(block: Node<'_, '_>) -> ApiResult<usize> {
    let mut remaining = vec![block];
    let mut tables = 0;
    while let Some(node) = remaining.pop() {
        if node.has_tag_name((W, "tbl")) {
            tables += 1;
        } else if node.has_tag_name((W, "sdt")) {
            let mut contents = children(node, W, "sdtContent");
            let first = contents.next();
            if contents.next().is_some()
                || node.children().filter(Node::is_element).any(|child| {
                    !child.has_tag_name((W, "sdtContent")) && has_body_flow_table(child)
                })
            {
                if has_body_flow_table(node) {
                    return Err(unsupported_document());
                }
            } else if let Some(contents) = first {
                remaining.extend(contents.children().filter(Node::is_element));
            }
        } else if node.has_tag_name((W, "customXml")) {
            remaining.extend(node.children().filter(Node::is_element));
        } else if has_body_flow_table(node) {
            return Err(unsupported_document());
        }
    }
    Ok(tables)
}

fn has_body_flow_table(block: Node<'_, '_>) -> bool {
    if block.has_tag_name((W, "p")) || block.has_tag_name((W, "txbxContent")) {
        return false;
    }
    block.descendants().any(|node| {
        node.has_tag_name((W, "tbl"))
            && !node
                .ancestors()
                .take_while(|ancestor| *ancestor != block)
                .any(|ancestor| {
                    ancestor.has_tag_name((W, "p")) || ancestor.has_tag_name((W, "txbxContent"))
                })
    })
}

#[derive(Default)]
pub(super) struct Ranges<'a> {
    fields: Vec<bool>,
    revisions: BTreeSet<(&'a str, &'a str)>,
}

impl<'a> Ranges<'a> {
    pub(super) fn is_closed(&self) -> bool {
        self.fields.is_empty() && self.revisions.is_empty()
    }

    pub(super) fn inspect(&mut self, block: Node<'a, '_>) -> ApiResult<bool> {
        let mut excluded = !self.fields.is_empty() || !self.revisions.is_empty();
        for node in block.descendants() {
            if !node.is_element() || node.tag_name().namespace() != Some(W) {
                continue;
            }
            let name = node.tag_name().name();
            let revision = name
                .strip_suffix("RangeStart")
                .or_else(|| name.strip_suffix("RangeEnd"));
            let revision = revision.filter(|name| {
                matches!(
                    *name,
                    "moveFrom"
                        | "moveTo"
                        | "customXmlIns"
                        | "customXmlDel"
                        | "customXmlMoveFrom"
                        | "customXmlMoveTo"
                )
            });
            if !matches!(name, "fldChar" | "instrText" | "delInstrText") && revision.is_none() {
                continue;
            }
            excluded = true;
            if node
                .ancestors()
                .any(|parent| parent.has_tag_name((W, "txbxContent")))
            {
                continue;
            }
            if node
                .ancestors()
                .any(|parent| parent.has_tag_name((MC, "AlternateContent")))
            {
                return Err(unsupported_document());
            }
            if name == "fldChar" {
                match node.attribute((W, "fldCharType")) {
                    Some("begin") => self.fields.push(false),
                    Some("separate") if self.fields.last() == Some(&false) => {
                        *self.fields.last_mut().ok_or_else(unsupported_document)? = true;
                    }
                    Some("end") if self.fields.pop().is_some() => {}
                    _ => return Err(unsupported_document()),
                }
            }
            if let Some(kind) = revision {
                let id = node.attribute((W, "id")).ok_or_else(unsupported_document)?;
                let valid = if name.ends_with("Start") {
                    self.revisions.insert((kind, id))
                } else {
                    self.revisions.remove(&(kind, id))
                };
                if !valid {
                    return Err(unsupported_document());
                }
            }
        }
        Ok(excluded)
    }
}

#[derive(Default)]
struct Catalog<'a, 'input> {
    ranges: Ranges<'a>,
    targets: Vec<Target<'a, 'input>>,
    total_units: usize,
}

impl<'a, 'input> Catalog<'a, 'input> {
    fn table(&mut self, table: Node<'a, 'input>, table_index: usize) -> ApiResult<()> {
        let columns = (table_index < MAX_INDEX)
            .then(|| table_columns(table))
            .flatten();
        let Some(columns) = columns else {
            self.ranges.inspect(table)?;
            return Ok(());
        };
        let mut row_index = 0;
        for row in table.children().filter(Node::is_element) {
            if !row.has_tag_name((W, "tr")) {
                self.ranges.inspect(row)?;
                continue;
            }
            if row_index < MAX_INDEX && regular_row(row, columns) {
                let mut cell_index = 0;
                for cell in row.children().filter(Node::is_element) {
                    if cell.has_tag_name((W, "tc")) {
                        self.cell(cell, [table_index, row_index, cell_index])?;
                        cell_index += 1;
                    } else {
                        self.ranges.inspect(cell)?;
                    }
                }
            } else {
                self.ranges.inspect(row)?;
            }
            row_index += 1;
        }
        Ok(())
    }

    fn cell(&mut self, cell: Node<'a, 'input>, address: CellAddress) -> ApiResult<()> {
        if !ordered_children(cell, &["tcPr"], "p")
            || children(cell, W, "tcPr").any(|properties| {
                revised_properties(properties)
                    || contains_compatibility_markup(properties)
                    || ["vMerge", "cellIns", "cellDel", "cellMerge", "tcPrChange"]
                        .iter()
                        .any(|name| children(properties, W, name).next().is_some())
            })
        {
            self.ranges.inspect(cell)?;
            return Ok(());
        }
        let mut index = 0;
        for paragraph in cell.children().filter(Node::is_element) {
            let excluded = self.ranges.inspect(paragraph)?;
            if paragraph.has_tag_name((W, "p")) {
                if !excluded
                    && !contains_compatibility_markup(paragraph)
                    && !revised_properties(paragraph)
                    && !paragraph
                        .descendants()
                        .any(|node| node.has_tag_name((W, "fldSimple")))
                {
                    self.paragraph(paragraph, Some(address), index);
                }
                index += 1;
            }
        }
        Ok(())
    }

    fn paragraph(&mut self, block: Node<'a, 'input>, cell: Option<CellAddress>, paragraph: usize) {
        if paragraph >= MAX_INDEX
            || self.targets.len() == MAX_RUNS
            || children(block, W, "pPr").any(revised_properties)
        {
            return;
        }
        if cell.is_some() && empty_paragraph(block) {
            self.targets.push(Target {
                cell,
                paragraph,
                run: 0,
                slot: TextSlot::EmptyParagraph(block),
                text: "",
            });
            return;
        }
        for (run, node) in children(block, W, "r").take(MAX_INDEX).enumerate() {
            if self.targets.len() == MAX_RUNS {
                break;
            }
            let Some(node) = ordinary_text(node) else {
                continue;
            };
            let text = node.text().unwrap_or_default();
            let units = text.encode_utf16().count();
            if !valid_text(text) || units > MAX_TOTAL_UNITS - self.total_units {
                continue;
            }
            self.total_units += units;
            self.targets.push(Target {
                cell,
                paragraph,
                run,
                slot: TextSlot::Existing(node),
                text,
            });
        }
    }
}

fn table_columns(table: Node<'_, '_>) -> Option<usize> {
    if !ordered_children(table, &["tblPr", "tblGrid"], "tr")
        || children(table, W, "tblPr").any(|properties| {
            revised_properties(properties)
                || contains_compatibility_markup(properties)
                || children(properties, W, "tblPrChange").next().is_some()
        })
        || children(table, W, "tr").any(|row| {
            row.children()
                .filter(|node| !node.has_tag_name((W, "tc")))
                .flat_map(|node| node.descendants())
                .filter(|node| node.has_tag_name((W, "trPr")))
                .any(|properties| {
                    properties
                        .descendants()
                        .any(|node| node.has_tag_name((W, "ins")) || node.has_tag_name((W, "del")))
                })
        })
    {
        return None;
    }
    let columns = if let Some(grid) = children(table, W, "tblGrid").next() {
        if !ordered_children(grid, &[], "gridCol") || contains_compatibility_markup(grid) {
            return None;
        }
        children(grid, W, "gridCol").count()
    } else {
        let first = children(table, W, "tr").next()?;
        let columns = children(first, W, "tc").count();
        if !children(table, W, "tr").all(|row| regular_row(row, columns)) {
            return None;
        }
        columns
    };
    (1..=MAX_INDEX).contains(&columns).then_some(columns)
}

fn regular_row(row: Node<'_, '_>, columns: usize) -> bool {
    ordered_children(row, &["tblPrEx", "trPr"], "tc")
        && !row
            .children()
            .filter(|child| child.has_tag_name((W, "trPr")) || child.has_tag_name((W, "tblPrEx")))
            .any(|properties| {
                revised_properties(properties)
                    || contains_compatibility_markup(properties)
                    || properties.descendants().any(|node| {
                        node.tag_name().namespace() == Some(W)
                            && matches!(
                                node.tag_name().name(),
                                "gridBefore" | "gridAfter" | "trPrChange" | "tblPrExChange"
                            )
                    })
            })
        && children(row, W, "tc").count() == columns
        && children(row, W, "tc").all(|cell| {
            let mut properties = children(cell, W, "tcPr");
            let first = properties.next();
            properties.next().is_none()
                && first.is_none_or(|properties| {
                    if contains_compatibility_markup(properties)
                        || properties.descendants().any(|node| {
                            node.tag_name().namespace() == Some(W)
                                && match node.tag_name().name() {
                                    "hMerge" | "cellIns" | "cellDel" | "cellMerge" => true,
                                    "gridSpan" | "vMerge" => node.parent() != Some(properties),
                                    _ => false,
                                }
                        })
                    {
                        return false;
                    }
                    let mut spans = children(properties, W, "gridSpan");
                    spans.next().is_none_or(|span| {
                        span.attribute((W, "val"))
                            .and_then(|value| value.parse().ok())
                            == Some(1u32)
                            && spans.next().is_none()
                    })
                })
        })
}

pub(super) fn ordered_children(parent: Node<'_, '_>, properties: &[&str], content: &str) -> bool {
    let mut next_property = 0;
    let mut found_content = false;
    for node in parent.children().filter(Node::is_element) {
        if node.has_tag_name((W, content)) {
            found_content = true;
        } else {
            if found_content || node.tag_name().namespace() != Some(W) {
                return false;
            }
            let Some(index) = properties[next_property..]
                .iter()
                .position(|name| *name == node.tag_name().name())
            else {
                return false;
            };
            next_property += index + 1;
        }
    }
    found_content
}

fn contains_compatibility_markup(node: Node<'_, '_>) -> bool {
    node.descendants()
        .any(|node| node.has_tag_name((MC, "AlternateContent")))
}

fn empty_paragraph(paragraph: Node<'_, '_>) -> bool {
    children(paragraph, W, "pPr").count() <= 1
        && paragraph.children().all(|node| {
            node.has_tag_name((W, "pPr"))
                || node.is_comment()
                || node.is_text() && node.text().is_some_and(|text| text.trim().is_empty())
        })
}

fn revised_properties(node: Node<'_, '_>) -> bool {
    node.descendants().any(|node| {
        node.is_element()
            && node.tag_name().namespace() == Some(W)
            && matches!(
                node.tag_name().name(),
                "pPrChange" | "rPrChange" | "ins" | "del" | "moveFrom" | "moveTo"
            )
    })
}

fn ordinary_text<'a, 'input>(run: Node<'a, 'input>) -> Option<Node<'a, 'input>> {
    if run.children().any(|node| {
        node.is_text()
            && node.text().is_some_and(|value| {
                value
                    .chars()
                    .any(|c| !matches!(c, ' ' | '\t' | '\r' | '\n'))
            })
    }) {
        return None;
    }
    let mut elements = run.children().filter(Node::is_element);
    let first = elements.next()?;
    let text = if first.has_tag_name((W, "rPr")) {
        if revised_properties(first) {
            return None;
        }
        elements.next()?
    } else {
        first
    };
    (text.has_tag_name((W, "t"))
        && elements.next().is_none()
        && text.children().all(|node| node.is_text())
        && text.children().count() <= 1
        && text.attributes().all(|attribute| {
            attribute.namespace() == Some(XML)
                && attribute.name() == "space"
                && matches!(attribute.value(), "default" | "preserve")
        }))
    .then_some(text)
}

fn edge_space(text: &str) -> bool {
    text.starts_with(' ') || text.ends_with(' ')
}

fn fill_paragraph(xml: &str, paragraph: Node<'_, '_>, text: &str) -> ApiResult<Vec<u8>> {
    let range = paragraph.range();
    let raw = &xml[range.clone()];
    let start_end = start_tag_end(raw).ok_or_else(invalid_zip)?;
    let name_end = raw[1..]
        .find([' ', '\t', '\r', '\n', '/', '>'])
        .ok_or_else(invalid_zip)?
        + 1;
    let name = &raw[1..name_end];
    let prefix = name.strip_suffix('p').ok_or_else(invalid_zip)?;
    let space = if edge_space(text) {
        " xml:space=\"preserve\""
    } else {
        ""
    };
    let text = escape(text);
    let run = format!("<{prefix}r><{prefix}t{space}>{text}</{prefix}t></{prefix}r>");
    let change = if raw[..start_end].ends_with('/') {
        (
            range.start + start_end - 1..range.end,
            format!(">{run}</{name}>"),
        )
    } else {
        let at = range.start + raw.rfind("</").ok_or_else(invalid_zip)?;
        (at..at, run)
    };
    edit(xml, vec![change])
}

fn replace_text(xml: &str, node: Node<'_, '_>, text: &str) -> ApiResult<Vec<u8>> {
    edit(xml, text_edits(xml, node, text)?)
}

fn text_edits(xml: &str, node: Node<'_, '_>, text: &str) -> ApiResult<Vec<(Range<usize>, String)>> {
    let range = node.range();
    let raw = &xml[range.clone()];
    let start_end = start_tag_end(raw).ok_or_else(invalid_zip)?;
    let mut edits = Vec::new();
    let self_closing = raw[..start_end].ends_with('/');
    if edge_space(text) && node.attribute((XML, "space")) != Some("preserve") {
        if let Some(attribute) = node.attribute_node((XML, "space")) {
            edits.push((attribute.range_value(), "preserve".to_owned()));
        } else {
            let at = range.start + start_end - usize::from(self_closing);
            edits.push((at..at, " xml:space=\"preserve\"".to_owned()));
        }
    }
    let contents = escape(text);
    if self_closing {
        let name_end = raw[1..]
            .find([' ', '\t', '\r', '\n', '/', '>'])
            .ok_or_else(invalid_zip)?
            + 1;
        let name = &raw[1..name_end];
        edits.push((
            range.start + start_end - 1..range.end,
            format!(">{contents}</{name}>"),
        ));
    } else {
        let end_start = raw.rfind("</").ok_or_else(invalid_zip)?;
        edits.push((
            range.start + start_end + 1..range.start + end_start,
            contents,
        ));
    }
    Ok(edits)
}

fn start_tag_end(raw: &str) -> Option<usize> {
    let mut quote = None;
    for (index, byte) in raw.bytes().enumerate() {
        match (quote, byte) {
            (Some(active), value) if active == value => quote = None,
            (None, b'\'' | b'"') => quote = Some(byte),
            (None, b'>') => return Some(index),
            _ => {}
        }
    }
    None
}
