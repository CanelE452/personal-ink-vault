use super::{
    A, Deck, MAX_PACKAGE, MAX_SLIDES, MAX_XML, P, PRESENTATION, document, edit, expected_hash,
    open_source, path, require, require_fresh_output, single_child, unsigned,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid};
use roxmltree::{Attribute, Node};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::ops::Range;

const MIN_OFFSET: i64 = i32::MIN as i64;
const MAX_COORDINATE: i64 = i32::MAX as i64;
const MAX_SHAPES: usize = 400;
const MAX_NAME_UNITS: usize = 1_024;
const GEOMETRY_KEYS: [&str; 4] = ["xEmu", "yEmu", "widthEmu", "heightEmu"];

#[derive(Clone, Copy, PartialEq, Eq)]
struct Geometry {
    x: i64,
    y: i64,
    width: i64,
    height: i64,
}

impl Geometry {
    fn new([x, y, width, height]: [i64; 4]) -> Option<Self> {
        if [x, y]
            .into_iter()
            .all(|value| (MIN_OFFSET..=MAX_COORDINATE).contains(&value))
            && [width, height]
                .into_iter()
                .all(|value| (1..=MAX_COORDINATE).contains(&value))
        {
            Some(Self {
                x,
                y,
                width,
                height,
            })
        } else {
            None
        }
    }

    fn values(self) -> [i64; 4] {
        [self.x, self.y, self.width, self.height]
    }

    fn add_to_reply(self, mut reply: Value) -> Value {
        for (key, value) in GEOMETRY_KEYS.into_iter().zip(self.values()) {
            reply[key] = json!(value);
        }
        reply
    }
}

#[derive(PartialEq, Eq)]
struct ShapeGeometry<'a> {
    id: u32,
    kind: &'static str,
    name: &'a str,
    geometry: Geometry,
    can_move: bool,
    can_resize: bool,
    aspect_ratio_locked: bool,
    ranges: [Range<usize>; 4],
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
        let shapes: Vec<_> = editable_shapes(parsed.root_element())?
            .into_iter()
            .map(|shape| {
                shape.geometry.add_to_reply(json!({
                    "shapeId": shape.id, "name": shape.name, "kind": shape.kind,
                    "canMove": shape.can_move, "canResize": shape.can_resize,
                    "aspectRatioLocked": shape.aspect_ratio_locked,
                }))
            })
            .collect();
        json!({"sourceSha256": sha, "slideCount": slide_count, "slideIndex": index, "shapes": shapes})
    } else {
        let slides: Vec<_> = deck
            .slides
            .iter()
            .enumerate()
            .map(|(index, slide)| {
                let mut reply = json!({"index": index, "hidden": slide.hidden});
                if let Some(title) = &slide.title {
                    reply["title"] = json!(title);
                }
                reply
            })
            .collect();
        json!({"sourceSha256": sha, "slideCount": slide_count, "slides": slides})
    };
    open_source(source_path, sha)?;
    Ok(reply)
}

pub(crate) fn replace(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 10 {
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
    let mut values = [0; 4];
    for (value, key) in values.iter_mut().zip(GEOMETRY_KEYS) {
        *value = request
            .get(key)
            .and_then(Value::as_i64)
            .ok_or_else(invalid)?;
    }
    let geometry = Geometry::new(values).ok_or_else(invalid)?;
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
    let original = shape.geometry;
    let moved = (original.x, original.y) != (geometry.x, geometry.y);
    let resized = (original.width, original.height) != (geometry.width, geometry.height);
    if !(moved || resized)
        || (moved && !shape.can_move)
        || (resized && !shape.can_resize)
        || (resized && shape.aspect_ratio_locked && !same_aspect_ratio(original, geometry))
    {
        return Err(invalid());
    }
    let mut replacements = Vec::new();
    for ((before, after), range) in original
        .values()
        .into_iter()
        .zip(geometry.values())
        .zip(&shape.ranges)
    {
        if before != after {
            replacements.push((range.clone(), after.to_string()));
        }
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
            let parsed = document(&verified.xml[&slide.part])?;
            let updated = editable_shapes(parsed.root_element())?;
            let actual = updated
                .iter()
                .find(|shape| shape.id == shape_id)
                .ok_or_else(invalid_zip)?;
            require(
                actual.geometry == geometry
                    && actual.kind == shape.kind
                    && actual.name == shape.name
                    && actual.can_move == shape.can_move
                    && actual.can_resize == shape.can_resize
                    && actual.aspect_ratio_locked == shape.aspect_ratio_locked,
            )
        },
    )?;
    Ok(geometry.add_to_reply(json!({
        "sourceSha256": sha, "outputSha256": output_sha, "slideCount": deck.slides.len(),
        "slideIndex": index, "shapeId": shape_id,
    })))
}

fn same_aspect_ratio(original: Geometry, geometry: Geometry) -> bool {
    fn proportional(new_extent: i64, original_extent: i64, original_other: i64) -> i128 {
        let basis = i128::from(original_extent);
        (i128::from(new_extent) * i128::from(original_other) + basis / 2) / basis
    }
    i128::from(geometry.height) == proportional(geometry.width, original.width, original.height)
        || i128::from(geometry.width)
            == proportional(geometry.height, original.height, original.width)
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

pub(super) fn slide_index(value: &Value) -> ApiResult<usize> {
    value
        .as_u64()
        .filter(|&index| index < MAX_SLIDES as u64)
        .map(|index| index as usize)
        .ok_or_else(invalid)
}

fn editable_shapes<'a, 'input>(root: Node<'a, 'input>) -> ApiResult<Vec<ShapeGeometry<'a>>> {
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
    for node in tree.children() {
        if let Some(shape) = editable_shape(node)? {
            require(shapes.len() < MAX_SHAPES)?;
            shapes.push(shape);
        }
    }
    Ok(shapes)
}

fn editable_shape<'a, 'input>(node: Node<'a, 'input>) -> ApiResult<Option<ShapeGeometry<'a>>> {
    let (kind, non_visual, object_properties, lock_name) = if node.has_tag_name((P, "sp")) {
        ("shape", "nvSpPr", "cNvSpPr", "spLocks")
    } else if node.has_tag_name((P, "pic")) {
        ("picture", "nvPicPr", "cNvPicPr", "picLocks")
    } else {
        return Ok(None);
    };
    let Some(properties) = unique_child(node, P, non_visual)? else {
        return Ok(None);
    };
    let identity = single_child(properties, P, "cNvPr")?;
    let id = unsigned(identity.attribute("id").ok_or_else(invalid_zip)?)?;
    if id == 0
        || unique_child(properties, P, "nvPr")?.is_some_and(|properties| {
            properties
                .children()
                .any(|node| node.has_tag_name((P, "ph")))
        })
    {
        return Ok(None);
    }
    let locks = unique_child(properties, P, object_properties)?
        .map(|properties| unique_child(properties, A, lock_name))
        .transpose()?
        .flatten();
    let can_move = !drawing_flag(locks, "noMove")?;
    let can_resize = !drawing_flag(locks, "noResize")?;
    if drawing_flag(locks, "noSelect")? || !(can_move || can_resize) {
        return Ok(None);
    }
    let aspect_ratio_locked = drawing_flag(locks, "noChangeAspect")?;
    let Some(transform) = unique_child(node, P, "spPr")?
        .map(|properties| unique_child(properties, A, "xfrm"))
        .transpose()?
        .flatten()
    else {
        return Ok(None);
    };
    let (Some(offset), Some(extents)) = (
        unique_child(transform, A, "off")?,
        unique_child(transform, A, "ext")?,
    ) else {
        return Ok(None);
    };
    let attributes = [
        offset.attribute_node("x"),
        offset.attribute_node("y"),
        extents.attribute_node("cx"),
        extents.attribute_node("cy"),
    ];
    let [Some(x), Some(y), Some(width), Some(height)] = attributes else {
        return Ok(None);
    };
    let attributes = [x, y, width, height];
    let mut values = [0; 4];
    for (slot, attribute) in values.iter_mut().zip(attributes) {
        let Ok(value) = attribute.value().trim().parse() else {
            return Ok(None);
        };
        *slot = value;
    }
    let Some(geometry) = Geometry::new(values) else {
        return Ok(None);
    };
    Ok(Some(ShapeGeometry {
        id,
        kind,
        name: bounded_name(identity.attribute("name").unwrap_or("")),
        geometry,
        can_move,
        can_resize,
        aspect_ratio_locked,
        ranges: attributes.map(|attribute: Attribute<'_, '_>| attribute.range_value()),
    }))
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

pub(super) fn drawing_flag(node: Option<Node<'_, '_>>, name: &str) -> ApiResult<bool> {
    match node.and_then(|node| node.attribute(name)).map(str::trim) {
        None | Some("0" | "false") => Ok(false),
        Some("1" | "true") => Ok(true),
        Some(_) => Err(invalid_zip()),
    }
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
