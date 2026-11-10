use crate::{ApiResult, error, invalid, string};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use unicode_segmentation::UnicodeSegmentation;

const PROTOCOL: &str = "piv-text-style-map-1";
const MAX_OLD_UTF16: usize = 200_000;
const MAX_NEW_UTF16: usize = 8_192;
const MAX_PARAGRAPHS: usize = 512;
const MAX_RESULT_BYTES: usize = 1_048_576;
const MAX_EXACT_CELLS: usize = 1_000_000;
const MAX_MYERS_DISTANCE: usize = 512;
const MAX_WORK: usize = 8_000_000;

fn limit() -> crate::ApiError {
    error(
        "text_style_limit",
        "Text style planning exceeds supported limits",
    )
}

struct Budget {
    remaining: usize,
}

impl Budget {
    fn spend(&mut self, work: usize) -> ApiResult<()> {
        self.remaining = self.remaining.checked_sub(work).ok_or_else(limit)?;
        Ok(())
    }
}

struct Graphemes<'a> {
    text: &'a str,
    parts: Vec<&'a str>,
    offsets: Vec<usize>,
}

impl<'a> Graphemes<'a> {
    fn new(text: &'a str) -> Self {
        let parts: Vec<_> = text.graphemes(true).collect();
        let mut offsets = Vec::with_capacity(parts.len() + 1);
        offsets.push(0);
        for part in &parts {
            offsets.push(offsets.last().copied().unwrap_or(0) + part.encode_utf16().count());
        }
        Self {
            text,
            parts,
            offsets,
        }
    }
}

#[derive(Clone, Copy)]
struct Piece {
    old: usize,
    new: usize,
    length: usize,
}

fn push_piece(pieces: &mut Vec<Piece>, old: usize, new: usize, length: usize) {
    if length == 0 {
        return;
    }
    if let Some(previous) = pieces.last_mut()
        && previous.old + previous.length == old
        && previous.new + previous.length == new
    {
        previous.length += length;
        return;
    }
    pieces.push(Piece { old, new, length });
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Retain,
    Inherit,
}

struct Segment {
    kind: Kind,
    new_start: usize,
    new_end: usize,
    old_start: usize,
    old_end: usize,
}

impl Segment {
    fn json(self) -> Value {
        json!({
            "kind": match self.kind { Kind::Retain => "retain", Kind::Inherit => "inherit" },
            "newStart": self.new_start, "newEnd": self.new_end,
            "oldStart": self.old_start, "oldEnd": self.old_end,
        })
    }
}

fn push_segment(segments: &mut Vec<Segment>, segment: Segment) {
    if let Some(previous) = segments.last_mut()
        && previous.kind == segment.kind
        && previous.new_end == segment.new_start
        && match segment.kind {
            Kind::Retain => previous.old_end == segment.old_start,
            Kind::Inherit => {
                previous.old_start == segment.old_start && previous.old_end == segment.old_end
            }
        }
    {
        previous.new_end = segment.new_end;
        if segment.kind == Kind::Retain {
            previous.old_end = segment.old_end;
        }
        return;
    }
    segments.push(segment);
}

pub(super) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 4 || string(request.get("protocol"))? != PROTOCOL {
        return Err(invalid());
    }
    let old = string(request.get("oldText"))?;
    let new = string(request.get("newText"))?;
    let old_length = old.encode_utf16().count();
    let new_length = new.encode_utf16().count();
    if old_length > MAX_OLD_UTF16
        || new_length > MAX_NEW_UTF16
        || old.split('\n').count() > MAX_PARAGRAPHS
        || new.split('\n').count() > MAX_PARAGRAPHS
    {
        return Err(limit());
    }
    let old_lines: Vec<_> = old.split('\n').map(Graphemes::new).collect();
    let new_lines: Vec<_> = new.split('\n').map(Graphemes::new).collect();
    let mut budget = Budget {
        remaining: MAX_WORK,
    };
    budget.spend(old_length + new_length)?;
    let mapping = paragraph_map(&old_lines, &new_lines, &mut budget)?;
    let mut paragraphs = Vec::with_capacity(new_lines.len());
    for (index, line) in new_lines.iter().enumerate() {
        let source = mapping[index];
        let segments = paragraph_segments(&old_lines[source], line, &mut budget)?;
        paragraphs.push(json!({"sourceParagraph":source,"segments":segments}));
    }
    let result = json!({
        "protocol":PROTOCOL,
        "oldUtf16Length":old_length,"newUtf16Length":new_length,
        "oldSha256":digest(old),"newSha256":digest(new),
        "paragraphs":paragraphs,
    });
    if result.to_string().len() > MAX_RESULT_BYTES {
        return Err(limit());
    }
    Ok(result)
}

fn digest(text: &str) -> String {
    Sha256::digest(text.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn paragraph_map(
    old: &[Graphemes<'_>],
    new: &[Graphemes<'_>],
    budget: &mut Budget,
) -> ApiResult<Vec<usize>> {
    if old.len() == new.len() {
        return Ok((0..new.len()).collect());
    }
    budget.spend(old.len() * new.len())?;
    let width = new.len() + 1;
    let mut scores = vec![0_u16; (old.len() + 1) * width];
    for row in (0..old.len()).rev() {
        for column in (0..new.len()).rev() {
            scores[row * width + column] = if old[row].text == new[column].text {
                scores[(row + 1) * width + column + 1] + 1
            } else {
                scores[(row + 1) * width + column].max(scores[row * width + column + 1])
            };
        }
    }
    let mut mapping = vec![None; new.len()];
    let (mut row, mut column) = (0, 0);
    while row < old.len() && column < new.len() {
        if old[row].text == new[column].text {
            mapping[column] = Some(row);
            row += 1;
            column += 1;
        } else if scores[(row + 1) * width + column] >= scores[row * width + column + 1] {
            row += 1;
        } else {
            column += 1;
        }
    }
    let first_source = mapping.iter().flatten().next().copied().unwrap_or(0);
    let mut previous = first_source;
    Ok(mapping
        .into_iter()
        .map(|source| {
            previous = source.unwrap_or(previous);
            previous
        })
        .collect())
}

fn matching_pieces(old: &[&str], new: &[&str], budget: &mut Budget) -> ApiResult<Vec<Piece>> {
    let mut prefix = 0;
    while prefix < old.len() && prefix < new.len() {
        budget.spend(1)?;
        if old[prefix] != new[prefix] {
            break;
        }
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < old.len() - prefix && suffix < new.len() - prefix {
        budget.spend(1)?;
        if old[old.len() - suffix - 1] != new[new.len() - suffix - 1] {
            break;
        }
        suffix += 1;
    }
    let mut pieces = Vec::new();
    push_piece(&mut pieces, 0, 0, prefix);
    let old_middle = &old[prefix..old.len() - suffix];
    let new_middle = &new[prefix..new.len() - suffix];
    if !old_middle.is_empty() && !new_middle.is_empty() {
        budget.spend(old_middle.len() + new_middle.len())?;
        let present: HashSet<_> = new_middle.iter().copied().collect();
        let shared = old_middle.iter().any(|part| present.contains(part));
        if shared {
            let matches = if (old_middle.len() + 1) * (new_middle.len() + 1) <= MAX_EXACT_CELLS {
                exact_matches(old_middle, new_middle, budget)?
            } else {
                myers_matches(old_middle, new_middle, budget)?
            };
            for (old_index, new_index) in matches {
                push_piece(&mut pieces, prefix + old_index, prefix + new_index, 1);
            }
        }
    }
    push_piece(&mut pieces, old.len() - suffix, new.len() - suffix, suffix);
    Ok(pieces)
}

fn exact_matches(
    old: &[&str],
    new: &[&str],
    budget: &mut Budget,
) -> ApiResult<Vec<(usize, usize)>> {
    budget.spend(old.len() * new.len())?;
    let width = new.len() + 1;
    let mut scores = vec![0_u16; (old.len() + 1) * width];
    for row in (0..old.len()).rev() {
        for column in (0..new.len()).rev() {
            scores[row * width + column] = if old[row] == new[column] {
                scores[(row + 1) * width + column + 1] + 1
            } else {
                scores[(row + 1) * width + column].max(scores[row * width + column + 1])
            };
        }
    }
    let mut matches = Vec::new();
    let (mut row, mut column) = (0, 0);
    while row < old.len() && column < new.len() {
        budget.spend(1)?;
        if old[row] == new[column] {
            matches.push((row, column));
            row += 1;
            column += 1;
        } else if scores[(row + 1) * width + column] >= scores[row * width + column + 1] {
            row += 1;
        } else {
            column += 1;
        }
    }
    Ok(matches)
}

fn myers_matches(
    old: &[&str],
    new: &[&str],
    budget: &mut Budget,
) -> ApiResult<Vec<(usize, usize)>> {
    if old.len().abs_diff(new.len()) > MAX_MYERS_DISTANCE {
        return Err(limit());
    }
    let center = MAX_MYERS_DISTANCE as isize + 1;
    let at = |diagonal: isize| (diagonal + center) as usize;
    let mut frontier = vec![-1_isize; MAX_MYERS_DISTANCE * 2 + 3];
    frontier[at(1)] = 0;
    let mut trace = Vec::new();
    for distance in 0..=MAX_MYERS_DISTANCE {
        budget.spend(frontier.len())?;
        trace.push(frontier.clone());
        let distance = distance as isize;
        for diagonal in (-distance..=distance).step_by(2) {
            budget.spend(1)?;
            let mut x = if diagonal == -distance
                || diagonal != distance && frontier[at(diagonal - 1)] < frontier[at(diagonal + 1)]
            {
                frontier[at(diagonal + 1)]
            } else {
                frontier[at(diagonal - 1)] + 1
            };
            let mut y = x - diagonal;
            while x < old.len() as isize && y < new.len() as isize {
                budget.spend(1)?;
                if old[x as usize] != new[y as usize] {
                    break;
                }
                x += 1;
                y += 1;
            }
            frontier[at(diagonal)] = x;
            if x >= old.len() as isize && y >= new.len() as isize {
                let mut matches = Vec::new();
                for step in (0..trace.len()).rev() {
                    let before = &trace[step];
                    let current = x - y;
                    let step = step as isize;
                    let previous = if current == -step
                        || current != step && before[at(current - 1)] < before[at(current + 1)]
                    {
                        current + 1
                    } else {
                        current - 1
                    };
                    let previous_x = before[at(previous)];
                    let previous_y = previous_x - previous;
                    while x > previous_x && y > previous_y {
                        budget.spend(1)?;
                        matches.push(((x - 1) as usize, (y - 1) as usize));
                        x -= 1;
                        y -= 1;
                    }
                    x = previous_x;
                    y = previous_y;
                }
                matches.reverse();
                return Ok(matches);
            }
        }
    }
    Err(limit())
}

fn inherited_segment(
    old: &Graphemes<'_>,
    new: &Graphemes<'_>,
    old_cursor: usize,
    old_end: usize,
    new_cursor: usize,
    new_end: usize,
) -> Segment {
    let anchor = if old_end > old_cursor || old_cursor == 0 {
        old_cursor
    } else {
        old_cursor - 1
    };
    let (old_start, old_end) = if old.parts.is_empty() {
        (0, 0)
    } else {
        (old.offsets[anchor], old.offsets[anchor + 1])
    };
    Segment {
        kind: Kind::Inherit,
        new_start: new.offsets[new_cursor],
        new_end: new.offsets[new_end],
        old_start,
        old_end,
    }
}

fn paragraph_segments(
    old: &Graphemes<'_>,
    new: &Graphemes<'_>,
    budget: &mut Budget,
) -> ApiResult<Vec<Value>> {
    if new.parts.is_empty() {
        return Ok(vec![
            inherited_segment(old, new, 0, old.parts.len(), 0, 0).json(),
        ]);
    }
    let pieces = matching_pieces(&old.parts, &new.parts, budget)?;
    let mut segments = Vec::new();
    let (mut old_cursor, mut new_cursor) = (0, 0);
    for piece in pieces {
        if new_cursor < piece.new {
            push_segment(
                &mut segments,
                inherited_segment(old, new, old_cursor, piece.old, new_cursor, piece.new),
            );
        }
        push_segment(
            &mut segments,
            Segment {
                kind: Kind::Retain,
                new_start: new.offsets[piece.new],
                new_end: new.offsets[piece.new + piece.length],
                old_start: old.offsets[piece.old],
                old_end: old.offsets[piece.old + piece.length],
            },
        );
        old_cursor = piece.old + piece.length;
        new_cursor = piece.new + piece.length;
    }
    if new_cursor < new.parts.len() {
        push_segment(
            &mut segments,
            inherited_segment(
                old,
                new,
                old_cursor,
                old.parts.len(),
                new_cursor,
                new.parts.len(),
            ),
        );
    }
    Ok(segments.into_iter().map(Segment::json).collect())
}
