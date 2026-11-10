//! Source-package PPTX slide edits. The caller renders and commits the PDF.
use crate::pptx_zip::{
    Layout, MAX_ENTRIES, MAX_PACKAGE, PackageEdits, canonical_part, invalid_zip, io_error,
};
use crate::{ApiError, ApiResult, error, invalid, string};
use regex::Regex;
use roxmltree::{Document, Node, ParsingOptions};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{File, symlink_metadata};
use std::io::{ErrorKind, Read, Seek, SeekFrom};
use std::ops::Range;
use std::path::Path;
use std::sync::OnceLock;

#[path = "pptx_delete.rs"]
pub(super) mod deletion;
#[path = "pptx_find_replace.rs"]
pub(super) mod find_replace;
#[path = "pptx_insert.rs"]
pub(super) mod insertion;
#[path = "pptx_photo_add.rs"]
pub(super) mod photo_add;
#[path = "pptx_shape_delete.rs"]
pub(super) mod shape_delete;
#[path = "pptx_shape_geometry.rs"]
pub(super) mod shape_geometry;
#[path = "pptx_shape_order.rs"]
pub(super) mod shape_order;
#[path = "pptx_shape_text.rs"]
pub(super) mod shape_text;
#[path = "pptx_slide_background.rs"]
pub(super) mod slide_background;
#[path = "pptx_slide_display.rs"]
pub(super) mod slide_display;
#[path = "pptx_speaker_notes.rs"]
pub(super) mod speaker_notes;
#[path = "pptx_table_add.rs"]
pub(super) mod table_add;
#[path = "pptx_table_cell_text.rs"]
pub(super) mod table_cell_text;
#[path = "pptx_table_structure.rs"]
pub(super) mod table_structure;
#[path = "pptx_text_box.rs"]
pub(super) mod text_box;

const P: &str = "http://schemas.openxmlformats.org/presentationml/2006/main";
pub(super) const A: &str = "http://schemas.openxmlformats.org/drawingml/2006/main";
pub(super) const R: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
pub(super) const PKG: &str = "http://schemas.openxmlformats.org/package/2006/relationships";
pub(super) const CT: &str = "http://schemas.openxmlformats.org/package/2006/content-types";
const P14: &str = "http://schemas.microsoft.com/office/powerpoint/2010/main";
const A16: &str = "http://schemas.microsoft.com/office/drawing/2014/main";
const MS_MEDIA: &str = "http://schemas.microsoft.com/office/2007/relationships/media";
const PRESENTATION: &str = "ppt/presentation.xml";
pub(super) const TYPES: &str = "[Content_Types].xml";
pub(super) const ROOT_RELATIONSHIPS: &str = "_rels/.rels";
const MIME: &str = "application/vnd.openxmlformats-officedocument.presentationml.";
const MAX_SLIDES: usize = 256;
pub(super) const MAX_PART: usize = 8 * 1024 * 1024;
const MAX_XML: usize = 32 * 1024 * 1024;

fn source_changed() -> ApiError {
    error("source_changed", "The PPTX source hash changed")
}

fn unsupported_slide() -> ApiError {
    error(
        "unsupported_slide",
        "The selected slide cannot be safely duplicated",
    )
}

fn output_exists() -> ApiError {
    error(
        "output_exists",
        "The private PPTX destination already exists",
    )
}

pub(super) fn require(value: bool) -> ApiResult<()> {
    if value { Ok(()) } else { Err(invalid_zip()) }
}

fn path(value: Option<&Value>) -> ApiResult<&Path> {
    let path = Path::new(string(value)?);
    if !path.is_absolute()
        || !path
            .extension()
            .and_then(|v| v.to_str())
            .is_some_and(|v| v.eq_ignore_ascii_case("pptx"))
    {
        return Err(invalid());
    }
    Ok(path)
}

pub(super) fn expected_hash(value: Option<&Value>) -> ApiResult<&str> {
    let sha = string(value)?;
    if sha.len() != 64
        || !sha
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(invalid());
    }
    Ok(sha)
}

pub(super) fn hash_file(file: &mut File) -> ApiResult<String> {
    file.seek(SeekFrom::Start(0)).map_err(io_error)?;
    let mut sha = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    let mut total = 0;
    loop {
        let size = file.read(&mut buffer).map_err(io_error)?;
        if size == 0 {
            break;
        }
        total += size;
        require(total <= MAX_PACKAGE)?;
        sha.update(&buffer[..size]);
    }
    Ok(sha
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn open_source(path: &Path, expected: &str) -> ApiResult<File> {
    let meta = symlink_metadata(path).map_err(io_error)?;
    require(meta.is_file() && meta.len() <= MAX_PACKAGE as u64)?;
    let mut source = File::open(path).map_err(io_error)?;
    if hash_file(&mut source)? != expected {
        return Err(source_changed());
    }
    Ok(source)
}

fn require_fresh_output(path: &Path) -> ApiResult<()> {
    match symlink_metadata(path) {
        Ok(_) => Err(output_exists()),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        Err(e) => Err(io_error(e)),
    }
}

pub(super) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut file = open_source(source_path, sha)?;
    let deck = Deck::read(&mut file)?;
    let slides = deck.slides.iter().enumerate().map(|(index,slide)| {
        let mut row = json!({"index":index,"canDuplicate":deck.plan(index,sha,false).is_ok(),"hidden":slide.hidden});
        if let Some(title) = &slide.title {
            row["title"] = json!(title);
        }
        row
    }).collect::<Vec<_>>();
    open_source(source_path, sha)?;
    Ok(json!({"sourceSha256":sha,"slideCount":slides.len(),"slides":slides}))
}

pub(super) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 5 {
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
    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    let plan = deck
        .plan(index, sha, true)
        .map_err(|_| unsupported_slide())?;
    let mut expected_order = deck
        .slides
        .iter()
        .map(|slide| slide.part.as_str())
        .collect::<Vec<_>>();
    expected_order.insert(index + 1, &plan.new_slide);
    let slide_count = expected_order.len();
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
                    .map(|s| s.part.as_str())
                    .eq(expected_order),
            )
        },
    )?;
    Ok(json!({"sourceSha256":sha,"outputSha256":output_sha,
        "slideCount":slide_count,"duplicateIndex":index+1}))
}

pub(super) fn reorder_inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    let sections = deck.sections()?;
    let section_memberships = sections
        .iter()
        .filter(|section| !section.entries.is_empty())
        .enumerate()
        .flat_map(|(group, section)| {
            std::iter::repeat_n(
                Some((group, section.title.as_deref())),
                section.entries.len(),
            )
        });
    let mut slides = Vec::with_capacity(deck.slides.len());
    for ((index, slide), membership) in deck
        .slides
        .iter()
        .enumerate()
        .zip(section_memberships.chain(std::iter::repeat(None)))
    {
        let mut row = json!({"index":index,"hidden":slide.hidden});
        if let Some(title) = &slide.title {
            row["title"] = json!(title);
        }
        if let Some((group, title)) = membership {
            row["sectionGroup"] = json!(group);
            if let Some(title) = title {
                row["sectionTitle"] = json!(title);
            }
        }
        slides.push(row);
    }
    open_source(source_path, sha)?;
    Ok(json!({"sourceSha256":sha,"slideCount":slides.len(),"slides":slides}))
}

pub(super) fn match_slide_identity(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 5 {
        return Err(invalid());
    }
    let previous_path = path(request.get("previousPath"))?;
    let previous_sha = expected_hash(request.get("previousSha256"))?;
    let current_path = path(request.get("currentPath"))?;
    let current_sha = expected_hash(request.get("currentSha256"))?;

    let previous = Deck::read(&mut open_source(previous_path, previous_sha)?)?
        .slides
        .into_iter()
        .map(|slide| slide.identity)
        .collect::<Vec<_>>();
    let current_indices = Deck::read(&mut open_source(current_path, current_sha)?)?
        .slides
        .into_iter()
        .enumerate()
        .map(|(index, slide)| (slide.identity, index))
        .collect::<BTreeMap<_, _>>();
    let previous_to_current = previous
        .into_iter()
        .map(|identity| current_indices.get(&identity).copied())
        .collect::<Vec<_>>();
    open_source(previous_path, previous_sha)?;
    open_source(current_path, current_sha)?;
    Ok(json!({
        "previousSha256": previous_sha,
        "currentSha256": current_sha,
        "currentSlideCount": current_indices.len(),
        "previousToCurrent": previous_to_current,
    }))
}

pub(super) fn reorder_apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let slide_index = |key: &str| {
        request
            .get(key)
            .and_then(Value::as_u64)
            .filter(|&value| value < MAX_SLIDES as u64)
            .map(|value| value as usize)
            .ok_or_else(invalid)
    };
    let source_index = slide_index("sourceIndex")?;
    let target_index = slide_index("targetIndex")?;
    let after = request
        .get("after")
        .and_then(Value::as_bool)
        .ok_or_else(invalid)?;
    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    let slide_count = deck.slides.len();
    if source_index == target_index || source_index >= slide_count || target_index >= slide_count {
        return Err(invalid());
    }
    let destination_index =
        target_index + usize::from(after) - usize::from(source_index < target_index);
    let sections = deck.sections()?;
    let presentation = &deck.xml[PRESENTATION];
    let mut order = (0..slide_count).collect::<Vec<_>>();
    order.remove(source_index);
    order.insert(destination_index, source_index);
    let mut edits = Vec::new();
    for (current, &incoming) in order.iter().enumerate() {
        if current != incoming {
            edits.push((
                deck.slides[current].listing_range.clone(),
                presentation[deck.slides[incoming].listing_range.clone()].to_owned(),
            ));
        }
    }
    let (expected_sections, membership_changed) =
        deck.reorder_sections(&sections, source_index, target_index, after, &mut edits)?;
    if destination_index == source_index && !membership_changed {
        return Err(invalid());
    }
    let edited = edit(presentation, edits)?;
    let growth = edited.len().saturating_sub(presentation.len());
    require(deck.layout.expanded + growth <= MAX_PACKAGE && deck.xml_bytes + growth <= MAX_XML)?;
    let edits = PackageEdits {
        changed: BTreeMap::from([(PRESENTATION.to_owned(), edited)]),
        ..PackageEdits::default()
    };
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
                    .map(|s| (s.part.as_str(), s.identity))
                    .eq(order.iter().map(|&index| {
                        let slide = &deck.slides[index];
                        (slide.part.as_str(), slide.identity)
                    })),
            )?;
            require(
                verified
                    .sections()?
                    .iter()
                    .map(Section::order)
                    .eq(expected_sections),
            )
        },
    )?;
    Ok(json!({"sourceSha256":sha,"outputSha256":output_sha,
        "slideCount":slide_count,"sourceIndex":source_index,"destinationIndex":destination_index}))
}

#[derive(Clone)]
pub(super) struct Relationship {
    pub(super) kind: String,
    pub(super) target: String,
    pub(super) external: bool,
    target_span: Range<usize>,
    range: Range<usize>,
}
pub(super) type Relationships = BTreeMap<String, Relationship>;

struct Slide {
    part: String,
    hidden: bool,
    title: Option<String>,
    identity: u32,
    relationship_id: String,
    listing_range: Range<usize>,
}

struct Section {
    title: Option<String>,
    entries: Vec<(u32, Range<usize>)>,
}

impl Section {
    fn order(&self) -> Vec<u32> {
        self.entries.iter().map(|(id, _)| *id).collect()
    }
}

#[derive(Default)]
struct CreationIds {
    pages: BTreeSet<u32>,
    shapes: BTreeSet<String>,
}

struct Deck {
    layout: Layout,
    xml: BTreeMap<String, String>,
    xml_bytes: usize,
    defaults: BTreeMap<String, String>,
    overrides: BTreeMap<String, String>,
    slide_parts: BTreeSet<String>,
    slides: Vec<Slide>,
    slide_relationships: Vec<Relationships>,
    notes_owners: BTreeMap<String, usize>,
    main_relationships: Relationships,
    slide_ids: BTreeSet<u32>,
    ids: CreationIds,
}

struct Plan {
    edits: PackageEdits,
    new_slide: String,
}

impl Deck {
    fn read(file: &mut File) -> ApiResult<Self> {
        let layout = Layout::parse(file)?;
        require(!layout.entries.iter().any(|entry| {
            entry
                .name
                .to_ascii_lowercase()
                .starts_with("_xmlsignatures/")
        }))?;
        let mut deck = Self {
            layout,
            xml: BTreeMap::new(),
            xml_bytes: 0,
            defaults: BTreeMap::new(),
            overrides: BTreeMap::new(),
            slide_parts: BTreeSet::new(),
            slides: vec![],
            slide_relationships: vec![],
            notes_owners: BTreeMap::new(),
            main_relationships: BTreeMap::new(),
            slide_ids: BTreeSet::new(),
            ids: CreationIds::default(),
        };
        for part in [TYPES, ROOT_RELATIONSHIPS, PRESENTATION] {
            deck.load_xml(file, part)?;
        }
        let (defaults, overrides) = content_types(&deck.xml[TYPES], &deck.layout)?;
        deck.defaults = defaults;
        deck.overrides = overrides;
        let roots = parse_relationships(&deck.xml[ROOT_RELATIONSHIPS], "", &deck.layout)?;
        let mut main = roots
            .values()
            .filter(|rel| rel.kind == kind("officeDocument"));
        let main_rel = main.next().ok_or_else(invalid_zip)?;
        require(!main_rel.external && main_rel.target == PRESENTATION && main.next().is_none())?;
        require(deck.content_type(PRESENTATION) == mime("presentation.main"))?;
        deck.main_relationships = deck.load_relationships(file, PRESENTATION)?;
        let listing = document(&deck.xml[PRESENTATION])?;
        let root = listing.root_element();
        require(root.has_tag_name((P, "presentation")))?;
        let list = single_child(root, P, "sldIdLst")?;
        let mut parts = vec![];
        for slide in list.children().filter(Node::is_element) {
            require(parts.len() < MAX_SLIDES && slide.has_tag_name((P, "sldId")))?;
            let id = unsigned(slide.attribute("id").ok_or_else(invalid_zip)?)?;
            require((256..0x8000_0000).contains(&id) && deck.slide_ids.insert(id))?;
            let relationship_id = slide.attribute((R, "id")).ok_or_else(invalid_zip)?;
            let rel = deck
                .main_relationships
                .get(relationship_id)
                .ok_or_else(invalid_zip)?;
            require(
                rel.kind == kind("slide")
                    && !rel.external
                    && deck.content_type(&rel.target) == mime("slide"),
            )?;
            require(deck.slide_parts.insert(rel.target.clone()))?;
            parts.push((
                rel.target.clone(),
                id,
                relationship_id.to_owned(),
                slide.range(),
            ));
        }
        require(!parts.is_empty())?;
        drop(listing);
        for (part, identity, relationship_id, listing_range) in parts {
            deck.load_xml(file, &part)?;
            let rels = deck.load_relationships(file, &part)?;
            for rel in rels
                .values()
                .filter(|rel| rel.kind == kind("notesSlide") && !rel.external)
            {
                *deck.notes_owners.entry(rel.target.clone()).or_default() += 1;
                deck.load_xml(file, &rel.target)?;
                deck.load_relationships(file, &rel.target)?;
            }
            let document = document(&deck.xml[&part])?;
            let slide = document.root_element();
            require(slide.has_tag_name((P, "sld")))?;
            single_child(single_child(slide, P, "cSld")?, P, "spTree")?;
            let hidden = match slide.attribute("show") {
                None | Some("1" | "true") => false,
                Some("0" | "false") => true,
                _ => return Err(invalid_zip()),
            };
            deck.slides.push(Slide {
                part,
                hidden,
                title: slide_title(slide),
                identity,
                relationship_id,
                listing_range,
            });
            deck.slide_relationships.push(rels);
        }
        for part in deck.slide_parts.iter().chain(deck.notes_owners.keys()) {
            let xml = document(&deck.xml[part])?;
            for node in xml.descendants().filter(Node::is_element) {
                if node.has_tag_name((P14, "creationId")) {
                    if let Some(Ok(id)) = node.attribute("val").map(unsigned) {
                        deck.ids.pages.insert(id);
                    }
                } else if node.has_tag_name((A16, "creationId")) {
                    if let Some(id) = node.attribute("id").filter(|id| valid_guid(id)) {
                        deck.ids.shapes.insert(id.to_ascii_uppercase());
                    }
                }
            }
        }
        Ok(deck)
    }

    fn sections(&self) -> ApiResult<Vec<Section>> {
        let doc = document(&self.xml[PRESENTATION])?;
        let root = doc.root_element();
        let mut lists = root
            .descendants()
            .filter(|n| n.has_tag_name((P14, "sectionLst")));
        let Some(list) = lists.next() else {
            return Ok(Vec::new());
        };
        require(lists.next().is_none())?;
        let extensions = list
            .parent()
            .filter(|n| n.has_tag_name((P, "ext")))
            .and_then(|n| n.parent())
            .filter(|n| n.has_tag_name((P, "extLst")))
            .ok_or_else(invalid_zip)?;
        require(extensions.parent() == Some(root) && list.children().all(ignorable_or_element))?;
        let mut sections = Vec::new();
        let mut ids = BTreeSet::new();
        for section in list.children().filter(Node::is_element) {
            require(
                section.has_tag_name((P14, "section"))
                    && section.children().all(ignorable_or_element),
            )?;
            if let Some(id) = section.attribute("id") {
                require(valid_guid(id) && ids.insert(id.to_ascii_uppercase()))?;
            }
            let slides = single_child(section, P14, "sldIdLst")?;
            require(slides.children().all(ignorable_or_element))?;
            let mut entries = Vec::new();
            for slide in slides.children().filter(Node::is_element) {
                require(
                    slide.has_tag_name((P14, "sldId"))
                        && slide.attributes().len() == 1
                        && !slide.has_children(),
                )?;
                let identity = unsigned(slide.attribute("id").ok_or_else(invalid_zip)?)?;
                entries.push((identity, slide.range()));
            }
            sections.push(Section {
                title: section.attribute("name").and_then(normalized_title),
                entries,
            });
        }
        require(
            !sections.is_empty()
                && sections
                    .iter()
                    .flat_map(|s| s.entries.iter().map(|(id, _)| *id))
                    .eq(self.slides.iter().map(|s| s.identity)),
        )?;
        Ok(sections)
    }

    fn reorder_sections(
        &self,
        sections: &[Section],
        source: usize,
        target: usize,
        after: bool,
        edits: &mut Vec<Edit>,
    ) -> ApiResult<(Vec<Vec<u32>>, bool)> {
        let mut expected = sections.iter().map(Section::order).collect::<Vec<_>>();
        if sections.is_empty() {
            return Ok((expected, false));
        }
        let find_position = |index: usize| {
            let id = self.slides[index].identity;
            expected
                .iter()
                .enumerate()
                .find_map(|(section, order)| {
                    order
                        .iter()
                        .position(|&candidate| candidate == id)
                        .map(|entry| (section, entry))
                })
                .ok_or_else(invalid_zip)
        };
        let (from_section, from_entry) = find_position(source)?;
        let (to_section, to_entry) = find_position(target)?;
        let (identity, source_range) = &sections[from_section].entries[from_entry];
        let (_, target_range) = &sections[to_section].entries[to_entry];
        let insertion = if after {
            target_range.end
        } else {
            target_range.start
        };
        let entry = if from_section == to_section {
            self.xml[PRESENTATION][source_range.clone()].to_owned()
        } else {
            // Namespace declarations inherited from the source section may not be in scope here.
            format!("<p14:sldId xmlns:p14=\"{P14}\" id=\"{identity}\"/>")
        };
        edits.push((source_range.clone(), String::new()));
        edits.push((insertion..insertion, entry));
        expected[from_section].remove(from_entry);
        let destination = to_entry + usize::from(after)
            - usize::from(from_section == to_section && from_entry < to_entry);
        expected[to_section].insert(destination, *identity);
        Ok((expected, from_section != to_section))
    }

    fn write_candidate(
        &self,
        mut source: File,
        (source_path, output_path): (&Path, &Path),
        sha: &str,
        edits: &PackageEdits,
        verify: impl FnOnce(&Deck) -> ApiResult<()>,
    ) -> ApiResult<String> {
        let mut temporary =
            tempfile::NamedTempFile::new_in(output_path.parent().ok_or_else(invalid)?)
                .map_err(io_error)?;
        let candidate = temporary.as_file_mut();
        self.layout.rewrite(&mut source, candidate, edits)?;
        candidate.sync_all().map_err(io_error)?;
        let verified = Deck::read(candidate)?;
        self.layout.verify_unchanged(&verified.layout, edits)?;
        verified.layout.verify_payloads(candidate)?;
        for (part, data) in edits.changed.iter().chain(&edits.added) {
            require(verified.layout.read(candidate, part, data.len())? == *data)?;
        }
        verify(&verified)?;
        let output_sha = hash_file(candidate)?;
        if hash_file(&mut source)? != sha {
            return Err(source_changed());
        }
        open_source(source_path, sha)?;
        temporary.persist_noclobber(output_path).map_err(|e| {
            if e.error.kind() == ErrorKind::AlreadyExists {
                output_exists()
            } else {
                io_error(e.error)
            }
        })?;
        Ok(output_sha)
    }

    fn load_xml(&mut self, file: &mut File, part: &str) -> ApiResult<()> {
        if self.xml.contains_key(part) {
            return Ok(());
        }
        let data = self.layout.read(file, part, MAX_PART)?;
        self.xml_bytes += data.len();
        require(self.xml_bytes <= MAX_XML)?;
        let source = String::from_utf8(data).map_err(|_| invalid_zip())?;
        self.xml.insert(part.to_owned(), source);
        Ok(())
    }

    fn load_relationships(&mut self, file: &mut File, part: &str) -> ApiResult<Relationships> {
        let rel_path = relationships_path(part);
        if self.layout.entry(&rel_path).is_none() {
            return Ok(BTreeMap::new());
        }
        self.load_xml(file, &rel_path)?;
        parse_relationships(&self.xml[&rel_path], part, &self.layout)
    }

    fn content_type(&self, part: &str) -> &str {
        self.overrides
            .get(part)
            .or_else(|| {
                part.rsplit_once('.')
                    .and_then(|(_, ext)| self.defaults.get(&ext.to_ascii_lowercase()))
            })
            .map_or("", String::as_str)
    }

    fn validate_dependencies(
        &self,
        xml: Node,
        relationships: &Relationships,
        notes_of: Option<&str>,
    ) -> ApiResult<()> {
        let mut counts = BTreeMap::<&str, usize>::new();
        for rel in relationships.values() {
            let kind = rel
                .kind
                .strip_prefix(R)
                .and_then(|kind| kind.strip_prefix('/'));
            if rel.external {
                require(kind == Some("hyperlink") && safe_external(&rel.target))?;
                continue;
            }
            let media = self.content_type(&rel.target);
            match kind {
                Some("slide") => require(notes_of.map_or_else(
                    || self.slide_parts.contains(&rel.target),
                    |slide| slide == rel.target,
                ))?,
                Some(media_kind @ ("image" | "audio" | "video")) => require(
                    media
                        .strip_prefix(media_kind)
                        .is_some_and(|value| value.starts_with('/')),
                )?,
                Some("media") => {
                    require(media.starts_with("audio/") || media.starts_with("video/"))?
                }
                Some(dep @ ("notesSlide" | "slideLayout")) if notes_of.is_none() => {
                    require(media == mime(dep))?
                }
                Some("notesMaster") if notes_of.is_some() => require(media == mime("notesMaster"))?,
                None if rel.kind == MS_MEDIA => {
                    require(media.starts_with("audio/") || media.starts_with("video/"))?
                }
                _ => return Err(unsupported_slide()),
            }
            if let Some(name) = kind {
                *counts.entry(name).or_default() += 1;
            }
        }
        require(
            ["notesSlide", "slideLayout", "notesMaster"]
                .iter()
                .all(|name| counts.get(name).copied().unwrap_or(0) <= 1),
        )?;
        require(notes_of.is_none() || counts.get("slide") == Some(&1))?;
        require(
            xml.descendants()
                .filter(Node::is_element)
                .flat_map(|node| node.attributes())
                .all(|attr| {
                    attr.namespace() != Some(R) || relationships.contains_key(attr.value())
                }),
        )?;
        Ok(())
    }

    fn unused_part(&self, near: &str, stem: &str) -> ApiResult<String> {
        let directory = part_parent(near);
        let separator = if directory.is_empty() { "" } else { "/" };
        (1..=MAX_ENTRIES)
            .map(|index| format!("{directory}{separator}{stem}{index}.xml"))
            .find(|part| {
                [part.clone(), relationships_path(part)]
                    .iter()
                    .all(|candidate| {
                        canonical_part(candidate) && !self.layout.contains_casefold(candidate)
                    })
            })
            .ok_or_else(unsupported_slide)
    }

    fn plan(&self, index: usize, sha: &str, build: bool) -> ApiResult<Plan> {
        require(self.slides.len() < MAX_SLIDES)?;
        let slide = self.slides.get(index).ok_or_else(unsupported_slide)?;
        let rels = &self.slide_relationships[index];
        let slide_xml = document(&self.xml[&slide.part])?;
        self.validate_dependencies(slide_xml.root_element(), rels, None)?;
        let new_slide = self.unused_part(&slide.part, "slide")?;
        let mut assigned = CreationIds::default();
        let mut added = BTreeMap::new();
        let mut changed = BTreeMap::new();
        let mut override_parts = vec![(new_slide.as_str(), self.content_type(&slide.part))];
        let slide_edits = creation_edits(
            slide_xml.root_element(),
            sha,
            &slide.part,
            &self.ids,
            &mut assigned,
        )?;
        added.insert(
            new_slide.clone(),
            edit(&self.xml[&slide.part], slide_edits)?,
        );
        let slide_rels = relationships_path(&slide.part);
        if let Some(raw) = self.xml.get(&slide_rels) {
            added.insert(relationships_path(&new_slide), raw.as_bytes().to_vec());
        }
        let new_notes;
        if let Some(notes) = rels.values().find(|rel| rel.kind == kind("notesSlide")) {
            require(self.notes_owners.get(&notes.target) == Some(&1))?;
            let notes_xml = document(&self.xml[&notes.target])?;
            let notes_root = notes_xml.root_element();
            require(notes_root.has_tag_name((P, "notes")))?;
            single_child(single_child(notes_root, P, "cSld")?, P, "spTree")?;
            let note_rels = relationships_path(&notes.target);
            let raw_note_rels = self.xml.get(&note_rels).ok_or_else(invalid_zip)?;
            let back = parse_relationships(raw_note_rels, &notes.target, &self.layout)?;
            self.validate_dependencies(notes_root, &back, Some(&slide.part))?;
            let original_link = back
                .values()
                .find(|rel| rel.kind == kind("slide"))
                .ok_or_else(invalid_zip)?;
            new_notes = self.unused_part(&notes.target, "notesSlide")?;
            override_parts.push((&new_notes, self.content_type(&notes.target)));
            let note_edits =
                creation_edits(notes_root, sha, &notes.target, &self.ids, &mut assigned)?;
            added.insert(
                new_notes.clone(),
                edit(&self.xml[&notes.target], note_edits)?,
            );
            added.insert(
                relationships_path(&new_slide),
                edit(
                    &self.xml[&slide_rels],
                    vec![(
                        notes.target_span.clone(),
                        escape(&relative_part(&new_slide, &new_notes)),
                    )],
                )?,
            );
            added.insert(
                relationships_path(&new_notes),
                edit(
                    raw_note_rels,
                    vec![(
                        original_link.target_span.clone(),
                        escape(&relative_part(&new_notes, &new_slide)),
                    )],
                )?,
            );
        }
        require(self.layout.entries.len() + added.len() <= MAX_ENTRIES)?;
        let new_id = (256..0x8000_0000)
            .find(|id| !self.slide_ids.contains(id))
            .ok_or_else(unsupported_slide)?;
        let relation_id = (1..=MAX_ENTRIES + 1)
            .map(|index| format!("rId{index}"))
            .find(|id| !self.main_relationships.contains_key(id))
            .ok_or_else(unsupported_slide)?;
        let slide_id = format!(
            "<p:sldId xmlns:p=\"{P}\" xmlns:r=\"{R}\" id=\"{new_id}\" r:id=\"{relation_id}\"/>"
        );
        let target = escape(&relative_part(PRESENTATION, &new_slide));
        let main_relation = format!(
            "<Relationship xmlns=\"{PKG}\" Id=\"{relation_id}\" Type=\"{R}/slide\" Target=\"{target}\"/>"
        );
        let new_types = override_parts
            .into_iter()
            .map(|(part, mime)| {
                format!(
                    "<Override xmlns=\"{CT}\" PartName=\"/{}\" ContentType=\"{}\"/>",
                    escape(part),
                    escape(mime)
                )
            })
            .collect::<String>();
        let main_rels = relationships_path(PRESENTATION);
        for (part, len) in [
            (PRESENTATION, slide_id.len()),
            (&main_rels, main_relation.len()),
            (TYPES, new_types.len()),
        ] {
            require(self.xml[part].len() + len <= MAX_PART)?;
        }
        let growth = slide_id.len()
            + main_relation.len()
            + new_types.len()
            + added.values().map(Vec::len).sum::<usize>();
        require(
            self.layout.expanded + growth <= MAX_PACKAGE && self.xml_bytes + growth <= MAX_XML,
        )?;
        if build {
            let insertion = slide.listing_range.end..slide.listing_range.end;
            changed.insert(
                PRESENTATION.into(),
                edit(&self.xml[PRESENTATION], vec![(insertion, slide_id)])?,
            );
            changed.insert(
                main_rels.clone(),
                append_element(&self.xml[&main_rels], main_relation)?,
            );
            changed.insert(TYPES.into(), append_element(&self.xml[TYPES], new_types)?);
        }
        Ok(Plan {
            edits: PackageEdits {
                changed,
                added,
                ..PackageEdits::default()
            },
            new_slide,
        })
    }
}

pub(super) fn document(xml: &str) -> ApiResult<Document<'_>> {
    Document::parse_with_options(
        xml,
        ParsingOptions {
            nodes_limit: 200_000,
            ..Default::default()
        },
    )
    .map_err(|_| invalid_zip())
}

pub(super) fn single_child<'a, 'input>(
    node: Node<'a, 'input>,
    namespace: &str,
    name: &str,
) -> ApiResult<Node<'a, 'input>> {
    let mut children = node
        .children()
        .filter(|child| child.has_tag_name((namespace, name)));
    let child = children.next().ok_or_else(invalid_zip)?;
    require(children.next().is_none())?;
    Ok(child)
}

fn ignorable_or_element(node: Node) -> bool {
    !node.is_text() || node.text().is_none_or(|text| text.trim().is_empty())
}

fn unsigned(value: &str) -> ApiResult<u32> {
    require(!value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))?;
    value.parse().map_err(|_| invalid_zip())
}

fn kind(name: &str) -> String {
    format!("{R}/{name}")
}
fn mime(name: &str) -> String {
    format!("{MIME}{name}+xml")
}

fn part_parent(part: &str) -> &str {
    part.rsplit_once('/').map_or("", |(parent, _)| parent)
}

pub(super) fn relationships_path(part: &str) -> String {
    if let Some((parent, name)) = part.rsplit_once('/') {
        format!("{parent}/_rels/{name}.rels")
    } else {
        format!("_rels/{part}.rels")
    }
}

fn resolve_target(part: &str, target: &str) -> ApiResult<String> {
    require(
        !target.is_empty()
            && !target.starts_with('/')
            && !target.ends_with('/')
            && !target
                .chars()
                .any(|c| c.is_control() || matches!(c, '\\' | ':' | '%' | '?' | '#')),
    )?;
    let mut components = part_parent(part)
        .split('/')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>();
    for component in target.split('/') {
        match component {
            "." => {}
            ".." => {
                components.pop().ok_or_else(invalid_zip)?;
            }
            "" => return Err(invalid_zip()),
            value => components.push(value),
        }
    }
    let canonical = components.join("/");
    require(canonical_part(&canonical))?;
    Ok(canonical)
}

pub(super) fn relative_part(part: &str, target: &str) -> String {
    let source = part_parent(part)
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect::<Vec<_>>();
    let target = target.split('/').collect::<Vec<_>>();
    let common = source
        .iter()
        .zip(&target)
        .take_while(|(a, b)| a == b)
        .count();
    let tail = target[common..].join("/");
    format!("{}{tail}", "../".repeat(source.len() - common))
}

fn safe_external(target: &str) -> bool {
    if target
        .chars()
        .any(|c| c.is_whitespace() || c.is_control() || c == '\\')
    {
        return false;
    }
    let Some((scheme, value)) = target.split_once(':') else {
        return false;
    };
    if scheme.eq_ignore_ascii_case("mailto") {
        return !value.is_empty() && !value.starts_with("//");
    }
    (scheme.eq_ignore_ascii_case("https") || scheme.eq_ignore_ascii_case("http"))
        && value
            .strip_prefix("//")
            .and_then(|rest| rest.split(['/', '?', '#']).next())
            .is_some_and(|host| !host.is_empty() && !host.contains('@'))
}

pub(super) fn parse_relationships(
    xml: &str,
    owner: &str,
    layout: &Layout,
) -> ApiResult<Relationships> {
    let xml = document(xml)?;
    let root = xml.root_element();
    require(root.has_tag_name((PKG, "Relationships")) && root.attributes().len() == 0)?;
    let mut relationships = BTreeMap::new();
    for node in root.children().filter(Node::is_element) {
        require(
            node.has_tag_name((PKG, "Relationship"))
                && !node.children().any(|child| child.is_element())
                && node.attributes().all(|attr| {
                    attr.namespace().is_none()
                        && matches!(attr.name(), "Id" | "Type" | "Target" | "TargetMode")
                }),
        )?;
        let id = node
            .attribute("Id")
            .filter(|v| !v.is_empty() && v.trim() == *v)
            .ok_or_else(invalid_zip)?;
        let kind = node
            .attribute("Type")
            .filter(|v| !v.is_empty() && !signed_marker(v))
            .ok_or_else(invalid_zip)?;
        let target = node.attribute_node("Target").ok_or_else(invalid_zip)?;
        require(!target.value().is_empty() && !target.value().chars().any(char::is_control))?;
        let external = match node.attribute("TargetMode") {
            None | Some("Internal") => false,
            Some("External") => true,
            _ => return Err(invalid_zip()),
        };
        let resolved = if external {
            target.value().to_owned()
        } else {
            let name = resolve_target(owner, target.value())?;
            require(layout.entry(&name).is_some_and(|e| !e.name.ends_with('/')))?;
            name
        };
        require(
            relationships
                .insert(
                    id.into(),
                    Relationship {
                        kind: kind.into(),
                        target: resolved,
                        external,
                        target_span: target.range_value(),
                        range: node.range(),
                    },
                )
                .is_none(),
        )?;
    }
    Ok(relationships)
}

fn signed_marker(value: &str) -> bool {
    let value = value.to_ascii_lowercase();
    value.contains("/digital-signature/") || value.contains(".digital-signature-")
}

pub(super) type MimeMap = BTreeMap<String, String>;
pub(super) fn content_types(xml: &str, layout: &Layout) -> ApiResult<(MimeMap, MimeMap)> {
    let xml = document(xml)?;
    let root = xml.root_element();
    require(root.has_tag_name((CT, "Types")))?;
    let mut defaults = BTreeMap::new();
    let mut overrides = BTreeMap::new();
    for node in root.children().filter(Node::is_element) {
        require(!node.children().any(|child| child.is_element()))?;
        let mime = node
            .attribute("ContentType")
            .filter(|v| !v.is_empty() && !signed_marker(v))
            .ok_or_else(invalid_zip)?;
        if node.has_tag_name((CT, "Default")) {
            let ext = node
                .attribute("Extension")
                .filter(|v| !v.is_empty())
                .ok_or_else(invalid_zip)?;
            require(
                defaults
                    .insert(ext.to_ascii_lowercase(), mime.into())
                    .is_none(),
            )?;
        } else if node.has_tag_name((CT, "Override")) {
            let part = node
                .attribute("PartName")
                .and_then(|value| value.strip_prefix('/'))
                .ok_or_else(invalid_zip)?;
            require(
                layout.entry(part).is_some()
                    && overrides.insert(part.into(), mime.into()).is_none(),
            )?;
        } else {
            return Err(invalid_zip());
        }
    }
    Ok((defaults, overrides))
}

fn slide_title(slide: Node) -> Option<String> {
    let text = slide
        .descendants()
        .filter(|node| node.has_tag_name((P, "sp")))
        .find(|shape| {
            shape.descendants().any(|child| {
                child.has_tag_name((P, "ph"))
                    && matches!(child.attribute("type"), Some("title" | "ctrTitle"))
            })
        })
        .and_then(|shape| {
            shape.descendants().find(|node| {
                node.has_tag_name((A, "t")) && node.text().is_some_and(|t| !t.trim().is_empty())
            })
        })
        .or_else(|| {
            slide.descendants().find(|node| {
                node.has_tag_name((A, "t")) && node.text().is_some_and(|t| !t.trim().is_empty())
            })
        })?
        .text()?;
    normalized_title(text)
}

pub(super) fn normalized_title(text: &str) -> Option<String> {
    let mut title = String::new();
    let mut units = 0;
    let mut space = false;
    for character in text.trim().chars() {
        if character.is_whitespace() || character.is_control() {
            space = !title.is_empty();
            continue;
        }
        let next = units + character.len_utf16() + usize::from(space);
        if next > 200 {
            break;
        }
        if space {
            title.push(' ');
        }
        title.push(character);
        space = false;
        units = next;
    }
    (!title.is_empty()).then_some(title)
}

pub(super) fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

type Edit = (Range<usize>, String);
pub(super) fn edit(source: &str, mut edits: Vec<Edit>) -> ApiResult<Vec<u8>> {
    edits.sort_by_key(|(range, _)| range.start);
    let mut output = Vec::with_capacity(source.len());
    let mut offset = 0;
    for (range, value) in edits {
        require(range.start >= offset && range.end <= source.len())?;
        output.extend_from_slice(&source.as_bytes()[offset..range.start]);
        output.extend_from_slice(value.as_bytes());
        offset = range.end;
    }
    output.extend_from_slice(&source.as_bytes()[offset..]);
    require(output.len() <= MAX_PART)?;
    Ok(output)
}

pub(super) fn append_element(source: &str, element: String) -> ApiResult<Vec<u8>> {
    let range = document(source)?.root_element().range();
    if let Some(start_tag) = source[range.clone()].strip_suffix("/>") {
        let name = start_tag[1..]
            .split_ascii_whitespace()
            .next()
            .ok_or_else(invalid_zip)?;
        return edit(
            source,
            vec![(range.end - 2..range.end, format!(">{element}</{name}>"))],
        );
    }
    let at = source[..range.end]
        .rfind("</")
        .filter(|at| *at > range.start)
        .ok_or_else(invalid_zip)?;
    edit(source, vec![(at..at, element)])
}

fn guid_pattern() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}")
            .expect("constant pattern")
    })
}

fn valid_guid(value: &str) -> bool {
    value.len() == 38 && guid_pattern().is_match(value)
}

fn new_guid(sha: &str, part: &str, original: &str, salt: u32) -> String {
    let bytes = Sha256::digest(format!("piv-pptx-shape/{sha}/{part}/{original}/{salt}").as_bytes());
    let mut guid = [0; 16];
    guid.copy_from_slice(&bytes[..16]);
    guid[6] = (guid[6] & 15) | 0x40;
    guid[8] = (guid[8] & 63) | 0x80;
    let hex: String = guid.iter().map(|byte| format!("{byte:02X}")).collect();
    format!(
        "{{{}-{}-{}-{}-{}}}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

fn creation_edits(
    root: Node,
    sha: &str,
    part: &str,
    known: &CreationIds,
    assigned: &mut CreationIds,
) -> ApiResult<Vec<Edit>> {
    let mut edits = vec![];
    let mut shape_map = BTreeMap::new();
    let mut page = None;
    for node in root.descendants().filter(Node::is_element) {
        if node.has_tag_name((P14, "creationId")) {
            require(page.is_none())?;
            let attr = node.attribute_node("val").ok_or_else(invalid_zip)?;
            page = Some(unsigned(attr.value())?);
            let value = (1..u32::MAX)
                .find(|value| !known.pages.contains(value) && !assigned.pages.contains(value))
                .ok_or_else(unsupported_slide)?;
            assigned.pages.insert(value);
            edits.push((attr.range_value(), value.to_string()));
        } else if node.has_tag_name((A16, "creationId")) {
            if let Some(attr) = node.attribute_node("id") {
                require(valid_guid(attr.value()))?;
                let old = attr.value().to_ascii_uppercase();
                require(!shape_map.contains_key(&old))?;
                let new = (0..=MAX_ENTRIES as u32)
                    .map(|salt| new_guid(sha, part, &old, salt))
                    .find(|id| !known.shapes.contains(id) && !assigned.shapes.contains(id))
                    .ok_or_else(unsupported_slide)?;
                assigned.shapes.insert(new.clone());
                shape_map.insert(old, new.clone());
                edits.push((attr.range_value(), new));
            }
        }
    }
    for node in root.descendants().filter(Node::is_element) {
        for attr in node.attributes() {
            let name = attr.name();
            let value = attr.value();
            if (node.has_tag_name((P14, "creationId")) && name == "val")
                || (node.has_tag_name((A16, "creationId")) && name == "id")
            {
                continue;
            }
            if (node.has_tag_name((A16, "cxnDERefs")) && matches!(name, "st" | "end"))
                || (node.has_tag_name((A16, "predDERef")) && name == "pred")
            {
                let id = shape_map
                    .get(&value.to_ascii_uppercase())
                    .ok_or_else(unsupported_slide)?;
                edits.push((attr.range_value(), id.clone()));
            } else if (!shape_map.is_empty()
                && guid_pattern()
                    .find_iter(value)
                    .any(|matched| shape_map.contains_key(&matched.as_str().to_ascii_uppercase())))
                || (page.is_some()
                    && matches!(name, "cId" | "creationId" | "slideCreationId")
                    && unsigned(value).ok() == page)
            {
                return Err(unsupported_slide());
            }
        }
    }
    Ok(edits)
}
