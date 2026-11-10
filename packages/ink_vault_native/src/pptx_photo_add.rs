use super::text_box::{insertion_site, slide_size};
use super::{
    A, CT, Deck, MAX_ENTRIES, MAX_PACKAGE, MAX_PART, MAX_SLIDES, MAX_XML, P, PKG, R, TYPES,
    append_element, document, edit, expected_hash, open_source, path, relative_part,
    relationships_path, require, require_fresh_output, single_child,
};
use crate::docx_photo::read_asset;
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid, string};
use serde_json::{Map, Value, json};
use std::path::Path;

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    slide_size(&deck)?;
    let sections = deck.sections()?;
    let section_names = sections
        .iter()
        .flat_map(|section| std::iter::repeat_n(section.title.as_deref(), section.entries.len()));
    let slides = deck
        .slides
        .iter()
        .zip(section_names.chain(std::iter::repeat(None)))
        .enumerate()
        .map(|(index, (slide, section_name))| {
            let xml = &deck.xml[&slide.part];
            let rel_part = relationships_path(&slide.part);
            let rel_xml = deck.xml.get(&rel_part);
            let can_add = insertion_site(xml).is_ok()
                && xml.len() + 1024 <= MAX_PART
                && rel_xml.is_none_or(|xml| xml.len() + 256 <= MAX_PART)
                && deck.layout.entries.len() + 1 + usize::from(rel_xml.is_none()) <= MAX_ENTRIES
                && deck.xml_bytes + 2048 <= MAX_XML
                && deck.layout.expanded + 2048 <= MAX_PACKAGE;
            let mut row = json!({"index":index,"hidden":slide.hidden,"canAdd":can_add});
            if let Some(title) = &slide.title {
                row["title"] = json!(title);
            }
            if let Some(name) = section_name {
                row["sectionName"] = json!(name);
            }
            row
        })
        .collect::<Vec<_>>();
    open_source(source_path, sha)?;
    Ok(json!({"sourceSha256":sha,"slideCount":slides.len(),"slides":slides}))
}

pub(crate) fn add(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let asset_path = Path::new(string(request.get("assetPath"))?);
    if !asset_path.is_absolute()
        || output_path.parent() != source_path.parent()
        || asset_path.parent() != source_path.parent()
        || asset_path == source_path
        || asset_path == output_path
    {
        return Err(invalid());
    }
    let sha = expected_hash(request.get("sourceSha256"))?;
    let asset_sha = expected_hash(request.get("assetSha256"))?;
    let slide_index = request
        .get("slideIndex")
        .and_then(Value::as_u64)
        .filter(|&index| index < MAX_SLIDES as u64)
        .ok_or_else(invalid)? as usize;

    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    let size = slide_size(&deck)?;
    let slide = deck.slides.get(slide_index).ok_or_else(invalid)?;
    let slide_xml = &deck.xml[&slide.part];
    let site = insertion_site(slide_xml)?;
    let (image, format, width, height) = read_asset(asset_path, asset_sha)?;
    let image_bytes = image.len();
    let media = (1..=MAX_ENTRIES + 1)
        .map(|i| format!("ppt/media/piv-{}-{i}.{}", &asset_sha[..16], format.extension()))
        .find(|name| !deck.layout.contains_casefold(name))
        .ok_or_else(invalid_zip)?;

    let original = document(slide_xml)?;
    let referenced: std::collections::BTreeSet<_> = original
        .descendants()
        .filter(roxmltree::Node::is_element)
        .flat_map(|node| node.attributes())
        .filter(|attr| attr.namespace() == Some(R))
        .map(|attr| attr.value())
        .collect();
    let links = &deck.slide_relationships[slide_index];
    let relationship = (1..=MAX_ENTRIES + referenced.len() + 1)
        .map(|i| format!("rId{i}"))
        .find(|id| !links.contains_key(id) && !referenced.contains(id.as_str()))
        .ok_or_else(invalid_zip)?;

    let frame = Frame::fit(size, (width.into(), height.into()));
    let picture = frame.picture(site.id, &relationship);
    let mut edits = PackageEdits::default();
    edits.changed.insert(
        slide.part.clone(),
        edit(slide_xml, vec![(site.offset..site.offset, picture)])?,
    );
    let rel_part = relationships_path(&slide.part);
    let target = relative_part(&slide.part, &media);
    let link = format!(
        "<Relationship xmlns=\"{PKG}\" Id=\"{relationship}\" Type=\"{R}/image\" Target=\"{target}\"/>"
    );
    let mut xml_growth = edits.changed[&slide.part].len() - slide_xml.len();
    if let Some(xml) = deck.xml.get(&rel_part) {
        let result = append_element(xml, link)?;
        xml_growth += result.len() - xml.len();
        edits.changed.insert(rel_part, result);
    } else {
        let result = format!("<Relationships xmlns=\"{PKG}\">{link}</Relationships>").into_bytes();
        xml_growth += result.len();
        edits.added.insert(rel_part, result);
    }
    if deck.content_type(&media) != format.mime() {
        let xml = &deck.xml[TYPES];
        let entry = format!(
            "<Override xmlns=\"{CT}\" PartName=\"/{media}\" ContentType=\"{}\"/>",
            format.mime()
        );
        let result = append_element(xml, entry)?;
        xml_growth += result.len() - xml.len();
        edits.changed.insert(TYPES.to_owned(), result);
    }
    edits.added.insert(media.clone(), image);
    require(
        deck.layout.entries.len() + edits.added.len() <= MAX_ENTRIES
            && deck.xml_bytes + xml_growth <= MAX_XML
            && deck.layout.expanded + xml_growth + image_bytes <= MAX_PACKAGE,
    )?;
    let output_sha = deck.write_candidate(
        source,
        (source_path, output_path),
        sha,
        &edits,
        |verified| {
            require(verified.slides.len() == deck.slides.len())?;
            let selected = &verified.slides[slide_index];
            require(
                selected.part == slide.part
                    && selected.identity == slide.identity
                    && selected.hidden == slide.hidden
                    && verified.content_type(&media) == format.mime(),
            )?;
            let link = verified.slide_relationships[slide_index]
                .get(&relationship)
                .ok_or_else(invalid_zip)?;
            require(!link.external && link.kind == format!("{R}/image") && link.target == media)?;
            frame.verify(&verified.xml[&slide.part], site.id, &relationship)
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":slide_index,"shapeId":site.id,
    }))
}

struct Frame {
    x: u64,
    y: u64,
    width: u64,
    height: u64,
}

impl Frame {
    fn fit((slide_width, slide_height): (u64, u64), (width, height): (u64, u64)) -> Self {
        let max_width = slide_width * 4 / 5;
        let max_height = slide_height * 4 / 5;
        let (width, height) = if width * max_height >= height * max_width {
            (max_width, (max_width * height / width).max(1))
        } else {
            ((max_height * width / height).max(1), max_height)
        };
        Self {
            x: (slide_width - width) / 2,
            y: (slide_height - height) / 2,
            width,
            height,
        }
    }

    fn picture(&self, id: u32, relationship: &str) -> String {
        let Self { x, y, width, height } = self;
        format!(
            "<p:pic xmlns:p=\"{P}\" xmlns:a=\"{A}\" xmlns:r=\"{R}\">\
             <p:nvPicPr><p:cNvPr id=\"{id}\" name=\"Photo {id}\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
             <p:blipFill><a:blip r:embed=\"{relationship}\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
             <p:spPr><a:xfrm><a:off x=\"{x}\" y=\"{y}\"/><a:ext cx=\"{width}\" cy=\"{height}\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>\
             </p:pic>"
        )
    }

    fn verify(&self, xml: &str, id: u32, relationship: &str) -> ApiResult<()> {
        let xml = document(xml)?;
        let tree = single_child(single_child(xml.root_element(), P, "cSld")?, P, "spTree")?;
        let id = id.to_string();
        let mut pictures = tree
            .children()
            .filter(|node| node.has_tag_name((P, "pic")))
            .filter(|picture| {
                single_child(*picture, P, "nvPicPr")
                    .and_then(|props| single_child(props, P, "cNvPr"))
                    .is_ok_and(|props| props.attribute("id") == Some(&id))
            });
        let picture = pictures.next().ok_or_else(invalid_zip)?;
        require(pictures.next().is_none())?;
        let blip = single_child(single_child(picture, P, "blipFill")?, A, "blip")?;
        require(blip.attribute((R, "embed")) == Some(relationship))?;
        let transform = single_child(single_child(picture, P, "spPr")?, A, "xfrm")?;
        let offset = single_child(transform, A, "off")?;
        let extent = single_child(transform, A, "ext")?;
        for (node, attribute, value) in [
            (offset, "x", self.x),
            (offset, "y", self.y),
            (extent, "cx", self.width),
            (extent, "cy", self.height),
        ] {
            require(node.attribute(attribute).and_then(|value| value.parse().ok()) == Some(value))?;
        }
        Ok(())
    }
}
