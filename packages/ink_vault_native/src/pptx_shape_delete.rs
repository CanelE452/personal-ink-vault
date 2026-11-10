use super::shape_geometry::{
    bounded_name, drawing_flag, require_unprotected, slide_index, unique_child,
};
use super::{
    A, A16, Deck, P, P14, R, Relationships, document, edit, expected_hash, ignorable_or_element,
    open_source, path, require, require_fresh_output, single_child, unsigned,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid};
use roxmltree::Node;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;

const A14: &str = "http://schemas.microsoft.com/office/drawing/2010/main";
const MC: &str = "http://schemas.openxmlformats.org/markup-compatibility/2006";
const MAX_SHAPES: usize = 400;

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
        shape_ids(parsed.root_element())?;
        let shapes: Vec<_> =
            deletable_shapes(parsed.root_element(), &deck.slide_relationships[index])?
                .into_iter()
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
    if request.len() != 6 {
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
    let mut remaining_ids = shape_ids(parsed.root_element())?;
    let shape = deletable_shapes(parsed.root_element(), &deck.slide_relationships[index])?
        .into_iter()
        .find(|shape| shape.id == shape_id)
        .ok_or_else(invalid)?;
    require(remaining_ids.remove(&shape_id))?;
    let edits = PackageEdits {
        changed: BTreeMap::from([(
            slide.part.clone(),
            edit(xml, vec![(shape.range, String::new())])?,
        )]),
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
            require(shape_ids(parsed.root_element())? == remaining_ids)
        },
    )?;
    Ok(
        json!({"sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":index,"shapeId":shape_id}),
    )
}

fn shape_ids(root: Node) -> ApiResult<BTreeSet<u32>> {
    let mut ids = BTreeSet::new();
    for node in root
        .descendants()
        .filter(|node| node.has_tag_name((P, "cNvPr")))
    {
        let id = unsigned(node.attribute("id").ok_or_else(invalid_zip)?)?;
        require(ids.insert(id))?;
    }
    Ok(ids)
}

fn deletable_shapes<'a, 'input>(
    root: Node<'a, 'input>,
    relationships: &Relationships,
) -> ApiResult<Vec<Shape<'a>>> {
    let tree = single_child(single_child(root, P, "cSld")?, P, "spTree")?;
    require(tree.children().all(ignorable_or_element))?;
    let Some(references) = referenced_shapes(root, relationships)? else {
        return Ok(Vec::new());
    };
    let mut shapes = Vec::new();
    for shape in tree.children().filter(|node| node.has_tag_name((P, "sp"))) {
        let non_visual = single_child(shape, P, "nvSpPr")?;
        let identity = single_child(non_visual, P, "cNvPr")?;
        let id = unsigned(identity.attribute("id").ok_or_else(invalid_zip)?)?;
        if id == 0 || references.contains(&id) {
            continue;
        }
        require(shape.children().all(ignorable_or_element))?;
        require(shape.children().filter(Node::is_element).all(|child| {
            child.tag_name().namespace() == Some(P)
                && matches!(
                    child.tag_name().name(),
                    "nvSpPr" | "spPr" | "style" | "txBody" | "extLst"
                )
        }))?;
        for name in ["style", "txBody", "extLst"] {
            unique_child(shape, P, name)?;
        }
        require(
            non_visual.children().all(ignorable_or_element)
                && non_visual.children().filter(Node::is_element).count() == 3,
        )?;
        require(
            shape
                .descendants()
                .skip(1)
                .filter(Node::is_element)
                .all(|child| {
                    child.tag_name().namespace() != Some(P)
                        || (child.tag_name().name() == "cNvPr" && child == identity)
                        || !matches!(
                            child.tag_name().name(),
                            "sp" | "pic"
                                | "cxnSp"
                                | "graphicFrame"
                                | "grpSp"
                                | "contentPart"
                                | "cNvPr"
                        )
                }),
        )?;
        let properties = single_child(non_visual, P, "cNvSpPr")?;
        let application = single_child(non_visual, P, "nvPr")?;
        if application
            .children()
            .filter(Node::is_element)
            .any(|node| !node.has_tag_name((P, "extLst")))
        {
            continue;
        }
        let lock = unique_child(properties, A, "spLocks")?;
        if drawing_flag(lock, "noSelect")? || drawing_flag(lock, "noDelete")? {
            continue;
        }
        let drawing = single_child(shape, P, "spPr")?;
        let freeform = unique_child(drawing, A, "custGeom")?.is_some();
        let preset = unique_child(drawing, A, "prstGeom")?.is_some();
        require(!(freeform && preset))?;
        let kind = if drawing_flag(Some(properties), "txBox")? {
            "textBox"
        } else if freeform {
            "freeform"
        } else {
            "shape"
        };
        require(shapes.len() < MAX_SHAPES)?;
        shapes.push(Shape {
            id,
            name: bounded_name(identity.attribute("name").unwrap_or("")),
            kind,
            range: shape.range(),
        });
    }
    Ok(shapes)
}

fn referenced_shapes(
    root: Node,
    relationships: &Relationships,
) -> ApiResult<Option<BTreeSet<u32>>> {
    // The slide's comment or VML parts can have references outside its XML.
    if relationships.values().any(|relation| {
        let name = relation
            .kind
            .rsplit('/')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        name.contains("comment") || name == "vmldrawing"
    }) {
        return Ok(None);
    }
    let timing = unique_child(root, P, "timing")?;
    if timing.is_some_and(|node| {
        node.descendants()
            .filter(Node::is_element)
            .any(|element| !matches!(element.tag_name().namespace(), Some(P | A)))
    }) {
        return Ok(None);
    }
    let mut references = BTreeSet::new();
    for node in root.descendants().filter(Node::is_element) {
        if (node.has_tag_name((MC, "AlternateContent")) && !transition_alternatives(root, node))
            || (node.tag_name().name() == "extLst" && !known_extensions(node))
        {
            return Ok(None);
        }
        let connector = node.has_tag_name((A, "stCxn")) || node.has_tag_name((A, "endCxn"));
        for attribute in node.attributes() {
            if attribute.namespace() == Some(R) {
                require(relationships.contains_key(attribute.value()))?;
            }
            let name = attribute.name();
            if name.eq_ignore_ascii_case("spid")
                || name.eq_ignore_ascii_case("shapeId")
                || (connector && name == "id")
            {
                let Ok(id) = unsigned(attribute.value().trim()) else {
                    return Ok(None);
                };
                references.insert(id);
            }
        }
    }
    Ok(Some(references))
}

fn transition_alternatives(root: Node, node: Node) -> bool {
    if node.parent() != Some(root) || !node.children().all(ignorable_or_element) {
        return false;
    }
    let mut branches = node.children().filter(Node::is_element).peekable();
    if !branches
        .peek()
        .is_some_and(|branch| branch.has_tag_name((MC, "Choice")))
    {
        return false;
    }
    while let Some(branch) = branches.next() {
        if !(branch.has_tag_name((MC, "Choice"))
            || (branch.has_tag_name((MC, "Fallback")) && branches.peek().is_none()))
            || !branch.children().all(ignorable_or_element)
            || branch.children().filter(Node::is_element).count() != 1
            || !branch
                .first_element_child()
                .is_some_and(|element| element.has_tag_name((P, "transition")))
        {
            return false;
        }
    }
    true
}

fn known_extensions(list: Node) -> bool {
    let Some(namespace @ (P | A)) = list.tag_name().namespace() else {
        return false;
    };
    list.children().all(ignorable_or_element)
        && list.children().filter(Node::is_element).all(|extension| {
            let mut children = extension.children().filter(Node::is_element);
            extension.has_tag_name((namespace, "ext"))
                && extension.children().all(ignorable_or_element)
                && children.next().is_some_and(|child| {
                    child.first_element_child().is_none()
                        && child.children().all(ignorable_or_element)
                        && (child.has_tag_name((P14, "creationId"))
                            || child.has_tag_name((A16, "creationId"))
                            || child.has_tag_name((A14, "useLocalDpi")))
                })
                && children.next().is_none()
        })
}
