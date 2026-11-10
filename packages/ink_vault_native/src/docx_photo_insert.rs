use super::body_text::paragraph::insertion_location;
use super::{
    A, ApiResult, File, MAX_PHOTOS, Node, PIC, Package, R, W, WP, children, document, drawing_id,
    edit, expected_hash, invalid, invalid_zip, open_source, parse_relationships, read_asset,
    read_xml, requested_path, require, require_fresh_output, single_child, unsupported_document,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

pub(crate) fn insert(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 8 {
        return Err(invalid());
    }
    let source_path = requested_path(request.get("sourcePath"), true)?;
    let output_path = requested_path(request.get("outputPath"), true)?;
    let asset_path = requested_path(request.get("assetPath"), false)?;
    if source_path.parent() != output_path.parent()
        || source_path.parent() != asset_path.parent()
        || asset_path == source_path
        || asset_path == output_path
    {
        return Err(invalid());
    }
    let sha = expected_hash(request.get("sourceSha256"))?;
    let asset_sha = expected_hash(request.get("assetSha256"))?;
    let mut source = open_source(&source_path, sha)?;
    require_fresh_output(&output_path)?;
    let package = Package::read(&mut source)?;
    if package.photos.len() == MAX_PHOTOS {
        return Err(unsupported_document());
    }
    let xml = document(&package.main_xml)?;
    let root = xml.root_element();
    let (offset, paragraph_index) = insertion_location(request, &package, root)?;
    let id = next_picture_id(&package, &mut source, root)?;
    let (asset, format, width, height) = read_asset(&asset_path, asset_sha)?;
    let (relationship, media_part, mut edits) = package.plan_media(asset, format)?;
    let (width, height) = fitted_extent(width.into(), height.into());
    let picture = picture_paragraph(id, &relationship, width, height);
    edits.changed.insert(
        package.main_part.clone(),
        edit(&package.main_xml, vec![(offset..offset, picture)])?,
    );
    let output_sha = package.write_candidate(
        source,
        (&source_path, &output_path),
        sha,
        &edits,
        |written| {
            let xml = document(&written.main_xml)?;
            let body = single_child(xml.root_element(), W, "body")?;
            let paragraph = children(body, W, "p")
                .nth(paragraph_index)
                .ok_or_else(invalid_zip)?;
            let drawing = single_child(single_child(paragraph, W, "r")?, W, "drawing")?;
            let inserted = written
                .photos
                .iter()
                .find(|photo| photo.id == id)
                .ok_or_else(invalid_zip)?;
            require(
                paragraph.range().start == offset
                    && inserted.drawing_range == drawing.range()
                    && inserted.media_part == media_part
                    && inserted.media_sha == asset_sha
                    && inserted.format == format
                    && written.photos.len() == package.photos.len() + 1
                    && written
                        .photos
                        .iter()
                        .filter(|photo| photo.id != id)
                        .zip(&package.photos)
                        .all(|(after, before)| after.same_picture(before)),
            )
        },
    )?;
    Ok(json!({"sourceSha256":sha,"outputSha256":output_sha,"paragraphIndex":paragraph_index}))
}

fn next_picture_id(package: &Package, source: &mut File, root: Node<'_, '_>) -> ApiResult<u32> {
    let mut ids: BTreeSet<_> = root.descendants().filter_map(drawing_id).collect();
    if !package.rels_xml.is_empty() {
        let links = parse_relationships(&package.rels_xml, &package.main_part, &package.layout)?;
        for link in links.values().filter(|link| {
            !link.external
                && matches!(
                    link.kind.rsplit_once('/'),
                    Some((
                        R,
                        "header"
                            | "footer"
                            | "footnotes"
                            | "endnotes"
                            | "comments"
                            | "glossaryDocument"
                    ))
                )
        }) {
            let story = read_xml(&package.layout, source, &link.target)?;
            ids.extend(
                document(&story)?
                    .root_element()
                    .descendants()
                    .filter_map(drawing_id),
            );
        }
    }
    // Word reserves 0 and values above the signed 32-bit drawing ID range.
    (1..i32::MAX as u32)
        .find(|id| !ids.contains(id))
        .ok_or_else(unsupported_document)
}

fn fitted_extent(width: u64, height: u64) -> (u64, u64) {
    const EMU_PER_INCH: u64 = 914_400;
    const EMU_PER_PIXEL_AT_96_DPI: u64 = EMU_PER_INCH / 96;
    const MAX_WIDTH: u64 = 6 * EMU_PER_INCH;
    const MAX_HEIGHT: u64 = 8 * EMU_PER_INCH;
    let width = width * EMU_PER_PIXEL_AT_96_DPI;
    let height = height * EMU_PER_PIXEL_AT_96_DPI;
    if width <= MAX_WIDTH && height <= MAX_HEIGHT {
        (width, height)
    } else if width * MAX_HEIGHT >= height * MAX_WIDTH {
        (MAX_WIDTH, (MAX_WIDTH * height / width).max(1))
    } else {
        ((MAX_HEIGHT * width / height).max(1), MAX_HEIGHT)
    }
}

fn picture_paragraph(id: u32, relationship: &str, width: u64, height: u64) -> String {
    format!(
        "<w:p xmlns:w=\"{W}\" xmlns:wp=\"{WP}\" xmlns:a=\"{A}\" xmlns:pic=\"{PIC}\" xmlns:r=\"{R}\">\
         <w:r><w:drawing><wp:inline>\
         <wp:extent cx=\"{width}\" cy=\"{height}\"/><wp:docPr id=\"{id}\" name=\"Photo {id}\"/>\
         <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>\
         <a:graphic><a:graphicData uri=\"{PIC}\"><pic:pic>\
         <pic:nvPicPr><pic:cNvPr id=\"0\" name=\"Photo {id}\"/><pic:cNvPicPr/></pic:nvPicPr>\
         <pic:blipFill><a:blip r:embed=\"{relationship}\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
         <pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"{width}\" cy=\"{height}\"/></a:xfrm>\
         <a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>\
         </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
    )
}
