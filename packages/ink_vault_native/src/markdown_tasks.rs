use super::{ApiResult, invalid, string};
use pulldown_cmark::{Event, Options, Parser, Tag};
use serde_json::{Map, Value, json};
use std::ops::Range;

const MAX_MARKDOWN_BYTES: usize = 1024 * 1024;
const MAX_TASKS: usize = 5000;

pub(super) fn scan(request: &Map<String, Value>) -> ApiResult<Value> {
    let markdown = string(request.get("markdown"))?;
    if request.len() != 2 || markdown.len() > MAX_MARKDOWN_BYTES {
        return Err(invalid());
    }

    let mut markers = Vec::new();
    let mut custom = None;
    for (event, range) in Parser::new_ext(markdown, Options::ENABLE_TASKLISTS).into_offset_iter() {
        let marker = match event {
            Event::Start(Tag::Item) => {
                custom = custom_marker(markdown, range);
                None
            }
            Event::Start(Tag::Paragraph) => None,
            Event::TaskListMarker(_) => {
                custom = None;
                let start = range.start + markdown[range].find('[').ok_or_else(invalid)? + 1;
                Some((start, markdown[start..].chars().next().ok_or_else(invalid)?))
            }
            // The parser has identified the candidate as inline list text, so an
            // indented code block, HTML block or link cannot supply this marker.
            Event::Text(_) => custom
                .take()
                .filter(|(offset, _)| *offset == range.start + 1),
            _ => {
                custom = None;
                None
            }
        };
        if let Some(marker) = marker {
            if markers.len() == MAX_TASKS {
                return Err(invalid());
            }
            markers.push(marker);
        }
    }

    markers.sort_unstable_by_key(|(offset, _)| *offset);
    markers.dedup_by_key(|(offset, _)| *offset);
    let (mut offset, mut utf16, mut line) = (0, 0, 1);
    let mut after_carriage_return = false;
    let tasks = markers
        .into_iter()
        .map(|(next, status)| {
            for character in markdown[offset..next].chars() {
                utf16 += character.len_utf16();
                if character == '\r' || (character == '\n' && !after_carriage_return) {
                    line += 1;
                }
                after_carriage_return = character == '\r';
            }
            offset = next;
            json!({"line": line, "statusOffset": utf16, "status": status})
        })
        .collect::<Vec<_>>();
    Ok(json!({"tasks": tasks}))
}

fn custom_marker(markdown: &str, item: Range<usize>) -> Option<(usize, char)> {
    let list = markdown[item.clone()].trim_start_matches([' ', '\t']);
    let separator = list.find([' ', '\t', '\r', '\n'])?;
    let content = list[separator..].trim_start_matches([' ', '\t']);
    let status_text = content.strip_prefix('[')?;
    let status = status_text.chars().next()?;
    if matches!(status, 'x' | 'X' | '[' | ']' | '\\')
        || status.is_whitespace()
        || status.is_control()
    {
        return None;
    }
    let rest = status_text[status.len_utf8()..].strip_prefix(']')?;
    if !rest.is_empty() && !rest.starts_with([' ', '\t', '\r', '\n']) {
        return None;
    }
    Some((item.end - status_text.len(), status))
}
