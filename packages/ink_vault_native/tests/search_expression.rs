use ink_vault_native::request_json;
use serde_json::{Value, json};

fn request(value: Value) -> Value {
    request_json(&value.to_string())
}

fn search(query: &str, documents: &Value) -> Value {
    request(json!({"op": "search_expression", "query": query, "documents": documents}))
}

fn ids(result: &Value) -> Vec<&str> {
    result["matches"]
        .as_array()
        .unwrap_or_else(|| panic!("missing matches in {result}"))
        .iter()
        .map(|item| item["id"].as_str().unwrap())
        .collect()
}

#[test]
fn scopes_use_metadata_and_compose_with_grouping_and_negation() {
    let documents = json!([
        {"id": "a", "title": "논문", "markdown": "그래프의 결과", "file": "논문.md",
         "path": "연구 노트/논문.md", "tags": ["연구/그래프"]},
        {"id": "b", "title": "초안", "markdown": "그래프의 초안", "file": "보고서.PDF",
         "path": "보관/보고서.PDF", "tags": ["#연구"]},
        {"id": "c", "title": "강의", "markdown": "#연구 그래프", "file": "강의.md",
         "path": "보관/강의.md", "tags": ["연구자"]},
        {"id": "d", "title": "노트", "markdown": "#연구 그래프", "file": "노트.md",
         "path": "연구 노트/노트.md"}
    ]);
    let result = search(
        r##"path:("연구 노트" OR 보관) tag:#연구 -초안"##,
        &documents,
    );
    assert_eq!(ids(&result), ["a"]);
    assert_eq!(ids(&search("FiLe:.pdf", &documents)), ["b"]);
    assert!(ids(&search("보관", &documents)).is_empty());
    assert!(ids(&search("file:보관", &documents)).is_empty());
    assert!(ids(&search("content:논문", &documents)).is_empty());
    assert_eq!(ids(&search("file:-.md -content:결과", &documents)), ["b"]);
}

#[test]
fn an_unknown_filename_or_path_only_matches_when_negated_outside_the_scope() {
    let documents = json!([
        {"id": "null", "title": "Report.md", "markdown": "", "file": null, "path": null},
        {"id": "missing", "title": "Report.md", "markdown": ""}
    ]);
    assert_eq!(ids(&search("Report", &documents)), ["missing", "null"]);
    for query in ["file:Report", "file:-draft", "path:(-draft OR report)"] {
        assert!(ids(&search(query, &documents)).is_empty(), "{query}");
    }
    assert_eq!(ids(&search("-file:draft", &documents)), ["missing", "null"]);
}

#[test]
fn quotes_match_body_word_edges_but_match_filename_substrings() {
    let documents = json!([
        {"id": "a", "title": "Report", "markdown": "a bobcat jumped, then said \"hello\" to a cat.",
         "file": "Report.md", "path": "notes/Report.md"},
        {"id": "b", "title": "Other", "markdown": "a bobcatapult", "file": "bobcatapult.md",
         "path": "notes/bobcatapult.md"}
    ]);
    assert_eq!(ids(&search(r#"content:"cat""#, &documents)), ["a"]);
    assert_eq!(ids(&search(r#"file:"cat""#, &documents)), ["b"]);
    assert_eq!(
        ids(&search(r#"content:"said \"hello\"""#, &documents)),
        ["a"]
    );
    assert_eq!(
        ids(&search(r#"content:"cat" OR file:"cat""#, &documents)),
        ["b", "a"]
    );
}

#[test]
fn quotes_can_match_overlapping_phrases_and_korean_without_spaces() {
    let documents = json!([
        {"id": "overlap", "title": "Overlap", "markdown": "ba a a"},
        {"id": "korean", "title": "Language", "markdown": "이번한국어수업"}
    ]);
    assert_eq!(ids(&search(r#"content:"a a""#, &documents)), ["overlap"]);
    assert_eq!(ids(&search(r#"content:"한국어""#, &documents)), ["korean"]);
}

#[test]
fn normalizes_decomposed_unicode_and_keeps_uppercase_or_as_an_operator() {
    let documents = json!([
        {"id": "a", "title": "Cafe\u{301}", "markdown": "graph model and a result",
         "file": "Cafe\u{301}.md", "path": "한글/Cafe\u{301}.md", "tags": ["Cafe\u{301}/topic"]},
        {"id": "b", "title": "Other", "markdown": "graph modelling and or", "file": "Other.md"}
    ]);
    assert_eq!(
        ids(&search(
            r#"path:한글 (tag:CAFÉ OR content:"graph model")"#,
            &documents
        )),
        ["a"]
    );
    assert_eq!(ids(&search(r#"content:"graph model""#, &documents)), ["a"]);
    assert_eq!(ids(&search("content:or", &documents)), ["b"]);
}

#[test]
fn scores_title_matches_and_reports_the_actual_phrase_location() {
    let markdown = format!(
        "bobcat {} then a cat is visible.",
        "previous text ".repeat(35)
    );
    let documents = json!([
        {"id": "b", "title": "Body match", "markdown": markdown},
        {"id": "a", "title": "Cat", "markdown": "no matching body"}
    ]);
    let result = search(r#""cat""#, &documents);
    assert_eq!(ids(&result), ["a", "b"]);
    assert!(
        result["matches"][0]["score"].as_u64().unwrap()
            > result["matches"][1]["score"].as_u64().unwrap()
    );
    assert!(
        result["matches"][1]["snippet"]
            .as_str()
            .unwrap()
            .contains("then a cat is visible")
    );
    assert_eq!(ids(&search("-content:cat", &documents)), ["a"]);
}

#[test]
fn opt_in_search_reports_original_utf16_offsets_after_normalization() {
    let prefix = "😀 e\u{301} — ";
    let matched = "Cafe\u{301}";
    let markdown = format!("{prefix}{matched} and later CAFÉ");
    let documents = json!([
        {"id": "body", "title": "Meeting", "markdown": markdown},
        {"id": "title", "title": "Café", "markdown": "no match"}
    ]);
    let plain = request(json!({"op": "search", "query": "CAFÉ", "documents": documents}));
    let mut opted_in = request(json!({
        "op": "search", "query": "CAFÉ", "documents": documents, "includeBodyMatch": true
    }));
    let matches = opted_in["matches"].as_array_mut().unwrap();
    assert_eq!(matches[0]["id"], "title");
    assert!(matches[0].get("bodyMatch").is_none());
    assert_eq!(matches[1]["id"], "body");
    let start = prefix.encode_utf16().count();
    assert_eq!(
        matches[1].as_object_mut().unwrap().remove("bodyMatch"),
        Some(
            json!({"start": start, "end": start + matched.encode_utf16().count(), "text": matched})
        )
    );
    assert_eq!(opted_in, plain);
}

#[test]
fn opt_in_expression_uses_the_earliest_positive_body_hit_with_phrase_edges() {
    let prefix = "😀 bobcat, then a ";
    let documents = json!([{
        "id": "note", "title": "Cat", "markdown": format!("{prefix}CAT and a puppy"),
        "file": "notes.md", "path": "inbox/notes.md", "tags": ["idea"]
    }]);
    let query = r#"file:notes (content:"puppy" OR content:"cat") -tag:archive"#;
    let plain = search(query, &documents);
    let mut opted_in = request(json!({
        "op": "search_expression", "query": query, "documents": documents, "includeBodyMatch": true
    }));
    let result = opted_in["matches"][0].as_object_mut().unwrap();
    let start = prefix.encode_utf16().count();
    assert_eq!(
        result.remove("bodyMatch"),
        Some(json!({"start": start, "end": start + 3, "text": "CAT"}))
    );
    assert_eq!(opted_in, plain);
    for query in ["tag:idea", "file:notes", "path:inbox", "-content:missing"] {
        let result = request(json!({
            "op": "search_expression", "query": query, "documents": documents, "includeBodyMatch": true
        }));
        assert_eq!(ids(&result), ["note"]);
        assert!(result["matches"][0].get("bodyMatch").is_none(), "{query}");
    }
}

#[test]
fn a_normalized_hit_inside_a_case_expansion_has_no_original_range() {
    let documents = json!([{"id": "note", "title": "Entry", "markdown": "İ"}]);
    for op in ["search", "search_expression"] {
        let result = request(
            json!({"op": op, "query": "i", "documents": documents, "includeBodyMatch": true}),
        );
        assert_eq!(ids(&result), ["note"]);
        assert!(result["matches"][0].get("bodyMatch").is_none(), "{op}");
    }
}

#[test]
fn validates_expressions_without_documents_and_rejects_unsupported_syntax() {
    let validate =
        |query: &str| request(json!({"op": "validate_search_expression", "query": query}));
    assert_eq!(
        validate(r#"content:("graph model" OR 한글) -tag:#draft"#),
        json!({"valid": true})
    );
    let long = "😀".repeat(1025);
    let deep = format!("{}x{}", "(".repeat(33), ")".repeat(33));
    let many = "word ".repeat(257);
    for query in [
        r#""""#,
        r#""open"#,
        "file:",
        "tag:#",
        "(x",
        "x)",
        "x OR",
        "OR x",
        "x OR OR y",
        "tag:(x)",
        r#"tag:"x""#,
        "tag:-x",
        "unknown:x",
        "path:(tag:x)",
        "/regex/",
        "[property]",
        "-",
        "x\0y",
        &long,
        &deep,
        &many,
    ] {
        assert_eq!(
            validate(query)["error"]["code"],
            "invalid_search_expression",
            "query {query:?}"
        );
        assert_eq!(
            search(query, &json!([]))["error"]["code"],
            "invalid_search_expression",
            "query {query:?}"
        );
    }
    assert_eq!(validate(&"😀".repeat(1024)), json!({"valid": true}));
    assert!(ids(&search("  ", &json!([]))).is_empty());
}
