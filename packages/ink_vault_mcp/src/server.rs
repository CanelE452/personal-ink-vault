use crate::{BridgeClient, BridgeError};
use base64::Engine;
use rmcp::{
    ErrorData, RoleServer, ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::*,
    schemars,
    service::RequestContext,
    tool, tool_handler, tool_router,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::num::NonZeroU32;

#[path = "discussion_wire.rs"]
mod discussion_wire;
use discussion_wire::{ListPageDiscussions, MutatePageDiscussion};

#[derive(Clone)]
pub struct InkVaultServer {
    bridge: BridgeClient,
    tool_router: ToolRouter<Self>,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListDocuments {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub include_deleted: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub offset: Option<u64>,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SearchDocuments {
    /// Vault search expression using file:, path:, tag:, content:, quotes, OR, parentheses, or - exclusion. Up to 2048 UTF-16 code units.
    #[schemars(length(min = 1, max = 2048))]
    pub query: String,
    /// Number of matches to return, 1..100; default 50.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 1, max = 100))]
    pub limit: Option<u32>,
    /// Number of matches to skip, 0..1000000; default 0.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 0, max = 1000000))]
    pub offset: Option<u32>,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadDocument {
    pub note_id: String,
    #[serde(
        default,
        deserialize_with = "deserialize_read_revision",
        skip_serializing_if = "omit_read_revision"
    )]
    #[schemars(with = "Option<String>")]
    pub revision_id: Option<Option<String>>,
    /// Current PPTX table-structure authority. An empty object lists slides.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "PptxTableStructureQuery")]
    pub pptx_table_structure: Option<PptxTableStructureQuery>,
    /// Current DOCX table-structure authority. An empty object reads the first page.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "DocxTableStructureQuery")]
    pub docx_table_structure: Option<DocxTableStructureQuery>,
    /// True reads the current PPTX slide order, section identities, and source SHA.
    /// Omit revisionId and table queries for this read. False is an ordinary read.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "bool")]
    pub pptx_slide_order: Option<bool>,
}

// Ordinary reads accept a null revision ID, while DOCX discovery requires the field to be absent.
fn deserialize_read_revision<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<Option<String>>, D::Error> {
    Option::deserialize(deserializer).map(Some)
}

fn omit_read_revision(revision: &Option<Option<String>>) -> bool {
    !matches!(revision, Some(Some(_)))
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DocxTableStructureQuery {
    /// Zero-based table offset, 0..512. Default 0.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u16", range(min = 0, max = 512))]
    pub table_offset: Option<u16>,
    /// Number of table records, 1..32. Default 16.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u8", range(min = 1, max = 32))]
    pub table_limit: Option<u8>,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PptxTableStructureQuery {
    /// Zero-based slide index. When omitted, the result lists slides.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u8", range(min = 0, max = 255))]
    pub slide_index: Option<u8>,
    /// Zero-based table offset on the selected slide, 0..400; default 0.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u16", range(min = 0, max = 400))]
    pub table_offset: Option<u16>,
    /// Table records to return on the selected slide, 1..32; default 16.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u8", range(min = 1, max = 32))]
    pub table_limit: Option<u8>,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct QueryDataview {
    /// LIST, TABLE, or TASK query text, up to 4096 UTF-16 code units.
    #[schemars(length(min = 1, max = 4096))]
    pub query: String,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QueryDatabaseInput {
    pub note_id: String,
    /// Current database body revision returned by read_document.
    pub expected_revision_id: String,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DatabaseQuery {
    pub note_id: String,
    pub expected_revision_id: String,
    /// Persisted databases from the same vault, at most 64 explicit references.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub related_databases: Option<Vec<QueryDatabaseInput>>,
    /// Canonical UTC DateTime ISO string, for example 2026-10-30T12:00:00.000Z.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub captured_at_utc: Option<String>,
    /// Shared calculation depth limit, 1..128; default 32.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_depth: Option<u32>,
    /// Shared calculation work budget, 1..1000000; default 10000.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub budget: Option<u32>,
    /// 1..512 operations in one Rust calculation snapshot and budget.
    pub operations: Vec<DatabaseQueryOperation>,
}

fn deserialize_non_null_option<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

fn deserialize_task_parent<'de, D>(deserializer: D) -> Result<Value, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Value::deserialize(deserializer)?;
    if value.is_null() || value.is_string() {
        Ok(value)
    } else {
        Err(serde::de::Error::custom("parentId must be text or null"))
    }
}

fn task_parent_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({"type": ["string", "null"]})
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum DatabaseQueryOperation {
    Value {
        row_id: String,
        property_id: String,
    },
    Apply {
        view: serde_json::Map<String, Value>,
    },
    Values {
        from: u32,
        property_ids: Vec<String>,
    },
    Aggregate {
        property_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        calculation: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        row_ids: Option<Vec<String>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        from: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        view: Option<serde_json::Map<String, Value>>,
    },
    Calendar {
        property_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        view: Option<serde_json::Map<String, Value>>,
    },
    Chart {
        group_by: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        value_property_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        calculation: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        view: Option<serde_json::Map<String, Value>>,
    },
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadDatabaseTaskLinks {
    pub note_id: String,
    pub expected_revision_id: String,
    pub row_id: String,
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListRevisions {
    pub note_id: String,
    /// Restrict records to saved body revisions. Omit target to page all owned revisions.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "RevisionTarget")]
    pub target: Option<RevisionTarget>,
    /// Zero-based record offset; default 0 in page mode.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u64", range(min = 0))]
    pub offset: Option<u64>,
    /// 1..100 records per page; default 100 in page mode.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u32", range(min = 1, max = 100))]
    pub limit: Option<u32>,
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum RevisionTarget {
    Body,
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadRevision {
    pub note_id: String,
    pub revision_id: String,
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ComparePageRevision {
    pub note_id: String,
    /// Saved past body snapshot to compare as the before side.
    pub revision_id: String,
    /// Exact saved current BODY revision, used as the after side; no unsaved draft.
    pub expected_revision_id: String,
    /// Zero-based change offset; default 0. Inspect pagination and truncation in the result.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u64", range(min = 0))]
    pub offset: Option<u64>,
    /// 1..100 changes per page; default 100.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u32", range(min = 1, max = 100))]
    pub limit: Option<u32>,
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RestorePageRevision {
    pub note_id: String,
    /// Saved past whole body snapshot selected in compare_page_revision.
    pub revision_id: String,
    /// Exact saved current BODY revision used for the comparison.
    pub expected_revision_id: String,
    /// Copy the entire compare result guard map unchanged: body, note metadata and ancestor folder heads.
    pub expected_heads: std::collections::BTreeMap<String, Vec<String>>,
    /// Reuse only for an identical retry; the app reuses its prepared receipt without another revision.
    pub request_id: String,
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateDocument {
    pub title: String,
    /// word/presentation/hwpx create editable originals; omit body and use
    /// read_document then office_edit for their content. Other supported kinds
    /// accept the typed body shown in the app documentation.
    pub kind: DocumentKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<Value>,
    /// Reuse this same ID when retrying the same write after a timeout.
    pub request_id: String,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ReadDailyNote {
    /// Calendar date YYYY-MM-DD, with years 0001 through 9999.
    #[schemars(length(min = 10, max = 10))]
    pub date: String,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnsureDailyNote {
    /// Calendar date YYYY-MM-DD, with years 0001 through 9999.
    #[schemars(length(min = 10, max = 10))]
    pub date: String,
    /// Lowercase hyphenated request UUID. Reuse only for the identical retry.
    #[schemars(length(min = 36, max = 36))]
    pub request_id: String,
}

fn valid_daily_date(date: &str) -> bool {
    let bytes = date.as_bytes();
    if bytes.len() != 10
        || !bytes.iter().enumerate().all(|(index, byte)| match index {
            4 | 7 => *byte == b'-',
            _ => byte.is_ascii_digit(),
        })
    {
        return false;
    }
    let year = bytes[..4]
        .iter()
        .fold(0u16, |value, digit| value * 10 + u16::from(*digit - b'0'));
    let pair = |index: usize| 10 * (bytes[index] - b'0') + (bytes[index + 1] - b'0');
    let last_day = match pair(5) {
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => return false,
    };
    year != 0 && (1..=last_day).contains(&pair(8))
}

fn invalid_daily_date() -> CallToolResult {
    error_result(BridgeError::new(
        "invalid_arguments",
        "날짜는 0001년부터 9999년까지 유효한 YYYY-MM-DD로 입력하세요.",
    ))
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum DocumentKind {
    Word,
    Presentation,
    Hwpx,
    Handwriting,
    Pdf,
    Markdown,
    Infinite,
    Image,
    Office,
    Canvas,
    Page,
    Database,
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum UpdateTarget {
    Markdown,
    Body,
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateDocument {
    pub note_id: String,
    pub target: UpdateTarget,
    pub content: Value,
    /// Exact revision read before editing. A stale revision is never overwritten.
    pub expected_revision_id: String,
    pub request_id: String,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[schemars(extend("type" = "object"))]
#[serde(
    tag = "action",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum DatabaseAction {
    RunButton {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        rule_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        row_id: Option<String>,
    },
    AddRow {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        /// Optional saved row template. Explicit values override its defaults.
        #[serde(skip_serializing_if = "Option::is_none")]
        template_id: Option<String>,
        /// Creates this row as a subtask of the given active row in the same DB.
        #[serde(skip_serializing_if = "Option::is_none")]
        parent_task_id: Option<String>,
        #[serde(default)]
        values: serde_json::Map<String, Value>,
    },
    CreateRowTemplate {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        row_id: String,
        name: String,
    },
    DeleteRowTemplate {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        template_id: String,
    },
    SetCell {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        row_id: String,
        property_id: String,
        value: Value,
    },
    SetTaskLinks {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        row_id: String,
        /// Explicit null clears the parent.
        #[serde(deserialize_with = "deserialize_task_parent")]
        #[schemars(schema_with = "task_parent_schema")]
        parent_id: Value,
        /// Complete predecessor list. An empty list clears it.
        #[schemars(length(max = 64))]
        predecessor_ids: Vec<String>,
    },
    PutRule {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        rule: serde_json::Map<String, Value>,
    },
    ArchiveRule {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        rule_id: String,
    },
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Action {
    Rename,
    Move,
    Trash,
    Restore,
    Open,
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DocumentAction {
    pub note_id: String,
    pub action: Action,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_revision_id: Option<String>,
    pub request_id: String,
}
const SOURCE_TEXT_UTF16_LIMIT: usize = 131072;

#[derive(Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OfficeSourceTableAdd {
    #[schemars(range(min = 1, max = 1))]
    authority_version: u8,
    #[schemars(length(min = 11, max = 74))]
    id: String,
    #[schemars(length(min = 1, max = 256))]
    owner_id: String,
    #[schemars(length(min = 64, max = 64))]
    expected_source_sha256: String,
    #[schemars(length(min = 1, max = 1024))]
    source_part: String,
    #[schemars(length(min = 64, max = 64))]
    expected_source_part_sha256: String,
    #[schemars(length(min = 64, max = 64))]
    expected_shape_id_inventory_sha256: String,
    #[schemars(with = "f64", range(min = -1000, max = 1000))]
    x_mm: serde_json::Number,
    #[schemars(with = "f64", range(min = -1000, max = 1000))]
    y_mm: serde_json::Number,
    #[schemars(with = "Vec<f64>", length(min = 1, max = 100))]
    column_widths_mm: Vec<serde_json::Number>,
    #[schemars(with = "Vec<f64>", length(min = 1, max = 100))]
    row_heights_mm: Vec<serde_json::Number>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OfficeSourceTableAddWire {
    authority_version: u8,
    id: String,
    owner_id: String,
    expected_source_sha256: String,
    source_part: String,
    expected_source_part_sha256: String,
    expected_shape_id_inventory_sha256: String,
    x_mm: serde_json::Number,
    y_mm: serde_json::Number,
    column_widths_mm: Vec<serde_json::Number>,
    row_heights_mm: Vec<serde_json::Number>,
}

fn source_structure_alias(value: &str) -> bool {
    value.strip_prefix("new-table-").is_some_and(|suffix| {
        !suffix.is_empty()
            && suffix.len() <= 64
            && suffix
                .bytes()
                .all(|value| value.is_ascii_alphanumeric() || value == b'_' || value == b'-')
    })
}

fn source_structure_mm(value: &serde_json::Number, positive: bool) -> Option<i64> {
    let number = value.as_f64()?;
    if !number.is_finite() || !(-1000.0..=1000.0).contains(&number) || positive && number <= 0.0 {
        return None;
    }
    let rendered = value.to_string();
    let (mantissa, exponent) = match rendered.find(['e', 'E']) {
        Some(index) => (
            &rendered[..index],
            rendered[index + 1..].parse::<i32>().ok()?,
        ),
        None => (rendered.as_str(), 0),
    };
    let (whole, fraction) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    let coefficient = format!("{whole}{fraction}").parse::<i64>().ok()?;
    if coefficient == 0 {
        return Some(0);
    }
    let shift = 2 + exponent - i32::try_from(fraction.len()).ok()?;
    if shift >= 0 {
        coefficient.checked_mul(10_i64.checked_pow(u32::try_from(shift).ok()?)?)
    } else {
        let divisor = 10_i64.checked_pow(u32::try_from(-shift).ok()?)?;
        (coefficient % divisor == 0).then_some(coefficient / divisor)
    }
}

impl<'de> Deserialize<'de> for OfficeSourceTableAdd {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = OfficeSourceTableAddWire::deserialize(deserializer)?;
        let valid_owner = !value.owner_id.is_empty()
            && value.owner_id.encode_utf16().count() <= 256
            && !value.owner_id.chars().any(|value| (value as u32) < 32);
        let valid_part = !value.source_part.is_empty()
            && value.source_part.encode_utf16().count() <= 1024
            && value.source_part.chars().all(source_text_xml_scalar)
            && !value
                .source_part
                .chars()
                .any(|value| (value as u32) < 32 || "\\:%?#".contains(value))
            && value
                .source_part
                .split('/')
                .all(|part| !part.is_empty() && part != "." && part != "..");
        let bounded_grid = !value.column_widths_mm.is_empty()
            && !value.row_heights_mm.is_empty()
            && value.column_widths_mm.len() <= 100
            && value.row_heights_mm.len() <= 100
            && value.column_widths_mm.len() * value.row_heights_mm.len() <= 100;
        let valid_sizes = bounded_grid
            && [&value.column_widths_mm, &value.row_heights_mm]
                .iter()
                .all(|sizes| {
                    sizes
                        .iter()
                        .map(|size| source_structure_mm(size, true))
                        .collect::<Option<Vec<_>>>()
                        .is_some_and(|sizes| sizes.iter().sum::<i64>() <= 100000)
                });
        if value.authority_version != 1
            || !source_structure_alias(&value.id)
            || !valid_owner
            || !valid_part
            || !source_text_hash(&value.expected_source_sha256)
            || !source_text_hash(&value.expected_source_part_sha256)
            || !source_text_hash(&value.expected_shape_id_inventory_sha256)
            || source_structure_mm(&value.x_mm, false).is_none()
            || source_structure_mm(&value.y_mm, false).is_none()
            || !valid_sizes
        {
            return Err(serde::de::Error::custom(
                "invalid presentation source table creation guards",
            ));
        }
        Ok(Self {
            authority_version: value.authority_version,
            id: value.id,
            owner_id: value.owner_id,
            expected_source_sha256: value.expected_source_sha256,
            source_part: value.source_part,
            expected_source_part_sha256: value.expected_source_part_sha256,
            expected_shape_id_inventory_sha256: value.expected_shape_id_inventory_sha256,
            x_mm: value.x_mm,
            y_mm: value.y_mm,
            column_widths_mm: value.column_widths_mm,
            row_heights_mm: value.row_heights_mm,
        })
    }
}

#[derive(Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OfficeSourceTextPatch {
    #[schemars(range(min = 1, max = 1))]
    authority_version: u8,
    #[schemars(length(min = 1, max = 256))]
    owner_id: String,
    #[schemars(length(min = 1, max = 256))]
    table_id: String,
    #[schemars(length(min = 1, max = 256))]
    cell_id: String,
    /// Lowercase SHA-256 of the captured original package, not the native table.
    #[schemars(length(min = 64, max = 64))]
    expected_source_sha256: String,
    #[schemars(length(min = 1, max = 1024))]
    source_part: String,
    /// Original unsigned decimal source ID; preserve leading zeroes.
    #[schemars(length(min = 1, max = 256))]
    shape_id: String,
    #[schemars(length(min = 64, max = 64))]
    expected_source_frame_sha256: String,
    /// Full current UTF-8 cell text SHA after preceding source operations.
    #[schemars(length(min = 64, max = 64))]
    expected_text_sha256: String,
    #[schemars(range(min = 0, max = 131072))]
    start_utf16: u32,
    #[schemars(range(min = 0, max = 131072))]
    end_utf16: u32,
    #[schemars(length(max = 131072))]
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OfficeSourceTextPatchWire {
    authority_version: u8,
    owner_id: String,
    table_id: String,
    cell_id: String,
    expected_source_sha256: String,
    source_part: String,
    shape_id: String,
    expected_source_frame_sha256: String,
    expected_text_sha256: String,
    start_utf16: u32,
    end_utf16: u32,
    text: String,
}

fn source_text_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|value| value.is_ascii_digit() || (b'a'..=b'f').contains(&value))
}

fn deserialize_source_sha256<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<String, D::Error> {
    let hash = String::deserialize(deserializer)?;
    if !source_text_hash(&hash) {
        return Err(serde::de::Error::custom(
            "expectedSourceSha256 must be lowercase SHA-256",
        ));
    }
    Ok(hash)
}

fn hwp_table_anchor(value: &str) -> bool {
    let Some((section, paragraph)) = value.strip_prefix('s').and_then(|id| id.split_once(":p"))
    else {
        return false;
    };
    [section, paragraph].into_iter().all(|part| {
        !part.is_empty()
            && (part == "0" || !part.starts_with('0'))
            && part.bytes().all(|byte| byte.is_ascii_digit())
    })
}

fn hwp_table_cells_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({
        "type": "array",
        "minItems": 1,
        "maxItems": 8,
        "items": {
            "type": "array",
            "minItems": 1,
            "maxItems": 6,
            "items": { "type": "string", "maxLength": 120 }
        }
    })
}

fn valid_hwp_table_cells(cells: &[Vec<String>], rows: u8, columns: u8) -> bool {
    cells.len() == usize::from(rows)
        && cells.iter().all(|row| {
            row.len() == usize::from(columns)
                && row.iter().all(|cell| {
                    cell.encode_utf16().count() <= 120
                        && !cell.chars().any(|ch| {
                            ch.is_control()
                                || matches!(ch, '\u{2028}' | '\u{2029}' | '\u{fffe}' | '\u{ffff}')
                        })
                })
        })
}

fn source_text_xml_scalar(value: char) -> bool {
    matches!(value as u32, 9 | 10 | 13 | 0x20..=0xd7ff | 0xe000..=0xfffd | 0x10000..=0x10ffff)
}

impl<'de> Deserialize<'de> for OfficeSourceTextPatch {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = OfficeSourceTextPatchWire::deserialize(deserializer)?;
        let valid_id = |id: &str| {
            !id.is_empty()
                && id.encode_utf16().count() <= 256
                && !id.chars().any(|value| (value as u32) < 32)
        };
        let valid_part = !value.source_part.is_empty()
            && value.source_part.encode_utf16().count() <= 1024
            && value.source_part.chars().all(source_text_xml_scalar)
            && !value
                .source_part
                .chars()
                .any(|value| (value as u32) < 32 || "\\:%?#".contains(value))
            && value
                .source_part
                .split('/')
                .all(|part| !part.is_empty() && part != "." && part != "..");
        let valid_shape = !value.shape_id.is_empty()
            && value.shape_id.len() <= 256
            && value.shape_id.bytes().all(|value| value.is_ascii_digit())
            && value.shape_id.parse::<u32>().is_ok();
        if value.authority_version != 1
            || !valid_id(&value.owner_id)
            || !valid_id(&value.table_id)
            || !valid_id(&value.cell_id)
            || !source_text_hash(&value.expected_source_sha256)
            || !source_text_hash(&value.expected_source_frame_sha256)
            || !source_text_hash(&value.expected_text_sha256)
            || !valid_part
            || !valid_shape
            || value.start_utf16 > value.end_utf16
            || value.end_utf16 as usize > SOURCE_TEXT_UTF16_LIMIT
            || value.text.encode_utf16().count() > SOURCE_TEXT_UTF16_LIMIT
            || !value.text.chars().all(source_text_xml_scalar)
        {
            return Err(serde::de::Error::custom(
                "invalid presentation source text patch guards",
            ));
        }
        Ok(Self {
            authority_version: value.authority_version,
            owner_id: value.owner_id,
            table_id: value.table_id,
            cell_id: value.cell_id,
            expected_source_sha256: value.expected_source_sha256,
            source_part: value.source_part,
            shape_id: value.shape_id,
            expected_source_frame_sha256: value.expected_source_frame_sha256,
            expected_text_sha256: value.expected_text_sha256,
            start_utf16: value.start_utf16,
            end_utf16: value.end_utf16,
            text: value.text,
        })
    }
}

fn deserialize_office_operations<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<OfficeOperation>, D::Error> {
    let operations = Vec::<OfficeOperation>::deserialize(deserializer)?;
    for operation in &operations {
        if matches!(
            operation,
            OfficeOperation::PresentationTableStructureEdit { .. }
        ) && operations.len() != 1
        {
            return Err(serde::de::Error::custom(
                "PPTX table structure editing requires one operation per request",
            ));
        }
        if let OfficeOperation::DocxTableStructureEdit {
            table_index,
            action,
            index,
            anchor_index,
            ..
        } = operation
            && (operations.len() != 1
                || *table_index >= 512
                || !action.allows_position(*index, *anchor_index))
        {
            return Err(serde::de::Error::custom(
                "DOCX table structure editing requires one operation with a valid table and band position",
            ));
        }
        if let OfficeOperation::SlideDuplicate { id } = operation {
            let valid_id = id
                .strip_prefix("slide-")
                .and_then(|index| index.parse::<u32>().ok())
                .is_some_and(|index| index <= 999_999 && id == &format!("slide-{index}"));
            if operations.len() != 1 || !valid_id {
                return Err(serde::de::Error::custom(
                    "PPTX slide duplication requires one operation with a saved slide ID",
                ));
            }
        }
        if let OfficeOperation::PptxSlideSectionMove {
            source_index,
            target_index,
            after,
            ..
        } = operation
        {
            let same_position_target = if *after {
                source_index.checked_sub(1)
            } else {
                source_index.checked_add(1)
            };
            if operations.len() != 1 || same_position_target != Some(*target_index) {
                return Err(serde::de::Error::custom(
                    "PPTX slide section reassignment requires one operation that preserves slide order",
                ));
            }
        }
        if let OfficeOperation::TableInsert {
            id,
            reference_id,
            expected_text_sha256,
            rows,
            columns,
            cells,
            ..
        } = operation
            && (operations.len() != 1
                || id.trim().is_empty()
                || id.encode_utf16().count() > 256
                || id.contains('\0')
                || hwp_table_anchor(id)
                || reference_id.len() > 256
                || !hwp_table_anchor(reference_id)
                || !source_text_hash(expected_text_sha256)
                || !(1..=8).contains(rows)
                || !(1..=6).contains(columns)
                || cells
                    .as_ref()
                    .is_some_and(|cells| !valid_hwp_table_cells(cells, *rows, *columns)))
        {
            return Err(serde::de::Error::custom(
                "HWPX table insertion requires one operation with a valid anchor, text hash, size, and optional cells",
            ));
        }
        if let OfficeOperation::TableStructure { id, index, .. } = operation
            && (operations.len() != 1
                || *index > 64
                || id.len() > 128
                || !id.split_once(":t").is_some_and(|(owner, control)| {
                    hwp_table_anchor(owner)
                        && control
                            .parse::<u32>()
                            .is_ok_and(|number| number.to_string() == control)
                }))
        {
            return Err(serde::de::Error::custom(
                "HWPX table structure editing requires one operation with a saved table ID and a bounded index",
            ));
        }
        if let OfficeOperation::ImageRotate {
            expected_rotation_hundredths: before,
            rotation_hundredths: after,
            ..
        } = operation
        {
            if *before >= 36000
                || *after >= 36000
                || before == after
                || before.abs_diff(*after) % 9000 != 0
            {
                return Err(serde::de::Error::custom(
                    "Office photo rotation requires a nonzero quarter turn",
                ));
            }
        }
    }
    let source_count = operations
        .iter()
        .filter(|value| matches!(value, OfficeOperation::PresentationCellTextPatch(_)))
        .count();
    if operations.is_empty()
        || operations.len() > 128
        || source_count != 0 && (source_count != operations.len() || operations.len() > 100)
    {
        return Err(serde::de::Error::custom(
            "source text requires a source-only batch of at most 100 operations",
        ));
    }
    let structure_count = operations
        .iter()
        .filter(|value| matches!(value, OfficeOperation::PresentationSourceTableAdd(_)))
        .count();
    if structure_count != 0 {
        if structure_count != operations.len() || operations.len() > 100 {
            return Err(serde::de::Error::custom(
                "source table creation requires a source-only batch of at most 100 operations",
            ));
        }
        let mut aliases = std::collections::HashSet::new();
        let mut source = None::<String>;
        for operation in &operations {
            if let OfficeOperation::PresentationSourceTableAdd(addition) = operation {
                if !aliases.insert(addition.id.clone())
                    || source
                        .as_ref()
                        .is_some_and(|value| value != &addition.expected_source_sha256)
                {
                    return Err(serde::de::Error::custom(
                        "source table creation aliases or base package guards conflict",
                    ));
                }
                source.get_or_insert_with(|| addition.expected_source_sha256.clone());
            }
        }
    }
    Ok(operations)
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OfficeEdit {
    pub note_id: String,
    pub expected_revision_id: String,
    /// 1..128 supported operations, in order. Geometry and line widths are in mm.
    /// Use object IDs and sourceRevisionId from read_document; new IDs must be
    /// unique within this edit, even after deletion. Unsupported kinds stay intact.
    /// HWPX tableInsert and tableStructure, PPTX slideDuplicate, pptxSlideSectionMove and presentationTableStructureEdit, and DOCX docxTableStructureEdit each require a separate request.
    #[serde(deserialize_with = "deserialize_office_operations")]
    #[schemars(length(min = 1, max = 128))]
    pub operations: Vec<OfficeOperation>,
    pub request_id: String,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[schemars(extend("type" = "object"))]
#[serde(
    tag = "action",
    rename_all = "lowercase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum OfficeAsset {
    /// requestId is the new assetId. Upload PNG/JPEG, at most 20 MiB and 40 million pixels.
    Begin {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        mime_type: String,
        byte_length: u32,
        sha256: String,
    },
    /// At most 128 KiB decoded per chunk. offset is measured in bytes, not base64 characters.
    Append {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        asset_id: String,
        offset: u32,
        base64_data: String,
    },
    Seal {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        asset_id: String,
    },
    Status {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        asset_id: String,
    },
    Discard {
        note_id: String,
        expected_revision_id: String,
        request_id: String,
        asset_id: String,
    },
}

pub struct OfficeSlideLayout(u16);

impl Serialize for OfficeSlideLayout {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u16(self.0)
    }
}

impl<'de> Deserialize<'de> for OfficeSlideLayout {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let code = u16::deserialize(deserializer)?;
        if matches!(code, 0 | 1 | 19 | 20) {
            Ok(Self(code))
        } else {
            Err(serde::de::Error::custom(
                "Unsupported standard slide layout",
            ))
        }
    }
}

impl schemars::JsonSchema for OfficeSlideLayout {
    fn schema_name() -> std::borrow::Cow<'static, str> {
        "OfficeSlideLayout".into()
    }

    fn json_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
        schemars::json_schema!({"type": "integer", "enum": [0, 1, 19, 20]})
    }
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum OfficeTextTarget {
    Paragraph,
    Shape,
    Cell,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum OfficeShapeKind {
    Text,
    Rectangle,
    Ellipse,
    Line,
    #[serde(rename = "roundedRectangle")]
    RoundedRectangle,
    #[serde(rename = "rightArrow")]
    RightArrow,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum OfficePaintStyle {
    None,
    Solid,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum OfficeParagraphPosition {
    Before,
    After,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum OfficeHwpTablePosition {
    After,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum OfficeParagraphAlignment {
    Left,
    Center,
    Right,
    Justify,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum OfficeParagraphList {
    None,
    Bullet,
    Number,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum PptxTableStructureAction {
    InsertRowBefore,
    InsertRowAfter,
    InsertColumnBefore,
    InsertColumnAfter,
    DeleteRow,
    DeleteColumn,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum DocxTableStructureAction {
    InsertRow,
    DeleteRow,
    InsertColumn,
    DeleteColumn,
}

impl DocxTableStructureAction {
    fn allows_position(&self, index: u8, anchor: Option<u8>) -> bool {
        let (limit, insert) = match self {
            Self::InsertRow => (64, true),
            Self::DeleteRow => (64, false),
            Self::InsertColumn => (32, true),
            Self::DeleteColumn => (32, false),
        };
        match (insert, anchor) {
            (true, Some(anchor)) => anchor < limit && (index == anchor || index == anchor + 1),
            (false, None) => index < limit,
            _ => false,
        }
    }
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum HwpTableStructureAction {
    InsertRow,
    DeleteRow,
    InsertColumn,
    DeleteColumn,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(
    tag = "op",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum OfficeOperation {
    /// Create an actual PPTX table using source-bound slide authority. Package/part/inventory guards refer to the captured input; use a unique new-table alias.
    PresentationSourceTableAdd(OfficeSourceTableAdd),
    /// Exact source-byte text patch. Package/frame guards use the input baseline; text SHA/ranges use current text. The app validates fresh source authority and actual cell refs.
    PresentationCellTextPatch(OfficeSourceTextPatch),
    /// Edit an existing PPTX table. Use the source SHA, slide, numeric shape ID and a permitted zero-based position from read_document.pptxTableStructure. Send this operation by itself.
    PresentationTableStructureEdit {
        #[serde(deserialize_with = "deserialize_source_sha256")]
        #[schemars(length(min = 64, max = 64), regex(pattern = r"^[0-9a-f]{64}$"))]
        expected_source_sha256: String,
        #[schemars(range(min = 0, max = 255))]
        slide_index: u8,
        #[schemars(range(min = 1, max = 4294967295_u32))]
        shape_id: NonZeroU32,
        action: PptxTableStructureAction,
        #[schemars(range(min = 0, max = 255))]
        index: u8,
    },
    /// Edit one regular DOCX body table. Use the source SHA and numeric table index from read_document.docxTableStructure. Send this operation by itself.
    DocxTableStructureEdit {
        #[serde(deserialize_with = "deserialize_source_sha256")]
        #[schemars(length(min = 64, max = 64), regex(pattern = r"^[0-9a-f]{64}$"))]
        expected_source_sha256: String,
        /// Zero-based body-flow ordinal from the DOCX structure query.
        #[schemars(range(min = 0, max = 511))]
        table_index: u16,
        action: DocxTableStructureAction,
        /// Zero-based row or column to delete, or the insertion gap before or after anchorIndex.
        #[schemars(range(min = 0, max = 64))]
        index: u8,
        /// For insert only, zero-based existing row or column. Set index to anchorIndex or anchorIndex + 1. Omit for delete.
        #[serde(
            default,
            deserialize_with = "deserialize_non_null_option",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(with = "u8", range(min = 0, max = 63))]
        anchor_index: Option<u8>,
    },
    /// Set millimetres (at most two decimals) on an actual pageStyles ID whose canEditGeometry is true. Supply width/height/landscape together; omitted margins stay unchanged. Read the current layoutSha256 after each geometry edit. Header/footer sharing flags are read-only.
    PageGeometry {
        id: String,
        expected_layout_sha256: String,
        #[serde(
            default,
            deserialize_with = "deserialize_non_null_option",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(with = "f64")]
        width: Option<f64>,
        #[serde(
            default,
            deserialize_with = "deserialize_non_null_option",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(with = "f64")]
        height: Option<f64>,
        #[serde(
            default,
            deserialize_with = "deserialize_non_null_option",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(with = "bool")]
        landscape: Option<bool>,
        #[serde(
            default,
            deserialize_with = "deserialize_non_null_option",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(with = "f64")]
        left_margin: Option<f64>,
        #[serde(
            default,
            deserialize_with = "deserialize_non_null_option",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(with = "f64")]
        right_margin: Option<f64>,
        #[serde(
            default,
            deserialize_with = "deserialize_non_null_option",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(with = "f64")]
        top_margin: Option<f64>,
        #[serde(
            default,
            deserialize_with = "deserialize_non_null_option",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(with = "f64")]
        bottom_margin: Option<f64>,
    },
    /// Split a paragraph in its actual body/header/footer owner; the original ID stays on the left and newId names the right in this batch.
    ParagraphSplit {
        id: String,
        new_id: String,
        offset_utf16: u32,
        expected_text_sha256: String,
    },
    /// Insert plain text without newlines before or after a paragraph in the same owner; IDs cannot be reused across owners.
    ParagraphInsert {
        id: String,
        reference_id: String,
        position: OfficeParagraphPosition,
        expected_text_sha256: String,
        text: String,
    },
    /// Insert an unmerged HWPX table after a paragraph with tableInsertAnchor. Send this operation alone.
    TableInsert {
        #[schemars(length(min = 1, max = 256))]
        id: String,
        #[schemars(
            length(min = 5, max = 256),
            regex(pattern = r"^s(?:0|[1-9][0-9]*):p(?:0|[1-9][0-9]*)$")
        )]
        reference_id: String,
        position: OfficeHwpTablePosition,
        /// Lowercase SHA-256 of the anchor paragraph's current UTF-8 text.
        #[schemars(length(min = 64, max = 64), regex(pattern = r"^[0-9a-f]{64}$"))]
        expected_text_sha256: String,
        #[schemars(range(min = 1, max = 8))]
        rows: u8,
        #[schemars(range(min = 1, max = 6))]
        columns: u8,
        /// Optional rows × columns matrix in row order, with single-line text up to 120 UTF-16 units per cell.
        /// Omit to insert a blank table. Empty strings and surrounding spaces are preserved.
        #[serde(
            default,
            deserialize_with = "deserialize_non_null_option",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(schema_with = "hwp_table_cells_schema")]
        cells: Option<Vec<Vec<String>>>,
    },
    /// Change an existing HWPX table with structure metadata from read_document. Send this operation alone.
    /// Insert index is a zero-based boundary, including the end. Delete index selects an existing row or column.
    TableStructure {
        #[schemars(
            length(min = 8, max = 128),
            regex(pattern = r"^s(?:0|[1-9][0-9]*):p(?:0|[1-9][0-9]*):t(?:0|[1-9][0-9]*)$")
        )]
        id: String,
        action: HwpTableStructureAction,
        #[schemars(range(min = 0, max = 64))]
        index: u8,
    },
    /// Join directly adjacent paragraphs in the same owner; body/header/footer, tables and opaque blocks cannot be crossed.
    ParagraphJoin {
        id: String,
        next_id: String,
        expected_text_sha256: String,
        expected_next_text_sha256: String,
    },
    ParagraphDelete {
        id: String,
        expected_text_sha256: String,
    },
    /// Set only supplied paragraph properties using a style name returned by read_document. pageBreakBefore is body-only.
    ParagraphFormat {
        id: String,
        expected_text_sha256: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        style_name: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        alignment: Option<OfficeParagraphAlignment>,
        #[serde(skip_serializing_if = "Option::is_none")]
        list_kind: Option<OfficeParagraphList>,
        #[serde(skip_serializing_if = "Option::is_none")]
        list_level: Option<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        page_break_before: Option<bool>,
    },
    /// UTF-16 half-open range in current text after earlier operations; SHA256 is of full UTF-8 text.
    TextReplace {
        target_kind: OfficeTextTarget,
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        cell: Option<String>,
        start_utf16: u32,
        end_utf16: u32,
        expected_text_sha256: String,
        text: String,
    },
    /// Apply only supplied properties to the selected range; protected fields cannot be flattened.
    TextStyle {
        target_kind: OfficeTextTarget,
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        cell: Option<String>,
        start_utf16: u32,
        end_utf16: u32,
        expected_text_sha256: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        font_size: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        bold: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        italic: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        underline: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        color: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        font_family: Option<String>,
    },
    ImageAdd {
        id: String,
        slide_id: String,
        asset_id: String,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    },
    ImageReplace {
        id: String,
        asset_id: String,
    },
    /// Rotate an existing PPTX slide photo with image.canRotate.
    /// Angles are clockwise hundredths of a degree. Use the current angle
    /// and a distinct target separated by a multiple of 9000.
    ImageRotate {
        id: String,
        #[schemars(range(min = 0, max = 35999))]
        expected_rotation_hundredths: u16,
        #[schemars(range(min = 0, max = 35999))]
        rotation_hundredths: u16,
    },
    /// Add a sealed PNG/JPEG at a verified body wordImageTargets paragraph and UTF-16 point. id is a new batch alias, never reused after deletion. Dimensions are positive millimetres, at most 1000 with two decimal places; the app verifies the current paragraph SHA and protected boundaries.
    WordImageAdd {
        id: String,
        owner_id: String,
        paragraph_id: String,
        #[schemars(range(min = 0, max = 20_000_000))]
        offset_utf16: u32,
        expected_text_sha256: String,
        asset_id: String,
        width: f64,
        height: f64,
    },
    /// Move a canMove AS_CHARACTER body image to a verified canMoveHere paragraph point. Preserve the logical source-or-batch id and original picture properties; no asset or geometry is accepted.
    WordImageMove {
        id: String,
        owner_id: String,
        paragraph_id: String,
        #[schemars(range(min = 0, max = 20_000_000))]
        offset_utf16: u32,
        expected_text_sha256: String,
    },
    /// Delete only the exact source-or-batch image id whose canDelete capability is true. The retired alias cannot be reused in this batch.
    WordImageDelete {
        id: String,
    },
    ParagraphText {
        id: String,
        text: String,
    },
    ParagraphStyle {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        font_size: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        bold: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        color: Option<u32>,
    },
    TableCellText {
        table_id: String,
        cell: String,
        text: String,
    },
    ShapeText {
        id: String,
        text: String,
    },
    ShapeStyle {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        font_size: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        bold: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        color: Option<u32>,
    },
    ShapeGeometry {
        id: String,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    },
    ShapeAdd {
        id: String,
        slide_id: String,
        shape_kind: OfficeShapeKind,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        text: Option<String>,
    },
    ShapeDelete {
        id: String,
    },
    ShapeAppearance {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        fill_style: Option<OfficePaintStyle>,
        #[serde(skip_serializing_if = "Option::is_none")]
        fill_color: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        line_style: Option<OfficePaintStyle>,
        #[serde(skip_serializing_if = "Option::is_none")]
        line_color: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        line_width: Option<f64>,
    },
    /// Change an actual source-bound common design or a supported standard layout.
    /// Recreated nonempty objects are rejected; inspect the new revision before follow-up edits.
    SlideDesign {
        id: String,
        change_id: String,
        expected_design_sha256: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        master_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        layout_code: Option<OfficeSlideLayout>,
    },
    /// Explicit slide visibility and common-object display, without toggling unknown state.
    SlideDisplay {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        visible: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        show_master_objects: Option<bool>,
    },
    SlideBackground {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        fill_style: Option<OfficePaintStyle>,
        #[serde(skip_serializing_if = "Option::is_none")]
        fill_color: Option<u32>,
    },
    SlideAdd {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        index: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        text: Option<String>,
    },
    /// Copy the saved PPTX slide immediately after itself. Use a read_document slide ID whose canDuplicate is true. Send this operation by itself.
    SlideDuplicate {
        #[schemars(
            length(min = 7, max = 12),
            regex(pattern = r"^slide-(?:0|[1-9][0-9]{0,5})$")
        )]
        id: String,
    },
    /// Reassign a PPTX slide to the adjacent slide's section while keeping its order.
    /// Read pptxSlideOrder first and send this operation by itself.
    PptxSlideSectionMove {
        #[serde(deserialize_with = "deserialize_source_sha256")]
        #[schemars(length(min = 64, max = 64), regex(pattern = r"^[0-9a-f]{64}$"))]
        expected_source_sha256: String,
        #[schemars(range(min = 0, max = 255))]
        source_index: u8,
        #[schemars(range(min = 0, max = 255))]
        target_index: u8,
        after: bool,
    },
    SlideDelete {
        id: String,
    },
    SlideMove {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        index: Option<u32>,
    },
}
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RenderPage {
    pub note_id: String,
    /// Zero-based page index; omitted means the first page.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page_index: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision_id: Option<String>,
    /// The source, PDF binding and stable page UUID from an Office page link.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "OfficePageTarget")]
    pub office_page_target: Option<OfficePageTarget>,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OfficePageTarget {
    pub source_revision_id: String,
    pub pdf_binding_id: String,
    pub page_id: String,
}

#[derive(Clone, Copy, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum PageMediaMode {
    Metadata,
    Bytes,
    Preview,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadPageMedia {
    pub note_id: String,
    /// Exact saved page or database body revision returned by read_document.
    pub revision_id: String,
    /// Registered image or attachment block in the selected page or row.
    pub block_id: String,
    /// Required for database row media; omit for a standalone page.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "String")]
    pub row_id: Option<String>,
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "PageMediaMode")]
    pub mode: Option<PageMediaMode>,
    /// Byte mode only; zero-based offset, default 0.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u32", range(min = 0))]
    pub offset: Option<u32>,
    /// Byte mode only; at most 256 KiB, default 64 KiB.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u32", range(min = 1, max = 262144))]
    pub limit: Option<u32>,
    /// Preview mode only; longest side, default 1024; encoded output is separately bounded.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "u32", range(min = 64, max = 2048))]
    pub max_dimension: Option<u32>,
}

#[tool_router]
impl InkVaultServer {
    pub fn new(bridge: BridgeClient) -> Self {
        Self {
            bridge,
            tool_router: Self::tool_router(),
        }
    }

    #[tool(
        description = "실행 중인 앱과 저장소 상태를 확인합니다.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn vault_status(&self) -> CallToolResult {
        self.forward("vault_status", json!({})).await
    }
    #[tool(
        description = "문서 제목·검색·폴더로 문서 목록을 읽습니다.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn list_documents(&self, Parameters(args): Parameters<ListDocuments>) -> CallToolResult {
        self.forward("list_documents", args).await
    }
    #[tool(
        description = "현재 보관함의 저장된 문서를 앱과 같은 검색식으로 찾습니다. file:, path:, tag:, content: 조건과 따옴표, OR, 괄호, - 제외를 지원합니다. 반환된 noteId를 read_document에 사용하세요.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn search_documents(
        &self,
        Parameters(args): Parameters<SearchDocuments>,
    ) -> CallToolResult {
        if args.query.trim().is_empty()
            || args.query.encode_utf16().count() > 2048
            || args.limit.is_some_and(|value| !(1..=100).contains(&value))
            || args.offset.is_some_and(|value| value > 1_000_000)
        {
            return error_result(BridgeError::new(
                "invalid_arguments",
                "검색식은 UTF-16 코드 단위 2048개까지 지원합니다. 검색식과 결과 범위를 확인하세요.",
            ));
        }
        self.forward("search_documents", args).await
    }
    #[tool(
        description = "저장소의 폴더 목록을 읽습니다.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn list_folders(&self) -> CallToolResult {
        self.forward("list_folders", json!({})).await
    }
    #[tool(
        description = "문서 본문·판본을 읽습니다. Office는 원본의 글자·개체와 sourceRevisionId를 반환합니다. Word의 선택적 wordOwners/pageStyles는 실제 머리글·바닥글 영역과 페이지 설정 관측값이며, 최상위 paragraphs/blocks는 본문입니다. 없는 메타데이터나 truncated 응답으로 편집 가능 여부를 추정하지 마세요. PPTX 표 행·열은 pptxTableStructure:{}로 슬라이드를 찾고 slideIndex를 지정해 표와 허용 위치를 조회합니다. DOCX 표 행·열은 docxTableStructure:{}로 편집 가능한 본문 표와 원본 해시를 조회합니다. pptxSlideOrder:true는 현재 PPTX의 순서·구역·원본 해시를 읽습니다. 구조 조회에서는 revisionId를 생략하세요.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn read_document(&self, Parameters(args): Parameters<ReadDocument>) -> CallToolResult {
        if args.pptx_slide_order == Some(true)
            && (args.revision_id.is_some()
                || args.docx_table_structure.is_some()
                || args.pptx_table_structure.is_some())
        {
            return error_result(BridgeError::new(
                "invalid_arguments",
                "현재 PPTX 슬라이드 순서를 조회할 때는 revisionId와 표 조회 조건을 생략하세요.",
            ));
        }
        if args.docx_table_structure.as_ref().is_some_and(|query| {
            args.revision_id.is_some()
                || args.pptx_table_structure.is_some()
                || query.table_offset.is_some_and(|offset| offset > 512)
                || query
                    .table_limit
                    .is_some_and(|limit| !(1..=32).contains(&limit))
        }) {
            return error_result(BridgeError::new(
                "invalid_arguments",
                "DOCX 표 조회에는 현재 판본만 사용할 수 있습니다. 표 조회 종류와 범위를 확인하세요.",
            ));
        }
        if args.pptx_table_structure.as_ref().is_some_and(|query| {
            args.revision_id.as_ref().is_some_and(Option::is_some)
                || query.table_offset.is_some_and(|offset| offset > 400)
                || query
                    .table_limit
                    .is_some_and(|limit| !(1..=32).contains(&limit))
                || (query.slide_index.is_none()
                    && (query.table_offset.is_some() || query.table_limit.is_some()))
        }) {
            return error_result(BridgeError::new(
                "invalid_arguments",
                "현재 PPTX 조회에서만 표 범위를 지정할 수 있습니다. 슬라이드와 조회 범위를 확인하세요.",
            ));
        }
        self.forward("read_document", args).await
    }
    #[tool(
        description = "일반 블록 페이지에 저장된 토론을 읽습니다. threadId를 지정하면 해당 스레드와 답글을 조회합니다. 결과의 페이지 커서와 현재 저장 판본을 확인하세요.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn list_page_discussions(
        &self,
        Parameters(args): Parameters<ListPageDiscussions>,
    ) -> CallToolResult {
        self.forward("list_page_discussions", args).await
    }

    #[tool(
        description = "현재 페이지 메타데이터와 저장 본문 상태를 조건으로 댓글·답글을 추가하거나 해결 상태를 기록합니다. 수정 허용이 필요합니다. 동일한 작업을 재시도할 때 같은 requestId를 사용하세요.",
        annotations(
            read_only_hint = false,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn mutate_page_discussion(
        &self,
        Parameters(args): Parameters<MutatePageDiscussion>,
    ) -> CallToolResult {
        self.forward("mutate_page_discussion", args).await
    }

    #[tool(
        description = "저장된 DB의 필터·정렬·수식·관계·롤업·집계·달력·차트를 앱의 Rust 엔진으로 읽습니다. read_document의 본문 revisionId를 expectedRevisionId에 지정하세요. 관련 DB는 같은 저장소의 noteId와 본문 판본으로 명시합니다. 저장하지 않으며 읽기 전용 연결에서도 가능합니다.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn database_query(&self, Parameters(args): Parameters<DatabaseQuery>) -> CallToolResult {
        self.forward("database_query", args).await
    }
    #[tool(
        description = "저장된 DB의 한 작업에서 상위 작업과 선행 작업 ID를 읽습니다. read_document의 본문 판본을 expectedRevisionId에 지정하세요.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn database_task_links(
        &self,
        Parameters(args): Parameters<ReadDatabaseTaskLinks>,
    ) -> CallToolResult {
        self.forward("database_task_links", args).await
    }

    #[tool(
        description = "현재 보관함의 저장된 Markdown을 Dataview LIST·TABLE·TASK로 조회합니다. TASK는 할 일 상태와 원본 Markdown 판본 ID·줄 번호를 반환합니다. 읽기 전용 연결에서도 사용할 수 있습니다.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn query_dataview(&self, Parameters(args): Parameters<QueryDataview>) -> CallToolResult {
        if args.query.trim().is_empty() || args.query.encode_utf16().count() > 4096 {
            return error_result(BridgeError::new(
                "invalid_arguments",
                "Dataview 쿼리는 비어 있지 않아야 하며 UTF-16 코드 단위 4096개까지 지원합니다.",
            ));
        }
        self.forward("query_dataview", args).await
    }

    #[tool(
        description = "날짜별 노트의 저장 상태와 판본을 조회합니다. 날짜는 YYYY-MM-DD로 지정합니다. 읽기 전용 연결에서도 사용할 수 있습니다.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn read_daily_note(&self, Parameters(args): Parameters<ReadDailyNote>) -> CallToolResult {
        if !valid_daily_date(&args.date) {
            return invalid_daily_date();
        }
        self.forward("read_daily_note", args).await
    }
    #[tool(
        description = "지정한 날짜의 노트를 찾거나, 처음이면 보관함의 기본 템플릿으로 만듭니다. 날짜는 YYYY-MM-DD이며 수정 허용과 requestId가 필요합니다.",
        annotations(
            read_only_hint = false,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn ensure_daily_note(
        &self,
        Parameters(args): Parameters<EnsureDailyNote>,
    ) -> CallToolResult {
        if !valid_daily_date(&args.date) {
            return invalid_daily_date();
        }
        let valid_id = uuid::Uuid::parse_str(&args.request_id).is_ok_and(|id| {
            id.hyphenated().to_string() == args.request_id
                && (1..=8).contains(&id.get_version_num())
                && id.get_variant() == uuid::Variant::RFC4122
        });
        if !valid_id {
            return error_result(BridgeError::new(
                "invalid_arguments",
                "requestId는 소문자 UUID 형식으로 입력하세요.",
            ));
        }
        self.forward("ensure_daily_note", args).await
    }
    #[tool(
        description = "문서를 만듭니다. word/presentation/hwpx는 실제 원본을 생성하며 본문은 read_document 후 office_edit로 편집합니다. 수정 허용과 요청 ID가 필요합니다.",
        annotations(
            read_only_hint = false,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn create_document(
        &self,
        Parameters(args): Parameters<CreateDocument>,
    ) -> CallToolResult {
        self.forward("create_document", args).await
    }
    #[tool(
        description = "읽었던 판본을 조건으로 Markdown 또는 구조화된 본문을 수정합니다. 다른 판본은 덮어쓰지 않습니다.",
        annotations(
            read_only_hint = false,
            destructive_hint = true,
            open_world_hint = false
        )
    )]
    async fn update_document(
        &self,
        Parameters(args): Parameters<UpdateDocument>,
    ) -> CallToolResult {
        self.forward("update_document", args).await
    }
    #[tool(
        description = "데이터베이스의 버튼 실행, 행 추가, 셀 변경, 작업 연결, 항목 템플릿과 자동화 규칙을 관리합니다. read_document의 본문 판본을 expectedRevisionId에 전달하세요. add_row는 templateId와 parentTaskId를 받을 수 있습니다. set_task_links에서 parentId:null은 부모를, predecessorIds:[]는 선행 작업을 비웁니다. set_cell value:null은 셀 값을 비웁니다.",
        annotations(
            read_only_hint = false,
            destructive_hint = true,
            open_world_hint = false
        )
    )]
    async fn database_action(
        &self,
        Parameters(args): Parameters<DatabaseAction>,
    ) -> CallToolResult {
        self.forward("database_action", args).await
    }
    #[tool(
        description = "문서 이름·폴더·휴지통 상태를 바꾸거나 앱에서 문서를 엽니다.",
        annotations(
            read_only_hint = false,
            destructive_hint = true,
            open_world_hint = false
        )
    )]
    async fn document_action(
        &self,
        Parameters(args): Parameters<DocumentAction>,
    ) -> CallToolResult {
        self.forward("document_action", args).await
    }
    #[tool(
        description = "문서의 저장된 판본 목록을 읽습니다. target:body를 지정하면 저장된 BODY 판본만 조회하고, target 없이 offset/limit만 지정하면 전체 소유 판본을 정확한 record 단위로 페이지 조회합니다(offset 기본0, limit 기본100, 1..100). 세 필드를 모두 생략하면 기존 전체 소유 판본 목록(최대500개) 응답을 유지합니다. 판본 ID나 반환 순서로 날짜·최신 순서를 추정하지 마세요.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn list_revisions(&self, Parameters(args): Parameters<ListRevisions>) -> CallToolResult {
        self.forward("list_revisions", args).await
    }
    #[tool(
        description = "지정한 저장 판본을 읽습니다. 현재 문서나 미저장 draft를 바꾸지 않습니다. 개별 raw 본문은1MiB까지 제공하며 더 큰 본문은 생략하고 contentUnavailable:too_large로 알립니다. 기존 판본에 없는 저장 날짜를 만들거나 판본 ID에서 추정하지 마세요.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn read_revision(&self, Parameters(args): Parameters<ReadRevision>) -> CallToolResult {
        self.forward("read_revision", args).await
    }
    #[tool(
        description = "일반 블록 페이지의 저장된 전체 BODY snapshot을 읽기 전용으로 비교합니다. revisionId는 과거 before, expectedRevisionId는 저장된 현재 BODY after입니다. 미저장 draft는 비교하지 않습니다. offset 기본0·limit 기본100(1..100)이며 반환된 페이지·truncation 정보를 확인하세요. 날짜가 없는 기존 판본에 시각을 만들지 않습니다. 복원에는 결과의 body·문서 metadata·모든 상위 폴더 expectedHeads guard map 전체를 그대로 사용하세요.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn compare_page_revision(
        &self,
        Parameters(args): Parameters<ComparePageRevision>,
    ) -> CallToolResult {
        self.forward("compare_page_revision", args).await
    }
    #[tool(
        description = "compare_page_revision에서 확인한 과거 전체 BODY snapshot을 현재 head의 새 자식 판본으로 복원합니다. expectedRevisionId는 비교한 현재 BODY이며 expectedHeads는 body·문서 metadata·모든 상위 폴더 guard map 전체입니다. 바뀐 head·폴더·충돌은 거절하므로 다시 비교하세요. 이전 파일·baseRefs·summary를 보존합니다. 수정 허용과 requestId가 필요하며 동일 요청 재시도는 준비된 receipt를 재사용하여 중복 판본을 만들지 않습니다. document_action.restore는 별도의 휴지통 복귀 작업입니다.",
        annotations(
            read_only_hint = false,
            destructive_hint = true,
            open_world_hint = false
        )
    )]
    async fn restore_page_revision(
        &self,
        Parameters(args): Parameters<RestorePageRevision>,
    ) -> CallToolResult {
        self.forward("restore_page_revision", args).await
    }
    #[tool(
        description = "Office 원본의 지원되는 개체를 편집하고 새 원본·PDF 판본으로 저장합니다. 이전 판본·필기는 보존됩니다. pptxSlideSectionMove는 슬라이드 순서를 유지하고 인접한 슬라이드의 구역으로 옮깁니다.",
        annotations(
            read_only_hint = false,
            destructive_hint = true,
            open_world_hint = false
        )
    )]
    async fn office_edit(&self, Parameters(args): Parameters<OfficeEdit>) -> CallToolResult {
        self.forward("office_edit", args).await
    }

    #[tool(
        description = "Office 이미지 PNG/JPEG를 begin→append(최대128KiB씩)→seal로 준비합니다. begin requestId가 assetId입니다. noteId·현재 sourceRevisionId에 묶이며 office_edit imageAdd/imageReplace/wordImageAdd에서 assetId를 사용합니다. wordImageMove/wordImageDelete는 asset을 받지 않습니다. 임의 경로·URL은 받지 않습니다. status로 전송량을 확인하고 discard로 미사용 이미지를 정리합니다.",
        annotations(
            read_only_hint = false,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn office_asset(&self, Parameters(args): Parameters<OfficeAsset>) -> CallToolResult {
        self.forward("office_asset", args).await
    }
    #[tool(
        description = "PDF와 필기 문서의 실제 한 페이지 이미지를 읽습니다. 첫 페이지는 pageIndex=0입니다. Office 필기 링크의 정확한 페이지를 읽을 때는 officePageTarget에 sourceRevisionId, pdfBindingId, pageId를 넣고 pageIndex와 revisionId를 생략하세요.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn render_page(&self, Parameters(args): Parameters<RenderPage>) -> CallToolResult {
        if args.office_page_target.is_some()
            && (args.page_index.is_some() || args.revision_id.is_some())
        {
            return error_result(BridgeError::new(
                "invalid_arguments",
                "Office 페이지 대상을 지정할 때 페이지 번호와 별도 판본을 함께 보낼 수 없습니다.",
            ));
        }
        self.forward("render_page", args).await
    }

    #[tool(
        description = "저장된 페이지나 데이터베이스 행의 소유 이미지·첨부를 읽습니다. read_document의 noteId·본문 revisionId·등록 blockId가 필요하며 DB는 rowId도 필수입니다. 일반 페이지에서는 rowId를 생략합니다. 기본 metadata, bytes는 offset/limit(최대256KiB), preview는 이미지의 maxDimension(64..2048)을 사용합니다. 경로·URL·전역 blob 해시는 받지 않습니다.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            open_world_hint = false
        )
    )]
    async fn read_page_media(&self, Parameters(args): Parameters<ReadPageMedia>) -> CallToolResult {
        let valid = match args.mode.unwrap_or(PageMediaMode::Metadata) {
            PageMediaMode::Metadata => {
                args.offset.is_none() && args.limit.is_none() && args.max_dimension.is_none()
            }
            PageMediaMode::Bytes => {
                args.max_dimension.is_none()
                    && args.limit.is_none_or(|value| (1..=262144).contains(&value))
            }
            PageMediaMode::Preview => {
                args.offset.is_none()
                    && args.limit.is_none()
                    && args
                        .max_dimension
                        .is_none_or(|value| (64..=2048).contains(&value))
            }
        };
        if !valid {
            return error_result(BridgeError::new(
                "invalid_arguments",
                "미디어 모드와 읽기 범위를 확인하세요.",
            ));
        }
        self.forward("read_page_media", args).await
    }

    async fn forward<T: Serialize>(&self, operation: &str, args: T) -> CallToolResult {
        let args = match serde_json::to_value(args) {
            Ok(args) => args,
            Err(_) => {
                return error_result(BridgeError::new(
                    "invalid_arguments",
                    "작업 인자를 읽지 못했습니다.",
                ));
            }
        };
        match self.bridge.call(operation, args).await {
            Ok(value) => match image_result(value) {
                Ok(value) => value,
                Err(error) => error_result(error),
            },
            Err(error) => error_result(error),
        }
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for InkVaultServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().enable_resources().build())
            .with_server_info(Implementation::new("personal-ink-vault", env!("CARGO_PKG_VERSION")))
            .with_instructions("Only the running local app owns vault writes. Read a current revision before edits. Reuse requestId only for an identical retry. App write permission is authoritative. No external file paths or servers are opened.")
    }
    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, ErrorData> {
        Ok(ListResourcesResult::with_all_items(vec![
            Resource::new("inkvault://documents", "documents")
                .with_title("문서 목록")
                .with_mime_type("application/json"),
        ]))
    }
    async fn list_resource_templates(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourceTemplatesResult, ErrorData> {
        Ok(ListResourceTemplatesResult::with_all_items(vec![
            ResourceTemplate::new("inkvault://document/{noteId}", "document")
                .with_title("문서 읽기")
                .with_mime_type("application/json"),
        ]))
    }
    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, ErrorData> {
        let (operation, args) = if request.uri == "inkvault://documents" {
            ("list_documents", json!({}))
        } else if let Some(id) = request.uri.strip_prefix("inkvault://document/") {
            if uuid::Uuid::parse_str(id).is_err() {
                return Err(ErrorData::invalid_params("Expected a document UUID", None));
            }
            ("read_document", json!({"noteId":id}))
        } else {
            return Err(ErrorData::invalid_params(
                "Unsupported inkvault resource URI",
                None,
            ));
        };
        let value = self.bridge.call(operation, args).await.map_err(|error| {
            ErrorData::internal_error(error.message, Some(json!({"code":error.code})))
        })?;
        Ok(
            ReadResourceResult::new(vec![ResourceContents::text(value.to_string(), request.uri)])
                .into(),
        )
    }
}

fn error_result(error: BridgeError) -> CallToolResult {
    CallToolResult::structured_error(json!({"code":error.code,"message":error.message}))
}
fn image_result(mut value: Value) -> Result<CallToolResult, BridgeError> {
    let image = value
        .as_object_mut()
        .and_then(|object| object.remove("image"));
    let Some(image) = image else {
        return Ok(CallToolResult::structured(value));
    };
    let data = image["data"].as_str().ok_or_else(invalid_image)?;
    let mime = image["mimeType"].as_str().ok_or_else(invalid_image)?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|_| invalid_image())?;
    let valid = match mime {
        "image/png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "image/jpeg" => bytes.starts_with(&[0xff, 0xd8, 0xff]),
        "image/webp" => bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP"),
        _ => false,
    };
    if !valid {
        return Err(invalid_image());
    }
    let mut result = CallToolResult::structured(value);
    result.content.push(ContentBlock::image(data, mime));
    Ok(result)
}
fn invalid_image() -> BridgeError {
    BridgeError::new(
        "invalid_image_result",
        "문서 페이지 이미지의 형식을 확인하지 못했습니다.",
    )
}

#[cfg(test)]
mod source_patch_wire_tests {
    use super::*;

    fn operation() -> Value {
        json!({
            "op":"presentationCellTextPatch","authorityVersion":1,
            "ownerId":"slide-0","tableId":"slide-0/shape-7","cellId":"stable-cell-42",
            "expectedSourceSha256":"a".repeat(64),
            "sourcePart":"ppt/slides/slide1.xml","shapeId":"0009",
            "expectedSourceFrameSha256":"b".repeat(64),
            "expectedTextSha256":"c".repeat(64),
            "startUtf16":0,"endUtf16":4,"text":""
        })
    }

    #[test]
    fn source_patch_flat_closed_operation_roundtrips_all_guards_and_empty_text() {
        let value = operation();
        let parsed: OfficeOperation = serde_json::from_value(value.clone())
            .expect("source patch must be a typed independent operation");
        assert_eq!(serde_json::to_value(parsed).unwrap(), value);
    }

    #[test]
    fn source_patch_rejects_unknown_missing_invalid_guard_scalar_and_range_fields() {
        for (key, value) in [
            ("extra", json!(1)),
            ("authorityVersion", json!(2)),
            ("authorityVersion", json!(true)),
            ("ownerId", json!("")),
            ("expectedSourceSha256", json!("A".repeat(64))),
            ("expectedSourceFrameSha256", json!("bad")),
            ("expectedTextSha256", json!("c".repeat(63))),
            ("sourcePart", json!("../slide.xml")),
            ("sourcePart", json!("ppt\\slides\\slide1.xml")),
            ("shapeId", json!("shape-9")),
            ("startUtf16", json!(true)),
            ("startUtf16", json!(-1)),
            ("startUtf16", json!(5)),
            ("endUtf16", json!(131073)),
            ("text", json!("\u{0000}")),
            ("text", json!("😀".repeat(65537))),
        ] {
            let mut invalid = operation();
            invalid[key] = value;
            assert!(
                serde_json::from_value::<OfficeOperation>(invalid).is_err(),
                "{key}"
            );
        }
        for key in [
            "authorityVersion",
            "ownerId",
            "tableId",
            "cellId",
            "expectedSourceSha256",
            "sourcePart",
            "shapeId",
            "expectedSourceFrameSha256",
            "expectedTextSha256",
            "startUtf16",
            "endUtf16",
            "text",
        ] {
            let mut invalid = operation();
            invalid.as_object_mut().unwrap().remove(key);
            assert!(
                serde_json::from_value::<OfficeOperation>(invalid).is_err(),
                "{key}"
            );
        }
    }

    #[test]
    fn source_patch_batch_is_at_most_one_hundred_without_reducing_legacy_budget() {
        let envelope = |operations| {
            json!({
                "noteId":"01234567-89ab-4cde-8fab-0123456789ab",
                "expectedRevisionId":"01234567-89ab-4cde-8fab-0123456789ac",
                "requestId":"source-batch","operations":operations
            })
        };
        let valid = envelope(vec![operation(); 100]);
        assert!(serde_json::from_value::<OfficeEdit>(valid).is_ok());
        assert!(serde_json::from_value::<OfficeEdit>(envelope(vec![operation(); 101])).is_err());
        let legacy = json!({"op":"tableCellText","tableId":"WordTable1","cell":"A1","text":""});
        assert!(serde_json::from_value::<OfficeEdit>(envelope(vec![legacy; 128])).is_ok());
    }
}

#[cfg(test)]
mod pptx_slide_section_wire_tests {
    use super::*;

    const NOTE_ID: &str = "01234567-89ab-4cde-8fab-0123456789ab";

    fn operation(source: u8, target: u8, after: bool) -> Value {
        json!({
            "op": "pptxSlideSectionMove",
            "expectedSourceSha256": "a".repeat(64),
            "sourceIndex": source,
            "targetIndex": target,
            "after": after
        })
    }

    fn edit(operations: Vec<Value>) -> Value {
        json!({
            "noteId": NOTE_ID,
            "expectedRevisionId": "01234567-89ab-4cde-8fab-0123456789ac",
            "requestId": "section-move-wire",
            "operations": operations
        })
    }

    #[test]
    fn pptx_slide_order_read_is_an_optional_closed_boolean() {
        let schema = serde_json::to_value(schemars::schema_for!(ReadDocument)).unwrap();
        assert_eq!(schema["properties"]["pptxSlideOrder"]["type"], "boolean");
        assert!(
            !schema["required"]
                .as_array()
                .unwrap()
                .contains(&json!("pptxSlideOrder"))
        );
        for value in [
            json!({"noteId": NOTE_ID}),
            json!({"noteId": NOTE_ID, "pptxSlideOrder": false}),
            json!({"noteId": NOTE_ID, "pptxSlideOrder": true}),
        ] {
            let parsed: ReadDocument = serde_json::from_value(value.clone()).unwrap();
            assert_eq!(serde_json::to_value(parsed).unwrap(), value);
        }
        for selector in [json!(null), json!("true"), json!({}), json!(1)] {
            let value = json!({"noteId": NOTE_ID, "pptxSlideOrder": selector});
            assert!(serde_json::from_value::<ReadDocument>(value).is_err());
        }
    }

    #[tokio::test]
    async fn pptx_slide_order_rejects_explicit_revision_and_table_queries_before_bridge() {
        let missing_bridge = std::env::temp_dir().join(format!(
            "ink-vault-pptx-section-wire-{}-missing.json",
            std::process::id()
        ));
        assert!(!missing_bridge.exists());
        let server = InkVaultServer::new(BridgeClient::from_file(missing_bridge).unwrap());
        for (field, value) in [
            ("revisionId", json!(null)),
            ("revisionId", json!(NOTE_ID)),
            ("pptxTableStructure", json!({})),
            ("docxTableStructure", json!({})),
        ] {
            let mut request = json!({"noteId": NOTE_ID, "pptxSlideOrder": true});
            request[field] = value;
            let args = serde_json::from_value(request).unwrap();
            let result = server.read_document(Parameters(args)).await;
            assert_eq!(
                result.structured_content.unwrap()["code"],
                "invalid_arguments"
            );
        }
    }

    #[test]
    fn pptx_slide_section_move_roundtrips_both_same_order_directions_and_legacy_move() {
        for item in [
            operation(0, 1, false),
            operation(255, 254, true),
            json!({"op": "slideMove", "id": "slide-0", "index": 2}),
        ] {
            let value = edit(vec![item]);
            let parsed: OfficeEdit = serde_json::from_value(value.clone()).unwrap();
            assert_eq!(serde_json::to_value(parsed).unwrap(), value);
        }
    }

    #[test]
    fn pptx_slide_section_move_rejects_mixed_reordered_or_malformed_requests() {
        for item in [
            operation(0, 0, false),
            operation(0, 1, true),
            operation(0, 2, false),
            operation(255, 0, false),
            operation(0, 255, true),
        ] {
            assert!(serde_json::from_value::<OfficeEdit>(edit(vec![item])).is_err());
        }
        let valid = operation(0, 1, false);
        assert!(
            serde_json::from_value::<OfficeEdit>(edit(vec![valid.clone(), valid.clone()])).is_err()
        );
        assert!(
            serde_json::from_value::<OfficeEdit>(edit(vec![
                valid.clone(),
                json!({"op": "slideMove", "id": "slide-0", "index": 2}),
            ]))
            .is_err()
        );
        for (field, value) in [
            ("sourceIndex", json!(-1)),
            ("targetIndex", json!(256)),
            ("targetIndex", json!(1.0)),
            ("after", json!(null)),
            ("expectedSourceSha256", json!("A".repeat(64))),
            ("sectionGroup", json!(0)),
        ] {
            let mut invalid = valid.clone();
            invalid[field] = value;
            assert!(
                serde_json::from_value::<OfficeEdit>(edit(vec![invalid])).is_err(),
                "{field}"
            );
        }
        for field in valid.as_object().unwrap().keys() {
            let mut invalid = valid.clone();
            invalid.as_object_mut().unwrap().remove(field);
            assert!(
                serde_json::from_value::<OfficeEdit>(edit(vec![invalid])).is_err(),
                "{field}"
            );
        }
    }
}

#[cfg(test)]
#[path = "presentation_structure_tests.rs"]
mod presentation_structure_tests;

#[cfg(test)]
#[path = "discussion_tools_tests.rs"]
mod discussion_tools_tests;
