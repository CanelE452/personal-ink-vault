use regex::Regex;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{CStr, CString, c_char};
use std::ops::Range;
use std::panic::catch_unwind;
use std::sync::OnceLock;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

mod docx_photo;
mod knowledge;
mod markdown_tasks;
mod pptx_clone;
mod pptx_zip;
mod search_expression;
mod text_style_map;
mod workspace_actions;
mod workspace_query;
mod workspace_query_case_table;
mod workspace_query_date;
mod workspace_query_value;
mod workspace_task_links;

type ApiResult<T> = Result<T, ApiError>;

struct ApiError {
    code: &'static str,
    message: &'static str,
}

impl ApiError {
    fn json(self) -> Value {
        json!({"error":{"code":self.code,"message":self.message}})
    }
}

fn error(code: &'static str, message: &'static str) -> ApiError {
    ApiError { code, message }
}

fn invalid() -> ApiError {
    error(
        "invalid_request",
        "Request fields have an invalid type or value",
    )
}

/// The input must point to a readable NUL-terminated C string, or be null.
/// The returned string is owned by Rust and must be passed once to `ink_vault_free`.
///
/// # Safety
/// Non-null input must remain valid for the duration of this synchronous call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ink_vault_request(input: *const c_char) -> *mut c_char {
    let response = catch_unwind(|| {
        if input.is_null() {
            return error("null_input", "Request pointer is null").json();
        }
        // SAFETY: The caller guarantees a readable NUL-terminated input string.
        match unsafe { CStr::from_ptr(input) }.to_str() {
            Ok(text) => request_json(text),
            Err(_) => error("invalid_utf8", "Request is not UTF-8").json(),
        }
    })
    .unwrap_or_else(|_| error("internal_error", "Native operation failed").json());
    // JSON escapes NUL characters, so the serialized result has no interior NUL.
    CString::new(response.to_string())
        .unwrap_or_else(|_| {
            c"{\"error\":{\"code\":\"internal_error\",\"message\":\"Encoding failed\"}}".to_owned()
        })
        .into_raw()
}

/// Releases a response returned by `ink_vault_request`. Null is accepted.
///
/// # Safety
/// A non-null pointer must be an unmodified, unfreed response from this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ink_vault_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: Ownership of this allocation is transferred back by the caller.
        drop(unsafe { CString::from_raw(value) });
    }
}

/// A static version string; the caller must not free or modify this pointer.
#[unsafe(no_mangle)]
pub extern "C" fn ink_vault_version() -> *const c_char {
    c"0.1.0".as_ptr()
}

pub fn request_json(input: &str) -> Value {
    let request: Value = match serde_json::from_str(input) {
        Ok(request) => request,
        Err(_) => return error("invalid_json", "Request is not valid JSON").json(),
    };
    dispatch(&request).unwrap_or_else(ApiError::json)
}

fn dispatch(request: &Value) -> ApiResult<Value> {
    let request = request.as_object().ok_or_else(invalid)?;
    match string(request.get("op"))? {
        "search" => search(request),
        "search_expression" => search_expression::search(request),
        "validate_search_expression" => search_expression::validate(request),
        "analyze_documents" => knowledge::analyze_documents(request),
        "find_unlinked_mentions" => knowledge::find_unlinked_mentions(request),
        "dataview_task_markers" => markdown_tasks::scan(request),
        "rewrite_note_links" => knowledge::rewrite_note_links(request),
        "portable_obsidian_links" => knowledge::portable_obsidian_links(request),
        "resolve_markdown_anchor" => knowledge::resolve_markdown_anchor(request),
        "normalize_workspace_segments" => normalize_workspace_segments(request),
        "folder_move" => folder_move(request),
        "validate_revision" => validate_revision(request.get("revision").ok_or_else(invalid)?),
        "sha256" => hash_bytes(request),
        "docx_photo_inspect" => docx_photo::inspect(request),
        "docx_photo_insert" => docx_photo::insert::insert(request),
        "docx_photo_replace" => docx_photo::replace(request),
        "docx_photo_delete" => docx_photo::delete(request),
        "docx_photo_rotate" => docx_photo::rotate(request),
        "docx_table_inspect" => docx_photo::table::inspect(request),
        "docx_table_insert" => docx_photo::table::insert(request),
        "docx_table_structure_inspect" => docx_photo::table_structure::inspect(request),
        "docx_table_structure_edit" => docx_photo::table_structure::apply(request),
        "docx_text_inspect" => docx_photo::body_text::inspect(request),
        "docx_text_replace" => docx_photo::body_text::replace(request),
        "docx_find_replace_preview" => docx_photo::body_text::find_replace::preview(request),
        "docx_find_replace_apply" => docx_photo::body_text::find_replace::apply(request),
        "docx_paragraph_insert_inspect" => docx_photo::body_text::paragraph::inspect(request),
        "docx_paragraph_insert" => docx_photo::body_text::paragraph::insert(request),
        "pptx_clone_inspect" => pptx_clone::inspect(request),
        "pptx_clone_apply" => pptx_clone::apply(request),
        "pptx_reorder_inspect" => pptx_clone::reorder_inspect(request),
        "pptx_reorder_apply" => pptx_clone::reorder_apply(request),
        "pptx_slide_identity_match" => pptx_clone::match_slide_identity(request),
        "pptx_slide_background_inspect" => pptx_clone::slide_background::inspect(request),
        "pptx_slide_background_apply" => pptx_clone::slide_background::apply(request),
        "pptx_slide_display" => pptx_clone::slide_display::apply(request),
        "pptx_delete_inspect" => pptx_clone::deletion::inspect(request),
        "pptx_delete_apply" => pptx_clone::deletion::apply(request),
        "pptx_insert_inspect" => pptx_clone::insertion::inspect(request),
        "pptx_insert_apply" => pptx_clone::insertion::apply(request),
        "pptx_layout_inspect" => pptx_clone::insertion::inspect_layout_change(request),
        "pptx_layout_apply" => pptx_clone::insertion::apply_layout_change(request),
        "pptx_text_box_inspect" => pptx_clone::text_box::inspect(request),
        "pptx_text_box_add" => pptx_clone::text_box::add(request),
        "pptx_preset_shape_inspect" => pptx_clone::text_box::inspect_presets(request),
        "pptx_preset_shape_add" => pptx_clone::text_box::add_preset(request),
        "pptx_table_add_inspect" => pptx_clone::table_add::inspect(request),
        "pptx_table_add" => pptx_clone::table_add::add(request),
        "pptx_table_cell_text_inspect" => pptx_clone::table_cell_text::inspect(request),
        "pptx_table_cell_text_replace" => pptx_clone::table_cell_text::replace(request),
        "pptx_table_structure_inspect" => pptx_clone::table_structure::inspect(request),
        "pptx_table_structure_edit" => pptx_clone::table_structure::edit(request),
        "pptx_table_merge_inspect" => pptx_clone::table_structure::merge::inspect(request),
        "pptx_table_merge_edit" => pptx_clone::table_structure::merge::edit(request),
        "pptx_photo_add_inspect" => pptx_clone::photo_add::inspect(request),
        "pptx_photo_add" => pptx_clone::photo_add::add(request),
        "pptx_shape_delete_inspect" => pptx_clone::shape_delete::inspect(request),
        "pptx_shape_delete" => pptx_clone::shape_delete::apply(request),
        "pptx_shape_geometry_inspect" => pptx_clone::shape_geometry::inspect(request),
        "pptx_shape_geometry_replace" => pptx_clone::shape_geometry::replace(request),
        "pptx_shape_order_inspect" => pptx_clone::shape_order::inspect(request),
        "pptx_shape_order_apply" => pptx_clone::shape_order::apply(request),
        "pptx_shape_text_inspect" => pptx_clone::shape_text::inspect(request),
        "pptx_shape_text_replace" => pptx_clone::shape_text::replace(request),
        "pptx_shape_text_format" => pptx_clone::shape_text::format(request),
        "pptx_shape_paragraph_alignment" => pptx_clone::shape_text::paragraph_alignment(request),
        "pptx_find_replace_preview" => pptx_clone::find_replace::preview(request),
        "pptx_find_replace_apply" => pptx_clone::find_replace::apply(request),
        "pptx_speaker_notes_inspect" => pptx_clone::speaker_notes::inspect(request),
        "pptx_speaker_notes_edit" => pptx_clone::speaker_notes::apply(request),
        "text_style_map" => text_style_map::apply(request),
        "workspace_actions" => workspace_actions::apply(request),
        "workspace_query" => workspace_query::apply(request),
        "workspace_task_links" => workspace_task_links::apply(request),
        _ => Err(error("unknown_operation", "Operation is not supported")),
    }
}

fn string(value: Option<&Value>) -> ApiResult<&str> {
    value.and_then(Value::as_str).ok_or_else(invalid)
}

fn normalize(value: &str) -> String {
    value
        .nfc()
        .flat_map(char::to_lowercase)
        .collect::<String>()
        .nfc()
        .collect()
}

fn normalize_workspace_segments(request: &Map<String, Value>) -> ApiResult<Value> {
    let values = request
        .get("segments")
        .and_then(Value::as_array)
        .filter(|values| values.len() <= 10_000)
        .ok_or_else(invalid)?;
    let keys = values
        .iter()
        .map(|value| {
            let segment = string(Some(value))?;
            if segment.is_empty() || segment.len() > 1024 {
                return Err(invalid());
            }
            Ok(normalize(segment))
        })
        .collect::<ApiResult<Vec<_>>>()?;
    Ok(json!({"segments": keys}))
}

struct Document<'a> {
    id: &'a str,
    title: &'a str,
    markdown: &'a str,
}

fn documents(request: &Map<String, Value>) -> ApiResult<Vec<Document<'_>>> {
    let values = request
        .get("documents")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    let mut ids = BTreeSet::new();
    values
        .iter()
        .map(|value| {
            let id = string(value.get("id"))?;
            if id.is_empty() || !ids.insert(id) {
                return Err(invalid());
            }
            Ok(Document {
                id,
                title: string(value.get("title"))?,
                markdown: string(value.get("markdown"))?,
            })
        })
        .collect()
}

fn search(request: &Map<String, Value>) -> ApiResult<Value> {
    let documents = documents(request)?;
    let query = normalize(string(request.get("query"))?);
    let terms: BTreeSet<&str> = query.split_whitespace().collect();
    let include_body_match = request.get("includeBodyMatch").and_then(Value::as_bool) == Some(true);
    let mut matches = Vec::new();
    if terms.is_empty() {
        return Ok(json!({"matches":matches}));
    }
    for document in documents {
        let title = normalize(document.title);
        let body = normalize(document.markdown);
        if !terms
            .iter()
            .all(|term| title.contains(term) || body.contains(term))
        {
            continue;
        }
        let score: u64 = terms
            .iter()
            .map(|term| if title.contains(term) { 10 } else { 1 })
            .sum();
        let body_hit = terms
            .iter()
            .filter_map(|term| body.find(term).map(|start| start..start + term.len()))
            .min_by_key(|range| (range.start, range.end));
        let snippet = search_snippet(
            document.markdown,
            &body,
            body_hit.as_ref().map_or(0, |range| range.start),
        );
        let mut result =
            json!({"id":document.id,"title":document.title,"snippet":snippet,"score":score});
        if include_body_match
            && let Some(hit) = body_hit
            && let Some(position) = body_match_json(document.markdown, &body, hit)
        {
            result["bodyMatch"] = position;
        }
        matches.push(result);
    }
    matches.sort_by(|a, b| {
        b["score"]
            .as_u64()
            .cmp(&a["score"].as_u64())
            .then_with(|| {
                normalize(a["title"].as_str().unwrap_or(""))
                    .cmp(&normalize(b["title"].as_str().unwrap_or("")))
            })
            .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
    });
    Ok(json!({"matches":matches}))
}

fn search_snippet(original: &str, normalized: &str, hit: usize) -> String {
    let char_hit = normalized[..hit].chars().count();
    // Use the source text when its scalar count agrees with canonical normalization.
    let text = if original.chars().count() == normalized.chars().count() {
        original
    } else {
        normalized
    };
    let start = char_hit.saturating_sub(40);
    let mut snippet: String = text.chars().skip(start).take(180).collect();
    if start > 0 {
        snippet.insert(0, '…');
    }
    if text.chars().count() > start + 180 {
        snippet.push('…');
    }
    snippet
}

fn body_match_json(original: &str, normalized: &str, hit: Range<usize>) -> Option<Value> {
    let matched = normalized
        .get(hit.clone())
        .filter(|text| !text.is_empty())?;
    let source_range = if original.is_ascii() || original == normalized {
        hit
    } else {
        let mut offset = 0;
        let mut source_start = None;
        let mut range = None;
        // Prove each original grapheme's contribution to the normalized prefix.
        // A match that cuts a changed grapheme may have no corresponding source span.
        for (byte, grapheme) in original.grapheme_indices(true) {
            let ascii = grapheme.is_ascii();
            let piece = if ascii {
                let piece = normalized.get(offset..offset + grapheme.len())?;
                if !piece.eq_ignore_ascii_case(grapheme) {
                    return None;
                }
                piece
            } else {
                let normalized_grapheme = normalize(grapheme);
                let piece = normalized.get(offset..offset + normalized_grapheme.len())?;
                if piece != normalized_grapheme {
                    return None;
                }
                piece
            };
            let next = offset + piece.len();
            let same_offsets = ascii || piece == grapheme;
            if (offset..next).contains(&hit.start) {
                if hit.start != offset && !same_offsets {
                    return None;
                }
                source_start = Some(byte + (hit.start - offset));
            }
            if hit.end <= next {
                let end = if hit.end == next {
                    byte + grapheme.len()
                } else if same_offsets {
                    byte + (hit.end - offset)
                } else {
                    return None;
                };
                range = Some(source_start?..end);
                break;
            }
            offset = next;
        }
        range?
    };
    let text = original.get(source_range.clone())?;
    if normalize(text) != matched {
        return None;
    }
    let start = original[..source_range.start].encode_utf16().count();
    Some(json!({"start": start, "end": start + text.encode_utf16().count(), "text": text}))
}

fn folder_move(request: &Map<String, Value>) -> ApiResult<Value> {
    let values = request
        .get("folders")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    let mut parents = BTreeMap::new();
    for value in values {
        let id = string(value.get("id"))?;
        let parent = nullable_string(value.get("parentId"))?;
        if id.is_empty() || parents.insert(id, parent).is_some() {
            return Err(invalid());
        }
    }
    let id = string(request.get("id"))?;
    let parent = nullable_string(request.get("parentId"))?;
    if !parents.contains_key(id) || parent.is_some_and(|parent| !parents.contains_key(parent)) {
        return Err(error(
            "folder_missing",
            "Folder or destination does not exist",
        ));
    }
    validate_folders(&parents)?;
    parents.insert(id, parent);
    validate_folders(&parents)?;
    Ok(json!({"valid":true,"id":id,"parentId":parent}))
}

fn nullable_string(value: Option<&Value>) -> ApiResult<Option<&str>> {
    match value {
        Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.is_empty() => Ok(Some(value)),
        _ => Err(invalid()),
    }
}

fn validate_folders(parents: &BTreeMap<&str, Option<&str>>) -> ApiResult<()> {
    for id in parents.keys() {
        let mut seen = BTreeSet::new();
        let mut current = Some(*id);
        while let Some(id) = current {
            if !seen.insert(id) {
                return Err(error(
                    "folder_cycle",
                    "Folder movement would create a cycle",
                ));
            }
            current = *parents
                .get(id)
                .ok_or_else(|| error("folder_missing", "Folder parent does not exist"))?;
        }
    }
    Ok(())
}

fn valid_id(value: &Value) -> bool {
    value.as_str().is_some_and(valid_id_str)
}

fn valid_id_str(value: &str) -> bool {
    static UUID: OnceLock<Regex> = OnceLock::new();
    let pattern = UUID.get_or_init(|| {
        Regex::new(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
            .expect("constant UUID regex")
    });
    pattern.is_match(value)
}

fn valid_ids(value: &Value, exclude: Option<&Value>) -> bool {
    let Some(ids) = value.as_array() else {
        return false;
    };
    let mut seen = BTreeSet::new();
    ids.iter()
        .all(|id| valid_id(id) && exclude != Some(id) && seen.insert(id.as_str().unwrap_or("")))
}

fn valid_logical_path(value: &str) -> bool {
    !value.is_empty()
        && !value
            .chars()
            .any(|ch| ch == '\\' || ch == ':' || ch <= '\u{1f}')
        && value
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

fn validate_revision(revision: &Value) -> ApiResult<Value> {
    let invalid_revision = || {
        error(
            "invalid_revision",
            "Revision does not match the supported vault schema",
        )
    };
    let value = revision.as_object().ok_or_else(invalid_revision)?;
    let format = value
        .get("formatVersion")
        .and_then(Value::as_u64)
        .ok_or_else(invalid_revision)?;
    let kind = value
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(invalid_revision)?;
    if !matches!(format, 1 | 2)
        || !matches!(
            kind,
            "metadata" | "ink" | "markdown" | "folder" | "attachment"
        )
        || (format == 1 && matches!(kind, "folder" | "attachment"))
    {
        return Err(invalid_revision());
    }
    for key in ["vaultId", "entityId", "revisionId", "deviceId"] {
        if !value.get(key).is_some_and(valid_id) {
            return Err(invalid_revision());
        }
    }
    if !value.get("deleted").is_some_and(Value::is_boolean)
        || !value
            .get("parentRevisionIds")
            .is_some_and(|parents| valid_ids(parents, value.get("revisionId")))
    {
        return Err(invalid_revision());
    }
    if let Some(owner) = value.get("ownerNoteId").filter(|owner| !owner.is_null())
        && (!valid_id(owner) || matches!(kind, "metadata" | "folder"))
    {
        return Err(invalid_revision());
    }
    let blobs = value
        .get("blobs")
        .and_then(Value::as_object)
        .ok_or_else(invalid_revision)?;
    for (name, blob) in blobs {
        let hash = blob
            .get("hash")
            .and_then(Value::as_str)
            .ok_or_else(invalid_revision)?;
        if !valid_logical_path(name)
            || hash.len() != 64
            || !hash
                .bytes()
                .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
            || !blob
                .get("length")
                .and_then(Value::as_i64)
                .is_some_and(|length| length >= 0)
        {
            return Err(invalid_revision());
        }
    }
    let bases = value
        .get("baseRefs")
        .and_then(Value::as_object)
        .ok_or_else(invalid_revision)?;
    for (id, revisions) in bases {
        if !valid_id(&json!(id)) || !valid_ids(revisions, None) {
            return Err(invalid_revision());
        }
    }
    Ok(json!({"valid":true,"formatVersion":format}))
}

fn hash_bytes(request: &Map<String, Value>) -> ApiResult<Value> {
    let values = request
        .get("bytes")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    let bytes: Vec<u8> = values
        .iter()
        .map(|value| {
            value
                .as_u64()
                .filter(|value| *value <= 255)
                .map(|value| value as u8)
                .ok_or_else(invalid)
        })
        .collect::<ApiResult<_>>()?;
    let hash: String = Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    Ok(json!({"sha256":hash}))
}
