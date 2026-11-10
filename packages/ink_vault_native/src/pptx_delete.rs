use super::{
    A, Deck, Edit, MAX_PART, MAX_SLIDES, MIME, P, PRESENTATION, R, ROOT_RELATIONSHIPS,
    Relationships, Section, Slide, TYPES, document, edit, expected_hash, invalid_zip, kind,
    open_source, parse_relationships, path, relationships_path, require, require_fresh_output,
    single_child, unsigned,
};
use crate::pptx_zip::PackageEdits;
use crate::{ApiError, ApiResult, error, invalid};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::ops::Range;

fn unsupported() -> ApiError {
    error(
        "unsupported_slide",
        "The selected slide cannot be safely deleted",
    )
}

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let mut deck = Deck::read(&mut source)?;
    let deletion = Deletion::read(&mut deck, &mut source)?;
    let section_names = deletion
        .sections
        .iter()
        .flat_map(|section| std::iter::repeat_n(section.title.as_deref(), section.entries.len()));
    let slides = deck
        .slides
        .iter()
        .zip(section_names.chain(std::iter::repeat(None)))
        .enumerate()
        .map(|(index, (slide, section_name))| {
            let mut row = json!({
                "index": index,
                "hidden": slide.hidden,
                "canDelete": deletion.selection(&deck, index).is_ok(),
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
    open_source(source_path, sha)?;
    Ok(json!({"sourceSha256":sha,"slideCount":slides.len(),"slides":slides}))
}

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
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
    let mut deck = Deck::read(&mut source)?;
    let deletion = Deletion::read(&mut deck, &mut source)?;
    if index >= deck.slides.len() {
        return Err(invalid());
    }
    let edits = deletion.plan(&deck, index)?;
    let removed = &deck.slides[index];
    let expected_sections = deletion.sections.iter().map(|section| {
        section
            .entries
            .iter()
            .map(|&(id, _)| id)
            .filter(|&id| id != removed.identity)
            .collect::<Vec<_>>()
    });
    let output_sha = deck.write_candidate(
        source,
        (source_path, output_path),
        sha,
        &edits,
        |verified| {
            let expected_order = deck
                .slides
                .iter()
                .filter(|slide| slide.identity != removed.identity)
                .map(|slide| (slide.part.as_str(), slide.identity));
            require(
                verified
                    .slides
                    .iter()
                    .map(|slide| (slide.part.as_str(), slide.identity))
                    .eq(expected_order),
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
        "slideCount":deck.slides.len()-1,"deletedIndex":index}))
}

struct CustomShow {
    identity: u32,
    range: Range<usize>,
    entries: Vec<(String, Range<usize>)>,
}

struct CustomShows {
    range: Range<usize>,
    shows: Vec<CustomShow>,
}

#[derive(Default)]
struct Navigation {
    custom_shows: BTreeSet<u32>,
    last_position: usize,
}

struct Deletion {
    graph: BTreeMap<String, Relationships>,
    sections: Vec<Section>,
    custom_shows: Option<CustomShows>,
    blocked_relationships: BTreeSet<String>,
    blocked_slide_ids: BTreeSet<u32>,
    configured_shows: BTreeSet<u32>,
    last_ranged_slide: usize,
    navigation: BTreeMap<String, Navigation>,
}

impl Deletion {
    fn read(deck: &mut Deck, file: &mut File) -> ApiResult<Self> {
        let graph = relationship_graph(deck, file)?;
        let (configured_shows, last_ranged_slide) = show_configuration(deck, file)?;
        let sections = deck.sections()?;
        let presentation = document(&deck.xml[PRESENTATION])?;
        let root = presentation.root_element();
        let custom_shows = custom_shows(deck, root)?;
        let listing_starts = deck.slides.iter().map(|slide| slide.listing_range.start);
        let known_relationships = listing_starts
            .clone()
            .chain(
                custom_shows
                    .iter()
                    .flat_map(|list| &list.shows)
                    .flat_map(|show| show.entries.iter().map(|(_, range)| range.start)),
            )
            .collect::<BTreeSet<_>>();
        let known_id_starts = listing_starts
            .chain(
                sections
                    .iter()
                    .flat_map(|section| section.entries.iter().map(|(_, range)| range.start)),
            )
            .collect::<BTreeSet<_>>();
        let mut blocked_relationships = BTreeSet::new();
        let mut blocked_slide_ids = BTreeSet::new();
        for node in root.descendants().filter(roxmltree::Node::is_element) {
            let start = node.range().start;
            for attr in node.attributes() {
                if attr.namespace() == Some(R)
                    && !(attr.name() == "id" && known_relationships.contains(&start))
                {
                    blocked_relationships.insert(attr.value().to_owned());
                }
                let name = attr.name();
                if !known_id_starts.contains(&start)
                    && (matches!(name, "slideId" | "sldId")
                        || (name == "id" && matches!(node.tag_name().name(), "slideId" | "sldId")))
                    && let Ok(id) = unsigned(attr.value())
                {
                    blocked_slide_ids.insert(id);
                }
            }
        }
        let navigation = navigation_actions(deck, file)?;
        Ok(Self {
            graph,
            sections,
            custom_shows,
            blocked_relationships,
            blocked_slide_ids,
            configured_shows,
            last_ranged_slide,
            navigation,
        })
    }

    fn selection(&self, deck: &Deck, index: usize) -> ApiResult<(Vec<Edit>, BTreeSet<String>)> {
        let slide = &deck.slides[index];
        if deck.slides.len() < 2
            || index < self.last_ranged_slide
            || self.blocked_relationships.contains(&slide.relationship_id)
            || self.blocked_slide_ids.contains(&slide.identity)
        {
            return Err(unsupported());
        }
        let mut presentation_edits = vec![(slide.listing_range.clone(), String::new())];
        for (identity, range) in self.sections.iter().flat_map(|section| &section.entries) {
            if *identity == slide.identity {
                presentation_edits.push((range.clone(), String::new()));
            }
        }
        let emptied_shows = self.edit_custom_shows(slide, &mut presentation_edits)?;
        let removed = self.removed_parts(deck, slide)?;
        if self.navigation.iter().any(|(owner, actions)| {
            !removed.contains(owner)
                && (index < actions.last_position
                    || !actions.custom_shows.is_disjoint(&emptied_shows))
        }) {
            return Err(unsupported());
        }
        Ok((presentation_edits, removed))
    }

    fn plan(&self, deck: &Deck, index: usize) -> ApiResult<PackageEdits> {
        let slide = &deck.slides[index];
        let (presentation_edits, removed) = self.selection(deck, index)?;
        let relationship_part = relationships_path(PRESENTATION);
        let relationship = &deck.main_relationships[&slide.relationship_id];
        let content_types = document(&deck.xml[TYPES])?;
        let override_edits = content_types
            .root_element()
            .children()
            .filter(|node| {
                node.attribute("PartName")
                    .and_then(|name| name.strip_prefix('/'))
                    .is_some_and(|part| removed.contains(part))
            })
            .map(|node| (node.range(), String::new()))
            .collect::<Vec<_>>();
        let mut changed = BTreeMap::from([
            (
                PRESENTATION.into(),
                edit(&deck.xml[PRESENTATION], presentation_edits)?,
            ),
            (
                relationship_part.clone(),
                edit(
                    &deck.xml[&relationship_part],
                    vec![(relationship.range.clone(), String::new())],
                )?,
            ),
        ]);
        if !override_edits.is_empty() {
            changed.insert(TYPES.into(), edit(&deck.xml[TYPES], override_edits)?);
        }
        Ok(PackageEdits {
            changed,
            removed,
            ..PackageEdits::default()
        })
    }

    fn edit_custom_shows(&self, slide: &Slide, edits: &mut Vec<Edit>) -> ApiResult<BTreeSet<u32>> {
        let mut empty_shows = BTreeSet::new();
        let Some(list) = &self.custom_shows else {
            return Ok(empty_shows);
        };
        let mut show_edits = Vec::new();
        for show in &list.shows {
            let removed = show
                .entries
                .iter()
                .filter(|(id, _)| id == &slide.relationship_id)
                .map(|(_, range)| (range.clone(), String::new()))
                .collect::<Vec<_>>();
            if removed.is_empty() {
                continue;
            }
            if removed.len() == show.entries.len() {
                if self.configured_shows.contains(&show.identity) {
                    return Err(unsupported());
                }
                empty_shows.insert(show.identity);
                show_edits.push((show.range.clone(), String::new()));
            } else {
                show_edits.extend(removed);
            }
        }
        if !list.shows.is_empty() && empty_shows.len() == list.shows.len() {
            edits.push((list.range.clone(), String::new()));
        } else {
            edits.extend(show_edits);
        }
        Ok(empty_shows)
    }

    fn removed_parts(&self, deck: &Deck, slide: &Slide) -> ApiResult<BTreeSet<String>> {
        let affected = self.reachable([slide.part.as_str()], None);
        let retain = deck
            .layout
            .entries
            .iter()
            .map(|entry| entry.name.as_str())
            .filter(|name| !affected.contains(name));
        // Other package parts, including pre-existing orphans, keep every part they reference.
        let surviving = self.reachable(
            std::iter::once("").chain(retain),
            Some(&slide.relationship_id),
        );
        if surviving.contains(slide.part.as_str()) {
            return Err(unsupported());
        }
        let mut removed = BTreeSet::new();
        for part in affected.difference(&surviving) {
            removed.insert((*part).to_owned());
            let relationship_part = relationships_path(part);
            if deck.layout.entry(&relationship_part).is_some() {
                removed.insert(relationship_part);
            }
        }
        Ok(removed)
    }

    fn reachable<'a>(
        &'a self,
        start: impl IntoIterator<Item = &'a str>,
        removed_relationship: Option<&str>,
    ) -> BTreeSet<&'a str> {
        let mut pending = start.into_iter().collect::<Vec<_>>();
        let mut found = BTreeSet::new();
        while let Some(owner) = pending.pop() {
            if !found.insert(owner) {
                continue;
            }
            if let Some(relationships) = self.graph.get(owner) {
                pending.extend(relationships.iter().filter_map(|(id, rel)| {
                    (!rel.external
                        && !(owner == PRESENTATION && removed_relationship == Some(id.as_str())))
                    .then_some(rel.target.as_str())
                }));
            }
        }
        found
    }
}

pub(super) fn last_insertion_position(deck: &mut Deck, file: &mut File) -> ApiResult<usize> {
    let (_, last_range) = show_configuration(deck, file)?;
    let last_jump = navigation_actions(deck, file)?
        .values()
        .map(|action| action.last_position)
        .max()
        .unwrap_or(0);
    Ok(last_range.max(last_jump))
}

fn show_configuration(deck: &mut Deck, file: &mut File) -> ApiResult<(BTreeSet<u32>, usize)> {
    let property_parts = deck
        .main_relationships
        .values()
        .filter(|rel| {
            !rel.external && matches!(rel.kind.strip_prefix(R), Some("/presProps" | "/viewProps"))
        })
        .map(|rel| rel.target.clone())
        .collect::<Vec<_>>();
    let mut configured_shows = BTreeSet::new();
    let mut last_ranged_slide = 0;
    for part in std::iter::once(PRESENTATION).chain(property_parts.iter().map(String::as_str)) {
        deck.load_xml(file, part)?;
        let doc = document(&deck.xml[part])?;
        for node in doc.descendants() {
            if node.has_tag_name((P, "sldRg")) {
                let start = unsigned(node.attribute("st").ok_or_else(invalid_zip)?)? as usize;
                let end = unsigned(node.attribute("end").ok_or_else(invalid_zip)?)? as usize;
                require(1 <= start && start <= end && end <= deck.slides.len())?;
                last_ranged_slide = last_ranged_slide.max(end);
            } else if node.has_tag_name((P, "custShow"))
                && node
                    .parent()
                    .is_some_and(|parent| parent.has_tag_name((P, "showPr")))
            {
                configured_shows.insert(unsigned(node.attribute("id").ok_or_else(invalid_zip)?)?);
            }
        }
    }
    Ok((configured_shows, last_ranged_slide))
}

fn navigation_actions(deck: &Deck, file: &mut File) -> ApiResult<BTreeMap<String, Navigation>> {
    let mut owners = BTreeMap::new();
    for entry in &deck.layout.entries {
        let part = &entry.name;
        let media = deck.content_type(part);
        let drawing_owner = part.starts_with("ppt/")
            || media.starts_with(MIME)
            || media.starts_with("application/vnd.openxmlformats-officedocument.drawingml.");
        if !drawing_owner
            || !(media.ends_with("+xml")
                || matches!(media, "application/xml" | "text/xml")
                || part
                    .rsplit_once('.')
                    .is_some_and(|(_, ext)| ext.eq_ignore_ascii_case("xml")))
        {
            continue;
        }
        let actions = if let Some(xml) = deck.xml.get(part) {
            parse_navigation(xml)?
        } else {
            let bytes = deck.layout.read(file, part, MAX_PART)?;
            parse_navigation(std::str::from_utf8(&bytes).map_err(|_| invalid_zip())?)?
        };
        if actions.last_position != 0 || !actions.custom_shows.is_empty() {
            owners.insert(part.clone(), actions);
        }
    }
    Ok(owners)
}

fn parse_navigation(xml: &str) -> ApiResult<Navigation> {
    let xml = document(xml)?;
    let mut actions = Navigation::default();
    for node in xml.descendants().filter(|node| {
        node.is_element()
            && node.tag_name().namespace() == Some(A)
            && matches!(
                node.tag_name().name(),
                "hlinkClick" | "hlinkHover" | "hlinkMouseOver"
            )
    }) {
        let Some((scheme, path)) = node
            .attribute("action")
            .and_then(|value| value.split_once("://"))
        else {
            continue;
        };
        if !scheme.eq_ignore_ascii_case("ppaction") {
            continue;
        }
        let Some((verb, query)) = path.split_once('?') else {
            continue;
        };
        for (key, value) in query.split('&').filter_map(|field| field.split_once('=')) {
            if verb.eq_ignore_ascii_case("customshow")
                && key.eq_ignore_ascii_case("id")
                && let Ok(id) = unsigned(value)
            {
                actions.custom_shows.insert(id);
            } else if verb.eq_ignore_ascii_case("hlinkshowjump")
                && key.eq_ignore_ascii_case("jump")
                && let Ok(position) = unsigned(value)
            {
                actions.last_position = actions.last_position.max(position.max(1) as usize);
            }
        }
    }
    Ok(actions)
}

fn relationship_graph(
    deck: &mut Deck,
    file: &mut File,
) -> ApiResult<BTreeMap<String, Relationships>> {
    let parts = deck
        .layout
        .entries
        .iter()
        .filter(|entry| entry.name.to_ascii_lowercase().ends_with(".rels"))
        .map(|entry| entry.name.clone())
        .collect::<BTreeSet<_>>();
    let mut graph = BTreeMap::new();
    for part in &parts {
        let owner = relationship_owner(part).ok_or_else(invalid_zip)?;
        require(
            owner.is_empty()
                || deck
                    .layout
                    .entry(&owner)
                    .is_some_and(|entry| !entry.name.ends_with('/')),
        )?;
        deck.load_xml(file, part)?;
        let relationships = parse_relationships(&deck.xml[part], &owner, &deck.layout)?;
        require(
            relationships
                .values()
                .all(|rel| rel.external || (rel.target != TYPES && !parts.contains(&rel.target))),
        )?;
        require(graph.insert(owner, relationships).is_none())?;
    }
    Ok(graph)
}

fn relationship_owner(part: &str) -> Option<String> {
    if part == ROOT_RELATIONSHIPS {
        return Some(String::new());
    }
    let (directory, filename) = if let Some(name) = part.strip_prefix("_rels/") {
        ("", name)
    } else {
        part.rsplit_once("/_rels/")?
    };
    let file = filename.strip_suffix(".rels")?;
    if file.is_empty() || file.contains('/') {
        return None;
    }
    Some(if directory.is_empty() {
        file.to_owned()
    } else {
        format!("{directory}/{file}")
    })
}

fn custom_shows(deck: &Deck, root: roxmltree::Node) -> ApiResult<Option<CustomShows>> {
    let mut lists = root
        .children()
        .filter(|node| node.has_tag_name((P, "custShowLst")));
    let Some(list) = lists.next() else {
        return Ok(None);
    };
    require(lists.next().is_none())?;
    let mut identities = BTreeSet::new();
    let mut shows = Vec::new();
    for show in list.children().filter(roxmltree::Node::is_element) {
        require(show.has_tag_name((P, "custShow")))?;
        let identity = unsigned(show.attribute("id").ok_or_else(invalid_zip)?)?;
        require(identities.insert(identity))?;
        let listing = single_child(show, P, "sldLst")?;
        let mut entries = Vec::new();
        for entry in listing.children().filter(roxmltree::Node::is_element) {
            require(entry.has_tag_name((P, "sld")))?;
            let id = entry.attribute((R, "id")).ok_or_else(invalid_zip)?;
            require(deck.main_relationships.get(id).is_some_and(|rel| {
                !rel.external && rel.kind == kind("slide") && deck.slide_parts.contains(&rel.target)
            }))?;
            entries.push((id.to_owned(), entry.range()));
        }
        shows.push(CustomShow {
            identity,
            range: show.range(),
            entries,
        });
    }
    Ok(Some(CustomShows {
        range: list.range(),
        shows,
    }))
}
