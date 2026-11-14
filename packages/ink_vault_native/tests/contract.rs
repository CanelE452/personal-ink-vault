use ink_vault_native::request_json;
use serde_json::{Value, json};

fn request(value: Value) -> Value {
    request_json(&value.to_string())
}

fn revision() -> Value {
    json!({
        "formatVersion": 1,
        "vaultId": "11111111-1111-4111-8111-111111111111",
        "entityId": "22222222-2222-4222-8222-222222222222",
        "revisionId": "33333333-3333-4333-8333-333333333333",
        "deviceId": "44444444-4444-4444-8444-444444444444",
        "kind": "markdown", "parentRevisionIds": [], "ownerNoteId": null,
        "deleted": false,
        "blobs": {"document.md": {"hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "length": 3}},
        "baseRefs": {}
    })
}

#[test]
fn search_requires_all_literal_terms_and_ranks_title_before_body() {
    let result = request(json!({"op":"search", "query":"rust 안전", "documents":[
        {"id":"a","title":"Rust 안전","markdown":"내용"},
        {"id":"b","title":"Other","markdown":"rust makes 안전 work"},
        {"id":"c","title":"Rust","markdown":"no second term"}
    ]}));
    let matches = result["matches"].as_array().unwrap();
    assert_eq!(
        matches
            .iter()
            .map(|m| m["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["a", "b"]
    );
    assert!(matches[0]["score"].as_u64().unwrap() > matches[1]["score"].as_u64().unwrap());
    assert!(matches[1]["snippet"].as_str().unwrap().contains("안전"));
}

#[test]
fn search_treats_regex_characters_literally_and_normalizes_unicode() {
    let result = request(json!({"op":"search", "query":"CAFÉ [x]", "documents":[
        {"id":"a","title":"Cafe\u{301}","markdown":"[x]"},
        {"id":"b","title":"cafe","markdown":"x"}
    ]}));
    assert_eq!(result["matches"][0]["id"], "a");
    assert_eq!(result["matches"].as_array().unwrap().len(), 1);
}

#[test]
fn workspace_segment_keys_match_knowledge_path_normalization() {
    let operation = "normalize_workspace_segments";
    assert_eq!(
        request(json!({"op": operation, "segments": ["Cafe\u{301}", "CAFÉ", "한글", "한글", "도서/Note"]})),
        json!({"segments": ["café", "café", "한글", "한글", "도서/note"]})
    );
    for input in [json!([""]), json!([42]), json!(["a".repeat(1025)]), json!(vec!["x"; 10001])] {
        assert_eq!(
            request(json!({"op": operation, "segments": input}))["error"]["code"],
            "invalid_request"
        );
    }
}

#[test]
fn search_empty_query_is_empty_and_duplicate_document_ids_are_rejected() {
    assert_eq!(
        request(json!({"op":"search","query":" ","documents":[]}))["matches"],
        json!([])
    );
    let result = request(json!({"op":"search","query":"x","documents":[
        {"id":"a","title":"X","markdown":""},{"id":"a","title":"Y","markdown":""}
    ]}));
    assert_eq!(result["error"]["code"], "invalid_request");
}

#[test]
fn analyze_resolves_wiki_alias_page_markdown_and_nested_tags() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":"a","title":"Source","markdown":"[[CAFÉ|표시]] [[b#page-2]] [note](b.md#section) #Study/Math #study\n```md\n[[missing]] #hidden\n```\n`[[inline]] #code`"},
        {"id":"b","title":"Cafe\u{301}","markdown":""}
    ]}));
    assert_eq!(result["edges"], json!([{"from":"a","to":"b"}]));
    assert_eq!(result["unresolved"], json!([]));
    assert_eq!(
        result["documents"][0]["tags"],
        json!(["study", "study/math"])
    );
    assert_eq!(result["documents"][0]["links"].as_array().unwrap().len(), 3);
    assert_eq!(result["documents"][0]["links"][1]["targetId"], "b");
    assert_eq!(result["documents"][0]["links"][1]["anchor"], "page-2");
}

#[test]
fn analyze_does_not_guess_ambiguous_titles_or_count_external_urls_as_unresolved() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":"a","title":"Source","markdown":"[[Same]] [[missing]] [outside](https://example.com/a)"},
        {"id":"b","title":"Same","markdown":""},
        {"id":"c","title":"same","markdown":""}
    ]}));
    assert_eq!(result["edges"], json!([]));
    assert_eq!(
        result["unresolved"],
        json!([{"from":"a","target":"Same"},{"from":"a","target":"missing"}])
    );
}

#[test]
fn analyze_ignores_html_comments_and_escaped_tags() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":"a","title":"A","markdown":"<!-- [[hidden]] #hidden -->\n\\#escaped normal#word #valid/path"}
    ]}));
    assert_eq!(
        result["documents"][0]["tags"],
        json!(["valid", "valid/path"])
    );
    assert_eq!(result["unresolved"], json!([]));
}

#[test]
fn analyze_excludes_link_syntax_from_tags_and_keeps_normal_paragraph_tags() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":"a","title":"Source","markdown":"[[Graph#오늘]] [[#오늘]] [[#section|#alias]] [fragment](#markdown) [external](https://example.com/#external) ![image](#image) #연구/그래프 #Rust\nA normal paragraph #paragraph\n`[[#inline]] #code`\n```md\n[[#fenced]] #block\n```"},
        {"id":"b","title":"Graph","markdown":""}
    ]}));
    assert_eq!(
        result["documents"][0]["tags"],
        json!(["paragraph", "rust", "연구", "연구/그래프"])
    );
    assert_eq!(
        result["edges"],
        json!([{"from":"a","to":"a"},{"from":"a","to":"b"}])
    );
    assert_eq!(result["unresolved"], json!([]));
}

#[test]
fn analyze_preserves_wiki_percent_literals_and_decodes_markdown_filename_and_anchor_separately() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":"a","title":"Source","markdown":"#Cafe\u{301} [encoded](A%23B.md#Sec%20One) [[A%20B]]"},
        {"id":"b","title":"A#B","markdown":""},
        {"id":"c","title":"A%20B","markdown":""},
        {"id":"d","title":"A B","markdown":""}
    ]}));
    assert_eq!(
        result["edges"],
        json!([{"from":"a","to":"b"},{"from":"a","to":"c"}])
    );
    assert_eq!(result["documents"][0]["links"][0]["anchor"], "Sec One");
    assert_eq!(result["documents"][0]["tags"], json!(["café"]));
}

#[test]
fn folder_move_accepts_root_or_unrelated_parent_and_returns_ids() {
    for parent in [Value::Null, json!("c")] {
        let result = request(json!({"op":"folder_move","folders":[
            {"id":"a","parentId":null},{"id":"b","parentId":"a"},{"id":"c","parentId":null}
        ],"id":"b","parentId":parent}));
        assert_eq!(result, json!({"valid":true,"id":"b","parentId":parent}));
    }
}

#[test]
fn folder_move_rejects_cycles_self_missing_and_existing_malformed_graphs() {
    let folders = json!([{"id":"a","parentId":null},{"id":"b","parentId":"a"}]);
    for (id, parent, code) in [
        ("a", "b", "folder_cycle"),
        ("a", "a", "folder_cycle"),
        ("a", "missing", "folder_missing"),
        ("missing", "a", "folder_missing"),
    ] {
        assert_eq!(
            request(json!({"op":"folder_move","folders":folders,"id":id,"parentId":parent}))["error"]
                ["code"],
            code
        );
    }
    let cyclic = json!([{"id":"a","parentId":"b"},{"id":"b","parentId":"a"}]);
    assert_eq!(
        request(json!({"op":"folder_move","folders":cyclic,"id":"a","parentId":null}))["error"]["code"],
        "folder_cycle"
    );
}

#[test]
fn validates_existing_v1_and_v2_revision_schema_without_mutation() {
    let first = revision();
    assert_eq!(
        request(json!({"op":"validate_revision","revision":first})),
        json!({"valid":true,"formatVersion":1})
    );
    let mut second = revision();
    second["formatVersion"] = json!(2);
    second["kind"] = json!("attachment");
    assert_eq!(
        request(json!({"op":"validate_revision","revision":second})),
        json!({"valid":true,"formatVersion":2})
    );
}

#[test]
fn revision_rejects_invalid_uuid_hash_length_paths_version_and_parents() {
    let mut cases = Vec::new();
    let mut value = revision();
    value["formatVersion"] = json!(3);
    cases.push(value);
    let mut value = revision();
    value["kind"] = json!("attachment");
    cases.push(value);
    let mut value = revision();
    value["entityId"] = json!("bad");
    cases.push(value);
    let mut value = revision();
    value["blobs"]["document.md"]["hash"] = json!("bad");
    cases.push(value);
    let mut value = revision();
    value["blobs"]["document.md"]["length"] = json!(-1);
    cases.push(value);
    let mut value = revision();
    value["blobs"]["document.md"]["length"] = json!(1.5);
    cases.push(value);
    let mut value = revision();
    value["blobs"]["document.md"]["length"] = json!(9223372036854775808u64);
    cases.push(value);
    let mut value = revision();
    value["blobs"] = json!({"../bad":{"hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","length":0}});
    cases.push(value);
    let mut value = revision();
    value["parentRevisionIds"] = json!([value["revisionId"], value["revisionId"]]);
    cases.push(value);
    let mut value = revision();
    value["ownerNoteId"] = json!("bad");
    cases.push(value);
    let mut value = revision();
    value["kind"] = json!("folder");
    value["formatVersion"] = json!(2);
    value["ownerNoteId"] = value["entityId"].clone();
    cases.push(value);
    let mut value = revision();
    value["baseRefs"] = json!({"22222222-2222-4222-8222-222222222222":["33333333-3333-4333-8333-333333333333","33333333-3333-4333-8333-333333333333"]});
    cases.push(value);
    for invalid in cases {
        assert_eq!(
            request(json!({"op":"validate_revision","revision":invalid}))["error"]["code"],
            "invalid_revision"
        );
    }
}

#[test]
fn hashes_exact_bytes_and_rejects_non_byte_values() {
    assert_eq!(
        request(json!({"op":"sha256","bytes":[97,98,99]}))["sha256"],
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        request(json!({"op":"sha256","bytes":[256]}))["error"]["code"],
        "invalid_request"
    );
}

#[test]
fn returns_structured_errors_for_malformed_requests() {
    assert_eq!(request_json("{")["error"]["code"], "invalid_json");
    assert_eq!(request_json("[]")["error"]["code"], "invalid_request");
    assert_eq!(
        request(json!({"op":"future"}))["error"]["code"],
        "unknown_operation"
    );
    assert_eq!(
        request(json!({"op":"search","documents":[],"query":null}))["error"]["code"],
        "invalid_request"
    );
}
