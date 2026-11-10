use super::super::table::preview;
use super::{
    ApiResult, MAX_INDEX, MC, Node, Package, PackageEdits, Ranges, W, XML, children, document,
    edge_space, edit, escape, expected_hash, index, invalid, invalid_zip, open_source,
    requested_path, require, require_fresh_output, single_child, unsupported_document, valid_text,
    verify_source,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

struct Anchor<'a, 'input> {
    paragraph: Node<'a, 'input>,
    before: bool,
    after: bool,
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
    let anchors = anchors(&package, xml.root_element())?;
    let paragraphs = anchors
        .iter()
        .enumerate()
        .map(|(index, anchor)| {
            json!({"index":index,"text":preview(anchor.paragraph),
                   "canBefore":anchor.before,"canAfter":anchor.after})
        })
        .collect::<Vec<_>>();
    verify_source(&mut source, &path, sha)?;
    Ok(json!({"sourceSha256":sha,"paragraphs":paragraphs}))
}

pub(crate) fn insert(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = requested_path(request.get("sourcePath"), true)?;
    let output_path = requested_path(request.get("outputPath"), true)?;
    if source_path.parent() != output_path.parent() {
        return Err(invalid());
    }
    let sha = expected_hash(request.get("sourceSha256"))?;
    let text = request
        .get("text")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty() && valid_text(value))
        .ok_or_else(invalid)?;
    let mut source = open_source(&source_path, sha)?;
    require_fresh_output(&output_path)?;
    let package = Package::read(&mut source)?;
    let xml = document(&package.main_xml)?;
    let (offset, paragraph_index) = insertion_location(request, &package, xml.root_element())?;
    let space = if edge_space(text) {
        r#" xml:space="preserve""#
    } else {
        ""
    };
    let paragraph = format!(
        r#"<w:p xmlns:w="{W}"><w:r><w:t{space}>{}</w:t></w:r></w:p>"#,
        escape(text)
    );
    let mut edits = PackageEdits::default();
    edits.changed.insert(
        package.main_part.clone(),
        edit(&package.main_xml, vec![(offset..offset, paragraph)])?,
    );
    let output_sha = package.write_candidate(
        source,
        (&source_path, &output_path),
        sha,
        &edits,
        |written| {
            let xml = document(&written.main_xml)?;
            let body = single_child(xml.root_element(), W, "body")?;
            let inserted = children(body, W, "p")
                .nth(paragraph_index)
                .ok_or_else(invalid_zip)?;
            require(inserted.range().start == offset)?;
            let run = single_child(inserted, W, "r")?;
            let inserted_text = single_child(run, W, "t")?;
            require(inserted_text.text() == Some(text))?;
            require(
                !edge_space(text) || inserted_text.attribute((XML, "space")) == Some("preserve"),
            )
        },
    )?;
    Ok(json!({"sourceSha256":sha,"outputSha256":output_sha,"paragraphIndex":paragraph_index}))
}

pub(in crate::docx_photo) fn insertion_location(
    request: &Map<String, Value>,
    package: &Package,
    root: Node<'_, '_>,
) -> ApiResult<(usize, usize)> {
    let index = index(request.get("anchorParagraphIndex"))?;
    let anchors = anchors(package, root)?;
    let anchor = anchors.get(index).ok_or_else(invalid)?;
    let range = anchor.paragraph.range();
    match request.get("position").and_then(Value::as_str) {
        Some("before") if anchor.before => Ok((range.start, index)),
        Some("after") if anchor.after => Ok((range.end, index + 1)),
        _ => Err(invalid()),
    }
}

fn anchors<'a, 'input>(
    package: &Package,
    root: Node<'a, 'input>,
) -> ApiResult<Vec<Anchor<'a, 'input>>> {
    if package.track_revisions {
        return Err(unsupported_document());
    }
    let body = single_child(root, W, "body")?;
    if let Some(section) = children(body, W, "sectPr").next() {
        require(body.last_element_child() == Some(section))?;
    }
    let mut ranges = Ranges::default();
    let mut marks = BTreeSet::new();
    let mut anchors = Vec::new();
    let mut closed = true;
    for block in body.children().filter(Node::is_element) {
        let before = closed;
        ranges.inspect(block)?;
        inspect_marks(block, &mut marks)?;
        closed = ranges.fields.is_empty() && ranges.revisions.is_empty() && marks.is_empty();
        if anchors.len() < MAX_INDEX && block.has_tag_name((W, "p")) {
            let has_section = block
                .descendants()
                .any(|node| node.has_tag_name((W, "sectPr")));
            anchors.push(Anchor {
                paragraph: block,
                before,
                after: closed && !has_section,
            });
        }
    }
    if !closed {
        return Err(unsupported_document());
    }
    Ok(anchors)
}

pub(in crate::docx_photo) fn inspect_marks<'a>(
    block: Node<'a, '_>,
    marks: &mut BTreeSet<(&'a str, &'a str)>,
) -> ApiResult<()> {
    for node in block.descendants().filter(Node::is_element) {
        let tag = node.tag_name();
        if tag.namespace() != Some(W) {
            continue;
        }
        let (kind, id, start) = match tag.name() {
            "proofErr" => match node.attribute((W, "type")) {
                Some("spellStart") => ("spell", "", true),
                Some("spellEnd") => ("spell", "", false),
                Some("gramStart") => ("grammar", "", true),
                Some("gramEnd") => ("grammar", "", false),
                _ => return Err(unsupported_document()),
            },
            name => {
                let range = match name {
                    "bookmarkStart" => Some(("bookmark", true)),
                    "bookmarkEnd" => Some(("bookmark", false)),
                    "permStart" => Some(("permission", true)),
                    "permEnd" => Some(("permission", false)),
                    _ => name
                        .strip_suffix("RangeStart")
                        .map(|kind| (kind, true))
                        .or_else(|| name.strip_suffix("RangeEnd").map(|kind| (kind, false))),
                };
                let Some((kind, start)) = range else { continue };
                let id = node
                    .attribute((W, "id"))
                    .filter(|id| !id.is_empty())
                    .ok_or_else(unsupported_document)?;
                (kind, id, start)
            }
        };
        if node
            .ancestors()
            .any(|ancestor| ancestor.has_tag_name((W, "txbxContent")))
        {
            continue;
        }
        if node
            .ancestors()
            .any(|ancestor| ancestor.has_tag_name((MC, "AlternateContent")))
        {
            return Err(unsupported_document());
        }
        let matched = if start {
            marks.insert((kind, id))
        } else {
            marks.remove(&(kind, id))
        };
        if !matched {
            return Err(unsupported_document());
        }
    }
    Ok(())
}
