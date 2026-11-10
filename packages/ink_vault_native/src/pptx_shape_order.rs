use super::shape_geometry::{
    bounded_name, drawing_flag, require_unprotected, slide_index, unique_child,
};
use super::{
    A, Deck, P, R, Relationships, document, edit, expected_hash, ignorable_or_element, open_source,
    path, require, require_fresh_output, single_child, unsigned,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid};
use roxmltree::Node;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;

const MAX_OBJECTS: usize = 400;

struct Shape<'a> {
    id: u32,
    name: &'a str,
    kind: &'static str,
    range: Range<usize>,
}

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    let index = request.get("slideIndex").map(slide_index).transpose()?;
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
        let shapes: Vec<_> =
            ordered_shapes(parsed.root_element(), &deck.slide_relationships[index])?
                .iter()
                .map(|shape| json!({"shapeId":shape.id,"name":shape.name,"kind":shape.kind}))
                .collect();
        json!({"sourceSha256":sha,"slideCount":slide_count,"slideIndex":index,"shapes":shapes})
    } else {
        let slides: Vec<_> = deck
            .slides
            .iter()
            .enumerate()
            .map(|(index, slide)| {
                let mut row = json!({"index":index,"hidden":slide.hidden});
                if let Some(title) = &slide.title {
                    row["title"] = json!(title);
                }
                row
            })
            .collect();
        json!({"sourceSha256":sha,"slideCount":slide_count,"slides":slides})
    };
    open_source(source_path, sha)?;
    Ok(reply)
}

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = slide_index(request.get("slideIndex").ok_or_else(invalid)?)?;
    let shape_id = request
        .get("shapeId")
        .and_then(Value::as_u64)
        .and_then(|id| u32::try_from(id).ok())
        .filter(|&id| id > 0)
        .ok_or_else(invalid)?;
    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide = deck.slides.get(index).ok_or_else(invalid)?;
    let xml = &deck.xml[&slide.part];
    let parsed = document(xml)?;
    let shapes = ordered_shapes(parsed.root_element(), &deck.slide_relationships[index])?;
    let from = shapes
        .iter()
        .position(|shape| shape.id == shape_id)
        .ok_or_else(invalid)?;
    let to = match request.get("direction").and_then(Value::as_str) {
        Some("front") => shapes.len() - 1,
        Some("forward") if from + 1 < shapes.len() => from + 1,
        Some("backward") if from > 0 => from - 1,
        Some("back") => 0,
        _ => return Err(invalid()),
    };
    if from == to {
        return Err(invalid());
    }

    let mut order: Vec<_> = shapes.iter().collect();
    let target = order.remove(from);
    order.insert(to, target);
    // Replace whole siblings in place so markup between slots stays byte-for-byte intact.
    let replacements = shapes
        .iter()
        .zip(&order)
        .filter(|(slot, object)| slot.id != object.id)
        .map(|(slot, object)| (slot.range.clone(), xml[object.range.clone()].to_owned()))
        .collect();
    let edits = PackageEdits {
        changed: BTreeMap::from([(slide.part.clone(), edit(xml, replacements)?)]),
        ..PackageEdits::default()
    };
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
            let parsed = document(&verified.xml[&slide.part])?;
            let actual =
                ordered_shapes(parsed.root_element(), &verified.slide_relationships[index])?;
            require(
                actual
                    .iter()
                    .map(|shape| shape.id)
                    .eq(order.iter().map(|shape| shape.id)),
            )
        },
    )?;
    Ok(
        json!({"sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":index,"shapeId":shape_id,"fromIndex":from,"toIndex":to}),
    )
}

fn ordered_shapes<'a>(
    root: Node<'a, '_>,
    relationships: &Relationships,
) -> ApiResult<Vec<Shape<'a>>> {
    let tree = single_child(single_child(root, P, "cSld")?, P, "spTree")?;
    require(tree.children().all(ignorable_or_element))?;
    require(
        root.descendants()
            .filter(Node::is_element)
            .flat_map(|node| node.attributes())
            .all(|attr| attr.namespace() != Some(R) || relationships.contains_key(attr.value())),
    )?;
    let mut ids = BTreeSet::new();
    for node in tree
        .descendants()
        .filter(|node| node.has_tag_name((P, "cNvPr")))
    {
        let id = unsigned(node.attribute("id").ok_or_else(invalid_zip)?)?;
        require(ids.insert(id))?;
    }

    let mut children = tree.children().filter(Node::is_element).peekable();
    for metadata in ["nvGrpSpPr", "grpSpPr"] {
        if children
            .next()
            .is_none_or(|node| !node.has_tag_name((P, metadata)))
        {
            return Ok(Vec::new());
        }
    }
    let mut shapes = Vec::new();
    while let Some(node) = children.next() {
        if node.has_tag_name((P, "extLst")) && children.peek().is_none() {
            break;
        }
        let tag = node.tag_name();
        let (mut kind, non_visual, properties, lock_name) = match (tag.namespace(), tag.name()) {
            (Some(P), "sp") => ("shape", "nvSpPr", "cNvSpPr", "spLocks"),
            (Some(P), "pic") => ("picture", "nvPicPr", "cNvPicPr", "picLocks"),
            (Some(P), "cxnSp") => ("connector", "nvCxnSpPr", "cNvCxnSpPr", "cxnSpLocks"),
            (Some(P), "graphicFrame") => (
                "graphicFrame",
                "nvGraphicFramePr",
                "cNvGraphicFramePr",
                "graphicFrameLocks",
            ),
            (Some(P), "grpSp") => ("group", "nvGrpSpPr", "cNvGrpSpPr", "grpSpLocks"),
            // A direct compatibility wrapper or content part can occupy an unidentifiable layer.
            _ => return Ok(Vec::new()),
        };
        let non_visual = single_child(node, P, non_visual)?;
        let identity = single_child(non_visual, P, "cNvPr")?;
        let properties = single_child(non_visual, P, properties)?;
        let id = unsigned(identity.attribute("id").ok_or_else(invalid_zip)?)?;
        require(id > 0 && shapes.len() < MAX_OBJECTS)?;
        if drawing_flag(unique_child(properties, A, lock_name)?, "noSelect")? {
            return Ok(Vec::new());
        }
        if kind == "shape" && drawing_flag(Some(properties), "txBox")? {
            kind = "textBox";
        }
        shapes.push(Shape {
            id,
            name: bounded_name(identity.attribute("name").unwrap_or("")),
            kind,
            range: node.range(),
        });
    }
    Ok(shapes)
}
