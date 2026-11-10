use super::{ApiResult, invalid, normalize, string, valid_id};
use pulldown_cmark::{Event, LinkType, Options, Parser, Tag, TagEnd};
use regex::{Regex, RegexBuilder};
use serde_json::{Map, Value, json};
use std::cmp::Reverse;
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;
use std::sync::OnceLock;

struct Document<'a> {
    id: &'a str,
    markdown: &'a str,
    names: Vec<&'a str>,
    paths: Option<Vec<String>>,
    attachment_paths: Vec<(String, &'a str)>,
    attachment_unavailable: bool,
}

impl Document<'_> {
    fn source_paths(&self) -> impl Iterator<Item = &str> {
        let attachment_only = self.paths.as_ref().is_none_or(Vec::is_empty);
        self.paths.iter().flatten().map(String::as_str).chain(
            self.attachment_paths
                .iter()
                .filter(move |_| attachment_only)
                .map(|(path, _)| path.as_str()),
        )
    }
}

fn string_array(value: &Value) -> ApiResult<Vec<&str>> {
    value
        .as_array()
        .ok_or_else(invalid)?
        .iter()
        .map(|item| item.as_str().ok_or_else(invalid))
        .collect()
}

fn documents(request: &Map<String, Value>) -> ApiResult<Vec<Document<'_>>> {
    let mut ids = BTreeSet::new();
    request
        .get("documents")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?
        .iter()
        .map(|value| {
            let value = value.as_object().ok_or_else(invalid)?;
            let id = string(value.get("id"))?;
            if id.is_empty() || !ids.insert(id) {
                return Err(invalid());
            }
            let title = string(value.get("title"))?;
            let mut names = match value.get("lookupTitles") {
                Some(value) => string_array(value)?,
                None => vec![title],
            };
            if let Some(value) = value.get("aliases") {
                names.extend(string_array(value)?);
            }
            let paths = value
                .get("paths")
                .map(|value| {
                    string_array(value)?
                        .into_iter()
                        .map(|value| path_key(value, "").ok_or_else(invalid))
                        .collect::<ApiResult<Vec<_>>>()
                })
                .transpose()?;
            let attachment_paths = value
                .get("attachmentPaths")
                .map(|value| {
                    string_array(value)?
                        .into_iter()
                        .map(attachment_path)
                        .collect::<ApiResult<Vec<_>>>()
                })
                .transpose()?
                .unwrap_or_default();
            let attachment_unavailable = value
                .get("attachmentUnavailable")
                .map(|value| value.as_bool().ok_or_else(invalid))
                .transpose()?
                .unwrap_or_default();
            Ok(Document {
                id,
                markdown: string(value.get("markdown"))?,
                names,
                paths,
                attachment_paths,
                attachment_unavailable,
            })
        })
        .collect()
}

fn filename_key(value: &str) -> String {
    let key = normalize(value.trim());
    key.strip_suffix(".md").unwrap_or(&key).to_owned()
}

fn path_key(value: &str, parent: &str) -> Option<String> {
    let mut key = normalized_path(value, parent)?;
    if key.ends_with(".md") {
        key.truncate(key.len() - 3);
    }
    Some(key)
}

fn normalized_path(value: &str, parent: &str) -> Option<String> {
    if value.is_empty() || value.contains('\\') || value.chars().any(char::is_control) {
        return None;
    }
    let mut parts: Vec<&str> = if value.starts_with('/') || parent.is_empty() {
        Vec::new()
    } else {
        parent.split('/').collect()
    };
    for part in value.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            _ => parts.push(part),
        }
    }
    if parts.is_empty() {
        return None;
    }
    Some(normalize(parts.join("/").trim()))
}

fn attachment_file_name(value: &str) -> bool {
    value.rsplit_once('.').is_some_and(|(stem, extension)| {
        !stem.is_empty()
            && !extension.is_empty()
            && !extension.eq_ignore_ascii_case("md")
            && extension.bytes().all(|byte| byte.is_ascii_alphanumeric())
    })
}

fn attachment_path(value: &str) -> ApiResult<(String, &str)> {
    if value.split('/').any(|part| {
        part.is_empty()
            || part.trim() != part
            || part.ends_with('.')
            || part.chars().any(|ch| {
                ch.is_control() || matches!(ch, '\\' | ':' | '<' | '>' | '"' | '|' | '?' | '*')
            })
    }) {
        return Err(invalid());
    }
    let name = value
        .rsplit('/')
        .next()
        .filter(|name| attachment_file_name(name));
    Ok((normalize(value), name.ok_or_else(invalid)?))
}

fn decode_destination(value: &str) -> Option<String> {
    let source = value.as_bytes();
    let mut bytes = Vec::with_capacity(source.len());
    let mut index = 0;
    while index < source.len() {
        if source[index] == b'%' {
            let high = (*source.get(index + 1)? as char).to_digit(16)?;
            let low = (*source.get(index + 2)? as char).to_digit(16)?;
            bytes.push((high * 16 + low) as u8);
            index += 3;
        } else {
            bytes.push(source[index]);
            index += 1;
        }
    }
    String::from_utf8(bytes).ok()
}

fn external(value: &str) -> bool {
    if value.starts_with("//") || value.contains('\\') || value.chars().any(char::is_control) {
        return true;
    }
    value.split_once(':').is_some_and(|(scheme, _)| {
        !scheme.is_empty()
            && scheme
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-' | '.'))
    })
}

struct Lookup<'a> {
    ids: BTreeMap<&'a str, usize>,
    names: BTreeMap<String, BTreeSet<&'a str>>,
    paths: BTreeMap<String, BTreeSet<&'a str>>,
    attachment_paths: BTreeMap<String, BTreeSet<Attachment<'a>>>,
    attachment_names: BTreeMap<String, BTreeSet<Attachment<'a>>>,
    attachment_by_id: BTreeMap<&'a str, &'a str>,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Attachment<'a> {
    id: &'a str,
    name: &'a str,
    unavailable: bool,
}

struct Resolved<'a> {
    target: String,
    anchor: Option<String>,
    id: Option<&'a str>,
    attachment_name: Option<&'a str>,
    stable: bool,
}

fn unique<T: Copy + Ord>(matches: &BTreeSet<T>) -> Option<T> {
    (matches.len() == 1).then(|| *matches.first().unwrap())
}

fn relative_candidates<T: Copy + Ord>(
    source: &Document<'_>,
    target: &str,
    paths: &BTreeMap<String, BTreeSet<T>>,
    key: fn(&str, &str) -> Option<String>,
) -> BTreeSet<T> {
    let mut candidates = BTreeSet::new();
    for source_path in source.source_paths() {
        let parent = source_path
            .rsplit_once('/')
            .map_or("", |(parent, _)| parent);
        if let Some(path) = key(target, parent)
            && let Some(found) = paths.get(&path)
        {
            candidates.extend(found.iter().copied());
        }
    }
    candidates
}

fn explicit_relative(target: &str) -> bool {
    target.starts_with("./") || target.starts_with("../") || matches!(target, "." | "..")
}

impl<'a> Lookup<'a> {
    fn new(documents: &[Document<'a>]) -> Self {
        let mut result = Self {
            ids: BTreeMap::new(),
            names: BTreeMap::new(),
            paths: BTreeMap::new(),
            attachment_paths: BTreeMap::new(),
            attachment_names: BTreeMap::new(),
            attachment_by_id: BTreeMap::new(),
        };
        for (index, document) in documents.iter().enumerate() {
            result.ids.insert(document.id, index);
            for name in &document.names {
                if !name.trim().is_empty() {
                    result
                        .names
                        .entry(filename_key(name))
                        .or_default()
                        .insert(document.id);
                }
            }
            for path in document.paths.iter().flatten() {
                result
                    .paths
                    .entry(path.clone())
                    .or_default()
                    .insert(document.id);
            }
            for (path, name) in &document.attachment_paths {
                let attachment = Attachment {
                    id: document.id,
                    name,
                    unavailable: document.attachment_unavailable,
                };
                result
                    .attachment_paths
                    .entry(path.clone())
                    .or_default()
                    .insert(attachment);
                result
                    .attachment_names
                    .entry(normalize(name))
                    .or_default()
                    .insert(attachment);
            }
            if !document.attachment_unavailable
                && let Some((_, first)) = document.attachment_paths.first()
                && document
                    .attachment_paths
                    .iter()
                    .all(|(_, name)| name == first)
            {
                result.attachment_by_id.insert(document.id, first);
            }
        }
        result
    }

    fn attachment_candidates(
        &self,
        source: &Document<'_>,
        target: &str,
        wiki: bool,
    ) -> BTreeSet<Attachment<'a>> {
        if self.attachment_paths.is_empty()
            || !target.rsplit('/').next().is_some_and(attachment_file_name)
        {
            return BTreeSet::new();
        }
        let path = normalized_path(target, "");
        let exact = || {
            path.as_ref()
                .and_then(|path| self.attachment_paths.get(path))
        };
        if target.starts_with('/') {
            return exact().cloned().unwrap_or_default();
        }
        let relative =
            || relative_candidates(source, target, &self.attachment_paths, normalized_path);
        if explicit_relative(target) || !wiki {
            return relative();
        }
        if target.contains('/') {
            if let Some(matches) = exact() {
                return matches.clone();
            }
            let Some(path) = path.filter(|path| path.contains('/')) else {
                return BTreeSet::new();
            };
            let local = relative();
            if !local.is_empty() {
                return local;
            }
            let suffix = format!("/{path}");
            return self
                .attachment_paths
                .iter()
                .filter(|(candidate, _)| candidate.ends_with(suffix.as_str()))
                .flat_map(|(_, matches)| matches.iter().copied())
                .collect();
        }
        let local = relative();
        if !local.is_empty() {
            return local;
        }
        path.as_ref()
            .and_then(|path| self.attachment_names.get(path))
            .cloned()
            .unwrap_or_default()
    }

    fn logical(&self, source: &Document<'a>, target: &str, wiki: bool) -> (Option<&'a str>, bool) {
        if target.is_empty() {
            return (Some(source.id), true);
        }
        let id = if target.to_ascii_lowercase().ends_with(".md") {
            &target[..target.len() - 3]
        } else {
            target
        };
        if let Some((id, _)) = self.ids.get_key_value(id) {
            return (Some(*id), true);
        }
        if valid_id(&json!(id)) {
            return (None, true);
        }
        if target.starts_with('/') {
            return (
                path_key(target, "").and_then(|path| self.paths.get(&path).and_then(unique)),
                false,
            );
        }
        let relative = || relative_candidates(source, target, &self.paths, path_key);
        if explicit_relative(target) || !wiki && target.contains('/') {
            return (unique(&relative()), false);
        }
        if wiki && target.contains('/') {
            let Some(path) = path_key(target, "") else {
                return (None, false);
            };
            if let Some(ids) = self.paths.get(&path) {
                return (unique(ids), false);
            }
            if !path.contains('/') {
                return (None, false);
            }
            let local = relative();
            if !local.is_empty() {
                return (unique(&local), false);
            }
            let suffix = format!("/{path}");
            let mut matches = self
                .paths
                .iter()
                .filter(|(candidate, _)| candidate.ends_with(suffix.as_str()))
                .flat_map(|(_, ids)| ids.iter().copied());
            let Some(first) = matches.next() else {
                return (None, false);
            };
            return (matches.all(|id| id == first).then_some(first), false);
        }
        if source.paths.is_some() || !source.attachment_paths.is_empty() {
            let local = relative();
            if !wiki || !local.is_empty() {
                return (unique(&local), false);
            }
        }
        (
            self.names.get(&filename_key(target)).and_then(unique),
            false,
        )
    }

    fn resolve(&self, source: &Document<'a>, value: &str, wiki: bool) -> Option<Resolved<'a>> {
        if let Some(route) = value.strip_prefix("inkvault://note/") {
            let (route, raw_anchor) = split_anchor(route);
            let (id, query) = route
                .split_once('?')
                .map_or((route, None), |(id, query)| (id, Some(query)));
            if id.is_empty() || id.contains('/') {
                return None;
            }
            let id = decode_destination(id)?;
            let anchor = decoded_anchor(raw_anchor)?;
            if id.chars().any(char::is_control)
                || anchor
                    .as_ref()
                    .is_some_and(|value| value.chars().any(char::is_control))
            {
                return None;
            }
            let attachment_name = match query {
                Some("view=markdown") => None,
                None if raw_anchor.is_none() && valid_id(&json!(id)) => {
                    Some(*self.attachment_by_id.get(id.as_str())?)
                }
                _ => return None,
            };
            return Some(Resolved {
                id: self.ids.get_key_value(id.as_str()).map(|(id, _)| *id),
                target: id,
                anchor,
                attachment_name,
                stable: true,
            });
        }
        let (target, anchor, wiki) = if let Some(route) = value.strip_prefix("inkwiki:") {
            if route.starts_with("//") || route.contains('?') {
                return None;
            }
            let (target, anchor) = split_anchor(route);
            (decode_destination(target)?, decoded_anchor(anchor)?, true)
        } else {
            if external(value) {
                return None;
            }
            let (target, anchor) = split_anchor(value);
            if wiki {
                (target.to_owned(), anchor.map(str::to_owned), true)
            } else {
                (
                    decode_destination(target).unwrap_or_else(|| target.to_owned()),
                    anchor.map(|anchor| {
                        decode_destination(anchor).unwrap_or_else(|| anchor.to_owned())
                    }),
                    false,
                )
            }
        };
        let target = target.trim().to_owned();
        if external(&target)
            || anchor
                .as_ref()
                .is_some_and(|value| value.chars().any(char::is_control))
        {
            return None;
        }
        let attachments = self.attachment_candidates(source, &target, wiki);
        let (id, attachment_name, stable) = if attachments.is_empty() {
            let (id, stable) = self.logical(source, &target, wiki);
            (id, None, stable)
        } else {
            // An unavailable original still owns its path. Never promote a
            // lower-priority candidate or a similarly named Markdown note.
            let attachment = unique(&attachments).filter(|file| !file.unavailable);
            (
                attachment.map(|file| file.id),
                attachment.map(|file| file.name),
                false,
            )
        };
        Some(Resolved {
            target,
            anchor,
            id,
            attachment_name,
            stable,
        })
    }
}

fn decoded_anchor(value: Option<&str>) -> Option<Option<String>> {
    match value {
        Some(value) => Some(Some(decode_destination(value)?)),
        None => Some(None),
    }
}

fn split_anchor(value: &str) -> (&str, Option<&str>) {
    value
        .split_once('#')
        .map_or((value, None), |(target, anchor)| (target, Some(anchor)))
}

struct SourceLink {
    span: Range<usize>,
    destination: String,
    kind: LinkType,
    image: bool,
}

fn frontmatter_range(text: &str) -> Option<Range<usize>> {
    let bom = usize::from(text.starts_with('\u{feff}')) * '\u{feff}'.len_utf8();
    let mut lines = text[bom..].split_inclusive('\n');
    let first = lines.next()?;
    if frontmatter_delimiter(first) != "---" {
        return None;
    }
    let mut end = bom + first.len();
    for line in lines {
        end += line.len();
        if matches!(frontmatter_delimiter(line), "---" | "...") {
            return Some(0..end);
        }
    }
    None
}

fn frontmatter_delimiter(line: &str) -> &str {
    line.trim_end_matches(['\r', '\n'])
        .trim_end_matches([' ', '\t'])
}

fn html_tag(raw: &str) -> Option<(String, bool, bool)> {
    let raw = raw.strip_prefix('<')?.strip_suffix('>')?.trim();
    let closing = raw.starts_with('/');
    let body = raw.strip_prefix('/').unwrap_or(raw);
    let end = body
        .find(|ch: char| !ch.is_ascii_alphanumeric() && ch != '-')
        .unwrap_or(body.len());
    let name = body[..end].to_ascii_lowercase();
    if name.is_empty() || !name.as_bytes()[0].is_ascii_alphabetic() {
        return None;
    }
    let self_closing = raw.ends_with('/')
        || matches!(
            name.as_str(),
            "area"
                | "base"
                | "br"
                | "col"
                | "embed"
                | "hr"
                | "img"
                | "input"
                | "link"
                | "meta"
                | "param"
                | "source"
                | "track"
                | "wbr"
        );
    Some((name, closing, self_closing))
}

fn protected_ranges(text: &str) -> Vec<Range<usize>> {
    let mut ranges: Vec<_> = frontmatter_range(text).into_iter().collect();
    let mut stack: Vec<(String, usize)> = Vec::new();
    for (event, range) in Parser::new_ext(text, Options::ENABLE_WIKILINKS).into_offset_iter() {
        match event {
            Event::Start(Tag::HtmlBlock) => ranges.push(range),
            Event::Html(_) => ranges.push(range),
            Event::InlineHtml(raw) => {
                ranges.push(range.clone());
                if let Some((name, closing, self_closing)) = html_tag(&raw) {
                    if closing {
                        if let Some(index) = stack.iter().rposition(|(open, _)| *open == name) {
                            ranges.push(stack[index].1..range.end);
                            stack.truncate(index);
                        }
                    } else if !self_closing {
                        stack.push((name, range.start));
                    }
                }
            }
            _ => {}
        }
    }
    ranges.extend(stack.into_iter().map(|(_, start)| start..text.len()));
    ranges.sort_unstable_by_key(|range| range.start);
    let mut merged: Vec<Range<usize>> = Vec::new();
    for range in ranges {
        if let Some(last) = merged.last_mut()
            && range.start <= last.end
        {
            last.end = last.end.max(range.end);
        } else {
            merged.push(range);
        }
    }
    merged
}

fn protected(range: &Range<usize>, regions: &[Range<usize>]) -> bool {
    let index = regions.partition_point(|region| region.end <= range.start);
    regions
        .get(index)
        .is_some_and(|region| region.start < range.end)
}

fn parsed_links(text: &str) -> (Vec<SourceLink>, BTreeSet<String>) {
    let regions = protected_ranges(text);
    let mut links = Vec::new();
    let mut tags = BTreeSet::new();
    let mut code_block = false;
    let mut link_depth = 0usize;
    for (event, range) in Parser::new_ext(text, Options::ENABLE_WIKILINKS).into_offset_iter() {
        match event {
            Event::Start(Tag::CodeBlock(_)) => code_block = true,
            Event::End(TagEnd::CodeBlock) => code_block = false,
            Event::End(TagEnd::Link | TagEnd::Image) => link_depth = link_depth.saturating_sub(1),
            Event::Start(tag @ (Tag::Link { .. } | Tag::Image { .. })) => {
                link_depth += 1;
                if code_block || protected(&(range.start..range.start + 1), &regions) {
                    continue;
                }
                let image = matches!(tag, Tag::Image { .. });
                let (Tag::Link {
                    link_type,
                    dest_url,
                    ..
                }
                | Tag::Image {
                    link_type,
                    dest_url,
                    ..
                }) = tag
                else {
                    unreachable!()
                };
                links.push(SourceLink {
                    span: range,
                    destination: dest_url.into_string(),
                    kind: link_type,
                    image,
                });
            }
            Event::Text(_) if !code_block && link_depth == 0 && !protected(&range, &regions) => {
                extract_tags(text, range, &mut tags)
            }
            _ => {}
        }
    }
    (links, tags)
}

fn extract_tags(markdown: &str, range: Range<usize>, tags: &mut BTreeSet<String>) {
    static TAG: OnceLock<Regex> = OnceLock::new();
    let pattern = TAG.get_or_init(|| {
        Regex::new(r"#[\p{L}\p{N}_-][\p{L}\p{M}\p{N}_-]*(?:/[\p{L}\p{N}_-][\p{L}\p{M}\p{N}_-]*)*")
            .expect("constant tag regex")
    });
    for found in pattern.find_iter(&markdown[range.clone()]) {
        let absolute = range.start + found.start();
        if markdown[..absolute]
            .chars()
            .next_back()
            .is_some_and(|ch| !ch.is_whitespace() && !matches!(ch, '(' | '[' | '{'))
        {
            continue;
        }
        let mut prefix = String::new();
        for segment in normalize(&found.as_str()[1..]).split('/') {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(segment);
            tags.insert(prefix.clone());
        }
    }
}

pub(super) fn find_unlinked_mentions(request: &Map<String, Value>) -> ApiResult<Value> {
    const MAX_MARKDOWN_BYTES: usize = 1024 * 1024;
    let target_id = mention_id(request.get("targetId"))?;
    let limit = request
        .get("limit")
        .and_then(Value::as_u64)
        .filter(|limit| (1..=128).contains(limit))
        .ok_or_else(invalid)? as usize;
    let names = request
        .get("names")
        .and_then(Value::as_array)
        .filter(|names| (1..=64).contains(&names.len()))
        .ok_or_else(invalid)?;
    let mut names = names
        .iter()
        .map(|name| {
            name.as_str()
                .filter(|name| {
                    name.encode_utf16().take(256).count() <= 255
                        && !name.trim().is_empty()
                        && !name.chars().any(char::is_control)
                })
                .ok_or_else(invalid)
        })
        .collect::<ApiResult<Vec<_>>>()?;
    let documents = request
        .get("documents")
        .and_then(Value::as_array)
        .filter(|documents| documents.len() <= 16)
        .ok_or_else(invalid)?;
    let mut ids = BTreeSet::new();
    let mut sources = Vec::new();
    let mut remaining = MAX_MARKDOWN_BYTES;
    for document in documents {
        let document = document.as_object().ok_or_else(invalid)?;
        let id = mention_id(document.get("id"))?;
        let markdown = string(document.get("markdown"))?;
        remaining = remaining.checked_sub(markdown.len()).ok_or_else(invalid)?;
        if !ids.insert(id) {
            return Err(invalid());
        }
        if id != target_id {
            sources.push((id, markdown));
        }
    }

    names.sort_unstable_by_key(|name| (Reverse(name.chars().count()), *name));
    names.dedup();
    let pattern = names
        .into_iter()
        .map(regex::escape)
        .collect::<Vec<_>>()
        .join("|");
    let pattern = RegexBuilder::new(&pattern)
        .case_insensitive(true)
        .build()
        .map_err(|_| invalid())?;
    let mut mentions = Vec::new();
    for (id, markdown) in sources {
        let regions = protected_ranges(markdown);
        let mut last_end = 0;
        let mut last_end_utf16 = 0;
        for range in mention_text_ranges(markdown) {
            let text = &markdown[range.clone()];
            let mut from = 0;
            while let Some(found) = pattern.find_at(text, from) {
                let start = range.start + found.start();
                let first = found.as_str().chars().next().expect("nonempty mention");
                from = found.start() + first.len_utf8();
                if word_character(first)
                    && markdown[..start]
                        .chars()
                        .next_back()
                        .is_some_and(word_character)
                {
                    continue;
                }
                let Some(end) = mention_end(markdown, &regions, range.start, text, &pattern, found)
                else {
                    continue;
                };
                if mentions.len() == limit {
                    return Ok(json!({"mentions":mentions,"truncated":true}));
                }
                let label = &markdown[start..end];
                let start_utf16 = last_end_utf16 + markdown[last_end..start].encode_utf16().count();
                last_end = end;
                last_end_utf16 = start_utf16 + label.encode_utf16().count();
                mentions.push(
                    json!({"sourceId":id,"start":start_utf16,"end":last_end_utf16,"text":label}),
                );
                from = end - range.start;
            }
        }
    }
    Ok(json!({"mentions":mentions,"truncated":false}))
}

fn mention_id(value: Option<&Value>) -> ApiResult<&str> {
    let id = string(value)?;
    if id.is_empty() || id.len() > 128 || id.chars().any(char::is_control) {
        return Err(invalid());
    }
    Ok(id)
}

fn mention_text_ranges(markdown: &str) -> Vec<Range<usize>> {
    let mut ranges: Vec<Range<usize>> = Vec::new();
    let mut code_block = false;
    let mut link_depth = 0usize;
    for (event, range) in Parser::new_ext(markdown, Options::ENABLE_WIKILINKS).into_offset_iter() {
        match event {
            Event::Start(Tag::CodeBlock(_)) => code_block = true,
            Event::End(TagEnd::CodeBlock) => code_block = false,
            Event::Start(Tag::Link { .. } | Tag::Image { .. }) => link_depth += 1,
            Event::End(TagEnd::Link | TagEnd::Image) => link_depth = link_depth.saturating_sub(1),
            Event::Text(text)
                if !code_block && link_depth == 0 && text.as_ref() == &markdown[range.clone()] =>
            {
                if let Some(last) = ranges.last_mut()
                    && last.end == range.start
                {
                    last.end = range.end;
                } else {
                    ranges.push(range);
                }
            }
            _ => {}
        }
    }
    ranges
}

fn word_character(ch: char) -> bool {
    static WORD_CHARACTER: OnceLock<Regex> = OnceLock::new();
    let mut utf8 = [0; 4];
    WORD_CHARACTER
        .get_or_init(|| Regex::new(r"^[\p{L}\p{M}\p{N}]$").expect("constant word regex"))
        .is_match(ch.encode_utf8(&mut utf8))
}

fn mention_end<'a>(
    markdown: &str,
    regions: &[Range<usize>],
    base: usize,
    text: &'a str,
    pattern: &Regex,
    mut found: regex::Match<'a>,
) -> Option<usize> {
    let start = base + found.start();
    loop {
        let end = base + found.end();
        let last = found
            .as_str()
            .chars()
            .next_back()
            .expect("nonempty mention");
        let joins_word =
            word_character(last) && markdown[end..].chars().next().is_some_and(word_character);
        if !joins_word && !protected(&(start..end), regions) {
            return Some(end);
        }
        // A shorter alias at this position may still end at a word boundary.
        let prefix_end = found.end() - last.len_utf8();
        if prefix_end <= found.start() {
            return None;
        }
        let shorter = pattern.find_at(&text[..prefix_end], found.start())?;
        if shorter.start() != found.start() {
            return None;
        }
        found = shorter;
    }
}

pub(super) fn analyze_documents(request: &Map<String, Value>) -> ApiResult<Value> {
    let documents = documents(request)?;
    let lookup = Lookup::new(&documents);
    let mut results = Vec::new();
    let mut edges = BTreeSet::new();
    let mut unresolved = BTreeSet::new();
    for document in &documents {
        let (source_links, tags) = parsed_links(document.markdown);
        let mut links = Vec::new();
        for link in source_links {
            if let Some(resolved) = lookup.resolve(
                document,
                &link.destination,
                matches!(link.kind, LinkType::WikiLink { .. }),
            ) {
                if let Some(id) = resolved.id {
                    edges.insert((document.id, id, resolved.attachment_name));
                } else {
                    unresolved.insert((document.id, resolved.target.clone()));
                }
                let mut value = json!({"target":resolved.target,"anchor":resolved.anchor,"targetId":resolved.id});
                if let Some(name) = resolved.attachment_name {
                    value["attachmentName"] = json!(name);
                }
                links.push(value);
            }
        }
        results.push(json!({"id":document.id,"tags":tags,"links":links}));
    }
    Ok(json!({"documents":results,
        "edges":edges.into_iter().map(|(from,to,attachment_name)|{
            let mut edge = json!({"from":from,"to":to});
            if let Some(name) = attachment_name {
                edge["attachmentName"] = json!(name);
            }
            edge
        }).collect::<Vec<_>>(),
        "unresolved":unresolved.into_iter().map(|(from,target)|json!({"from":from,"target":target})).collect::<Vec<_>>() }))
}

fn escape_at(bytes: &[u8], index: usize) -> bool {
    bytes[index] == b'\\' && bytes.get(index + 1).is_some_and(u8::is_ascii_punctuation)
}

fn skip_code(bytes: &[u8], start: usize) -> usize {
    let count = bytes[start..]
        .iter()
        .take_while(|byte| **byte == b'`')
        .count();
    let mut index = start + count;
    while index < bytes.len() {
        if bytes[index] == b'`' {
            let run = bytes[index..]
                .iter()
                .take_while(|byte| **byte == b'`')
                .count();
            if run == count {
                return index + run;
            }
            index += run;
        } else {
            index += 1;
        }
    }
    start + count
}

fn link_label_end(bytes: &[u8]) -> Option<usize> {
    if bytes.first() != Some(&b'[') {
        return None;
    }
    let mut index = 1;
    let mut depth = 1usize;
    while index < bytes.len() {
        if escape_at(bytes, index) {
            index += 2;
            continue;
        }
        match bytes[index] {
            b'`' => {
                index = skip_code(bytes, index);
                continue;
            }
            b'[' => depth += 1,
            b']' => {
                depth -= 1;
                if depth == 0 {
                    return Some(index);
                }
            }
            _ => {}
        }
        index += 1;
    }
    None
}

fn inline_href(raw: &str) -> Option<(Range<usize>, bool)> {
    let bytes = raw.as_bytes();
    let index = link_label_end(bytes)?;
    if bytes.get(index + 1) != Some(&b'(') {
        return None;
    }
    href_range(bytes, index + 2, false)
}

fn href_range(bytes: &[u8], mut index: usize, reference: bool) -> Option<(Range<usize>, bool)> {
    while bytes.get(index).is_some_and(u8::is_ascii_whitespace) {
        index += 1;
    }
    let angled = bytes.get(index) == Some(&b'<');
    if angled {
        index += 1;
    }
    let start = index;
    let mut parentheses = 0usize;
    while index < bytes.len() {
        if escape_at(bytes, index) {
            index += 2;
            continue;
        }
        match bytes[index] {
            b'>' if angled => return Some((start..index, true)),
            b'(' if !angled => parentheses += 1,
            b')' if !angled => {
                if parentheses == 0 {
                    return Some((start..index, false));
                }
                parentheses -= 1;
            }
            byte if !angled && byte.is_ascii_whitespace() && parentheses == 0 => {
                return Some((start..index, false));
            }
            _ => {}
        }
        index += 1;
    }
    (reference && !angled && parentheses == 0 && start < index).then_some((start..index, false))
}

fn inline_href_matches(raw: &str, angled: bool, expected: &str) -> bool {
    let probe = if angled {
        format!("[x](<{raw}>)")
    } else {
        format!("[x]({raw})")
    };
    let mut destinations = Parser::new(&probe).filter_map(|event| match event {
        Event::Start(Tag::Link {
            link_type: LinkType::Inline,
            dest_url,
            ..
        }) => Some(dest_url),
        _ => None,
    });
    destinations
        .next()
        .is_some_and(|value| value.as_ref() == expected)
        && destinations.next().is_none()
}

fn wiki_replacement(
    raw: &str,
    destination: &str,
    target: &str,
    piped: bool,
    embed: bool,
) -> Option<String> {
    let prefix = if embed { "![[" } else { "[[" };
    let body = raw.strip_prefix(prefix)?.strip_suffix("]]")?;
    let (raw_target, display) = if piped {
        body.split_once('|')?
    } else {
        (body, body)
    };
    if raw_target != destination {
        return None;
    }
    let (path, anchor) = split_anchor(raw_target);
    let (leading, trailing) = if embed {
        (
            &path[..path.len() - path.trim_start().len()],
            &path[path.trim_end().len()..],
        )
    } else {
        ("", "")
    };
    Some(format!(
        "{prefix}{leading}{target}{trailing}{}|{display}]]",
        anchor.map_or(String::new(), |anchor| format!("#{anchor}"))
    ))
}

fn is_obsidian_attachment_target(target: &str) -> bool {
    let name = target.rsplit('/').next().unwrap_or(target);
    // Match attachment spellings in the preview even if the actual file is missing.
    !name.starts_with('.')
        && name.rsplit_once('.').is_some_and(|(_, extension)| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "pdf"
                    | "canvas"
                    | "png"
                    | "jpg"
                    | "jpeg"
                    | "webp"
                    | "doc"
                    | "docx"
                    | "odt"
                    | "ppt"
                    | "pptx"
                    | "odp"
                    | "hwp"
                    | "hwpx"
            )
        })
}

struct Change<'a> {
    target_id: &'a str,
    span: Range<usize>,
    replacement: Option<String>,
    unsupported: Option<&'static str>,
}

fn utf16_offsets(text: &str, changes: &[Change<'_>]) -> BTreeMap<usize, usize> {
    let points: BTreeSet<_> = changes
        .iter()
        .flat_map(|change| [change.span.start, change.span.end])
        .collect();
    let mut offsets = BTreeMap::new();
    let (mut byte, mut units) = (0, 0);
    for point in points {
        units += text[byte..point].encode_utf16().count();
        offsets.insert(point, units);
        byte = point;
    }
    offsets
}

pub(super) fn rewrite_note_links(request: &Map<String, Value>) -> ApiResult<Value> {
    let documents = documents(request)?;
    let lookup = Lookup::new(&documents);
    let source_id = string(request.get("sourceId"))?;
    let source = &documents[*lookup.ids.get(source_id).ok_or_else(invalid)?];
    let target_ids = match (request.get("targetId"), request.get("targetIds")) {
        (Some(value), None) if valid_id(value) => BTreeSet::from([string(Some(value))?]),
        (None, Some(value)) => {
            let values = value.as_array().ok_or_else(invalid)?;
            if values.len() > 10_000 {
                return Err(invalid());
            }
            let mut ids = BTreeSet::new();
            for value in values {
                let id = string(Some(value))?;
                if !valid_id(value) || !ids.insert(id) {
                    return Err(invalid());
                }
            }
            ids
        }
        _ => return Err(invalid()),
    };
    if target_ids.iter().any(|id| !lookup.ids.contains_key(id)) {
        return Err(invalid());
    }
    let text = string(request.get("text"))?;
    let (links, _) = parsed_links(text);
    let mut changes = Vec::new();
    for link in links {
        let Some(resolved) = lookup.resolve(
            source,
            &link.destination,
            matches!(link.kind, LinkType::WikiLink { .. }),
        ) else {
            continue;
        };
        let Some(target_id) = resolved.id else {
            continue;
        };
        if !target_ids.contains(target_id) || resolved.stable {
            continue;
        }
        if link.image
            && (!matches!(link.kind, LinkType::WikiLink { .. })
                || resolved.attachment_name.is_some()
                || !documents[lookup.ids[target_id]].attachment_paths.is_empty()
                || is_obsidian_attachment_target(&resolved.target))
        {
            changes.push(Change {
                target_id,
                span: link.span,
                replacement: None,
                unsupported: Some("image"),
            });
            continue;
        }
        if let Some(name) = resolved.attachment_name
            && (!matches!(link.kind, LinkType::Inline)
                || resolved.anchor.is_some()
                || lookup.attachment_by_id.get(target_id).copied() != Some(name))
        {
            changes.push(Change {
                target_id,
                span: link.span,
                replacement: None,
                unsupported: Some("attachment"),
            });
            continue;
        }
        let raw = &text[link.span.clone()];
        match link.kind {
            LinkType::WikiLink { has_pothole } => {
                let replacement =
                    wiki_replacement(raw, &link.destination, target_id, has_pothole, link.image);
                changes.push(Change {
                    target_id,
                    span: link.span,
                    unsupported: replacement.is_none().then_some("wiki"),
                    replacement,
                });
            }
            LinkType::Inline => {
                if let Some((href, angled)) = inline_href(raw)
                    && inline_href_matches(&raw[href.clone()], angled, &link.destination)
                {
                    let raw_fragment = split_anchor(&raw[href.clone()]).1;
                    if raw_fragment.is_some_and(|fragment| decode_destination(fragment).is_none()) {
                        changes.push(Change {
                            target_id,
                            span: link.span,
                            replacement: None,
                            unsupported: Some("inline"),
                        });
                        continue;
                    }
                    let suffix =
                        raw_fragment.map_or(String::new(), |fragment| format!("#{fragment}"));
                    let replacement = if resolved.attachment_name.is_some() {
                        format!("inkvault://note/{target_id}")
                    } else {
                        format!("inkvault://note/{target_id}?view=markdown{suffix}")
                    };
                    changes.push(Change {
                        target_id,
                        span: link.span.start + href.start..link.span.start + href.end,
                        replacement: Some(replacement),
                        unsupported: None,
                    });
                } else {
                    changes.push(Change {
                        target_id,
                        span: link.span,
                        replacement: None,
                        unsupported: Some("inline"),
                    });
                }
            }
            _ => changes.push(Change {
                target_id,
                span: link.span,
                replacement: None,
                unsupported: Some("reference"),
            }),
        }
    }
    changes.sort_unstable_by_key(|change| change.span.start);
    let offsets = utf16_offsets(text, &changes);
    let mut replacements = Vec::new();
    let mut unsupported = Vec::new();
    for change in changes {
        let original = &text[change.span.clone()];
        let start = offsets[&change.span.start];
        let end = offsets[&change.span.end];
        if let Some(kind) = change.unsupported {
            unsupported.push(json!({"targetId":change.target_id,"kind":kind,"start":start,"end":end,"original":original}));
        } else if let Some(replacement) = change.replacement
            && replacement != original
        {
            replacements.push(
                json!({"start":start,"end":end,"original":original,"replacement":replacement}),
            );
        }
    }
    Ok(json!({"replacements":replacements,"unsupported":unsupported}))
}

const PORTABLE_LINK_DOCUMENTS: usize = 10_000;
const PORTABLE_LINK_BYTES: usize = 8 * 1024 * 1024;

struct PortablePath<'a> {
    primary: &'a str,
    markdown: Option<&'a str>,
}

fn portable_path(path: &str) -> bool {
    path.len() <= 1024
        && path.split('/').all(|part| {
            !part.is_empty()
                && !part.starts_with('.')
                && !part.ends_with('.')
                && !part.contains("%%")
                && part.trim() == part
                && !part.chars().any(|ch| {
                    ch.is_control()
                        || matches!(
                            ch,
                            '\\' | ':' | '<' | '>' | '"' | '|' | '?' | '*' | '#' | '[' | ']' | '^'
                        )
                })
        })
}

fn portable_href(source: &str, target: &str, anchor: Option<&str>) -> String {
    let parents: Vec<_> = source
        .rsplit_once('/')
        .map_or("", |(parent, _)| parent)
        .split('/')
        .filter(|part| !part.is_empty())
        .collect();
    let target: Vec<_> = target.split('/').collect();
    let shared = parents
        .iter()
        .zip(&target[..target.len() - 1])
        .take_while(|(a, b)| a == b)
        .count();
    let mut result = if shared == parents.len() {
        "./".to_owned()
    } else {
        "../".repeat(parents.len() - shared)
    };
    for (index, part) in target[shared..].iter().enumerate() {
        if index > 0 {
            result.push('/');
        }
        push_portable_url(&mut result, part, false);
    }
    if let Some(anchor) = anchor {
        result.push('#');
        push_portable_url(&mut result, anchor, true);
    }
    result
}

fn push_portable_url(output: &mut String, value: &str, fragment: bool) {
    use std::fmt::Write as _;
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric()
            || matches!(
                byte,
                b'-' | b'_' | b'.' | b'~' | b'$' | b'+' | b',' | b';' | b'=' | b'@'
            )
            || fragment && matches!(byte, b'#' | b'^' | b'/' | b':' | b'?')
        {
            output.push(char::from(byte));
        } else if byte == b'&' {
            output.push_str("&amp;");
        } else {
            write!(output, "%{byte:02X}").expect("writing to String cannot fail");
        }
    }
}

fn portable_wiki(
    raw: &str,
    link: &SourceLink,
    target: &str,
    stable: bool,
    piped: bool,
) -> Option<String> {
    let prefix = if link.image { "![[" } else { "[[" };
    let body = raw.strip_prefix(prefix)?.strip_suffix("]]")?;
    let (destination, display) = if piped {
        let (destination, display) = body.split_once('|')?;
        (destination, Some(display))
    } else {
        (body, None)
    };
    if destination != link.destination {
        return None;
    }
    let (original, anchor) = split_anchor(destination);
    let target = target.strip_suffix(".md").unwrap_or(target);
    let mut replacement = format!("{prefix}/{target}");
    if let Some(anchor) = anchor {
        replacement.push('#');
        replacement.push_str(anchor);
    }
    if let Some(display) = display.or_else(|| {
        (!link.image && !stable && original.rsplit('/').next() != target.rsplit('/').next())
            .then_some(destination)
    }) {
        replacement.push('|');
        replacement.push_str(display);
    }
    replacement.push_str("]]");
    Some(replacement)
}

fn portable_target<'a, 'doc>(
    lookup: &Lookup<'doc>,
    paths: &BTreeMap<&str, PortablePath<'a>>,
    source: &Document<'doc>,
    destination: &str,
    wiki: bool,
) -> Option<Result<(&'a str, Resolved<'doc>), String>> {
    let resolved = lookup.resolve(source, destination, wiki);
    let resolved = resolved.or_else(|| {
        (destination.starts_with("inkvault://note/") || destination.starts_with("inkwiki:")).then(
            || Resolved {
                target: destination.to_owned(),
                id: None,
                anchor: None,
                attachment_name: None,
                stable: true,
            },
        )
    })?;
    if resolved.target.is_empty() {
        return None;
    }
    let resolved = if !wiki
        && !resolved.stable
        && resolved.id.is_none()
        && destination.contains('/')
        && !destination.starts_with('/')
        && !explicit_relative(destination)
    {
        // Obsidian also writes vault-root paths without a leading slash.
        lookup
            .resolve(source, &format!("/{destination}"), false)
            .filter(|root| root.id.is_some())
            .unwrap_or(resolved)
    } else {
        resolved
    };
    let target = resolved.id.and_then(|id| paths.get(id));
    let target = target.and_then(|path| {
        if resolved.attachment_name.is_some() {
            Some(path.primary)
        } else if destination.starts_with("inkvault://note/") && resolved.stable {
            path.markdown
        } else {
            Some(path.markdown.unwrap_or(path.primary))
        }
    });
    Some(match target {
        Some(target) => Ok((target, resolved)),
        None => Err(resolved.target),
    })
}

fn rewrite_portable_text<'doc>(
    lookup: &Lookup<'doc>,
    paths: &BTreeMap<&str, PortablePath<'_>>,
    document: &Document<'doc>,
    source: &str,
    text: &str,
    warn: &mut impl FnMut(&str),
) -> ApiResult<String> {
    let (links, _) = parsed_links(text);
    let mut changes = Vec::new();
    for link in links {
        let wiki = matches!(link.kind, LinkType::WikiLink { .. });
        let Some(target) = portable_target(lookup, paths, document, &link.destination, wiki) else {
            continue;
        };
        let (target, resolved) = match target {
            Ok(target) => target,
            Err(target) => {
                warn(&target);
                continue;
            }
        };
        let raw = &text[link.span.clone()];
        match link.kind {
            LinkType::WikiLink { has_pothole } => {
                if let Some(replacement) =
                    portable_wiki(raw, &link, target, resolved.stable, has_pothole)
                {
                    changes.push((link.span, replacement));
                } else {
                    warn(&resolved.target);
                }
            }
            LinkType::Inline => {
                let prefix = usize::from(link.image);
                if let Some((href, angled)) = raw.get(prefix..).and_then(inline_href)
                    && inline_href_matches(
                        &raw[prefix + href.start..prefix + href.end],
                        angled,
                        &link.destination,
                    )
                {
                    let start = link.span.start + prefix;
                    changes.push((
                        start + href.start..start + href.end,
                        portable_href(source, target, resolved.anchor.as_deref()),
                    ));
                } else {
                    warn(&resolved.target);
                }
            }
            // Reference occurrences use the single definition processed below.
            LinkType::Reference | LinkType::Collapsed | LinkType::Shortcut => {}
            _ => warn(&resolved.target),
        }
    }
    let frontmatter = frontmatter_range(text);
    let parser = Parser::new_ext(text, Options::ENABLE_WIKILINKS);
    for (_, definition) in parser.reference_definitions().iter() {
        if frontmatter
            .as_ref()
            .is_some_and(|range| definition.span.start < range.end)
        {
            continue;
        }
        let Some(target) = portable_target(lookup, paths, document, &definition.dest, false) else {
            continue;
        };
        let (target, resolved) = match target {
            Ok(target) => target,
            Err(target) => {
                warn(&target);
                continue;
            }
        };
        let raw = &text[definition.span.clone()];
        let href = link_label_end(raw.as_bytes())
            .filter(|end| raw.as_bytes().get(end + 1) == Some(&b':'))
            .and_then(|end| href_range(raw.as_bytes(), end + 2, true));
        if let Some((href, angled)) = href
            && inline_href_matches(&raw[href.clone()], angled, &definition.dest)
        {
            let start = definition.span.start;
            changes.push((
                start + href.start..start + href.end,
                portable_href(source, target, resolved.anchor.as_deref()),
            ));
        } else {
            warn(&resolved.target);
        }
    }
    changes.sort_unstable_by_key(|(range, _)| (range.start, range.end));
    let mut markdown = String::with_capacity(text.len());
    let mut last = 0;
    for (range, replacement) in changes {
        if range.start < last {
            warn("overlapping link");
            continue;
        }
        markdown.push_str(&text[last..range.start]);
        markdown.push_str(&replacement);
        if markdown.len() > PORTABLE_LINK_BYTES {
            return Err(invalid());
        }
        last = range.end;
    }
    markdown.push_str(&text[last..]);
    if markdown.len() > PORTABLE_LINK_BYTES {
        return Err(invalid());
    }
    Ok(markdown)
}

pub(super) fn portable_obsidian_links(request: &Map<String, Value>) -> ApiResult<Value> {
    let documents = documents(request)?;
    if documents.len() > PORTABLE_LINK_DOCUMENTS
        || documents
            .iter()
            .map(|document| document.markdown.len())
            .sum::<usize>()
            > PORTABLE_LINK_BYTES
    {
        return Err(invalid());
    }
    let lookup = Lookup::new(&documents);
    let values = request
        .get("paths")
        .and_then(Value::as_object)
        .ok_or_else(invalid)?;
    let mut paths = BTreeMap::new();
    let mut used = BTreeSet::new();
    for (id, value) in values {
        let value = value.as_object().ok_or_else(invalid)?;
        let primary = string(value.get("primary"))?;
        let markdown = value
            .get("markdown")
            .map(|value| string(Some(value)))
            .transpose()?;
        if !lookup.ids.contains_key(id.as_str())
            || !portable_path(primary)
            || !used.insert(normalize(primary))
            || markdown.is_some_and(|path| {
                !path.ends_with(".md")
                    || !portable_path(path)
                    || path != primary && !used.insert(normalize(path))
            })
        {
            return Err(invalid());
        }
        paths.insert(id.as_str(), PortablePath { primary, markdown });
    }
    let mut properties = BTreeMap::new();
    if let Some(value) = request.get("properties") {
        let values = value.as_object().ok_or_else(invalid)?;
        let mut total = 0;
        for (id, value) in values {
            let texts = string_array(value)?;
            if texts.len() > 512 || !lookup.ids.contains_key(id.as_str()) {
                return Err(invalid());
            }
            total += texts.iter().map(|text| text.len()).sum::<usize>();
            if total > 512 * 1024 {
                return Err(invalid());
            }
            properties.insert(id.as_str(), texts);
        }
    }
    let mut result = Map::new();
    for document in &documents {
        if document.markdown.is_empty() {
            continue;
        }
        let source = paths
            .get(document.id)
            .and_then(|path| path.markdown)
            .ok_or_else(invalid)?;
        let mut warnings = BTreeSet::new();
        let mut warn = |target: &str| {
            if warnings.len() < 64 {
                warnings.insert(target.chars().take(160).collect::<String>());
            } else {
                warnings.insert("…".to_owned());
            }
        };
        let markdown = rewrite_portable_text(
            &lookup,
            &paths,
            document,
            source,
            document.markdown,
            &mut warn,
        )?;
        let properties = match properties.get(document.id) {
            Some(values) => values
                .iter()
                .map(|text| {
                    rewrite_portable_text(&lookup, &paths, document, source, text, &mut warn)
                })
                .collect::<ApiResult<Vec<_>>>()?,
            None => Vec::new(),
        };
        result.insert(
            document.id.to_owned(),
            json!({"markdown": markdown, "properties": properties, "warnings": warnings}),
        );
    }
    Ok(json!({"documents":result}))
}

enum AnchorCandidate<'a> {
    Heading { text: &'a str, level: u64 },
    Block { id: &'a str },
}

fn heading_key(value: &str) -> String {
    normalize(&value.split_whitespace().collect::<Vec<_>>().join(" "))
}

fn slug(value: &str) -> String {
    static PUNCTUATION: OnceLock<Regex> = OnceLock::new();
    let pattern = PUNCTUATION.get_or_init(|| {
        Regex::new(r"[^\p{L}\p{M}\p{N}_\-\s]").expect("constant heading slug regex")
    });
    pattern.replace_all(value, "").replace(' ', "-")
}

pub(super) fn resolve_markdown_anchor(request: &Map<String, Value>) -> ApiResult<Value> {
    const MAX_CANDIDATES: usize = 10_000;
    const MAX_TEXT_BYTES: usize = 1024 * 1024;
    let anchor = string(request.get("anchor"))?;
    if anchor.chars().any(char::is_control) {
        return Err(invalid());
    }
    let values = request
        .get("candidates")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    if values.len() > MAX_CANDIDATES || anchor.len() > MAX_TEXT_BYTES {
        return Err(invalid());
    }
    let mut candidates = Vec::with_capacity(values.len());
    let mut text_bytes = anchor.len();
    for value in values {
        let value = value.as_object().ok_or_else(invalid)?;
        match string(value.get("kind"))? {
            "heading" => {
                let text = string(value.get("text"))?;
                let level = value
                    .get("level")
                    .and_then(Value::as_u64)
                    .filter(|level| (1..=6).contains(level))
                    .ok_or_else(invalid)?;
                if text
                    .chars()
                    .any(|ch| ch.is_control() && !matches!(ch, '\r' | '\n' | '\t'))
                {
                    return Err(invalid());
                }
                text_bytes = text_bytes
                    .checked_add(text.len())
                    .filter(|size| *size <= MAX_TEXT_BYTES)
                    .ok_or_else(invalid)?;
                candidates.push(AnchorCandidate::Heading { text, level });
            }
            "block" => {
                let id = string(value.get("id"))?;
                if id.is_empty() || id.chars().any(char::is_control) {
                    return Err(invalid());
                }
                text_bytes = text_bytes
                    .checked_add(id.len())
                    .filter(|size| *size <= MAX_TEXT_BYTES)
                    .ok_or_else(invalid)?;
                candidates.push(AnchorCandidate::Block { id });
            }
            _ => return Err(invalid()),
        }
    }
    let result = if let Some(id) = anchor.strip_prefix('^') {
        let matching: Vec<_> = candidates
            .iter()
            .enumerate()
            .filter_map(|(index, candidate)| match candidate {
                AnchorCandidate::Block { id: candidate_id } if *candidate_id == id => Some(index),
                _ => None,
            })
            .take(2)
            .collect();
        (matching.len() == 1).then(|| matching[0])
    } else {
        let anchor = heading_key(anchor);
        let mut headings = Vec::new();
        let mut ancestors: Vec<(u64, String)> = Vec::new();
        let mut used_slugs = BTreeSet::new();
        let mut slug_suffixes: BTreeMap<String, usize> = BTreeMap::new();
        for (index, candidate) in candidates.iter().enumerate() {
            if let AnchorCandidate::Heading { text, level } = candidate {
                let key = heading_key(text);
                while ancestors
                    .last()
                    .is_some_and(|(ancestor_level, _)| ancestor_level >= level)
                {
                    ancestors.pop();
                }
                ancestors.push((*level, key.clone()));
                let base = slug(&key);
                let mut generated = base.clone();
                let suffix = slug_suffixes.entry(base.clone()).or_insert(1);
                while !used_slugs.insert(generated.clone()) {
                    generated = format!("{base}-{suffix}");
                    *suffix += 1;
                }
                headings.push((
                    index,
                    key,
                    ancestors
                        .iter()
                        .map(|(_, key)| key.clone())
                        .collect::<Vec<_>>(),
                    generated,
                ));
            }
        }
        if anchor.is_empty() {
            None
        } else if let Some((index, ..)) = headings.iter().find(|(_, key, _, _)| *key == anchor) {
            Some(*index)
        } else {
            let pieces: Vec<_> = anchor.split('#').map(heading_key).take(7).collect();
            let hierarchy = if (2..=6).contains(&pieces.len())
                && pieces.iter().all(|piece| !piece.is_empty())
            {
                headings
                    .iter()
                    .find(|(_, _, path, _)| path.ends_with(&pieces))
                    .map(|(index, ..)| *index)
            } else {
                None
            };
            hierarchy.or_else(|| {
                headings
                    .iter()
                    .find(|(_, _, _, slug)| *slug == anchor)
                    .map(|(index, ..)| *index)
            })
        }
    };
    Ok(json!({"candidateIndex":result}))
}
