use super::{
    A, CT, Deck, MAX_ENTRIES, MAX_PACKAGE, MAX_PART, MAX_SLIDES, MAX_XML, P, P14, PKG,
    PRESENTATION, R, Section, TYPES, append_element, deletion, document, edit, escape,
    expected_hash, kind, mime, normalized_title, open_source, path, relationships_path,
    relative_part, require, require_fresh_output,
    shape_text::{require_unprotected, unique_child},
    single_child,
};
use crate::pptx_zip::PackageEdits;
use crate::{ApiError, ApiResult, error, invalid};
use roxmltree::Node;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;

const MAX_LAYOUTS_PER_MASTER: usize = 64;
const MAX_LAYOUT_PLACEHOLDERS: usize = 8;

fn unsupported() -> ApiError {
    error(
        "unsupported_slide",
        "A blank slide cannot be safely inserted after the selected slide",
    )
}

fn unsupported_layout_change() -> ApiError {
    error(
        "unsupported_slide",
        "The slide does not have a compatible layout in its current master",
    )
}

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    let include_layouts = match request.get("includeLayouts") {
        None if request.len() == 3 => false,
        Some(Value::Bool(true)) if request.len() == 4 => true,
        _ => return Err(invalid()),
    };
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let mut deck = Deck::read(&mut source)?;
    let insertion = Insertion::read(&mut deck, &mut source)?;
    let section_names = insertion
        .sections
        .iter()
        .flat_map(|section| std::iter::repeat_n(section.title.as_deref(), section.entries.len()));
    let mut slides = deck
        .slides
        .iter()
        .zip(section_names.chain(std::iter::repeat(None)))
        .enumerate()
        .map(|(index, (slide, section_name))| {
            let mut row = json!({
                "index": index,
                "hidden": slide.hidden,
                "canInsert": insertion.plan(&deck, index, None, false).is_ok(),
            });
            if let Some(title) = &slide.title {
                row["title"] = json!(title);
            }
            if let Some(name) = section_name {
                row["sectionName"] = json!(name);
            }
            row
        })
        .collect::<Vec<_>>();
    if include_layouts {
        let mut choices_by_master = BTreeMap::new();
        for (index, slide) in slides.iter_mut().enumerate() {
            if slide["canInsert"] != true {
                continue;
            }
            let Some(anchor) = &insertion.anchor_layouts[index] else {
                continue;
            };
            let choices = choices_by_master.entry(&anchor.master).or_insert_with(|| {
                master_layouts(&mut deck, &mut source, &anchor.master)
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|(id, part)| {
                        layout_choice(&mut deck, &mut source, &anchor.master, id, part).ok()
                    })
                    .collect::<Vec<_>>()
            });
            let options = choices
                .iter()
                .filter(|choice| insertion.plan(&deck, index, Some(choice), false).is_ok())
                .map(|choice| json!({"id":choice.id,"name":choice.name,"kind":choice.kind}))
                .collect::<Vec<_>>();
            if !options.is_empty() {
                slide["layouts"] = json!(options);
            }
        }
    }
    open_source(source_path, sha)?;
    Ok(json!({"sourceSha256":sha,"slideCount":slides.len(),"slides":slides}))
}

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    let layout_id = match request.get("layoutId") {
        None if request.len() == 5 => None,
        Some(id) if request.len() == 6 => Some(
            id.as_u64()
                .and_then(|id| u32::try_from(id).ok())
                .filter(|&id| id > 0)
                .ok_or_else(invalid)?,
        ),
        _ => return Err(invalid()),
    };
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = request
        .get("slideIndex")
        .and_then(Value::as_u64)
        .filter(|&value| value < MAX_SLIDES as u64)
        .ok_or_else(invalid)? as usize;
    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let mut deck = Deck::read(&mut source)?;
    let insertion = Insertion::read(&mut deck, &mut source)?;
    if index >= deck.slides.len() {
        return Err(invalid());
    }
    let layout = if let Some(id) = layout_id {
        let anchor = insertion.anchor_layouts[index]
            .as_ref()
            .ok_or_else(unsupported)?;
        let (_, part) = master_layouts(&mut deck, &mut source, &anchor.master)?
            .into_iter()
            .find(|(candidate, _)| *candidate == id)
            .ok_or_else(unsupported)?;
        Some(layout_choice(
            &mut deck,
            &mut source,
            &anchor.master,
            id,
            part,
        )?)
    } else {
        None
    };
    let plan = insertion.plan(&deck, index, layout.as_ref(), true)?;
    let anchor_identity = deck.slides[index].identity;
    let inserted_index = index + 1;
    let mut expected_order = deck
        .slides
        .iter()
        .map(|slide| (slide.part.as_str(), slide.identity))
        .collect::<Vec<_>>();
    expected_order.insert(inserted_index, (plan.new_slide.as_str(), plan.identity));
    let expected_sections = insertion.sections.iter().map(|section| {
        let mut order = section.order();
        if let Some(anchor) = order
            .iter()
            .position(|&identity| identity == anchor_identity)
        {
            order.insert(anchor + 1, plan.identity);
        }
        order
    });
    let output_sha = deck.write_candidate(
        source,
        (source_path, output_path),
        sha,
        &plan.edits,
        |verified| {
            require(
                verified
                    .slides
                    .iter()
                    .map(|slide| (slide.part.as_str(), slide.identity))
                    .eq(expected_order),
            )?;
            let inserted = &verified.slides[inserted_index];
            require(!inserted.hidden && inserted.title.is_none())?;
            if let Some(layout) = &layout {
                require(
                    internal_target(&verified.slide_relationships[inserted_index], "slideLayout")
                        == Some(layout.part.as_str()),
                )?;
                let slide = document(&verified.xml[&inserted.part])?;
                require(layout_placeholders(slide.root_element())? == layout.placeholders)?;
            }
            require(
                verified
                    .sections()?
                    .iter()
                    .map(Section::order)
                    .eq(expected_sections),
            )
        },
    )?;
    let mut reply = json!({"sourceSha256":sha,"outputSha256":output_sha,
        "slideCount":deck.slides.len()+1,"insertedIndex":inserted_index});
    if let Some(id) = layout_id {
        reply["layoutId"] = json!(id);
    }
    Ok(reply)
}

pub(crate) fn inspect_layout_change(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let mut deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let sections = deck.sections()?;
    let section_names = sections
        .iter()
        .flat_map(|section| std::iter::repeat_n(section.title.as_deref(), section.entries.len()))
        .chain(std::iter::repeat(None));
    let mut choices_by_master = BTreeMap::new();
    let mut slides = Vec::with_capacity(deck.slides.len());
    for (index, (anchor, section_name)) in read_layout_anchors(&mut deck, &mut source)
        .into_iter()
        .zip(section_names)
        .enumerate()
    {
        let layouts = if let Some(anchor) = anchor {
            let choices = choices_by_master
                .entry(anchor.master.clone())
                .or_insert_with(|| {
                    layout_change_choices(&mut deck, &mut source, &anchor.master)
                        .unwrap_or_default()
                });
            compatible_layouts(&deck, index, &anchor.part, choices)
                .unwrap_or_default()
                .into_iter()
                .map(|choice| json!({"id":choice.id,"name":choice.name,"kind":choice.kind}))
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let slide = &deck.slides[index];
        let mut row = json!({"index":index,"slideId":slide.identity,"hidden":slide.hidden,
            "layouts":layouts});
        if let Some(title) = &slide.title {
            row["title"] = json!(title);
        }
        if let Some(name) = section_name {
            row["sectionName"] = json!(name);
        }
        slides.push(row);
    }
    open_source(source_path, sha)?;
    Ok(json!({"sourceSha256":sha,"slideCount":slides.len(),"slides":slides}))
}

pub(crate) fn apply_layout_change(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = request
        .get("slideIndex")
        .and_then(Value::as_u64)
        .filter(|&value| value < MAX_SLIDES as u64)
        .ok_or_else(invalid)? as usize;
    let slide_id = request
        .get("slideId")
        .and_then(Value::as_u64)
        .and_then(|id| u32::try_from(id).ok())
        .filter(|id| (256..0x8000_0000).contains(id))
        .ok_or_else(invalid)?;
    let layout_id = request
        .get("layoutId")
        .and_then(Value::as_u64)
        .and_then(|id| u32::try_from(id).ok())
        .filter(|&id| id > 0)
        .ok_or_else(invalid)?;
    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let mut deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    deck.sections()?;
    let slide = deck.slides.get(index).ok_or_else(invalid)?;
    if slide.identity != slide_id {
        return Err(invalid());
    }
    let (relationship_id, relationship) =
        slide_layout_relationship(&deck.slide_relationships[index])
            .ok_or_else(unsupported_layout_change)?;
    let current = relationship.target.clone();
    let span = relationship.target_span.clone();
    let relationship_id = relationship_id.clone();
    let master = layout_master(&mut deck, &mut source, &current)?;
    let choices = layout_change_choices(&mut deck, &mut source, &master)?;
    let selected = compatible_layouts(&deck, index, &current, &choices)?
        .into_iter()
        .find(|choice| choice.id == layout_id)
        .ok_or_else(unsupported_layout_change)?;
    let slide = &deck.slides[index];
    let rels_part = relationships_path(&slide.part);
    let old = &deck.xml[&rels_part];
    let target = escape(&relative_part(&slide.part, &selected.part));
    let new = edit(old, vec![(span, target)])?;
    if deck.layout.expanded - old.len() + new.len() > MAX_PACKAGE
        || deck.xml_bytes - old.len() + new.len() > MAX_XML
    {
        return Err(unsupported_layout_change());
    }
    let mut edits = PackageEdits::default();
    edits.changed.insert(rels_part, new);
    let output_sha = deck.write_candidate(
        source,
        (source_path, output_path),
        sha,
        &edits,
        |verified| {
            require(
                verified
                    .slides
                    .iter()
                    .map(|slide| (slide.identity, slide.hidden))
                    .eq(deck
                        .slides
                        .iter()
                        .map(|slide| (slide.identity, slide.hidden))),
            )?;
            let (id, relationship) =
                slide_layout_relationship(&verified.slide_relationships[index])
                    .ok_or_else(unsupported_layout_change)?;
            require(id == &relationship_id && relationship.target == selected.part)
        },
    )?;
    Ok(
        json!({"sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":index,"slideId":slide_id,"layoutId":layout_id}),
    )
}

struct ChangeLayout {
    id: u32,
    part: String,
    name: String,
    kind: String,
    slots: BTreeMap<u32, PlaceholderSlot>,
}

#[derive(PartialEq, Eq)]
struct PlaceholderSlot {
    kind: &'static str,
    size: &'static str,
    orientation: &'static str,
    custom_prompt: bool,
}

fn layout_change_choices(
    deck: &mut Deck,
    file: &mut File,
    master: &str,
) -> ApiResult<Vec<ChangeLayout>> {
    let presentation = document(&deck.xml[PRESENTATION])?;
    let master_list = single_child(presentation.root_element(), P, "sldMasterIdLst")?;
    let registered = master_list.children().filter(|node| {
        node.has_tag_name((P, "sldMasterId"))
            && node
                .attribute((R, "id"))
                .and_then(|id| deck.main_relationships.get(id))
                .is_some_and(|rel| {
                    !rel.external && rel.kind == kind("slideMaster") && rel.target == master
                })
    });
    require(registered.count() == 1)?;
    master_layouts(deck, file, master).map(|entries| {
        entries
            .into_iter()
            .filter_map(|(id, part)| change_layout_choice(deck, file, master, id, part).ok())
            .collect()
    })
}

fn change_layout_choice(
    deck: &mut Deck,
    file: &mut File,
    master: &str,
    id: u32,
    part: String,
) -> ApiResult<ChangeLayout> {
    require(layout_master(deck, file, &part)? == master)?;
    let xml = document(&deck.xml[&part])?;
    let root = xml.root_element();
    let kind = root.attribute("type").unwrap_or("cust");
    require(matches!(
        kind,
        "title"
            | "tx"
            | "twoColTx"
            | "tbl"
            | "txAndChart"
            | "chartAndTx"
            | "dgm"
            | "chart"
            | "txAndClipArt"
            | "clipArtAndTx"
            | "titleOnly"
            | "blank"
            | "txAndObj"
            | "objAndTx"
            | "objOnly"
            | "obj"
            | "txAndMedia"
            | "mediaAndTx"
            | "objOverTx"
            | "txOverObj"
            | "txAndTwoObj"
            | "twoObjAndTx"
            | "twoObjOverTx"
            | "fourObj"
            | "vertTx"
            | "clipArtAndVertTx"
            | "vertTitleAndTx"
            | "vertTitleAndTxOverChart"
            | "twoObj"
            | "objAndTwoObj"
            | "twoObjAndObj"
            | "cust"
            | "secHead"
            | "twoTxTwoObj"
            | "objTx"
            | "picTx"
    ))?;
    let name = layout_name(root, "Slide Layout")?;
    let slots = placeholder_signature(root)?;
    Ok(ChangeLayout {
        id,
        part,
        name,
        kind: kind.to_owned(),
        slots,
    })
}

fn compatible_layouts<'a>(
    deck: &Deck,
    index: usize,
    current: &str,
    layouts: &'a [ChangeLayout],
) -> ApiResult<Vec<&'a ChangeLayout>> {
    let source = layouts
        .iter()
        .find(|layout| layout.part == current)
        .ok_or_else(unsupported_layout_change)?;
    let slide = document(&deck.xml[&deck.slides[index].part])?;
    let slots = placeholder_signature(slide.root_element())?;
    // PowerPoint inherits slide layout placeholders by idx, including the default 0.
    require(slots.keys().all(|id| source.slots.contains_key(id)))?;
    Ok(layouts
        .iter()
        .filter(|layout| layout.id != source.id && layout.slots == source.slots)
        .collect())
}

fn placeholder_signature(root: Node) -> ApiResult<BTreeMap<u32, PlaceholderSlot>> {
    let tree = single_child(single_child(root, P, "cSld")?, P, "spTree")?;
    let mut slots = BTreeMap::new();
    for shape in tree.children().filter(Node::is_element) {
        let mut markers = shape
            .descendants()
            .filter(|node| node.has_tag_name((P, "ph")));
        let Some(marker) = markers.next() else {
            continue;
        };
        let non_visual = match (shape.tag_name().namespace(), shape.tag_name().name()) {
            (Some(P), "sp") => "nvSpPr",
            (Some(P), "pic") => "nvPicPr",
            (Some(P), "graphicFrame") => "nvGraphicFramePr",
            _ => return Err(unsupported_layout_change()),
        };
        let properties = single_child(single_child(shape, P, non_visual)?, P, "nvPr")?;
        require(markers.next().is_none() && marker == single_child(properties, P, "ph")?)?;
        require(
            !marker.children().any(|node| node.is_element())
                && marker.attributes().all(|attr| {
                    attr.namespace().is_none()
                        && matches!(
                            attr.name(),
                            "type" | "idx" | "sz" | "orient" | "hasCustomPrompt"
                        )
                }),
        )?;
        let index = marker
            .attribute("idx")
            .unwrap_or("0")
            .parse::<u32>()
            .map_err(|_| unsupported_layout_change())?;
        let kind = placeholder_value(
            marker,
            "type",
            &[
                "title", "body", "ctrTitle", "subTitle", "dt", "sldNum", "ftr", "hdr", "obj",
                "chart", "tbl", "clipArt", "dgm", "media", "sldImg", "pic",
            ],
        )?
        .unwrap_or("obj");
        let size = placeholder_value(marker, "sz", &["full", "half", "quarter"])?.unwrap_or("full");
        let orientation = placeholder_value(marker, "orient", &["horz", "vert"])?.unwrap_or("horz");
        let custom_prompt = match marker.attribute("hasCustomPrompt") {
            None | Some("0" | "false") => false,
            Some("1" | "true") => true,
            _ => return Err(unsupported_layout_change()),
        };
        require(
            slots
                .insert(
                    index,
                    PlaceholderSlot {
                        kind,
                        size,
                        orientation,
                        custom_prompt,
                    },
                )
                .is_none(),
        )?;
    }
    Ok(slots)
}

struct Insertion {
    sections: Vec<Section>,
    last_fixed_position: usize,
    anchor_layouts: Vec<Option<AnchorLayout>>,
}

struct AnchorLayout {
    part: String,
    master: String,
}

struct LayoutChoice {
    id: u32,
    part: String,
    name: String,
    kind: &'static str,
    placeholders: Vec<Placeholder>,
}

#[derive(PartialEq, Eq)]
struct Placeholder {
    kind: Option<&'static str>,
    index: Option<u32>,
    size: Option<&'static str>,
    orientation: Option<&'static str>,
}

struct InsertPlan {
    edits: PackageEdits,
    new_slide: String,
    identity: u32,
}

impl Insertion {
    fn read(deck: &mut Deck, file: &mut File) -> ApiResult<Self> {
        let sections = deck.sections()?;
        let last_fixed_position = deletion::last_insertion_position(deck, file)?;
        let anchor_layouts = read_layout_anchors(deck, file);
        Ok(Self {
            sections,
            last_fixed_position,
            anchor_layouts,
        })
    }

    fn plan(
        &self,
        deck: &Deck,
        index: usize,
        layout_choice: Option<&LayoutChoice>,
        build: bool,
    ) -> ApiResult<InsertPlan> {
        if deck.slides.len() >= MAX_SLIDES
            || deck.layout.entries.len() + 2 > MAX_ENTRIES
            || index + 1 < self.last_fixed_position
        {
            return Err(unsupported());
        }
        let anchor = &deck.slides[index];
        let anchor_layout = self.anchor_layouts[index]
            .as_ref()
            .ok_or_else(unsupported)?;
        let layout = layout_choice.map_or(anchor_layout.part.as_str(), |choice| &choice.part);
        let new_slide = deck.unused_part(&anchor.part, "slide")?;
        let identity = (256..0x8000_0000)
            .find(|id| !deck.slide_ids.contains(id))
            .ok_or_else(unsupported)?;
        let relation_id = (1..=MAX_ENTRIES + 1)
            .map(|number| format!("rId{number}"))
            .find(|id| !deck.main_relationships.contains_key(id))
            .ok_or_else(unsupported)?;
        let mut presentation_edits = vec![(
            anchor.listing_range.end..anchor.listing_range.end,
            format!(
                "<p:sldId xmlns:p=\"{P}\" xmlns:r=\"{R}\" id=\"{identity}\" r:id=\"{relation_id}\"/>"
            ),
        )];
        if let Some((_, range)) = self
            .sections
            .iter()
            .flat_map(|section| &section.entries)
            .find(|(id, _)| *id == anchor.identity)
        {
            presentation_edits.push((
                range.end..range.end,
                format!("<p14:sldId xmlns:p14=\"{P14}\" id=\"{identity}\"/>"),
            ));
        }
        let main_rels = relationships_path(PRESENTATION);
        let main_relation = relationship(&relation_id, "slide", PRESENTATION, &new_slide);
        let content_type = format!(
            "<Override xmlns=\"{CT}\" PartName=\"/{}\" ContentType=\"{}\"/>",
            escape(&new_slide),
            mime("slide"),
        );
        let (master_shapes, placeholders) = if let Some(choice) = layout_choice {
            let placeholders = choice
                .placeholders
                .iter()
                .enumerate()
                .map(|(index, placeholder)| placeholder_shape(index + 2, placeholder))
                .collect::<String>();
            ("", format!("\n      {placeholders}"))
        } else {
            (" showMasterSp=\"0\"", String::new())
        };
        let slide = format!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:p="{P}" xmlns:a="{A}"{master_shapes}>
  <p:cSld>
    <p:spTree>
      <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
      <p:grpSpPr/>{placeholders}
    </p:spTree>
  </p:cSld>
  <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>"#
        );
        let slide_layout = relationship("rId1", "slideLayout", &new_slide, layout);
        let slide_rels = format!("<Relationships xmlns=\"{PKG}\">{slide_layout}</Relationships>");
        let growth = [
            (
                PRESENTATION,
                presentation_edits.iter().map(|(_, xml)| xml.len()).sum(),
            ),
            (main_rels.as_str(), main_relation.len()),
            (TYPES, content_type.len()),
        ];
        let total_growth =
            growth.iter().map(|(_, bytes)| bytes).sum::<usize>() + slide.len() + slide_rels.len();
        if !growth
            .iter()
            .all(|(part, bytes)| deck.xml[*part].len() + bytes <= MAX_PART)
            || deck.layout.expanded + total_growth > MAX_PACKAGE
            || deck.xml_bytes + total_growth > MAX_XML
        {
            return Err(unsupported());
        }
        let mut edits = PackageEdits::default();
        if build {
            edits.changed.insert(
                PRESENTATION.into(),
                edit(&deck.xml[PRESENTATION], presentation_edits)?,
            );
            edits.changed.insert(
                main_rels.clone(),
                append_element(&deck.xml[&main_rels], main_relation)?,
            );
            edits.changed.insert(
                TYPES.into(),
                append_element(&deck.xml[TYPES], content_type)?,
            );
            edits.added.insert(new_slide.clone(), slide.into_bytes());
            edits
                .added
                .insert(relationships_path(&new_slide), slide_rels.into_bytes());
        }
        Ok(InsertPlan {
            edits,
            new_slide,
            identity,
        })
    }
}

fn read_layout_anchors(deck: &mut Deck, file: &mut File) -> Vec<Option<AnchorLayout>> {
    let anchors = deck
        .slide_relationships
        .iter()
        .map(|rels| internal_target(rels, "slideLayout").map(str::to_owned))
        .collect::<Vec<_>>();
    let mut masters = BTreeMap::new();
    anchors
        .into_iter()
        .map(|part| {
            let part = part?;
            let master = masters
                .entry(part.clone())
                .or_insert_with(|| layout_master(deck, file, &part).ok())
                .clone()?;
            Some(AnchorLayout { part, master })
        })
        .collect()
}

fn layout_master(deck: &mut Deck, file: &mut File, layout: &str) -> ApiResult<String> {
    require(deck.content_type(layout) == mime("slideLayout"))?;
    deck.load_xml(file, layout)?;
    require(
        document(&deck.xml[layout])?
            .root_element()
            .has_tag_name((P, "sldLayout")),
    )?;
    let layout_rels = deck.load_relationships(file, layout)?;
    let master = internal_target(&layout_rels, "slideMaster").ok_or_else(unsupported)?;
    require(deck.content_type(master) == mime("slideMaster"))?;
    deck.load_xml(file, master)?;
    require(
        document(&deck.xml[master])?
            .root_element()
            .has_tag_name((P, "sldMaster")),
    )?;
    Ok(master.to_owned())
}

fn master_layouts(deck: &mut Deck, file: &mut File, master: &str) -> ApiResult<Vec<(u32, String)>> {
    let relationships = deck.load_relationships(file, master)?;
    let xml = document(&deck.xml[master])?;
    let Some(list) = unique_child(xml.root_element(), P, "sldLayoutIdLst")? else {
        return Ok(Vec::new());
    };
    let mut ids = BTreeSet::new();
    let mut targets = BTreeSet::new();
    let mut layouts = Vec::new();
    let layout_kind = kind("slideLayout");
    for entry in list.children().filter(Node::is_element) {
        require(entry.has_tag_name((P, "sldLayoutId")) && ids.len() < MAX_LAYOUTS_PER_MASTER)?;
        let id = entry
            .attribute("id")
            .and_then(|id| id.parse::<u32>().ok())
            .filter(|&id| id > 0)
            .ok_or_else(unsupported)?;
        require(ids.insert(id))?;
        let relationship = entry
            .attribute((R, "id"))
            .and_then(|id| relationships.get(id));
        if let Some(relationship) =
            relationship.filter(|rel| !rel.external && rel.kind == layout_kind)
        {
            require(targets.insert(relationship.target.as_str()))?;
            layouts.push((id, relationship.target.clone()));
        }
    }
    Ok(layouts)
}

fn layout_choice(
    deck: &mut Deck,
    file: &mut File,
    master: &str,
    id: u32,
    part: String,
) -> ApiResult<LayoutChoice> {
    require(layout_master(deck, file, &part)? == master)?;
    let xml = document(&deck.xml[&part])?;
    let root = xml.root_element();
    let (kind, default_name) = match root.attribute("type").unwrap_or("cust") {
        "blank" => ("blank", "Blank"),
        "title" => ("title", "Title Slide"),
        "titleOnly" => ("titleOnly", "Title Only"),
        "tx" => ("tx", "Title and Text"),
        "obj" => ("obj", "Title and Content"),
        "secHead" => ("secHead", "Section Header"),
        "cust" => ("cust", "Custom Layout"),
        _ => return Err(unsupported()),
    };
    let name = layout_name(root, default_name)?;
    let placeholders = layout_placeholders(root)?;
    require(placeholders.is_empty() == (kind == "blank"))?;
    Ok(LayoutChoice {
        id,
        part,
        name,
        kind,
        placeholders,
    })
}

fn layout_name(root: Node, default_name: &str) -> ApiResult<String> {
    Ok(single_child(root, P, "cSld")?
        .attribute("name")
        .and_then(normalized_title)
        .or_else(|| root.attribute("matchingName").and_then(normalized_title))
        .unwrap_or_else(|| default_name.to_owned()))
}

fn layout_placeholders(root: Node) -> ApiResult<Vec<Placeholder>> {
    let tree = single_child(single_child(root, P, "cSld")?, P, "spTree")?;
    let mut placeholders = Vec::new();
    let mut identities = BTreeSet::new();
    for shape in tree.children().filter(Node::is_element) {
        let mut markers = shape
            .descendants()
            .filter(|node| node.has_tag_name((P, "ph")));
        let Some(marker) = markers.next() else {
            continue;
        };
        require(markers.next().is_none())?;
        if matches!(
            marker.attribute("type"),
            Some("dt" | "ftr" | "hdr" | "sldNum")
        ) {
            continue;
        }
        require(shape.has_tag_name((P, "sp")) && placeholders.len() < MAX_LAYOUT_PLACEHOLDERS)?;
        let properties = single_child(single_child(shape, P, "nvSpPr")?, P, "nvPr")?;
        require(marker == single_child(properties, P, "ph")?)?;
        require(marker.attributes().all(|attribute| {
            attribute.namespace().is_none()
                && match attribute.name() {
                    "type" | "idx" | "sz" | "orient" => true,
                    "hasCustomPrompt" => matches!(attribute.value(), "false" | "0"),
                    _ => false,
                }
        }))?;
        let kind = placeholder_value(
            marker,
            "type",
            &["title", "ctrTitle", "subTitle", "body", "obj"],
        )?;
        let size = placeholder_value(marker, "sz", &["full", "half", "quarter"])?;
        let orientation = placeholder_value(marker, "orient", &["horz", "vert"])?;
        let index = marker
            .attribute("idx")
            .map(|value| value.parse::<u32>().map_err(|_| unsupported()))
            .transpose()?;
        require(identities.insert((kind.unwrap_or("obj"), index.unwrap_or(0))))?;
        placeholders.push(Placeholder {
            kind,
            index,
            size,
            orientation,
        });
    }
    Ok(placeholders)
}

fn placeholder_value(
    node: Node,
    attribute: &str,
    allowed: &'static [&'static str],
) -> ApiResult<Option<&'static str>> {
    node.attribute(attribute)
        .map(|value| {
            allowed
                .iter()
                .copied()
                .find(|&item| item == value)
                .ok_or_else(unsupported)
        })
        .transpose()
}

fn placeholder_shape(id: usize, placeholder: &Placeholder) -> String {
    let mut attributes = String::new();
    for (key, value) in [
        ("type", placeholder.kind),
        ("sz", placeholder.size),
        ("orient", placeholder.orientation),
    ] {
        if let Some(value) = value {
            attributes.push_str(&format!(" {key}=\"{value}\""));
        }
    }
    if let Some(index) = placeholder.index {
        attributes.push_str(&format!(" idx=\"{index}\""));
    }
    format!(
        "<p:sp><p:nvSpPr><p:cNvPr id=\"{id}\" name=\"Placeholder {id}\"/><p:cNvSpPr/>\
         <p:nvPr><p:ph{attributes}/></p:nvPr></p:nvSpPr><p:spPr/>\
         <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>"
    )
}

fn internal_target<'a>(relationships: &'a super::Relationships, name: &str) -> Option<&'a str> {
    internal_relationship(relationships, name).map(|(_, rel)| rel.target.as_str())
}

fn slide_layout_relationship(
    relationships: &super::Relationships,
) -> Option<(&String, &super::Relationship)> {
    internal_relationship(relationships, "slideLayout")
}

fn internal_relationship<'a>(
    relationships: &'a super::Relationships,
    name: &str,
) -> Option<(&'a String, &'a super::Relationship)> {
    let relationship_kind = kind(name);
    let mut matches = relationships
        .iter()
        .filter(|(_, rel)| rel.kind == relationship_kind);
    let (id, relation) = matches.next()?;
    (!relation.external && matches.next().is_none()).then_some((id, relation))
}

fn relationship(id: &str, name: &str, owner: &str, target: &str) -> String {
    let target = escape(&relative_part(owner, target));
    format!("<Relationship xmlns=\"{PKG}\" Id=\"{id}\" Type=\"{R}/{name}\" Target=\"{target}\"/>")
}
