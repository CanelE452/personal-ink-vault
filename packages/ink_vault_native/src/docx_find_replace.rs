use super::{
    ApiResult, Node, Package, PackageEdits, Ranges, W, XML, children,
    contains_compatibility_markup, document, edge_space, edit, expected_hash, invalid, invalid_zip,
    open_source, ordinary_text, requested_path, require, require_fresh_output, revised_properties,
    single_child, text_edits, unsupported_document, valid_text, valid_text_chars, verify_source,
};
use crate::error;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::ops::Range;

const MAX_MATCHES: usize = 200;

pub(crate) fn preview(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 4 {
        return Err(invalid());
    }
    let path = requested_path(request.get("sourcePath"), true)?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let pattern = Pattern {
        find: find_text(request)?,
        replacement: None,
    };
    let mut source = open_source(&path, sha)?;
    let package = Package::read(&mut source)?;
    let plan = search(&package, pattern)?;
    verify_source(&mut source, &path, sha)?;
    Ok(json!({
        "sourceSha256":sha,"matchCount":plan.count,
        "paragraphCount":plan.matches.len(),"matches":plan.matches,
    }))
}

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = requested_path(request.get("sourcePath"), true)?;
    let output_path = requested_path(request.get("outputPath"), true)?;
    if source_path.parent() != output_path.parent() {
        return Err(invalid());
    }
    let sha = expected_hash(request.get("sourceSha256"))?;
    let find = find_text(request)?;
    let replacement = request
        .get("replacement")
        .and_then(Value::as_str)
        .filter(|value| *value != find && valid_text(value))
        .ok_or_else(invalid)?;
    let expected = request
        .get("expectedMatchCount")
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
        .filter(|value| (1..=MAX_MATCHES).contains(value))
        .ok_or_else(invalid)?;

    let mut source = open_source(&source_path, sha)?;
    require_fresh_output(&output_path)?;
    let package = Package::read(&mut source)?;
    let plan = search(
        &package,
        Pattern {
            find,
            replacement: Some(replacement),
        },
    )?;
    if plan.count != expected {
        return Err(invalid());
    }
    let mut edits = PackageEdits::default();
    edits.changed.insert(
        package.main_part.clone(),
        edit(&package.main_xml, plan.edits)?,
    );
    let output_sha = package.write_candidate(
        source,
        (&source_path, &output_path),
        sha,
        &edits,
        |written| verify_runs(written, &plan.written),
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"matchCount":plan.count,
        "paragraphCount":plan.matches.len(),
    }))
}

fn find_text(request: &Map<String, Value>) -> ApiResult<&str> {
    request
        .get("find")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && valid_text(value))
        .ok_or_else(invalid)
}

#[derive(Clone, Copy)]
struct Pattern<'a> {
    find: &'a str,
    replacement: Option<&'a str>,
}

struct TextRun<'a, 'input> {
    index: usize,
    node: Node<'a, 'input>,
    span: Range<usize>,
}

#[derive(Default)]
struct Segment<'a, 'input> {
    text: String,
    runs: Vec<TextRun<'a, 'input>>,
}

#[derive(Default)]
struct SearchPlan {
    count: usize,
    matches: Vec<Value>,
    edits: Vec<(Range<usize>, String)>,
    written: BTreeMap<usize, Vec<(usize, String)>>,
}

fn search(package: &Package, pattern: Pattern<'_>) -> ApiResult<SearchPlan> {
    if package.track_revisions {
        return Err(unsupported_document());
    }
    let xml = document(&package.main_xml)?;
    let body = single_child(xml.root_element(), W, "body")?;
    let mut plan = SearchPlan::default();
    let mut ranges = Ranges::default();
    let mut paragraph_index = 0;
    for block in body.children().filter(Node::is_element) {
        let excluded = ranges.inspect(block)?;
        if !block.has_tag_name((W, "p")) {
            continue;
        }
        if !excluded && !children(block, W, "pPr").any(revised_properties) {
            let mut segment = Segment::default();
            let mut snippet = None;
            let count_before = plan.count;
            let mut run_index = 0;
            for child in block.children() {
                if child.has_tag_name((W, "r")) {
                    let index = run_index;
                    run_index += 1;
                    if let Some(node) =
                        ordinary_text(child).filter(|_| !contains_compatibility_markup(child))
                    {
                        let text = node.text().unwrap_or_default();
                        if valid_text_chars(text) {
                            segment.push(index, node, text);
                            continue;
                        }
                    }
                } else if child.is_comment()
                    || child.is_text() && child.text().is_some_and(|text| text.trim().is_empty())
                {
                    continue;
                }
                segment.scan(
                    &package.main_xml,
                    pattern,
                    paragraph_index,
                    &mut plan,
                    &mut snippet,
                )?;
            }
            segment.scan(
                &package.main_xml,
                pattern,
                paragraph_index,
                &mut plan,
                &mut snippet,
            )?;
            if let Some(snippet) = snippet {
                plan.matches.push(json!({
                    "paragraphIndex":paragraph_index,"snippet":snippet,"count":plan.count-count_before,
                }));
            }
        }
        paragraph_index += 1;
    }
    if !ranges.is_closed() {
        return Err(unsupported_document());
    }
    Ok(plan)
}

impl<'a, 'input> Segment<'a, 'input> {
    fn push(&mut self, index: usize, node: Node<'a, 'input>, text: &str) {
        if !text.is_empty() {
            let start = self.text.len();
            self.text.push_str(text);
            self.runs.push(TextRun {
                index,
                node,
                span: start..self.text.len(),
            });
        }
    }

    fn scan(
        &mut self,
        xml: &str,
        pattern: Pattern<'_>,
        paragraph: usize,
        plan: &mut SearchPlan,
        snippet: &mut Option<String>,
    ) -> ApiResult<()> {
        let mut local_edits = BTreeMap::<usize, Vec<(Range<usize>, &str)>>::new();
        for (start, matched) in self.text.match_indices(pattern.find) {
            if plan.count == MAX_MATCHES {
                return Err(error(
                    "docx_match_limit",
                    "The DOCX search matched more than 200 locations",
                ));
            }
            plan.count += 1;
            snippet.get_or_insert_with(|| preview_snippet(&self.text, start));
            if let Some(replacement) = pattern.replacement {
                let end = start + matched.len();
                let first = self.runs.partition_point(|run| run.span.end <= start);
                let past_last = self.runs.partition_point(|run| run.span.start < end);
                for (offset, run) in self.runs[first..past_last].iter().enumerate() {
                    let span = start.max(run.span.start)..end.min(run.span.end);
                    let text = if offset == 0 { replacement } else { "" };
                    local_edits
                        .entry(first + offset)
                        .or_default()
                        .push((span, text));
                }
            }
        }
        for (index, replacements) in local_edits {
            let run = &self.runs[index];
            let mut text = String::new();
            let mut start = run.span.start;
            for (span, replacement) in replacements {
                text.push_str(&self.text[start..span.start]);
                text.push_str(replacement);
                start = span.end;
            }
            text.push_str(&self.text[start..run.span.end]);
            plan.edits.extend(text_edits(xml, run.node, &text)?);
            plan.written
                .entry(paragraph)
                .or_default()
                .push((run.index, text));
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
    // At most 78 Unicode scalars and two ellipses fit within 160 UTF-16 units.
    let end = text[start..]
        .char_indices()
        .nth(78)
        .map_or(text.len(), |(offset, _)| start + offset);
    let before = if start == 0 { "" } else { "…" };
    let after = if end == text.len() { "" } else { "…" };
    format!("{before}{}{after}", &text[start..end])
}

fn verify_runs(
    package: &Package,
    expected: &BTreeMap<usize, Vec<(usize, String)>>,
) -> ApiResult<()> {
    let xml = document(&package.main_xml)?;
    let body = single_child(xml.root_element(), W, "body")?;
    let mut paragraphs = children(body, W, "p");
    let mut next_paragraph = 0;
    for (&index, expected_runs) in expected {
        let paragraph = paragraphs
            .nth(index - next_paragraph)
            .ok_or_else(invalid_zip)?;
        next_paragraph = index + 1;
        let mut runs = children(paragraph, W, "r");
        let mut next_run = 0;
        for (index, expected_text) in expected_runs {
            let run = runs.nth(index - next_run).ok_or_else(invalid_zip)?;
            next_run = index + 1;
            let text = ordinary_text(run).ok_or_else(invalid_zip)?;
            require(
                text.text().unwrap_or_default() == expected_text
                    && (!edge_space(expected_text)
                        || text.attribute((XML, "space")) == Some("preserve")),
            )?;
        }
    }
    Ok(())
}
