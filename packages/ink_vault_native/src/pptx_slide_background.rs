use super::shape_text::{read_slide_index, require_unprotected};
use super::{
    A, Deck, MAX_PACKAGE, MAX_XML, P, document, edit, expected_hash, ignorable_or_element,
    open_source, path, require, require_fresh_output, single_child, source_changed,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid};
use roxmltree::Node;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::ops::Range;

enum Background {
    Inherited {
        insertion: usize,
    },
    Solid {
        rgb: u32,
        background_range: Range<usize>,
        color_range: Range<usize>,
    },
    Unsupported,
}

impl Background {
    fn value(&self) -> String {
        match self {
            Self::Inherited { .. } => "inherited".to_owned(),
            Self::Solid { rgb, .. } => format!("#{rgb:06X}"),
            Self::Unsupported => "unsupported".to_owned(),
        }
    }
}

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let mut slides = Vec::with_capacity(deck.slides.len());
    for (index, slide) in deck.slides.iter().enumerate() {
        let background = read_background(&deck.xml[&slide.part])?.value();
        let mut row = json!({"index":index,"hidden":slide.hidden,"background":background});
        if let Some(title) = &slide.title {
            row["title"] = json!(title);
        }
        slides.push(row);
    }
    open_source(source_path, sha)?;
    Ok(json!({"sourceSha256":sha,"slideCount":slides.len(),"slides":slides}))
}

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = read_slide_index(&request["slideIndex"])?;
    let expected = editable_value(&request["expectedBackground"])?;
    let background = editable_value(&request["background"])?;
    if source_path.parent() != output_path.parent() || expected == background {
        return Err(invalid());
    }
    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide = deck.slides.get(index).ok_or_else(invalid)?;
    let xml = &deck.xml[&slide.part];
    let original = read_background(xml)?;
    require(!matches!(original, Background::Unsupported))?;
    if original.value() != expected {
        return Err(source_changed());
    }
    let (range, replacement) = match (original, background.strip_prefix('#')) {
        (Background::Inherited { insertion }, Some(rgb)) => (
            insertion..insertion,
            format!(
                "<p:bg xmlns:p=\"{P}\" xmlns:a=\"{A}\"><p:bgPr><a:solidFill><a:srgbClr val=\"{rgb}\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"
            ),
        ),
        (Background::Solid { color_range, .. }, Some(rgb)) => (color_range, rgb.to_owned()),
        (
            Background::Solid {
                background_range, ..
            },
            None,
        ) => (background_range, String::new()),
        _ => return Err(invalid_zip()),
    };
    let changed = edit(xml, vec![(range, replacement)])?;
    let growth = changed.len().saturating_sub(xml.len());
    require(deck.xml_bytes + growth <= MAX_XML && deck.layout.expanded + growth <= MAX_PACKAGE)?;
    let edits = PackageEdits {
        changed: BTreeMap::from([(slide.part.clone(), changed)]),
        ..PackageEdits::default()
    };
    let slide_count = deck.slides.len();
    let output_sha =
        deck.write_candidate(source, (source_path, output_path), sha, &edits, |written| {
            require(
                written.slides.len() == slide_count
                    && written.slides.iter().zip(&deck.slides).all(|(new, old)| {
                        new.part == old.part
                            && new.identity == old.identity
                            && new.relationship_id == old.relationship_id
                            && new.title == old.title
                            && new.hidden == old.hidden
                    })
                    && read_background(&written.xml[&slide.part])?.value() == background,
            )
        })?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":slide_count,
        "slideIndex":index,"background":background
    }))
}

fn editable_value(value: &Value) -> ApiResult<&str> {
    let value = value.as_str().ok_or_else(invalid)?;
    if value == "inherited"
        || value.strip_prefix('#').is_some_and(|hex| {
            hex.len() == 6 && hex.bytes().all(|b| matches!(b, b'0'..=b'9' | b'A'..=b'F'))
        })
    {
        Ok(value)
    } else {
        Err(invalid())
    }
}

fn read_background(xml: &str) -> ApiResult<Background> {
    let parsed = document(xml)?;
    let common = single_child(parsed.root_element(), P, "cSld")?;
    let tree = single_child(common, P, "spTree")?;
    let mut children = common.children().filter(Node::is_element);
    let first = children.next().ok_or_else(invalid_zip)?;
    let has_background = first.has_tag_name((P, "bg"));
    let shape_tree = if has_background {
        children.next()
    } else {
        Some(first)
    };
    if shape_tree != Some(tree)
        || !common.children().all(ignorable_or_element)
        || children.any(|child| {
            let name = child.tag_name();
            name.namespace() != Some(P)
                || !matches!(name.name(), "custDataLst" | "controls" | "extLst")
        })
    {
        return Ok(Background::Unsupported);
    }
    if has_background {
        Ok(read_solid(first).unwrap_or(Background::Unsupported))
    } else {
        Ok(Background::Inherited {
            insertion: tree.range().start,
        })
    }
}

fn read_solid(background: Node) -> Option<Background> {
    let properties = sole_plain_element(background)?;
    if background.attributes().len() != 0
        || !properties.has_tag_name((P, "bgPr"))
        || !properties.attributes().all(|attribute| {
            attribute.namespace().is_none()
                && attribute.name() == "shadeToTitle"
                && matches!(attribute.value(), "0" | "false")
        })
        || !properties.children().all(ignorable_or_element)
    {
        return None;
    }
    let mut children = properties.children().filter(Node::is_element);
    let fill = children.next()?;
    if !fill.has_tag_name((A, "solidFill"))
        || fill.attributes().len() != 0
        || children.next().is_some_and(|effect| {
            !effect.has_tag_name((A, "effectLst"))
                || effect.attributes().len() != 0
                || !is_empty(effect)
        })
        || children.next().is_some()
    {
        return None;
    }
    let color = sole_plain_element(fill)?;
    if !color.has_tag_name((A, "srgbClr")) || color.attributes().len() != 1 || !is_empty(color) {
        return None;
    }
    let attribute = color
        .attributes()
        .find(|attribute| attribute.namespace().is_none() && attribute.name() == "val")?;
    let hex = attribute.value();
    if hex.len() != 6 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    Some(Background::Solid {
        rgb: u32::from_str_radix(hex, 16).ok()?,
        background_range: background.range(),
        color_range: attribute.range_value(),
    })
}

fn sole_plain_element<'a, 'input>(node: Node<'a, 'input>) -> Option<Node<'a, 'input>> {
    let mut elements = node.children().filter(Node::is_element);
    let child = elements.next()?;
    (elements.next().is_none() && node.children().all(ignorable_or_element)).then_some(child)
}

fn is_empty(node: Node) -> bool {
    node.children()
        .all(|child| !child.is_element() && ignorable_or_element(child))
}
