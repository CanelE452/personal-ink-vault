use super::shape_geometry::drawing_flag;
use super::{
    A, Deck, MAX_PACKAGE, MAX_SLIDES, MAX_XML, P, PRESENTATION, document, edit, escape,
    expected_hash, open_source, path, require, require_fresh_output, single_child, unsigned,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid, string};
use roxmltree::{Node, NodeId};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;

pub(super) const MAX_RUNS: usize = 400;
const MAX_RUN_UNITS: usize = 2_000;
pub(super) const MAX_SLIDE_UNITS: usize = 150_000;
const MAX_NAME_UNITS: usize = 1_024;

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
        let xml = &deck.xml[&slide.part];
        let document = document(xml)?;
        let shapes = editable_shapes(document.root_element())?
            .into_iter()
            .map(|shape| {
                let runs = shape
                    .runs
                    .into_iter()
                    .map(|run| {
                        json!({
                            "paragraphIndex":run.key.0,"runIndex":run.key.1,"text":run.content,
                        })
                    })
                    .collect::<Vec<_>>();
                json!({"shapeId":shape.id,"name":shape.name,"runs":runs})
            })
            .collect::<Vec<_>>();
        json!({"sourceSha256":sha,"slideCount":slide_count,"slideIndex":index,"shapes":shapes})
    } else {
        json!({"sourceSha256":sha,"slideCount":slide_count,"slides":text_slide_choices(&deck)})
    };
    open_source(source_path, sha)?;
    Ok(reply)
}

pub(super) fn text_slide_choices(deck: &Deck) -> Vec<Value> {
    deck.slides
        .iter()
        .enumerate()
        .map(|(index, slide)| {
            let mut item = json!({"index":index,"hidden":slide.hidden});
            if let Some(title) = &slide.title {
                item["title"] = json!(title);
            }
            item
        })
        .collect()
}

pub(crate) fn paragraph_alignment(request: &Map<String, Value>) -> ApiResult<Value> {
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = read_slide_index(request.get("slideIndex").ok_or_else(invalid)?)?;
    let output_path = request
        .get("outputPath")
        .map(|value| path(Some(value)))
        .transpose()?;
    require(request.len() == if output_path.is_some() { 8 } else { 4 })?;
    if let Some(output_path) = output_path {
        require_fresh_output(output_path)?;
    }
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide = deck.slides.get(index).ok_or_else(invalid)?;
    let xml = &deck.xml[&slide.part];
    let parsed = document(xml)?;
    let shapes = paragraph_shapes(parsed.root_element())?;
    let Some(output_path) = output_path else {
        let shapes = shapes
            .iter()
            .map(|shape| {
                let paragraphs = shape
                    .paragraphs
                    .iter()
                    .enumerate()
                    .map(|(index, paragraph)| {
                        let text: String = paragraph
                            .node
                            .children()
                            .filter(|node| {
                                node.has_tag_name((A, "r")) || node.has_tag_name((A, "fld"))
                            })
                            .flat_map(|node| {
                                node.children().filter(|child| child.has_tag_name((A, "t")))
                            })
                            .filter_map(|text| text.text())
                            .flat_map(str::chars)
                            .take(120)
                            .collect();
                        json!({"index":index,"text":text,"alignment":paragraph.authored()})
                    })
                    .collect::<Vec<_>>();
                json!({"shapeId":shape.id,"name":shape.name,"paragraphs":paragraphs})
            })
            .collect::<Vec<_>>();
        open_source(source_path, sha)?;
        return Ok(
            json!({"sourceSha256":sha,"slideCount":deck.slides.len(),"slideIndex":index,"shapes":shapes}),
        );
    };
    let shape_id = read_index(request.get("shapeId")).ok_or_else(invalid)?;
    let paragraph_index = read_index(request.get("paragraphIndex")).ok_or_else(invalid)? as usize;
    let alignment = match request.get("alignment") {
        Some(Value::Null) => None,
        Some(Value::String(value)) if matches!(value.as_str(), "l" | "ctr" | "r" | "just") => {
            Some(value.as_str())
        }
        _ => return Err(invalid()),
    };
    let shape = shapes
        .iter()
        .find(|shape| shape.id == shape_id)
        .ok_or_else(invalid)?;
    let paragraph = shape.paragraphs.get(paragraph_index).ok_or_else(invalid)?;
    if paragraph.authored() == alignment {
        return Err(invalid());
    }
    let changed = edit(xml, vec![paragraph.edit(xml, alignment)?])?;
    let growth = changed.len().saturating_sub(xml.len());
    require(deck.xml_bytes + growth <= MAX_XML && deck.layout.expanded + growth <= MAX_PACKAGE)?;
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
                    && selected.identity == slide.identity
                    && selected.part == slide.part,
            )?;
            let document = document(&verified.xml[&slide.part])?;
            let updated = paragraph_shapes(document.root_element())?;
            let matched = updated
                .iter()
                .find(|shape| shape.id == shape_id)
                .and_then(|shape| shape.paragraphs.get(paragraph_index))
                .ok_or_else(invalid_zip)?;
            require(matched.authored() == alignment)
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":index,"shapeId":shape_id,
    }))
}

struct ParagraphShape<'a, 'input> {
    id: u32,
    name: &'a str,
    paragraphs: Vec<Paragraph<'a, 'input>>,
}

struct Paragraph<'a, 'input> {
    node: Node<'a, 'input>,
    properties: Option<Node<'a, 'input>>,
}

impl<'a> Paragraph<'a, '_> {
    fn authored(&self) -> Option<&'a str> {
        self.properties.and_then(|node| node.attribute("algn"))
    }

    fn edit(&self, xml: &str, alignment: Option<&str>) -> ApiResult<(Range<usize>, String)> {
        if let Some(attribute) = self.properties.and_then(|node| node.attribute_node("algn")) {
            return Ok(match alignment {
                Some(value) => (attribute.range_value(), value.to_owned()),
                None => {
                    let mut range = attribute.range();
                    if xml.as_bytes().get(range.start - 1) == Some(&b' ') {
                        range.start -= 1;
                    }
                    (range, String::new())
                }
            });
        }
        let value = alignment.ok_or_else(invalid)?;
        let span = self.properties.unwrap_or(self.node).range();
        let raw = xml.get(span.clone()).ok_or_else(invalid_zip)?;
        let end = open_tag_end(raw).ok_or_else(invalid_zip)?;
        let self_closing = raw.as_bytes()[end - 1] == b'/';
        let at = span.start + end - usize::from(self_closing);
        if self.properties.is_some() {
            return Ok((at..at, format!(" algn=\"{value}\"")));
        }
        let name = qualified_name(raw)?;
        let prefix = prefix(name);
        let property = format!("<{prefix}pPr algn=\"{value}\"/>");
        if self_closing {
            Ok((at..at + 2, format!(">{property}</{name}>")))
        } else {
            Ok((at + 1..at + 1, property))
        }
    }
}

fn paragraph_shapes<'a, 'input>(
    root: Node<'a, 'input>,
) -> ApiResult<Vec<ParagraphShape<'a, 'input>>> {
    let mut shapes = Vec::new();
    let mut count = 0;
    for node in text_shape_nodes(root)? {
        let Some((id, name, body, properties)) = text_shape_parts(node)? else {
            continue;
        };
        let Some(shape_properties) = unique_child(properties, P, "cNvSpPr")? else {
            continue;
        };
        let locks = unique_child(shape_properties, A, "spLocks")?;
        if drawing_flag(locks, "noTextEdit")? || drawing_flag(locks, "noSelect")? {
            continue;
        }
        let mut paragraphs = Vec::new();
        for node in body.children().filter(|node| node.has_tag_name((A, "p"))) {
            let properties = unique_child(node, A, "pPr")?;
            require(properties.is_none_or(|value| value.prev_sibling_element().is_none()))?;
            let paragraph = Paragraph { node, properties };
            require(paragraph.authored().is_none_or(|value| {
                matches!(
                    value,
                    "l" | "ctr" | "r" | "just" | "justLow" | "dist" | "thaiDist"
                )
            }))?;
            count += 1;
            require(count <= MAX_RUNS)?;
            paragraphs.push(paragraph);
        }
        if !paragraphs.is_empty() {
            shapes.push(ParagraphShape {
                id,
                name,
                paragraphs,
            });
        }
    }
    Ok(shapes)
}

pub(crate) fn replace(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = read_slide_index(request.get("slideIndex").ok_or_else(invalid)?)?;
    let shape_id = read_index(request.get("shapeId"))
        .filter(|id| *id > 0)
        .ok_or_else(invalid)?;
    let changes = read_changes(request.get("changes"))?;

    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide = deck.slides.get(index).ok_or_else(invalid)?;
    let xml = &deck.xml[&slide.part];
    let parsed = document(xml)?;
    let shapes = editable_shapes(parsed.root_element())?;
    let shape = shapes
        .iter()
        .find(|shape| shape.id == shape_id)
        .ok_or_else(invalid)?;
    let mut replacements = Vec::new();
    for (&key, &new_text) in &changes {
        let run = shape
            .runs
            .iter()
            .find(|run| run.key == key)
            .ok_or_else(invalid)?;
        if run.content != new_text {
            replacements.push(text_edit(xml, run.span.clone(), new_text)?);
        }
    }
    if replacements.is_empty() {
        return Err(invalid());
    }
    let changed = edit(xml, replacements)?;
    let growth = changed.len().saturating_sub(xml.len());
    require(deck.xml_bytes + growth <= MAX_XML && deck.layout.expanded + growth <= MAX_PACKAGE)?;
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
            let doc = document(&verified.xml[&slide.part])?;
            let updated = editable_shapes(doc.root_element())?;
            let new_shape = updated
                .iter()
                .find(|shape| shape.id == shape_id)
                .ok_or_else(invalid_zip)?;
            require(new_shape.name == shape.name && new_shape.runs.len() == shape.runs.len())?;
            for (before, after) in shape.runs.iter().zip(&new_shape.runs) {
                let expected = changes.get(&before.key).copied().unwrap_or(before.content);
                require(before.key == after.key && after.content == expected)?;
            }
            Ok(())
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":index,"shapeId":shape_id,
    }))
}

pub(crate) fn format(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 11 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = read_slide_index(request.get("slideIndex").ok_or_else(invalid)?)?;
    let shape_id = read_index(request.get("shapeId"))
        .filter(|id| *id > 0)
        .ok_or_else(invalid)?;
    let key = (
        read_index(request.get("paragraphIndex")).ok_or_else(invalid)?,
        read_index(request.get("runIndex")).ok_or_else(invalid)?,
    );
    let start = read_index(request.get("start")).ok_or_else(invalid)? as usize;
    let end = read_index(request.get("end")).ok_or_else(invalid)? as usize;
    let styles = read_styles(request.get("styles"))?;

    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide = deck.slides.get(index).ok_or_else(invalid)?;
    let xml = &deck.xml[&slide.part];
    let parsed = document(xml)?;
    let shapes = editable_shapes(parsed.root_element())?;
    let shape = shapes
        .iter()
        .find(|shape| shape.id == shape_id)
        .ok_or_else(invalid)?;
    let run_index = shape
        .runs
        .iter()
        .position(|run| run.key == key)
        .ok_or_else(invalid)?;
    let run = &shape.runs[run_index];
    let node = parsed.get_node(run.node_id).ok_or_else(invalid_zip)?;
    let text = single_child(node, A, "t")?;
    require(text.children().count() == 1)?;
    let properties = unique_child(node, A, "rPr")?;
    require(properties.is_none_or(|props| props.range().end <= text.range().start))?;
    let selection = grapheme_selection(run.content, start, end).ok_or_else(invalid)?;
    let pieces: Vec<_> = [
        (&run.content[..selection.start], false),
        (&run.content[selection.clone()], true),
        (&run.content[selection.end..], false),
    ]
    .into_iter()
    .filter(|(value, _)| !value.is_empty())
    .collect();
    let split = pieces.len() > 1;
    if split {
        require(splittable_run(node, text, properties))?;
    }
    let style_edits = format_edits(xml, node, text, properties, &styles)?;
    if style_edits.is_empty() {
        return Err(invalid());
    }
    let span = node.range();
    let raw = xml.get(span.clone()).ok_or_else(invalid_zip)?;
    let mut fragments = String::new();
    for &(value, selected) in &pieces {
        let mut edits = if selected {
            style_edits.clone()
        } else {
            Vec::new()
        };
        if split {
            edits.push(text_edit(xml, run.span.clone(), value)?);
        }
        for (range, _) in &mut edits {
            range.start = range
                .start
                .checked_sub(span.start)
                .ok_or_else(invalid_zip)?;
            range.end = range.end.checked_sub(span.start).ok_or_else(invalid_zip)?;
        }
        let fragment = edit(raw, edits)?;
        fragments.push_str(std::str::from_utf8(&fragment).map_err(|_| invalid_zip())?);
    }
    let changed = edit(xml, vec![(span, fragments)])?;
    let growth = changed.len().saturating_sub(xml.len());
    require(deck.xml_bytes + growth <= MAX_XML && deck.layout.expanded + growth <= MAX_PACKAGE)?;
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
            let modified = &verified.xml[&slide.part];
            let doc = document(modified)?;
            let updated = editable_shapes(doc.root_element())?;
            let new_shape = updated
                .iter()
                .find(|shape| shape.id == shape_id)
                .ok_or_else(invalid_zip)?;
            require(
                new_shape.name == shape.name
                    && new_shape.runs.len() == shape.runs.len() + pieces.len() - 1,
            )?;
            for (offset, &(content, formatted)) in pieces.iter().enumerate() {
                let piece = &new_shape.runs[run_index + offset];
                require(piece.key == (key.0, key.1 + offset as u32) && piece.content == content)?;
                let node = doc.get_node(piece.node_id).ok_or_else(invalid_zip)?;
                let current = unique_child(node, A, "rPr")?;
                if formatted {
                    let current = current.ok_or_else(invalid_zip)?;
                    require(styles.attributes.iter().all(|(name, value)| {
                        style_matches(name, current.attribute(*name), value)
                    }))?;
                    if let Some(color) = &styles.color {
                        require(text_fill(current)?.is_some_and(|fill| rgb_matches(fill, color)))?;
                    }
                } else {
                    require(
                        current.map(|props| &modified[props.range()])
                            == properties.map(|props| &xml[props.range()]),
                    )?;
                }
            }
            Ok(())
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":index,"shapeId":shape_id,
    }))
}

#[derive(Default)]
struct RunStyles {
    attributes: Vec<(&'static str, String)>,
    color: Option<String>,
}

fn read_styles(value: Option<&Value>) -> ApiResult<RunStyles> {
    let fields = value
        .and_then(Value::as_object)
        .filter(|styles| !styles.is_empty() && styles.len() <= 5)
        .ok_or_else(invalid)?;
    let mut styles = RunStyles::default();
    for (name, value) in fields {
        let attribute = match name.as_str() {
            "bold" | "italic" | "underline" => {
                let on = value.as_bool().ok_or_else(invalid)?;
                let (name, setting) = match name.as_str() {
                    "bold" => ("b", if on { "1" } else { "0" }),
                    "italic" => ("i", if on { "1" } else { "0" }),
                    _ => ("u", if on { "sng" } else { "none" }),
                };
                (name, setting.to_owned())
            }
            "fontSize" => {
                let size = value
                    .as_u64()
                    .filter(|size| (100..=400_000).contains(size))
                    .ok_or_else(invalid)?;
                ("sz", size.to_string())
            }
            "fontColor" => {
                let color = value
                    .as_str()
                    .filter(|color| {
                        color.len() == 6 && color.bytes().all(|byte| byte.is_ascii_hexdigit())
                    })
                    .ok_or_else(invalid)?;
                styles.color = Some(color.to_ascii_uppercase());
                continue;
            }
            _ => return Err(invalid()),
        };
        styles.attributes.push(attribute);
    }
    Ok(styles)
}

fn style_matches(name: &str, current: Option<&str>, wanted: &str) -> bool {
    let Some(current) = current else { return false };
    current == wanted
        || if name == "sz" {
            current.trim().parse::<u32>().ok() == wanted.parse::<u32>().ok()
        } else {
            matches!((current, wanted), ("true", "1") | ("false", "0"))
        }
}

fn text_fill<'a, 'input>(properties: Node<'a, 'input>) -> ApiResult<Option<Node<'a, 'input>>> {
    let elements = properties.children().filter(Node::is_element);
    // Markup compatibility can expand a foreign wrapper into a direct fill.
    require(
        elements
            .clone()
            .all(|node| node.tag_name().namespace() == Some(A)),
    )?;
    let mut fills = elements.filter(|node| {
        matches!(
            node.tag_name().name(),
            "noFill" | "solidFill" | "gradFill" | "blipFill" | "pattFill" | "grpFill"
        )
    });
    let fill = fills.next();
    let outline = unique_child(properties, A, "ln")?;
    require(
        fills.next().is_none()
            && outline.is_none_or(|node| node.prev_sibling_element().is_none())
            && fill.is_none_or(|node| node.prev_sibling_element() == outline),
    )?;
    Ok(fill)
}

fn rgb_matches(fill: Node, color: &str) -> bool {
    let mut children = fill.children().filter(Node::is_element);
    fill.has_tag_name((A, "solidFill"))
        && fill.attributes().len() == 0
        && children.next().is_some_and(|rgb| {
            rgb.has_tag_name((A, "srgbClr"))
                && rgb.attributes().len() == 1
                && rgb
                    .attribute("val")
                    .is_some_and(|value| value.eq_ignore_ascii_case(color))
                && !rgb.children().any(|node| node.is_element())
        })
        && children.next().is_none()
}

pub(super) fn qualified_name(raw: &str) -> ApiResult<&str> {
    raw.get(1..)
        .and_then(|tag| {
            tag.split(|c: char| c.is_ascii_whitespace() || c == '/' || c == '>')
                .next()
        })
        .filter(|name| !name.is_empty())
        .ok_or_else(invalid_zip)
}

pub(super) fn prefix(qualified: &str) -> &str {
    qualified
        .rsplit_once(':')
        .map_or("", |(prefix, _)| &qualified[..prefix.len() + 1])
}

fn rgb_fill(prefix: &str, color: &str) -> String {
    format!("<{prefix}solidFill><{prefix}srgbClr val=\"{color}\"/></{prefix}solidFill>")
}

fn grapheme_selection(text: &str, start: usize, end: usize) -> Option<Range<usize>> {
    if start >= end {
        return None;
    }
    let mut start_byte = None;
    let mut units = 0;
    for (byte, cluster) in text.grapheme_indices(true).chain([(text.len(), "")]) {
        if units == start {
            start_byte = Some(byte);
        }
        if units >= end {
            return start_byte.filter(|_| units == end).map(|start| start..byte);
        }
        units += cluster.encode_utf16().count();
    }
    None
}

fn splittable_run(run: Node, text: Node, properties: Option<Node>) -> bool {
    run.attributes().len() == 0
        && run.children().all(|child| {
            child.is_element()
                || (child.is_text() && child.text().is_some_and(|value| value.trim().is_empty()))
        })
        && text
            .attributes()
            .all(|attribute| match attribute.namespace() {
                Some("http://www.w3.org/XML/1998/namespace") => attribute.name() == "space",
                None => !attribute.name().eq_ignore_ascii_case("id"),
                _ => false,
            })
        && properties.is_none_or(|props| {
            props.descendants().all(|node| {
                !node.is_element()
                    || (node.tag_name().namespace() == Some(A)
                        && !node.has_tag_name((A, "extLst"))
                        && node.attributes().all(|attribute| {
                            attribute.namespace().is_none()
                                && !attribute.name().eq_ignore_ascii_case("id")
                        }))
            })
        })
}

fn format_edits(
    xml: &str,
    run: Node,
    text: Node,
    properties: Option<Node>,
    styles: &RunStyles,
) -> ApiResult<Vec<(Range<usize>, String)>> {
    let mut edits = Vec::new();
    let mut added = String::new();
    for (name, value) in &styles.attributes {
        if let Some(attribute) = properties.and_then(|node| node.attribute_node(*name)) {
            if !style_matches(name, Some(attribute.value()), value) {
                edits.push((attribute.range_value(), value.clone()));
            }
        } else {
            added.push_str(&format!(" {name}=\"{value}\""));
        }
    }
    let Some(properties) = properties else {
        let raw = xml.get(run.range()).ok_or_else(invalid_zip)?;
        let prefix = prefix(qualified_name(raw)?);
        let properties = match &styles.color {
            Some(color) => {
                let fill = rgb_fill(prefix, color);
                format!("<{prefix}rPr{added}>{fill}</{prefix}rPr>")
            }
            None => format!("<{prefix}rPr{added}/>"),
        };
        let at = text.range().start;
        edits.push((at..at, properties));
        return Ok(edits);
    };
    if added.is_empty() && styles.color.is_none() {
        return Ok(edits);
    }
    let span = properties.range();
    let raw = xml.get(span.clone()).ok_or_else(invalid_zip)?;
    let end = open_tag_end(raw).ok_or_else(invalid_zip)?;
    let self_closing = raw.as_bytes()[end - 1] == b'/';
    let at = span.start + end - usize::from(self_closing);
    if let Some(color) = &styles.color {
        let existing = text_fill(properties)?;
        if !existing.is_some_and(|fill| rgb_matches(fill, color)) {
            let qualified = qualified_name(raw)?;
            let fill = rgb_fill(prefix(qualified), color);
            if self_closing {
                edits.push((at..at + 2, format!("{added}>{fill}</{qualified}>")));
                return Ok(edits);
            }
            let fill_range = existing.map_or_else(
                || {
                    let at = properties
                        .first_element_child()
                        .filter(|child| child.has_tag_name((A, "ln")))
                        .map_or(span.start + end + 1, |outline| outline.range().end);
                    at..at
                },
                |existing| existing.range(),
            );
            edits.push((fill_range, fill));
        }
    }
    if !added.is_empty() {
        edits.push((at..at, added));
    }
    Ok(edits)
}

pub(super) fn require_unprotected(deck: &Deck) -> ApiResult<()> {
    let presentation = document(&deck.xml[PRESENTATION])?;
    require(
        !presentation
            .root_element()
            .children()
            .any(|node| node.has_tag_name((P, "modifyVerifier"))),
    )
}

pub(super) fn read_index(value: Option<&Value>) -> Option<u32> {
    value?.as_u64().and_then(|value| u32::try_from(value).ok())
}

pub(super) fn read_slide_index(value: &Value) -> ApiResult<usize> {
    read_index(Some(value))
        .map(|index| index as usize)
        .filter(|&index| index < MAX_SLIDES)
        .ok_or_else(invalid)
}

pub(super) type RunKey = (u32, u32);

pub(super) fn read_changes(value: Option<&Value>) -> ApiResult<BTreeMap<RunKey, &str>> {
    let changes = value
        .and_then(Value::as_array)
        .filter(|items| !items.is_empty() && items.len() <= MAX_RUNS)
        .ok_or_else(invalid)?;
    let mut result = BTreeMap::new();
    let mut units = 0;
    for change in changes {
        let change = change
            .as_object()
            .filter(|object| object.len() == 3)
            .ok_or_else(invalid)?;
        let key = (
            read_index(change.get("paragraphIndex")).ok_or_else(invalid)?,
            read_index(change.get("runIndex")).ok_or_else(invalid)?,
        );
        let text = string(change.get("text"))?;
        units += text.encode_utf16().count();
        if !valid_text(text) || units > MAX_SLIDE_UNITS || result.insert(key, text).is_some() {
            return Err(invalid());
        }
    }
    Ok(result)
}

pub(super) fn valid_text(text: &str) -> bool {
    text.encode_utf16().count() <= MAX_RUN_UNITS && valid_text_chars(text)
}

pub(super) fn valid_text_chars(text: &str) -> bool {
    !text.chars().any(|character| {
        character.is_control()
            || matches!(character, '\u{2028}' | '\u{2029}' | '\u{fffe}' | '\u{ffff}')
    })
}

struct TextShape<'a> {
    id: u32,
    name: &'a str,
    runs: Vec<TextRun<'a>>,
}

struct TextRun<'a> {
    key: RunKey,
    content: &'a str,
    span: Range<usize>,
    node_id: NodeId,
}

fn editable_shapes<'a, 'input>(root: Node<'a, 'input>) -> ApiResult<Vec<TextShape<'a>>> {
    let mut shapes = Vec::new();
    let mut count = 0;
    let mut units = 0;
    for node in text_shape_nodes(root)? {
        if let Some(shape) = editable_shape(node)? {
            count += shape.runs.len();
            units += shape
                .runs
                .iter()
                .map(|run| run.content.encode_utf16().count())
                .sum::<usize>();
            require(count <= MAX_RUNS && units <= MAX_SLIDE_UNITS)?;
            shapes.push(shape);
        }
    }
    Ok(shapes)
}

fn text_shape_nodes<'a, 'input>(root: Node<'a, 'input>) -> ApiResult<Vec<Node<'a, 'input>>> {
    let tree = single_child(single_child(root, P, "cSld")?, P, "spTree")?;
    let mut ids = BTreeSet::new();
    for node in tree
        .descendants()
        .filter(|node| node.has_tag_name((P, "cNvPr")))
    {
        let id = unsigned(node.attribute("id").ok_or_else(invalid_zip)?)?;
        require(ids.insert(id))?;
    }
    let mut shapes = Vec::new();
    let mut groups = vec![tree.children()];
    while let Some(children) = groups.last_mut() {
        match children.next() {
            Some(group) if group.has_tag_name((P, "grpSp")) => groups.push(group.children()),
            Some(shape) if shape.has_tag_name((P, "sp")) => shapes.push(shape),
            Some(_) => (),
            None => {
                groups.pop();
            }
        }
    }
    Ok(shapes)
}

fn editable_shape<'a, 'input>(node: Node<'a, 'input>) -> ApiResult<Option<TextShape<'a>>> {
    let Some((id, name, body, _)) = text_shape_parts(node)? else {
        return Ok(None);
    };
    let mut runs = Vec::new();
    for (paragraph_index, paragraph) in body
        .children()
        .filter(|node| node.has_tag_name((A, "p")))
        .enumerate()
    {
        for (run_index, run) in paragraph
            .children()
            .filter(|node| node.has_tag_name((A, "r")))
            .enumerate()
        {
            if let Some(text) = editable_text(run)? {
                runs.push(TextRun {
                    key: (paragraph_index as u32, run_index as u32),
                    content: text.text().unwrap_or(""),
                    span: text.range(),
                    node_id: run.id(),
                });
                require(runs.len() <= MAX_RUNS)?;
            }
        }
    }
    Ok((!runs.is_empty()).then(|| TextShape { id, name, runs }))
}

fn text_shape_parts<'a, 'input>(
    node: Node<'a, 'input>,
) -> ApiResult<Option<(u32, &'a str, Node<'a, 'input>, Node<'a, 'input>)>> {
    let Some(body) = unique_child(node, P, "txBody")? else {
        return Ok(None);
    };
    let Some(properties) = unique_child(node, P, "nvSpPr")? else {
        return Ok(None);
    };
    let identity = single_child(properties, P, "cNvPr")?;
    let id = unsigned(identity.attribute("id").ok_or_else(invalid_zip)?)?;
    let name = bounded_name(identity.attribute("name").unwrap_or(""));
    Ok((id > 0).then_some((id, name, body, properties)))
}

pub(super) fn unique_child<'a, 'input>(
    node: Node<'a, 'input>,
    namespace: &str,
    name: &str,
) -> ApiResult<Option<Node<'a, 'input>>> {
    let mut children = node
        .children()
        .filter(|child| child.has_tag_name((namespace, name)));
    let result = children.next();
    require(children.next().is_none())?;
    Ok(result)
}

pub(super) fn editable_text<'a, 'input>(
    run: Node<'a, 'input>,
) -> ApiResult<Option<Node<'a, 'input>>> {
    Ok(ordinary_text(run)?.filter(|text| valid_text(text.text().unwrap_or(""))))
}

pub(super) fn ordinary_text<'a, 'input>(
    run: Node<'a, 'input>,
) -> ApiResult<Option<Node<'a, 'input>>> {
    if !run
        .children()
        .filter(Node::is_element)
        .all(|node| node.has_tag_name((A, "t")) || node.has_tag_name((A, "rPr")))
    {
        return Ok(None);
    }
    if unique_child(run, A, "rPr")?.is_some_and(|properties| {
        properties.descendants().any(|node| {
            node.has_tag_name((A, "hlinkClick")) || node.has_tag_name((A, "hlinkMouseOver"))
        })
    }) {
        return Ok(None);
    }
    Ok(unique_child(run, A, "t")?.filter(|text| text.children().all(|child| child.is_text())))
}

pub(super) fn bounded_name(value: &str) -> &str {
    let mut units = 0;
    for (index, character) in value.char_indices() {
        units += character.len_utf16();
        if units > MAX_NAME_UNITS {
            return &value[..index];
        }
    }
    value
}

pub(super) fn text_edit(
    xml: &str,
    span: Range<usize>,
    value: &str,
) -> ApiResult<(Range<usize>, String)> {
    let raw = xml.get(span.clone()).ok_or_else(invalid_zip)?;
    let end = open_tag_end(raw).ok_or_else(invalid_zip)?;
    let text = escape(value);
    if raw.as_bytes().get(end.wrapping_sub(1)) == Some(&b'/') {
        let name_end = raw[1..end]
            .find(|character: char| character == '/' || character.is_ascii_whitespace())
            .ok_or_else(invalid_zip)?
            + 1;
        let name = &raw[1..name_end];
        return Ok((
            span.start + end - 1..span.start + end + 1,
            format!(">{text}</{name}>"),
        ));
    }
    let end_tag = raw
        .rfind("</")
        .filter(|&offset| offset > end)
        .ok_or_else(invalid_zip)?;
    Ok((span.start + end + 1..span.start + end_tag, text))
}

pub(super) fn open_tag_end(raw: &str) -> Option<usize> {
    let mut quote = None;
    raw.bytes().enumerate().find_map(|(index, byte)| {
        match (quote, byte) {
            (Some(current), byte) if byte == current => quote = None,
            (None, b'\'' | b'"') => quote = Some(byte),
            (None, b'>') => return Some(index),
            _ => (),
        }
        None
    })
}
