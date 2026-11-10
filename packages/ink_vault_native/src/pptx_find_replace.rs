use super::shape_geometry::drawing_flag;
use super::shape_text::{
    open_tag_end, ordinary_text, require_unprotected, unique_child, valid_text, valid_text_chars,
};
use super::{
    A, Deck, Edit, MAX_PACKAGE, MAX_XML, P, document, edit, escape, expected_hash, hash_file,
    open_source, path, require, require_fresh_output, single_child, source_changed, unsigned,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, error, invalid, string};
use roxmltree::Node;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::ops::Range;

const MAX_MATCHES: usize = 200;
const MAX_SNIPPET_UNITS: usize = 160;

pub(crate) fn preview(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 4 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let pattern = Pattern {
        find: find_text(request)?,
        replacement: None,
    };
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    let plan = search(&deck, pattern)?;
    if hash_file(&mut source)? != sha {
        return Err(source_changed());
    }
    open_source(source_path, sha)?;
    Ok(json!({
        "sourceSha256":sha,"slideCount":deck.slides.len(),"matchCount":plan.count,"matches":plan.matches,
    }))
}

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let find = find_text(request)?;
    let replacement = string(request.get("replacement"))?;
    if replacement == find || !valid_text(replacement) {
        return Err(invalid());
    }
    let expected = request
        .get("expectedMatchCount")
        .and_then(Value::as_u64)
        .filter(|count| (1..=MAX_MATCHES as u64).contains(count))
        .ok_or_else(invalid)? as usize;

    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    let plan = search(
        &deck,
        Pattern {
            find,
            replacement: Some(replacement),
        },
    )?;
    if plan.count != expected {
        return Err(invalid());
    }
    let output_sha = deck.write_candidate(
        source,
        (source_path, output_path),
        sha,
        &plan.edits,
        |verified| {
            require(verified.slides.len() == deck.slides.len())?;
            require(
                verified
                    .slides
                    .iter()
                    .zip(&deck.slides)
                    .all(|(after, before)| {
                        after.identity == before.identity
                            && after.part == before.part
                            && after.relationship_id == before.relationship_id
                            && after.hidden == before.hidden
                    }),
            )
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),"matchCount":plan.count,
    }))
}

fn find_text(request: &Map<String, Value>) -> ApiResult<&str> {
    let find = string(request.get("find"))?;
    if find.is_empty() || !valid_text(find) {
        return Err(invalid());
    }
    Ok(find)
}

#[derive(Clone, Copy)]
struct Pattern<'a> {
    find: &'a str,
    replacement: Option<&'a str>,
}

#[derive(Default)]
struct SearchPlan {
    count: usize,
    matches: Vec<Value>,
    edits: PackageEdits,
}

#[derive(Default)]
struct SlidePlan {
    snippet: Option<String>,
    edits: Vec<Edit>,
}

#[derive(Default)]
struct Segment<'a, 'input> {
    text: String,
    runs: Vec<(Node<'a, 'input>, Range<usize>)>,
}

fn search(deck: &Deck, pattern: Pattern<'_>) -> ApiResult<SearchPlan> {
    require_unprotected(deck)?;
    let mut plan = SearchPlan::default();
    let mut growth = 0;
    for (slide_index, slide) in deck.slides.iter().enumerate() {
        let xml = &deck.xml[&slide.part];
        let parsed = document(xml)?;
        let tree = single_child(single_child(parsed.root_element(), P, "cSld")?, P, "spTree")?;
        let mut result = SlidePlan::default();
        let before = plan.count;
        let mut segment = Segment::default();
        for shape in tree.children().filter(|node| node.has_tag_name((P, "sp"))) {
            let Some(body) = editable_body(shape)? else {
                continue;
            };
            for paragraph in body.children().filter(|node| node.has_tag_name((A, "p"))) {
                for run in paragraph.children().filter(Node::is_element) {
                    if let Some(node) = searchable_run(run)? {
                        segment.push(node);
                    } else {
                        segment.scan(xml, pattern, &mut plan.count, &mut result)?;
                    }
                }
                segment.scan(xml, pattern, &mut plan.count, &mut result)?;
            }
        }
        if let Some(snippet) = result.snippet {
            plan.matches.push(
                json!({"slideIndex":slide_index,"snippet":snippet,"count":plan.count-before}),
            );
        }
        if !result.edits.is_empty() {
            let changed = edit(xml, result.edits)?;
            growth += changed.len().saturating_sub(xml.len());
            require(
                deck.xml_bytes + growth <= MAX_XML && deck.layout.expanded + growth <= MAX_PACKAGE,
            )?;
            plan.edits.changed.insert(slide.part.clone(), changed);
        }
    }
    Ok(plan)
}

fn editable_body<'a, 'input>(shape: Node<'a, 'input>) -> ApiResult<Option<Node<'a, 'input>>> {
    let Some(body) = unique_child(shape, P, "txBody")? else {
        return Ok(None);
    };
    let Some(properties) = unique_child(shape, P, "nvSpPr")? else {
        return Ok(None);
    };
    let id = single_child(properties, P, "cNvPr")?;
    let Some(shape_properties) = unique_child(properties, P, "cNvSpPr")? else {
        return Ok(None);
    };
    let locks = unique_child(shape_properties, A, "spLocks")?;
    if unsigned(id.attribute("id").ok_or_else(invalid_zip)?)? == 0
        || drawing_flag(locks, "noTextEdit")?
        || drawing_flag(locks, "noSelect")?
        || properties.descendants().any(|node| {
            node.has_tag_name((A, "hlinkClick"))
                || node.has_tag_name((A, "hlinkMouseOver"))
                || node.tag_name().namespace()
                    == Some("http://schemas.openxmlformats.org/markup-compatibility/2006")
        })
    {
        return Ok(None);
    }
    Ok(Some(body))
}

fn searchable_run<'a, 'input>(run: Node<'a, 'input>) -> ApiResult<Option<Node<'a, 'input>>> {
    if !run.has_tag_name((A, "r"))
        || run
            .descendants()
            .any(|node| node.is_element() && node.tag_name().namespace() != Some(A))
    {
        return Ok(None);
    }
    Ok(ordinary_text(run)?.filter(|node| valid_text_chars(node.text().unwrap_or_default())))
}

impl<'a, 'input> Segment<'a, 'input> {
    fn push(&mut self, node: Node<'a, 'input>) {
        let text = node.text().unwrap_or_default();
        if !text.is_empty() {
            let start = self.text.len();
            self.text.push_str(text);
            self.runs.push((node, start..self.text.len()));
        }
    }

    fn scan(
        &mut self,
        xml: &str,
        pattern: Pattern<'_>,
        count: &mut usize,
        slide: &mut SlidePlan,
    ) -> ApiResult<()> {
        let mut by_run = BTreeMap::<usize, Vec<(Range<usize>, &str)>>::new();
        for (start, matched) in self.text.match_indices(pattern.find) {
            if *count == MAX_MATCHES {
                return Err(error(
                    "pptx_match_limit",
                    "The PPTX search matched more than 200 locations",
                ));
            }
            *count += 1;
            slide
                .snippet
                .get_or_insert_with(|| preview_snippet(&self.text, start));
            if let Some(replacement) = pattern.replacement {
                let end = start + matched.len();
                let first = self.runs.partition_point(|(_, span)| span.end <= start);
                for (offset, (_, span)) in self.runs[first..]
                    .iter()
                    .take_while(|(_, span)| span.start < end)
                    .enumerate()
                {
                    let local = start.saturating_sub(span.start)..end.min(span.end) - span.start;
                    by_run
                        .entry(first + offset)
                        .or_default()
                        .push((local, if offset == 0 { replacement } else { "" }));
                }
            }
        }
        for (index, replacements) in by_run {
            let (node, _) = &self.runs[index];
            slide.edits.extend(text_edits(xml, *node, replacements)?);
        }
        self.text.clear();
        self.runs.clear();
        Ok(())
    }
}

fn preview_snippet(text: &str, match_start: usize) -> String {
    let start = text[..match_start]
        .char_indices()
        .rev()
        .nth(19)
        .map_or(0, |(offset, _)| offset);
    let mut units = 1 + usize::from(start != 0);
    let end = text[start..]
        .char_indices()
        .find_map(|(offset, character)| {
            units += character.len_utf16();
            (units > MAX_SNIPPET_UNITS).then_some(start + offset)
        })
        .unwrap_or(text.len());
    let before = if start == 0 { "" } else { "…" };
    let after = if end == text.len() { "" } else { "…" };
    format!("{before}{}{after}", &text[start..end])
}

// Map the decoded match offsets to lexical XML so that unmatched characters keep their
// original spelling, including numeric entities and CDATA.
fn text_edits(
    xml: &str,
    node: Node,
    replacements: Vec<(Range<usize>, &str)>,
) -> ApiResult<Vec<Edit>> {
    let raw = &xml[node.range()];
    let contents_start = open_tag_end(raw).ok_or_else(invalid_zip)? + 1;
    let contents_end = raw.rfind("</").ok_or_else(invalid_zip)?;
    let contents = raw
        .get(contents_start..contents_end)
        .ok_or_else(invalid_zip)?;
    let decoded = node.text().unwrap_or_default();
    let mut cursor = TextCursor {
        raw: contents,
        decoded,
        raw_offset: 0,
        offset: 0,
        cdata: false,
    };
    let mut changes = Vec::with_capacity(replacements.len());
    for (range, replacement) in &replacements {
        cursor.take_to(range.start)?;
        let first = cursor.next()?;
        let last = cursor.take_to(range.end)?.unwrap_or(first);
        let mut lexical = escape(replacement);
        let prefix = &contents[..first.start];
        let suffix = &contents[last.end..];
        let span = first.start..last.end;
        let same_cdata = first.cdata && last.cdata && !contents[span.clone()].contains("]]>");
        let leave_cdata = same_cdata
            && replacement.is_empty()
            && (prefix.ends_with("<![CDATA[") || suffix.starts_with("]]>"));
        if first.cdata && !leave_cdata {
            lexical.insert_str(0, "]]>");
        }
        if last.cdata && !leave_cdata {
            lexical.push_str("<![CDATA[");
        } else if !last.cdata
            && (suffix.starts_with('>') || suffix.starts_with("]>"))
            && (replacement.ends_with(']') || replacement.is_empty() && !first.cdata)
        {
            lexical.push_str("<![CDATA[]]>");
        }
        changes.push((span, lexical));
    }
    let expected = edit(
        decoded,
        replacements
            .into_iter()
            .map(|(span, value)| (span, value.to_owned()))
            .collect(),
    )?;
    let rendered = edit(contents, changes.clone())?;
    let candidate = format!(
        "<t>{}</t>",
        std::str::from_utf8(&rendered).map_err(|_| invalid_zip())?
    );
    let checked = document(&candidate)?;
    require(checked.root_element().text().unwrap_or_default().as_bytes() == expected)?;
    let base = node.range().start + contents_start;
    Ok(changes
        .into_iter()
        .map(|(span, value)| (base + span.start..base + span.end, value))
        .collect())
}

#[derive(Clone, Copy)]
struct XmlChar {
    start: usize,
    end: usize,
    cdata: bool,
}

struct TextCursor<'a> {
    raw: &'a str,
    decoded: &'a str,
    raw_offset: usize,
    offset: usize,
    cdata: bool,
}

impl TextCursor<'_> {
    fn take_to(&mut self, end: usize) -> ApiResult<Option<XmlChar>> {
        let mut last = None;
        while self.offset < end {
            last = Some(self.next()?);
        }
        require(self.offset == end)?;
        Ok(last)
    }

    fn next(&mut self) -> ApiResult<XmlChar> {
        loop {
            let rest = &self.raw[self.raw_offset..];
            if !self.cdata && rest.starts_with("<![CDATA[") {
                self.cdata = true;
                self.raw_offset += "<![CDATA[".len();
            } else if self.cdata && rest.starts_with("]]>") {
                self.cdata = false;
                self.raw_offset += 3;
            } else {
                break;
            }
        }
        let rest = &self.raw[self.raw_offset..];
        let (character, bytes) = if !self.cdata && rest.starts_with('&') {
            let end = rest.find(';').ok_or_else(invalid_zip)?;
            (
                decode_entity(&rest[1..end]).ok_or_else(invalid_zip)?,
                end + 1,
            )
        } else {
            let character = rest.chars().next().ok_or_else(invalid_zip)?;
            (character, character.len_utf8())
        };
        require(self.decoded[self.offset..].starts_with(character))?;
        let start = self.raw_offset;
        self.raw_offset += bytes;
        self.offset += character.len_utf8();
        Ok(XmlChar {
            start,
            end: self.raw_offset,
            cdata: self.cdata,
        })
    }
}

fn decode_entity(entity: &str) -> Option<char> {
    Some(match entity {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        _ => {
            let numeric = entity.strip_prefix('#')?;
            let value = match numeric.strip_prefix('x') {
                Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                None => numeric.parse().ok()?,
            };
            char::from_u32(value)?
        }
    })
}
