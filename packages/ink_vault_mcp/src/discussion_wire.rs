use super::{deserialize_non_null_option, schemars};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListPageDiscussions {
    pub note_id: String,
    /// Select a single thread and page its replies.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "String")]
    pub thread_id: Option<String>,
    /// Exclusive thread cursor in the page's discussion list.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "String")]
    pub after_thread_id: Option<String>,
    /// Exclusive reply cursor for the selected thread.
    #[serde(
        default,
        deserialize_with = "deserialize_non_null_option",
        skip_serializing_if = "Option::is_none"
    )]
    #[schemars(with = "String")]
    pub after_reply_id: Option<String>,
    /// 1..100 records per page.
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
pub struct MutatePageDiscussion {
    pub note_id: String,
    /// Exact page metadata revision observed before the operation.
    pub expected_metadata_revision_id: String,
    /// Exact saved page body state observed before the operation.
    pub expected_body: DiscussionExpectedBody,
    /// Stable operation ID reused with the same scope and payload on retry.
    pub request_id: String,
    pub action: PageDiscussionAction,
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[schemars(extend("type" = "object"))]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum DiscussionExpectedBody {
    Empty {},
    Saved { revision_id: String },
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[schemars(extend("type" = "object"))]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum PageDiscussionAction {
    CreateThread {
        anchor: PageDiscussionAnchor,
        /// Comment text, at most 8 KiB in UTF-8.
        #[schemars(length(min = 1, max = 8192))]
        body: String,
    },
    Reply {
        thread_id: String,
        reply_to_id: String,
        /// Reply text, at most 8 KiB in UTF-8.
        #[schemars(length(min = 1, max = 8192))]
        body: String,
    },
    SetResolved {
        thread_id: String,
        resolved: bool,
        /// All observed status heads, including every branch of a conflict.
        #[schemars(length(min = 1, max = 1024))]
        expected_status_ids: Vec<String>,
    },
}

#[derive(Deserialize, Serialize, schemars::JsonSchema)]
#[schemars(extend("type" = "object"))]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum PageDiscussionAnchor {
    Page {},
    Block {
        block_id: String,
    },
    Quote {
        block_id: String,
        /// Inclusive UTF-16 offset in the saved block text.
        start_utf16: u32,
        /// Exclusive UTF-16 offset in the saved block text.
        end_utf16: u32,
    },
}
