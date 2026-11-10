use super::shape_text::{open_tag_end, text_edit, unique_child};
use super::{
    A, CT, Deck, Edit, MAX_ENTRIES, MAX_SLIDES, P, PKG, PRESENTATION, R, Relationships, TYPES,
    append_element, document, edit, escape, expected_hash, kind, mime, open_source,
    parse_relationships, path, relationships_path, relative_part, require, require_fresh_output,
    single_child, unsigned,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, error, invalid, string};
use roxmltree::Node;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::fs::File;

const MAX_UNITS: usize = 8000;
const MAX_LINES: usize = 128;
const RELS_MIME: &str = "application/vnd.openxmlformats-package.relationships+xml";

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    let index = match request.len() {
        3 if !request.contains_key("slideIndex") => None,
        4 => Some(index(request)?),
        _ => return Err(invalid()),
    };
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let mut deck = Deck::read(&mut source)?;
    let slide_count = deck.slides.len();
    let result = if let Some(index) = index {
        if index >= slide_count {
            return Err(invalid());
        }
        let master = master_link(&deck)?;
        if let Some(master) = &master {
            master_placeholder(&mut deck, &mut source, master)?;
        }
        let note = read_note(&deck, index, master.as_deref())?;
        json!({"sourceSha256":sha,"slideCount":slide_count,"slideIndex":index,
            "text":note.text,"editable":note.editable,"hasNotes":!note.text.is_empty()})
    } else {
        let slides = deck
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
            .collect::<Vec<_>>();
        json!({"sourceSha256":sha,"slideCount":slide_count,"slides":slides})
    };
    open_source(source_path, sha)?;
    Ok(result)
}

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 6 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = index(request)?;
    let text = string(request.get("text"))?;
    if !valid_text(text) {
        return Err(invalid());
    }
    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let mut deck = Deck::read(&mut source)?;
    if index >= deck.slides.len() {
        return Err(invalid());
    }
    let master = master_link(&deck)?;
    let placeholder = if let Some(master) = &master {
        master_placeholder(&mut deck, &mut source, master)?
    } else {
        1
    };
    let note = read_note(&deck, index, master.as_deref())?;
    if !note.editable {
        return Err(error(
            "unsupported_notes",
            "These speaker notes cannot be safely edited",
        ));
    }
    if note.text == text {
        return Err(error("no_change", "The speaker notes did not change"));
    }
    let mut changes = PackageEdits::default();
    if let Some(part) = note.part {
        changes.changed.insert(
            part.into(),
            rewrite_note(&deck.xml[part], placeholder, text)?,
        );
    } else {
        create_note(
            &deck,
            index,
            master.as_deref(),
            placeholder,
            text,
            &mut changes,
        )?;
    }
    require(deck.layout.entries.len() + changes.added.len() <= MAX_ENTRIES)?;
    let output_sha =
        deck.write_candidate(source, (source_path, output_path), sha, &changes, |saved| {
            require(
                saved
                    .slides
                    .iter()
                    .map(|slide| (&slide.part, slide.identity))
                    .eq(deck
                        .slides
                        .iter()
                        .map(|slide| (&slide.part, slide.identity))),
            )?;
            let saved_master = master_link(saved)?;
            let note = read_note(saved, index, saved_master.as_deref())?;
            require(note.part.is_some() && note.editable && note.text == text)
        })?;
    Ok(json!({"sourceSha256":sha,"outputSha256":output_sha,
        "slideCount":deck.slides.len(),"slideIndex":index}))
}

fn index(request: &Map<String, Value>) -> ApiResult<usize> {
    request
        .get("slideIndex")
        .and_then(Value::as_u64)
        .filter(|&index| index < MAX_SLIDES as u64)
        .map(|index| index as usize)
        .ok_or_else(invalid)
}

fn valid_char(character: char) -> bool {
    matches!(character, '\n' | '\t')
        || (!character.is_control() && !matches!(character, '\u{fffe}' | '\u{ffff}'))
}

fn valid_text(text: &str) -> bool {
    text.encode_utf16().take(MAX_UNITS + 1).count() <= MAX_UNITS
        && text.split('\n').take(MAX_LINES + 1).count() <= MAX_LINES
        && text.chars().all(valid_char)
}

fn relation<'a>(rels: &'a Relationships, name: &str) -> ApiResult<Option<(&'a str, &'a str)>> {
    let kind = kind(name);
    let mut links = rels.iter().filter(|(_, rel)| rel.kind == kind);
    let Some((id, rel)) = links.next() else {
        return Ok(None);
    };
    require(!rel.external && links.next().is_none())?;
    Ok(Some((id, &rel.target)))
}

fn master_link(deck: &Deck) -> ApiResult<Option<String>> {
    let doc = document(&deck.xml[PRESENTATION])?;
    let listing = unique_child(doc.root_element(), P, "notesMasterIdLst")?;
    let link = relation(&deck.main_relationships, "notesMaster")?;
    let (Some(listing), Some((id, target))) = (listing, link) else {
        require(
            listing.is_none()
                && link.is_none()
                && deck
                    .overrides
                    .values()
                    .all(|media| media != &mime("notesMaster")),
        )?;
        return Ok(None);
    };
    let master_id = single_child(listing, P, "notesMasterId")?;
    require(
        master_id.attribute((R, "id")) == Some(id)
            && deck.content_type(target) == mime("notesMaster"),
    )?;
    Ok(Some(target.to_owned()))
}

fn master_placeholder(deck: &mut Deck, source: &mut File, part: &str) -> ApiResult<u32> {
    deck.load_xml(source, part)?;
    let doc = document(&deck.xml[part])?;
    let root = doc.root_element();
    require(root.has_tag_name((P, "notesMaster")))?;
    single_child(root, P, "clrMap")?;
    let tree = single_child(single_child(root, P, "cSld")?, P, "spTree")?;
    let Some((_, placeholder)) = body_shape(tree)? else {
        return Ok(1);
    };
    placeholder.attribute("idx").map_or(Ok(0), unsigned)
}

struct Note<'a> {
    part: Option<&'a str>,
    text: String,
    editable: bool,
}

fn read_note<'a>(deck: &'a Deck, index: usize, master: Option<&str>) -> ApiResult<Note<'a>> {
    let mut note = Note {
        part: None,
        text: String::new(),
        editable: true,
    };
    let Some((_, part)) = relation(&deck.slide_relationships[index], "notesSlide")? else {
        return Ok(note);
    };
    require(
        deck.notes_owners.get(part) == Some(&1) && deck.content_type(part) == mime("notesSlide"),
    )?;
    let doc = document(deck.xml.get(part).ok_or_else(invalid_zip)?)?;
    let root = doc.root_element();
    require(root.has_tag_name((P, "notes")))?;
    let notes_rels = deck
        .xml
        .get(&relationships_path(part))
        .ok_or_else(invalid_zip)?;
    let rels = parse_relationships(notes_rels, part, &deck.layout)?;
    require(
        relation(&rels, "slide")?.map(|(_, target)| target) == Some(&deck.slides[index].part)
            && master.is_some()
            && relation(&rels, "notesMaster")?.map(|(_, target)| target) == master,
    )?;
    require(
        root.descendants()
            .filter(Node::is_element)
            .flat_map(|node| node.attributes())
            .all(|attr| attr.namespace() != Some(R) || rels.contains_key(attr.value())),
    )?;
    note.part = Some(part);
    let tree = single_child(single_child(root, P, "cSld")?, P, "spTree")?;
    if let Some((shape, _)) = body_shape(tree)? {
        if let Some(body) = unique_child(shape, P, "txBody")? {
            note.text = body
                .children()
                .filter(|node| node.has_tag_name((A, "p")))
                .map(paragraph_text)
                .collect::<Vec<_>>()
                .join("\n");
            note.editable = editable_body(body) && valid_text(&note.text);
            if !valid_text(&note.text) {
                let (mut units, mut lines) = (0, 1);
                note.text = note
                    .text
                    .chars()
                    .map(|ch| if valid_char(ch) { ch } else { '\u{fffd}' })
                    .take_while(|ch| {
                        units += ch.len_utf16();
                        lines += usize::from(*ch == '\n');
                        units <= MAX_UNITS && lines <= MAX_LINES
                    })
                    .collect();
            }
        } else {
            note.editable = unique_child(shape, P, "spPr")?.is_some();
        }
    }
    Ok(note)
}

fn body_shape<'a, 'input>(
    tree: Node<'a, 'input>,
) -> ApiResult<Option<(Node<'a, 'input>, Node<'a, 'input>)>> {
    let mut placeholders = tree
        .descendants()
        .filter(|node| node.has_tag_name((P, "ph")) && node.attribute("type") == Some("body"));
    let Some(placeholder) = placeholders.next() else {
        return Ok(None);
    };
    let shape = placeholder
        .parent()
        .filter(|node| node.has_tag_name((P, "nvPr")))
        .and_then(|node| node.parent())
        .filter(|node| node.has_tag_name((P, "nvSpPr")))
        .and_then(|node| node.parent())
        .filter(|node| node.has_tag_name((P, "sp")) && node.parent() == Some(tree))
        .ok_or_else(invalid_zip)?;
    require(placeholders.next().is_none())?;
    Ok(Some((shape, placeholder)))
}

fn paragraph_text(paragraph: Node) -> String {
    let mut text = String::new();
    for child in paragraph.children().filter(Node::is_element) {
        if child.has_tag_name((A, "br")) {
            text.push('\n');
        } else if child.has_tag_name((A, "r")) || child.has_tag_name((A, "fld")) {
            for run_text in child.children().filter(|node| node.has_tag_name((A, "t"))) {
                text.push_str(run_text.text().unwrap_or(""));
            }
        }
    }
    text
}

fn editable_body(body: Node) -> bool {
    let mut children = body.children().filter(Node::is_element).peekable();
    if !children
        .next()
        .is_some_and(|node| node.has_tag_name((A, "bodyPr")))
    {
        return false;
    }
    if children
        .peek()
        .is_some_and(|node| node.has_tag_name((A, "lstStyle")))
    {
        children.next();
    }
    children.peek().is_some()
        && children.all(|node| node.has_tag_name((A, "p")) && editable_paragraph(node))
}

fn editable_paragraph(paragraph: Node) -> bool {
    if !paragraph.descendants().all(|node| {
        if node.is_element() {
            node.tag_name().namespace() == Some(A)
                && !matches!(
                    node.tag_name().name(),
                    "extLst" | "hlinkClick" | "hlinkMouseOver"
                )
                && node.attributes().all(|attr| {
                    attr.namespace().is_none()
                        || (node.has_tag_name((A, "t"))
                            && attr.namespace() == Some("http://www.w3.org/XML/1998/namespace")
                            && attr.name() == "space")
                })
        } else {
            node.is_text()
                && (node.parent().is_some_and(|p| p.has_tag_name((A, "t")))
                    || node.text().is_none_or(|text| text.trim().is_empty()))
        }
    }) {
        return false;
    }
    let mut children = paragraph.children().filter(Node::is_element).peekable();
    if children
        .peek()
        .is_some_and(|node| node.has_tag_name((A, "pPr")))
    {
        children.next();
    }
    while children
        .peek()
        .is_some_and(|node| node.has_tag_name((A, "r")))
    {
        let run = children.next().unwrap();
        let mut content = run.children().filter(Node::is_element).peekable();
        if content
            .peek()
            .is_some_and(|node| node.has_tag_name((A, "rPr")))
        {
            content.next();
        }
        if !content.next().is_some_and(|node| {
            node.has_tag_name((A, "t"))
                && node.children().all(|child| child.is_text())
                && !node.text().unwrap_or("").contains('\n')
        }) || content.next().is_some()
        {
            return false;
        }
    }
    if children
        .peek()
        .is_some_and(|node| node.has_tag_name((A, "endParaRPr")))
    {
        children.next();
    }
    children.next().is_none()
}

fn rewrite_note(xml: &str, placeholder: u32, text: &str) -> ApiResult<Vec<u8>> {
    let doc = document(xml)?;
    let tree = single_child(single_child(doc.root_element(), P, "cSld")?, P, "spTree")?;
    let Some((shape, _)) = body_shape(tree)? else {
        let ids = tree
            .descendants()
            .filter(|node| node.has_tag_name((P, "cNvPr")))
            .map(|node| unsigned(node.attribute("id").ok_or_else(invalid_zip)?))
            .collect::<ApiResult<BTreeSet<_>>>()?;
        let id = (1..).find(|id| !ids.contains(id)).ok_or_else(invalid_zip)?;
        let element = note_shape(id, "body", placeholder, "", &new_body(text));
        return edit(
            xml,
            vec![insert_in(
                xml,
                tree,
                unique_child(tree, P, "extLst")?,
                element,
            )?],
        );
    };
    let Some(body) = unique_child(shape, P, "txBody")? else {
        return edit(
            xml,
            vec![insert_in(
                xml,
                shape,
                unique_child(shape, P, "extLst")?,
                new_body(text),
            )?],
        );
    };
    let paragraphs = body
        .children()
        .filter(|node| node.has_tag_name((A, "p")))
        .collect::<Vec<_>>();
    let mut lines = text.split('\n');
    let mut edits = Vec::new();
    for &paragraph in &paragraphs {
        match lines.next() {
            Some(line) if paragraph_text(paragraph) == line => (),
            Some(line) => edits.extend(rewrite_paragraph(xml, paragraph, line)?),
            None => edits.push((paragraph.range(), String::new())),
        }
    }
    let remaining = lines.map(new_paragraph).collect::<String>();
    if !remaining.is_empty() {
        let after = paragraphs.last().ok_or_else(invalid_zip)?.range().end;
        edits.push((after..after, remaining));
    }
    edit(xml, edits)
}

fn rewrite_paragraph(xml: &str, paragraph: Node, mut line: &str) -> ApiResult<Vec<Edit>> {
    let mut runs = paragraph
        .children()
        .filter(|node| node.has_tag_name((A, "r")))
        .peekable();
    if runs.peek().is_none() {
        return Ok(vec![insert_in(
            xml,
            paragraph,
            unique_child(paragraph, A, "endParaRPr")?,
            new_run(line),
        )?]);
    }
    let mut edits = Vec::new();
    while let Some(run) = runs.next() {
        let old = single_child(run, A, "t")?;
        let previous = old.text().unwrap_or("");
        let split = if runs.peek().is_none() {
            line.len()
        } else {
            line.char_indices()
                .nth(previous.chars().count())
                .map_or(line.len(), |(at, _)| at)
        };
        let (part, rest) = line.split_at(split);
        line = rest;
        if part != previous {
            edits.push(text_edit(xml, old.range(), part)?);
        }
    }
    Ok(edits)
}

fn insert_in(xml: &str, owner: Node, before: Option<Node>, element: String) -> ApiResult<Edit> {
    if let Some(before) = before {
        let at = before.range().start;
        return Ok((at..at, element));
    }
    let span = owner.range();
    let raw = &xml[span.clone()];
    let tag_end = open_tag_end(raw).ok_or_else(invalid_zip)?;
    if raw.as_bytes().get(tag_end.wrapping_sub(1)) == Some(&b'/') {
        let name = raw[1..tag_end]
            .split(|c: char| c.is_ascii_whitespace() || c == '/')
            .next()
            .ok_or_else(invalid_zip)?;
        return Ok((span.end - 2..span.end, format!(">{element}</{name}>")));
    }
    let at = span.start + raw.rfind("</").ok_or_else(invalid_zip)?;
    Ok((at..at, element))
}

fn new_run(text: &str) -> String {
    format!("<a:r xmlns:a=\"{A}\"><a:t>{}</a:t></a:r>", escape(text))
}

fn new_paragraph(text: &str) -> String {
    if text.is_empty() {
        format!("<a:p xmlns:a=\"{A}\"/>")
    } else {
        format!("<a:p xmlns:a=\"{A}\">{}</a:p>", new_run(text))
    }
}

fn new_body(text: &str) -> String {
    let paragraphs = text.split('\n').map(new_paragraph).collect::<String>();
    format!(
        "<p:txBody xmlns:p=\"{P}\" xmlns:a=\"{A}\"><a:bodyPr/><a:lstStyle/>{paragraphs}</p:txBody>"
    )
}

fn note_shape(id: u32, kind: &str, index: u32, properties: &str, body: &str) -> String {
    format!(
        "<p:sp xmlns:p=\"{P}\"><p:nvSpPr><p:cNvPr id=\"{id}\" name=\"{kind}\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"{kind}\" idx=\"{index}\"/></p:nvPr></p:nvSpPr><p:spPr>{properties}</p:spPr>{body}</p:sp>"
    )
}

const GROUP_PROPERTIES: &str =
    "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>";

fn create_note(
    deck: &Deck,
    index: usize,
    master: Option<&str>,
    placeholder: u32,
    text: &str,
    changes: &mut PackageEdits,
) -> ApiResult<()> {
    let master_added;
    let master = if let Some(master) = master {
        master
    } else {
        master_added = create_master(deck, changes)?;
        &master_added
    };
    let note = deck.unused_part("ppt/notesSlides/notesSlide.xml", "notesSlide")?;
    let slide = &deck.slides[index].part;
    let body = note_shape(2, "body", placeholder, "", &new_body(text));
    let xml = format!(
        "<p:notes xmlns:p=\"{P}\" xmlns:a=\"{A}\"><p:cSld><p:spTree>{GROUP_PROPERTIES}{body}</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"
    );
    changes.added.insert(note.clone(), xml.into_bytes());
    let backlinks = format!(
        "{}{}",
        relationship("rId1", "slide", &note, slide),
        relationship("rId2", "notesMaster", &note, master)
    );
    changes
        .added
        .insert(relationships_path(&note), relationships(&backlinks));

    let slide_rel = relationships_path(slide);
    let slide_link = relationship(
        &new_id(&deck.slide_relationships[index])?,
        "notesSlide",
        slide,
        &note,
    );
    if let Some(existing) = deck.xml.get(&slide_rel) {
        changes
            .changed
            .insert(slide_rel, append_element(existing, slide_link)?);
    } else {
        require(!deck.layout.contains_casefold(&slide_rel))?;
        changes.added.insert(slide_rel, relationships(&slide_link));
    }
    let mut types = override_type(&note, "notesSlide");
    if changes.added.contains_key(master) {
        types.push_str(&override_type(master, "notesMaster"));
    }
    match deck.defaults.get("rels").map(String::as_str) {
        Some(RELS_MIME) => (),
        None => types.push_str(&format!(
            "<Default xmlns=\"{CT}\" Extension=\"rels\" ContentType=\"{RELS_MIME}\"/>"
        )),
        _ => return Err(invalid_zip()),
    }
    changes
        .changed
        .insert(TYPES.into(), append_element(&deck.xml[TYPES], types)?);
    Ok(())
}

fn create_master(deck: &Deck, changes: &mut PackageEdits) -> ApiResult<String> {
    let master = deck.unused_part("ppt/notesMasters/notesMaster.xml", "notesMaster")?;
    let properties = "<a:xfrm><a:off x=\"685800\" y=\"4800600\"/><a:ext cx=\"5486400\" cy=\"3657600\"/></a:xfrm>";
    let body = note_shape(2, "body", 1, properties, &new_body(""));
    let colors = "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>";
    let xml = format!(
        "<p:notesMaster xmlns:p=\"{P}\" xmlns:a=\"{A}\"><p:cSld><p:spTree>{GROUP_PROPERTIES}{body}</p:spTree></p:cSld>{colors}</p:notesMaster>"
    );
    changes.added.insert(master.clone(), xml.into_bytes());
    if let Some((_, theme)) = relation(&deck.main_relationships, "theme")? {
        require(
            deck.content_type(theme) == "application/vnd.openxmlformats-officedocument.theme+xml",
        )?;
        let link = relationship("rId1", "theme", &master, theme);
        changes
            .added
            .insert(relationships_path(&master), relationships(&link));
    }
    let id = new_id(&deck.main_relationships)?;
    let main = &deck.xml[PRESENTATION];
    let doc = document(main)?;
    let root = doc.root_element();
    let first = root
        .children()
        .filter(Node::is_element)
        .find(|node| !node.has_tag_name((P, "sldMasterIdLst")))
        .ok_or_else(invalid_zip)?;
    let at = first.range().start;
    let listing = format!(
        "<p:notesMasterIdLst xmlns:p=\"{P}\" xmlns:r=\"{R}\"><p:notesMasterId r:id=\"{id}\"/></p:notesMasterIdLst>"
    );
    changes
        .changed
        .insert(PRESENTATION.into(), edit(main, vec![(at..at, listing)])?);
    let main_rels = relationships_path(PRESENTATION);
    let link = relationship(&id, "notesMaster", PRESENTATION, &master);
    changes.changed.insert(
        main_rels.clone(),
        append_element(&deck.xml[&main_rels], link)?,
    );
    Ok(master)
}

fn new_id(rels: &Relationships) -> ApiResult<String> {
    (1..=MAX_ENTRIES + 1)
        .map(|index| format!("rId{index}"))
        .find(|id| !rels.contains_key(id))
        .ok_or_else(invalid_zip)
}

fn relationship(id: &str, name: &str, owner: &str, target: &str) -> String {
    let target = escape(&relative_part(owner, target));
    format!("<Relationship xmlns=\"{PKG}\" Id=\"{id}\" Type=\"{R}/{name}\" Target=\"{target}\"/>")
}

fn relationships(inner: &str) -> Vec<u8> {
    format!("<Relationships xmlns=\"{PKG}\">{inner}</Relationships>").into_bytes()
}

fn override_type(part: &str, name: &str) -> String {
    format!(
        "<Override xmlns=\"{CT}\" PartName=\"/{}\" ContentType=\"{}\"/>",
        escape(part),
        mime(name)
    )
}
