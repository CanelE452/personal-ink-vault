use ink_vault_native::request_json;
use serde_json::{Value, json};

const SOURCE: &str = "11111111-1111-4111-8111-111111111111";
const TARGET: &str = "22222222-2222-4222-8222-222222222222";
const OTHER: &str = "33333333-3333-4333-8333-333333333333";

fn request(value: Value) -> Value {
    request_json(&value.to_string())
}

#[test]
fn unlinked_mentions_preserve_unicode_offsets_and_skip_protected_markdown() {
    let text = concat!(
        "\u{feff}---\r\naliases: [Plan, 알파]\r\n...\r\n",
        "🙂 PLAN, **알파**, New York City, NYC, (R&D), New Yorkshire.\r\n",
        "Planet 9plan plané 계획알파안.\r\n",
        "[[Plan]] ![[알파]] [Plan](https://example.com) ![알파](image.png)\r\n",
        "`Plan` <mark>알파</mark> &amp;\r\n",
        "\r\n```md\r\nPlan 알파\r\n```\r\n",
    );
    let result = request(json!({
        "op":"find_unlinked_mentions", "targetId":TARGET,
        "names":["Plan", "알파", "New", "New York", "York City", "NYC", "(R&D)", "amp"],
        "documents":[{"id":TARGET,"markdown":"Plan"},{"id":SOURCE,"markdown":text}],
        "limit":10,
    }));
    let find = |literal: &str, at: usize| {
        let start = text[..at].encode_utf16().count();
        json!({"sourceId":SOURCE,"start":start,"end":start+literal.encode_utf16().count(),"text":literal})
    };
    assert_eq!(
        result,
        json!({"mentions":[
        find("PLAN",text.find("PLAN").unwrap()),
        find("알파",text.find("**알파").unwrap()+2),
        find("New York",text.find("New York City").unwrap()),
        find("NYC",text.find("NYC").unwrap()),
        find("(R&D)",text.find("(R&D)").unwrap()),
        find("New",text.find("New Yorkshire").unwrap()),
    ],"truncated":false})
    );
}

#[test]
fn unlinked_mentions_limit_is_global_and_ignores_duplicate_names() {
    let docs = json!([{"id":OTHER,"markdown":"(plan)"},{"id":SOURCE,"markdown":"PLAN. Plan."}]);
    let scan = |limit| {
        request(json!({"op":"find_unlinked_mentions", "targetId":TARGET,
            "names":["Plan", "PLAN", "plan"],"documents":docs,"limit":limit}))
    };
    assert_eq!(
        scan(2),
        json!({"mentions":[
        {"sourceId":OTHER,"start":1,"end":5,"text":"plan"},
        {"sourceId":SOURCE,"start":0,"end":4,"text":"PLAN"},
    ],"truncated":true})
    );
    assert_eq!(
        scan(3),
        json!({"mentions":[
        {"sourceId":OTHER,"start":1,"end":5,"text":"plan"},
        {"sourceId":SOURCE,"start":0,"end":4,"text":"PLAN"},
        {"sourceId":SOURCE,"start":6,"end":10,"text":"Plan"},
    ],"truncated":false})
    );
    assert_eq!(scan(129)["error"]["code"], "invalid_request");
}

#[test]
fn unlinked_mentions_use_unicode_word_boundaries_and_literal_punctuation() {
    let result = request(json!({
        "op":"find_unlinked_mentions", "targetId":TARGET,
        "names":["Plan", "(Plan)", "C++", "[Plan]"],
        "documents":[{"id":SOURCE,"markdown":concat!(
            "αPLAN PLAN\u{301} ²PLAN _PLAN_ prefix(Plan)suffix C++ c+ [Plan] ",
            "<https://example.test/Plan>",
        )}],
        "limit":10,
    }));
    let labels: Vec<_> = result["mentions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|mention| mention["text"].as_str().unwrap())
        .collect();
    assert_eq!(labels, ["PLAN", "(Plan)", "C++", "[Plan]"]);
}

#[test]
fn unlinked_mentions_reject_oversized_batches_and_names() {
    let scan = |names, documents| {
        request(json!({"op":"find_unlinked_mentions", "targetId":TARGET,
            "names":names,"documents":documents,"limit":128}))
    };
    let max_bytes = "é".repeat(1024 * 512);
    let target = json!({"id":TARGET,"markdown":max_bytes});
    assert_eq!(
        scan(json!(["Plan"]), json!([target])),
        json!({"mentions":[],"truncated":false})
    );
    assert_eq!(
        scan(
            json!(["Plan"]),
            json!([target, {"id":SOURCE,"markdown":"a"}])
        )["error"]["code"],
        "invalid_request"
    );
    assert_eq!(
        scan(json!(["🙂".repeat(128)]), json!([]))["error"]["code"],
        "invalid_request"
    );
    let too_many: Vec<_> = (0..17)
        .map(|index| json!({"id":index.to_string(),"markdown":""}))
        .collect();
    assert_eq!(
        scan(json!(["Plan"]), json!(too_many))["error"]["code"],
        "invalid_request"
    );
}

#[test]
fn portable_obsidian_uses_allocated_paths_and_preserves_link_labels_and_anchors() {
    let text = format!(
        "🖋 [[Shared#방법|보기]] ![[/Media/Article.pdf#page=2]]\n\
         [요약](inkvault://note/{OTHER}?view=markdown#내용 \"title\")\n\
         ![표](<../Media/Figure%20One.png> \"image\") [사이트](https://example.com/path)\n\
         [루트](Media/Article.pdf#page=3)\n\
         `[[Shared]]` [[Missing]]\n"
    );
    let pdf = OTHER;
    let figure = "44444444-4444-4444-8444-444444444444";
    let result = request(json!({
        "op":"portable_obsidian_links",
        "documents":[
            {"id":SOURCE,"title":"Start","paths":["Notes/Start.md"],"markdown":text},
            {"id":TARGET,"title":"Shared","paths":["Notes/Shared.md"],"markdown":""},
            {"id":pdf,"title":"Article","attachmentPaths":["Media/Article.pdf"],"markdown":""},
            {"id":figure,"title":"Figure","attachmentPaths":["Media/Figure One.png"],"markdown":""}
        ],
        "paths":{
            SOURCE:{"primary":"Study/Start.md","markdown":"Study/Start.md"},
            TARGET:{"primary":"Study/Shared (2).md","markdown":"Study/Shared (2).md"},
            pdf:{"primary":"Assets/Paper.pdf","markdown":"Assets/Paper 요약.md"},
            figure:{"primary":"Assets/Figure One.png"}
        }
    }));
    assert!(result.get("error").is_none(), "{result}");
    assert_eq!(
        result["documents"][SOURCE]["markdown"],
        concat!(
            "🖋 [[/Study/Shared (2)#방법|보기]] ![[/Assets/Paper.pdf#page=2]]\n",
            "[요약](../Assets/Paper%20%EC%9A%94%EC%95%BD.md#%EB%82%B4%EC%9A%A9 \"title\")\n",
            "![표](<../Assets/Figure%20One.png> \"image\") [사이트](https://example.com/path)\n",
            "[루트](../Assets/Paper.pdf#page=3)\n",
            "`[[Shared]]` [[Missing]]\n"
        )
    );
    assert_eq!(result["documents"][SOURCE]["warnings"], json!(["Missing"]));
}

#[test]
fn portable_obsidian_rewrites_reference_definitions_without_touching_code() {
    let text = format!(
        "[원본][paper] [원본][paper]\n\n\
         [paper]: inkvault://note/{TARGET}?view=markdown#^proof \"keep\"\n\n\
         ```md\n[paper]: inkvault://note/{TARGET}?view=markdown\n```\n"
    );
    let result = request(json!({
        "op":"portable_obsidian_links",
        "documents":[
            {"id":SOURCE,"title":"Start","paths":["Start.md"],"markdown":text},
            {"id":TARGET,"title":"Proof","paths":["Proof.md"],"markdown":""}
        ],
        "paths":{
            SOURCE:{"primary":"Start.md","markdown":"Start.md"},
            TARGET:{"primary":"Proof.md","markdown":"Proof.md"}
        }
    }));
    assert!(result.get("error").is_none(), "{result}");
    assert_eq!(
        result["documents"][SOURCE]["markdown"],
        text.replacen(
            &format!("inkvault://note/{TARGET}?view=markdown#^proof"),
            "./Proof.md#^proof",
            1
        )
    );
    assert_eq!(result["documents"][SOURCE]["warnings"], json!([]));
}

#[test]
fn portable_obsidian_rejects_output_path_escape() {
    let result = request(json!({
        "op":"portable_obsidian_links",
        "documents":[document(SOURCE, "Start", "[[#Self]]")],
        "paths":{SOURCE:{"primary":"../Start.md","markdown":"../Start.md"}}
    }));
    assert!(result.get("error").is_some(), "{result}");
}

fn document(id: &str, title: &str, markdown: &str) -> Value {
    json!({"id":id,"title":title,"markdown":markdown})
}

fn analyzed(markdown: &str, targets: Vec<Value>) -> Value {
    let mut documents = vec![document(SOURCE, "Source", markdown)];
    documents.extend(targets);
    let result = request(json!({"op":"analyze_documents","documents":documents}));
    assert!(result.get("error").is_none(), "{result}");
    result
}

fn source_links(result: &Value) -> &Vec<Value> {
    result["documents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|document| document["id"] == SOURCE)
        .unwrap()["links"]
        .as_array()
        .unwrap()
}

fn rewrite(text: &str, targets: Vec<Value>) -> Value {
    let mut documents = vec![document(SOURCE, "Source", text)];
    documents.extend(targets);
    let result = request(json!({
        "op":"rewrite_note_links", "documents":documents,
        "sourceId":SOURCE, "targetId":TARGET, "text":text
    }));
    assert!(result.get("error").is_none(), "{result}");
    result
}

fn utf16_span(text: &str, needle: &str) -> (usize, usize) {
    let byte = text.find(needle).unwrap();
    let start = text[..byte].encode_utf16().count();
    (start, start + needle.encode_utf16().count())
}

fn assert_replacement(text: &str, value: &Value, original: &str, replacement: &str) {
    let (start, end) = utf16_span(text, original);
    assert_eq!(value["start"], start);
    assert_eq!(value["end"], end);
    assert_eq!(value["original"], original);
    assert_eq!(value["replacement"], replacement);
    let units: Vec<u16> = text.encode_utf16().collect();
    assert_eq!(String::from_utf16(&units[start..end]).unwrap(), original);
}

fn apply_replacements(text: &str, result: &Value) -> String {
    let mut units: Vec<u16> = text.encode_utf16().collect();
    let replacements = result["replacements"].as_array().unwrap();
    let mut previous_end = 0;
    for change in replacements {
        let start = change["start"].as_u64().unwrap() as usize;
        let end = change["end"].as_u64().unwrap() as usize;
        assert!(start >= previous_end && end > start);
        assert_eq!(
            String::from_utf16(&units[start..end]).unwrap(),
            change["original"].as_str().unwrap()
        );
        previous_end = end;
    }
    for change in replacements.iter().rev() {
        let start = change["start"].as_u64().unwrap() as usize;
        let end = change["end"].as_u64().unwrap() as usize;
        units.splice(
            start..end,
            change["replacement"].as_str().unwrap().encode_utf16(),
        );
    }
    String::from_utf16(&units).unwrap()
}

#[test]
fn actual_lookup_titles_are_separate_from_display_and_aliases_deduplicate_note_ids() {
    let result = analyzed(
        "[[Before]] [[After]] [[Legacy]] [[AFTER.md]] [[Before / After]]",
        vec![json!({"id":TARGET,"title":"Before / After","markdown":"",
            "lookupTitles":["Before","After","After"],"aliases":["Legacy","legacy","Before"]})],
    );
    let links = source_links(&result);
    assert_eq!(links.len(), 5);
    for link in &links[..4] {
        assert_eq!(link["targetId"], TARGET);
    }
    assert!(links[4]["targetId"].is_null());
    assert_eq!(result["edges"], json!([{"from":SOURCE,"to":TARGET}]));
}

#[test]
fn explicit_empty_lookup_titles_does_not_invent_a_conflict_display_alias() {
    let result = analyzed(
        "[[Display]] [[Kept]]",
        vec![json!({"id":TARGET,"title":"Display","markdown":"",
            "lookupTitles":[],"aliases":["Kept"]})],
    );
    let links = source_links(&result);
    assert!(links[0]["targetId"].is_null());
    assert_eq!(links[1]["targetId"], TARGET);
}

#[test]
fn a_current_title_cannot_silently_capture_another_notes_historical_alias() {
    let result = analyzed(
        &format!("[[Before]] [[After]] [[{TARGET}]]"),
        vec![
            json!({"id":TARGET,"title":"After","markdown":"","aliases":["Before"]}),
            document(OTHER, "Before", ""),
        ],
    );
    let links = source_links(&result);
    assert!(links[0]["targetId"].is_null());
    assert_eq!(links[1]["targetId"], TARGET);
    assert_eq!(links[2]["targetId"], TARGET);
}

#[test]
fn explicit_relative_and_root_paths_resolve_in_source_context_without_basename_fallback() {
    let text = "[parent](../Target.md#Hello%20World) [[../Target#Topic]] [root](/Courses/Target.md) [missing](./Missing/Target.md) [escape](../../../Target.md)";
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":SOURCE,"title":"Source","markdown":text,"paths":["Courses/Week/Source.md"]},
        {"id":TARGET,"title":"Target","markdown":"","paths":["Courses/Target.md"]},
        {"id":OTHER,"title":"Target","markdown":"","paths":["Other/Target.md"]}
    ]}));
    assert!(result.get("error").is_none(), "{result}");
    let links = source_links(&result);
    assert_eq!(links.len(), 5);
    for link in &links[..3] {
        assert_eq!(link["targetId"], TARGET);
    }
    assert_eq!(links[0]["anchor"], "Hello World");
    assert_eq!(links[1]["anchor"], "Topic");
    assert!(links[3]["targetId"].is_null());
    assert!(links[4]["targetId"].is_null());
}

#[test]
fn wiki_folder_suffix_resolves_only_unprefixed_paths_at_a_segment_boundary() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":SOURCE,"title":"Source","markdown":
            "[[Topics/Note]] [[TOPICS/NOTE.MD#Topic|Alias]] [[/Topics/Note]] [[./Topics/Note]] [[../Topics/Note]] [relative](Topics/Note)",
            "paths":["Course/Reading/Source.md"]},
        {"id":TARGET,"title":"Note","markdown":"",
            "paths":["Archive/Topics/Note.md","Backup/Topics/Note.md"]},
        {"id":OTHER,"title":"Note","markdown":"","paths":["Archive/OldTopics/Note.md"]}
    ]}));
    assert!(result.get("error").is_none(), "{result}");
    let links = source_links(&result);
    assert_eq!(links.len(), 6);
    assert_eq!(links[0]["targetId"], TARGET);
    assert_eq!(links[1]["targetId"], TARGET);
    assert_eq!(links[1]["anchor"], "Topic");
    for link in &links[2..] {
        assert!(link["targetId"].is_null(), "{link}");
    }
}

#[test]
fn wiki_folder_suffix_keeps_exact_root_priority_then_prefers_the_source_directory() {
    let root = json!({"id":TARGET,"title":"Note","markdown":"","paths":["Topics/Note.md"]});
    let local = json!({"id":OTHER,"title":"Note","markdown":"","paths":["A/Topics/Note.md"]});
    let outside = json!({"id":TARGET,"title":"Note","markdown":"","paths":["B/Topics/Note.md"]});
    let source = |paths: &[&str]| json!({"id":SOURCE,"title":"Source","markdown":"[[Topics/Note]]","paths":paths});
    for (from, first, expected) in [
        (source(&["A/Source.md"]), root, json!(TARGET)),
        (source(&["A/Source.md"]), outside.clone(), json!(OTHER)),
        (source(&["C/Source.md"]), outside.clone(), Value::Null),
        (
            source(&["A/Source.md", "B/Source.md"]),
            outside,
            Value::Null,
        ),
    ] {
        let result = request(json!({"op":"analyze_documents","documents":[from, first, local]}));
        assert!(result.get("error").is_none(), "{result}");
        assert_eq!(source_links(&result)[0]["targetId"], expected, "{result}");
    }
}

#[test]
fn multiple_source_paths_do_not_choose_between_different_destination_notes() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":SOURCE,"title":"Source","markdown":"[relative](./Target.md)",
            "paths":["A/Source.md","B/Source.md"]},
        {"id":TARGET,"title":"Target","markdown":"","paths":["A/Target.md"]},
        {"id":OTHER,"title":"Target","markdown":"","paths":["B/Target.md"]}
    ]}));
    assert!(result.get("error").is_none(), "{result}");
    assert!(source_links(&result)[0]["targetId"].is_null());
}

#[test]
fn bare_markdown_is_directory_relative_and_unqualified_wiki_prefers_local_then_global_names() {
    let source = json!({"id":SOURCE,"title":"Source","markdown":
        format!("[relative](Target.md) [[Target]] [[{TARGET}]]"),"paths":["A/Source.md"]});
    let target = json!({"id":TARGET,"title":"Target","markdown":"","paths":["B/Target.md"]});
    let result =
        request(json!({"op":"analyze_documents","documents":[source.clone(),target.clone()]}));
    assert!(result.get("error").is_none(), "{result}");
    let links = source_links(&result);
    assert!(links[0]["targetId"].is_null());
    assert_eq!(links[1]["targetId"], TARGET);
    assert_eq!(links[2]["targetId"], TARGET);

    let mut unavailable = source.clone();
    unavailable["paths"] = json!([]);
    let no_context =
        request(json!({"op":"analyze_documents","documents":[unavailable,target.clone()]}));
    assert!(no_context.get("error").is_none(), "{no_context}");
    assert!(source_links(&no_context)[0]["targetId"].is_null());
    assert_eq!(source_links(&no_context)[1]["targetId"], TARGET);

    let local = json!({"id":OTHER,"title":"Local display","markdown":"","paths":["A/Target.md"]});
    let result = request(json!({"op":"analyze_documents","documents":[source,target,local]}));
    assert!(result.get("error").is_none(), "{result}");
    let links = source_links(&result);
    assert_eq!(links[0]["targetId"], OTHER);
    assert_eq!(links[1]["targetId"], OTHER);
    assert_eq!(links[2]["targetId"], TARGET);
}

#[test]
fn canonical_path_collisions_are_ambiguous_and_duplicate_paths_of_one_note_are_not() {
    let result = analyzed(
        "[unique](/A/One.md) [ambiguous](/B/Cafe%CC%81.md)",
        vec![
            json!({"id":TARGET,"title":"One","markdown":"",
                "paths":["A/One.md","a/one.md","B/Café.md"]}),
            json!({"id":OTHER,"title":"Two","markdown":"","paths":["b/Cafe\u{301}.md"]}),
        ],
    );
    let links = source_links(&result);
    assert_eq!(links[0]["targetId"], TARGET);
    assert!(links[1]["targetId"].is_null());
}

#[test]
fn markdown_paths_decode_once_but_wiki_percent_sequences_are_literal() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":SOURCE,"title":"Source","markdown":"[literal](./A%2520B.md#H%20%23%25) [[./A%20B.md]] [space](./A%20B.md)",
            "paths":["Notes/Source.md"]},
        {"id":TARGET,"title":"Literal","markdown":"","paths":["Notes/A%20B.md"]},
        {"id":OTHER,"title":"Space","markdown":"","paths":["Notes/A B.md"]}
    ]}));
    assert!(result.get("error").is_none(), "{result}");
    let links = source_links(&result);
    assert_eq!(links[0]["targetId"], TARGET);
    assert_eq!(links[0]["anchor"], "H #%");
    assert_eq!(links[1]["targetId"], TARGET);
    assert_eq!(links[2]["targetId"], OTHER);
}

#[test]
fn imported_attachment_paths_keep_filename_and_do_not_shadow_explicit_markdown_paths() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":SOURCE,"title":"Source","paths":["Course/Week/Source.md"],"markdown":
            "[original](../Assets/Cafe%CC%81%20Plan.PNG) [[/Course/Assets/Café Plan.png]] ![[Assets/Café Plan.png|480]] [[Café Plan.png]] [[/Course/Assets/Café Plan.PNG.md]] [summary](../Assets/Caf%C3%A9%20Plan.PNG.md)"},
        {"id":TARGET,"title":"Café Plan","paths":["Course/Assets/Café Plan.md"],"markdown":"",
            "attachmentPaths":["Course/Assets/Café Plan.PNG"]},
        {"id":OTHER,"title":"Café Plan.PNG","paths":["Course/Assets/Café Plan.PNG.md"],"markdown":"",
            "aliases":["Café Plan.png"]}
    ]}));
    assert!(result.get("error").is_none(), "{result}");
    let links = source_links(&result);
    assert_eq!(links.len(), 6);
    for link in &links[..4] {
        assert_eq!(link["targetId"], TARGET, "{link}");
        assert_eq!(link["attachmentName"], "Café Plan.PNG", "{link}");
    }
    for link in &links[4..] {
        assert_eq!(link["targetId"], OTHER, "{link}");
        assert!(link.get("attachmentName").is_none(), "{link}");
    }
    assert_eq!(
        result["edges"],
        json!([
            {"from":SOURCE,"to":TARGET,"attachmentName":"Café Plan.PNG"},
            {"from":SOURCE,"to":OTHER}
        ])
    );
}

#[test]
fn imported_attachment_paths_keep_explicit_context_and_reject_ambiguous_tiers() {
    let source = |paths: &[&str]| {
        json!({"id":SOURCE,"title":"Source","paths":paths,"markdown":
            "[literal](./Plot%2520A.PNG) [[./Plot%20A.png]] [[Plot%20A.png]] [[Assets/Plot%20A.png]] [[/Assets/Plot%20A.png]] [missing](Assets/Plot%2520A.PNG)"})
    };
    let first = json!({"id":TARGET,"title":"First","markdown":"",
        "attachmentPaths":["A/Plot%20A.PNG","Shelf/Assets/Plot%20A.PNG"]});
    let other = json!({"id":OTHER,"title":"Second","markdown":"","aliases":["Plot%20A.png"],
        "attachmentPaths":["B/Plot%20A.PNG","Shelf/OldAssets/Plot%20A.PNG"]});
    for (from, expected) in [
        (
            source(&["A/Source.md"]),
            [Some(TARGET), Some(TARGET), Some(TARGET)],
        ),
        (source(&["A/Source.md", "B/Source.md"]), [None, None, None]),
        (source(&["C/Source.md"]), [None, None, None]),
    ] {
        let result = request(json!({"op":"analyze_documents","documents":[from,first,other]}));
        assert!(result.get("error").is_none(), "{result}");
        let links = source_links(&result);
        for (link, target) in links.iter().zip(expected) {
            assert_eq!(link["targetId"], json!(target), "{link}");
        }
        assert_eq!(links[3]["targetId"], TARGET);
        assert_eq!(links[3]["attachmentName"], "Plot%20A.PNG");
        for link in &links[4..] {
            assert!(link["targetId"].is_null(), "{link}");
        }
    }
}

#[test]
fn imported_attachment_rewrite_keeps_plain_link_mode_and_reports_unsafe_forms() {
    let text = "😀 [asset](/Assets/Plan.PNG \"keep title\") ![[Assets/Plan.PNG|120]] ![figure](/Assets/Plan.PNG) [[Assets/Plan.PNG|alias]] [page](/Assets/Plan.PNG#page=2)";
    let attachment = json!({"id":TARGET,"title":"Plan","markdown":"",
        "attachmentPaths":["Assets/Plan.PNG"]});
    let result = rewrite(text, vec![attachment.clone()]);
    let replacements = result["replacements"].as_array().unwrap();
    assert_eq!(replacements.len(), 1, "{result}");
    assert_replacement(
        text,
        &replacements[0],
        "/Assets/Plan.PNG",
        &format!("inkvault://note/{TARGET}"),
    );
    let unsupported = result["unsupported"].as_array().unwrap();
    assert_eq!(unsupported.len(), 4, "{result}");
    for (value, kind) in unsupported
        .iter()
        .zip(["image", "image", "attachment", "attachment"])
    {
        assert_eq!(value["targetId"], TARGET);
        assert_eq!(value["kind"], kind);
    }
    let updated = apply_replacements(text, &result);
    assert!(updated.contains(&format!("[asset](inkvault://note/{TARGET} \"keep title\")")));
    let analysis = analyzed(&updated, vec![attachment.clone()]);
    assert_eq!(source_links(&analysis)[0]["attachmentName"], "Plan.PNG");
    let stable = rewrite(
        &format!("[asset](inkvault://note/{TARGET})"),
        vec![attachment],
    );
    assert_eq!(stable["replacements"], json!([]));
    assert_eq!(stable["unsupported"], json!([]));
}

#[test]
fn imported_attachment_contract_rejects_invalid_or_markdown_paths() {
    for paths in [
        json!(null),
        json!([7]),
        json!(["/Assets/Plan.PNG"]),
        json!(["Assets/../Plan.PNG"]),
        json!(["Assets/Plan.MD"]),
        json!(["Assets/Plan"]),
        json!(["C:/Plan.PNG"]),
        json!(["Assets\\Plan.PNG"]),
    ] {
        let result = request(json!({"op":"analyze_documents","documents":[
            {"id":TARGET,"title":"Plan","markdown":"","attachmentPaths":paths}
        ]}));
        assert_eq!(result["error"]["code"], "invalid_request", "{result}");
    }
}

#[test]
fn imported_attachment_summary_uses_attachment_folder_as_relative_source_context() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":SOURCE,"title":"Plan.PNG","markdown":"[notes](../Overview.md) ![diagram](Plot.png)",
            "paths":[],"attachmentPaths":["Course/Assets/Plan.PNG"]},
        {"id":TARGET,"title":"Overview","markdown":"","paths":["Course/Overview.md"]},
        {"id":OTHER,"title":"Plot.png","markdown":"","attachmentPaths":["Course/Assets/Plot.png"]}
    ]}));
    assert!(result.get("error").is_none(), "{result}");
    let links = source_links(&result);
    assert_eq!(links[0]["targetId"], TARGET);
    assert!(links[0].get("attachmentName").is_none());
    assert_eq!(links[1]["targetId"], OTHER);
    assert_eq!(links[1]["attachmentName"], "Plot.png");
}

#[test]
fn unavailable_attachment_reserves_its_path_without_opening_markdown_lookalikes() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":SOURCE,"title":"Source","paths":["Course/Source.md"],"markdown":format!(
            "[[/Assets/Deck.PPTX]] [relative](../Assets/Deck.pptx) [[Assets/Deck.pptx]] ![[Deck.pptx]] [[/Assets/Deck.PPTX.md]] [explicit](../Assets/Deck.pptx.md) [stable](inkvault://note/{TARGET})")},
        {"id":TARGET,"title":"Deck.PPTX","lookupTitles":[],"markdown":"",
            "attachmentPaths":["Assets/Deck.PPTX"],"attachmentUnavailable":true},
        {"id":OTHER,"title":"Deck.PPTX","paths":["Assets/Deck.PPTX.md"],"markdown":"",
            "aliases":["Deck.pptx"]}
    ]}));
    assert!(result.get("error").is_none(), "{result}");
    let links = source_links(&result);
    assert_eq!(links.len(), 6, "{result}");
    for link in &links[..4] {
        assert!(link["targetId"].is_null(), "{link}");
        assert!(link.get("attachmentName").is_none(), "{link}");
    }
    for link in &links[4..] {
        assert_eq!(link["targetId"], OTHER, "{link}");
        assert!(link.get("attachmentName").is_none(), "{link}");
    }
    assert_eq!(result["edges"], json!([{"from":SOURCE,"to":OTHER}]));
}

#[test]
fn unavailable_attachment_candidates_do_not_select_a_different_tier_or_break_a_collision() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":SOURCE,"title":"Source","paths":["Local/Source.md"],"markdown":
            "[[Assets/Plan.png]] [[Plan.png]] [[Set/Plan.png]] [[Backup/Set/Plan.png]]"},
        {"id":TARGET,"title":"Plan.PNG","lookupTitles":[],"markdown":"",
            "attachmentPaths":["Assets/Plan.PNG","Local/Plan.PNG","Old/Set/Plan.PNG"],
            "attachmentUnavailable":true},
        {"id":OTHER,"title":"Plan.png","lookupTitles":[],"markdown":"",
            "attachmentPaths":["Local/Assets/Plan.png","Backup/Set/Plan.png","Shelf/Plan.png"],
            "attachmentUnavailable":false}
    ]}));
    assert!(result.get("error").is_none(), "{result}");
    let links = source_links(&result);
    for link in &links[..3] {
        assert!(link["targetId"].is_null(), "{link}");
        assert!(link.get("attachmentName").is_none(), "{link}");
    }
    assert_eq!(links[3]["targetId"], OTHER);
    assert_eq!(links[3]["attachmentName"], "Plan.png");
}

#[test]
fn unavailable_attachment_marker_must_be_a_boolean() {
    let result = request(json!({"op":"analyze_documents","documents":[
        {"id":TARGET,"title":"Plan","markdown":"","attachmentUnavailable":"true",
            "attachmentPaths":["Assets/Plan.PNG"]}
    ]}));
    assert_eq!(result["error"]["code"], "invalid_request", "{result}");
}

#[test]
fn generated_internal_note_uris_remain_visible_to_backlinks() {
    let result = analyzed(
        &format!(
            "[stable](inkvault://note/{TARGET}?view=markdown#Sec%20One) [external](https://example.com/Target.md)"
        ),
        vec![document(TARGET, "After", "")],
    );
    let links = source_links(&result);
    assert_eq!(links.len(), 1);
    assert_eq!(links[0]["targetId"], TARGET);
    assert_eq!(links[0]["anchor"], "Sec One");
    assert_eq!(result["edges"], json!([{"from":SOURCE,"to":TARGET}]));

    let wiki_probe = analyzed(
        "[literal](inkwiki:A%23B%2520%7C%5D#X%23Y%25)",
        vec![document(TARGET, "A#B%20|]", "")],
    );
    let links = source_links(&wiki_probe);
    assert_eq!(links.len(), 1);
    assert_eq!(links[0]["targetId"], TARGET);
    assert_eq!(links[0]["anchor"], "X#Y%");
}

#[test]
fn optional_lookup_fields_require_arrays_of_strings() {
    for (field, value) in [
        ("lookupTitles", json!({})),
        ("aliases", json!("Before")),
        ("paths", json!([7])),
    ] {
        let mut target = document(TARGET, "Target", "");
        target.as_object_mut().unwrap().insert(field.into(), value);
        let result = request(json!({"op":"analyze_documents","documents":[target]}));
        assert_eq!(result["error"]["code"], "invalid_request", "{result}");
    }
}

#[test]
fn rewrite_wiki_links_preserves_aliases_anchors_and_exact_utf16_source_spans() {
    let text = "😀 前 [[Before#정리|보이는 이름]] and [[Before]]";
    let result = rewrite(text, vec![document(TARGET, "Before", "")]);
    let changes = result["replacements"].as_array().unwrap();
    assert_eq!(changes.len(), 2);
    assert_replacement(
        text,
        &changes[0],
        "[[Before#정리|보이는 이름]]",
        &format!("[[{TARGET}#정리|보이는 이름]]"),
    );
    assert_replacement(
        text,
        &changes[1],
        "[[Before]]",
        &format!("[[{TARGET}|Before]]"),
    );
    assert_eq!(result["unsupported"], json!([]));
    let normalized = apply_replacements(text, &result);
    let repeated = rewrite(&normalized, vec![document(TARGET, "Before", "")]);
    assert_eq!(repeated["replacements"], json!([]));
    assert_eq!(repeated["unsupported"], json!([]));
}

#[test]
fn rewrite_markdown_changes_only_href_and_keeps_raw_fragment_angle_brackets_and_title() {
    let text = "😀 [label *fmt*](<Before.md#Sec%20One> \"Keep title\")";
    let result = rewrite(text, vec![document(TARGET, "Before", "")]);
    let changes = result["replacements"].as_array().unwrap();
    assert_eq!(changes.len(), 1);
    let destination = format!("inkvault://note/{TARGET}?view=markdown#Sec%20One");
    assert_replacement(text, &changes[0], "Before.md#Sec%20One", &destination);
    let normalized = apply_replacements(text, &result);
    assert_eq!(
        normalized,
        format!("😀 [label *fmt*](<{destination}> \"Keep title\")")
    );
    let roundtrip = analyzed(&normalized, vec![document(TARGET, "After", "")]);
    assert_eq!(source_links(&roundtrip)[0]["targetId"], TARGET);
    assert_eq!(source_links(&roundtrip)[0]["anchor"], "Sec One");
    assert_eq!(
        rewrite(&normalized, vec![document(TARGET, "After", "")])["replacements"],
        json!([])
    );
}

#[test]
fn rewrite_ignores_code_comments_escaped_wiki_external_links_and_unrelated_notes() {
    let text = "---\t\nproperty: '[[Before]] #frontmatter'\n...\t\n\n`[[Before]]`\n\n```md\n[[Before]]\n```\n\n<!-- [[Before]] -->\n\n<div>\n[[Before]]\n</div>\n\n<span>[[Before]]</span>\n\n\\[[Before]] [outside](https://example.com/Before.md) [[Other]] [[Before|Visible]]";
    let result = rewrite(
        text,
        vec![document(TARGET, "Before", ""), document(OTHER, "Other", "")],
    );
    let changes = result["replacements"].as_array().unwrap();
    assert_eq!(changes.len(), 1);
    assert_replacement(
        text,
        &changes[0],
        "[[Before|Visible]]",
        &format!("[[{TARGET}|Visible]]"),
    );
    assert_eq!(result["unsupported"], json!([]));
}

#[test]
fn rewrite_does_not_guess_ambiguous_names_or_modify_already_stable_id_links() {
    let text = format!(
        "[[Before]] [[{TARGET}|Stable]] [stable](inkvault://note/{TARGET}?view=markdown#A)"
    );
    let result = rewrite(
        &text,
        vec![
            document(TARGET, "Before", ""),
            document(OTHER, "Before", ""),
        ],
    );
    assert_eq!(result["replacements"], json!([]));
    assert_eq!(result["unsupported"], json!([]));
}

#[test]
fn rewrite_reports_known_reference_links_as_unsupported_instead_of_claiming_success() {
    let text = "😀 [Read this][ref]\n\n[ref]: Before.md#Section \"Keep title\"\n";
    let result = rewrite(text, vec![document(TARGET, "Before", "")]);
    assert_eq!(result["replacements"], json!([]));
    let unsupported = result["unsupported"].as_array().unwrap();
    assert_eq!(unsupported.len(), 1);
    assert_eq!(unsupported[0]["targetId"], TARGET);
    assert_eq!(unsupported[0]["kind"], "reference");
    let (start, end) = utf16_span(text, "[Read this][ref]");
    assert_eq!(unsupported[0]["start"], start);
    assert_eq!(unsupported[0]["end"], end);
    assert_eq!(unsupported[0]["original"], "[Read this][ref]");
}

#[test]
fn rewrite_keeps_note_embeds_with_exact_anchors_and_aliases() {
    let text = "😀 ![[Before]] ![[Before#정리  |  별칭 | label  ]] ![[  Before  #^block|  블록  ]]\n\n`![[Before]]`\n\n```md\n![[Before]]\n```\n\n<!-- ![[Before]] -->";
    let result = rewrite(text, vec![document(TARGET, "Before", "")]);
    assert_eq!(result["unsupported"], json!([]), "{result}");
    let replacements = result["replacements"].as_array().unwrap();
    assert_eq!(replacements.len(), 3, "{result}");
    for (change, (original, replacement)) in replacements.iter().zip([
        ("![[Before]]", format!("![[{TARGET}|Before]]")),
        (
            "![[Before#정리  |  별칭 | label  ]]",
            format!("![[{TARGET}#정리  |  별칭 | label  ]]"),
        ),
        (
            "![[  Before  #^block|  블록  ]]",
            format!("![[  {TARGET}  #^block|  블록  ]]"),
        ),
    ]) {
        assert_replacement(text, change, original, &replacement);
    }
    let rewritten = apply_replacements(text, &result);
    let analysis = analyzed(&rewritten, vec![document(TARGET, "After", "")]);
    let links = source_links(&analysis);
    assert_eq!(links.len(), 3);
    assert!(links.iter().all(|link| link["targetId"] == TARGET));
    assert_eq!(links[1]["anchor"], "정리  ");
    assert_eq!(links[2]["anchor"], "^block");
    assert_eq!(
        rewrite(&rewritten, vec![document(TARGET, "After", "")]),
        json!({"replacements":[],"unsupported":[]})
    );
}

#[test]
fn rewrite_note_embeds_preserves_old_folder_context_after_source_and_target_move() {
    let text = "![[../Before#정리|relative]] ![[/Archive/Before#^same|absolute]] ![[Shared]] ![[Missing]] ![[#Local]]";
    let before = vec![
        json!({"id":SOURCE,"title":"Source","markdown":text,"paths":["Archive/Work/Source.md"]}),
        json!({"id":TARGET,"title":"Before","markdown":"","paths":["Archive/Before.md"],"aliases":["Shared"]}),
        json!({"id":OTHER,"title":"Before","markdown":"","paths":["Destination/Before.md"],"aliases":["Shared"]}),
    ];
    let result = request(json!({"op":"rewrite_note_links","documents":before,
        "sourceId":SOURCE,"targetIds":[TARGET,OTHER,SOURCE],"text":text}));
    assert_eq!(result["unsupported"], json!([]), "{result}");
    let rewritten = apply_replacements(text, &result);
    assert_eq!(
        rewritten,
        format!(
            "![[{TARGET}#정리|relative]] ![[{TARGET}#^same|absolute]] ![[Shared]] ![[Missing]] ![[#Local]]"
        )
    );
    let after = request(json!({"op":"analyze_documents","documents":[
        {"id":SOURCE,"title":"Source","markdown":rewritten,"paths":["Destination/Work/Source.md"]},
        {"id":TARGET,"title":"After","markdown":"","paths":["Elsewhere/After.md"],"aliases":["Shared"]},
        {"id":OTHER,"title":"Before","markdown":"","paths":["Destination/Before.md"],"aliases":["Shared"]}
    ]}));
    let links = source_links(&after);
    assert_eq!(links[0]["targetId"], TARGET);
    assert_eq!(links[1]["targetId"], TARGET);
    assert!(links[2]["targetId"].is_null());
    assert!(links[3]["targetId"].is_null());
    assert_eq!(links[4]["targetId"], SOURCE);
}

#[test]
fn rewrite_keeps_non_note_embeds_protected_even_with_a_logical_match() {
    for (text, target) in [
        (
            "![ordinary image](Before.md)",
            document(TARGET, "Before", ""),
        ),
        ("![[Before.PDF#page=2]]", document(TARGET, "Before.PDF", "")),
        ("![[Before.JPEG|120]]", document(TARGET, "Before.JPEG", "")),
        ("![[Before.PPTX]]", document(TARGET, "Before.PPTX", "")),
        (
            "![[Before]]",
            json!({"id":TARGET,"title":"Before","markdown":"", "attachmentPaths":["Assets/Before.pdf"],"attachmentUnavailable":true}),
        ),
    ] {
        let result = rewrite(text, vec![target]);
        assert_eq!(result["replacements"], json!([]), "{result}");
        let unsupported = result["unsupported"].as_array().unwrap();
        assert_eq!(unsupported.len(), 1, "{result}");
        assert_eq!(unsupported[0]["targetId"], TARGET);
        assert_eq!(unsupported[0]["kind"], "image");
        assert_eq!(unsupported[0]["original"], text);
    }
    let dotted = rewrite(
        "![[Version 2.5]]",
        vec![document(TARGET, "Version 2.5", "")],
    );
    assert_eq!(dotted["unsupported"], json!([]), "{dotted}");
    assert_eq!(
        apply_replacements("![[Version 2.5]]", &dotted),
        format!("![[{TARGET}|Version 2.5]]")
    );
}

#[test]
fn rewrite_requires_known_source_and_target_identities() {
    for (source, target) in [(OTHER, TARGET), (SOURCE, OTHER)] {
        let result = request(json!({"op":"rewrite_note_links",
            "documents":[document(SOURCE,"Source","[[Before]]"),document(TARGET,"Before","")],
            "sourceId":source,"targetId":target,"text":"[[Before]]"}));
        assert_eq!(result["error"]["code"], "invalid_request", "{result}");
    }
}

#[test]
fn rewrite_target_set_uses_original_unicode_spans_and_preserves_each_link_presentation() {
    let text = "😀 앞 [[Before#정리|보이는 이름]] [other *fmt*](<Other.md#Sec%20Two> \"Keep title\") [[Other]] [[Before]]";
    let result = request(json!({"op":"rewrite_note_links",
        "documents":[document(SOURCE,"Source",text),document(TARGET,"Before",""),document(OTHER,"Other","")],
        "sourceId":SOURCE,"targetIds":[OTHER,TARGET],"text":text}));
    assert!(result.get("error").is_none(), "{result}");
    let changes = result["replacements"].as_array().unwrap();
    assert_eq!(changes.len(), 4);
    assert_replacement(
        text,
        &changes[0],
        "[[Before#정리|보이는 이름]]",
        &format!("[[{TARGET}#정리|보이는 이름]]"),
    );
    assert_replacement(
        text,
        &changes[1],
        "Other.md#Sec%20Two",
        &format!("inkvault://note/{OTHER}?view=markdown#Sec%20Two"),
    );
    assert_replacement(
        text,
        &changes[2],
        "[[Other]]",
        &format!("[[{OTHER}|Other]]"),
    );
    assert_replacement(
        text,
        &changes[3],
        "[[Before]]",
        &format!("[[{TARGET}|Before]]"),
    );
    assert_eq!(result["unsupported"], json!([]));
    assert_eq!(
        apply_replacements(text, &result),
        format!(
            "😀 앞 [[{TARGET}#정리|보이는 이름]] [other *fmt*](<inkvault://note/{OTHER}?view=markdown#Sec%20Two> \"Keep title\") [[{OTHER}|Other]] [[{TARGET}|Before]]"
        )
    );
}

#[test]
fn rewrite_target_set_resolves_against_original_source_paths_and_keeps_stable_or_ambiguous_links() {
    let text = format!(
        "[relative](../Before.md#A%20B) [[Other#Topic|Other label]] [[Shared]] [[{TARGET}|Stable]] [stable](inkvault://note/{OTHER}?view=markdown#A) [[Missing]] [[Source#Self|This note]]"
    );
    let result = request(json!({"op":"rewrite_note_links","documents":[
        {"id":SOURCE,"title":"Source","markdown":text,"paths":["Old/Week/Source.md"]},
        {"id":TARGET,"title":"Before","markdown":"","aliases":["Shared"],"paths":["Old/Before.md"]},
        {"id":OTHER,"title":"Other","markdown":"","aliases":["Shared"],"paths":["Elsewhere/Other.md"]}
    ],"sourceId":SOURCE,"targetIds":[TARGET,OTHER,SOURCE],"text":text}));
    assert!(result.get("error").is_none(), "{result}");
    let changes = result["replacements"].as_array().unwrap();
    assert_eq!(changes.len(), 3);
    assert_replacement(
        &text,
        &changes[0],
        "../Before.md#A%20B",
        &format!("inkvault://note/{TARGET}?view=markdown#A%20B"),
    );
    assert_replacement(
        &text,
        &changes[1],
        "[[Other#Topic|Other label]]",
        &format!("[[{OTHER}#Topic|Other label]]"),
    );
    assert_replacement(
        &text,
        &changes[2],
        "[[Source#Self|This note]]",
        &format!("[[{SOURCE}#Self|This note]]"),
    );
    assert_eq!(result["unsupported"], json!([]));
}

#[test]
fn rewrite_target_set_preserves_protected_regions_and_unselected_or_unknown_links() {
    let text = "---\nproperty: '[[Before]] [[Other]]'\n---\n\n`[[Before]] [[Other]]`\n\n```md\n[[Before]] [[Other]]\n```\n\n<!-- [[Before]] [[Other]] -->\n\n<div>\n[[Before]] [[Other]]\n</div>\n\n<span>[[Before]] [[Other]]</span>\n\n\\[[Before]] \\[[Other]] [[Source]] [[Missing]] [outside](https://example.com/Other.md) [[Before|Visible one]] [[Other|Visible two]]";
    let result = request(json!({"op":"rewrite_note_links",
        "documents":[document(SOURCE,"Source",text),document(TARGET,"Before",""),document(OTHER,"Other","")],
        "sourceId":SOURCE,"targetIds":[TARGET,OTHER],"text":text}));
    assert!(result.get("error").is_none(), "{result}");
    let changes = result["replacements"].as_array().unwrap();
    assert_eq!(changes.len(), 2);
    assert_replacement(
        text,
        &changes[0],
        "[[Before|Visible one]]",
        &format!("[[{TARGET}|Visible one]]"),
    );
    assert_replacement(
        text,
        &changes[1],
        "[[Other|Visible two]]",
        &format!("[[{OTHER}|Visible two]]"),
    );
    assert_eq!(result["unsupported"], json!([]));
}

#[test]
fn rewrite_target_set_reports_each_unsupported_links_actual_target_identity() {
    let text = "😀 ![[Before]] [Other reference][ref] ![Other image](Other.md) [Before reference][before]\n\n[ref]: Other.md#Section \"Keep title\"\n[before]: Before.md\n";
    let result = request(json!({"op":"rewrite_note_links",
        "documents":[document(SOURCE,"Source",text),document(TARGET,"Before",""),document(OTHER,"Other","")],
        "sourceId":SOURCE,"targetIds":[OTHER,TARGET],"text":text}));
    assert!(result.get("error").is_none(), "{result}");
    let replacements = result["replacements"].as_array().unwrap();
    assert_eq!(replacements.len(), 1, "{result}");
    assert_replacement(
        text,
        &replacements[0],
        "![[Before]]",
        &format!("![[{TARGET}|Before]]"),
    );
    let unsupported = result["unsupported"].as_array().unwrap();
    assert_eq!(unsupported.len(), 3);
    for (row, (original, target, kind)) in unsupported.iter().zip([
        ("[Other reference][ref]", OTHER, "reference"),
        ("![Other image](Other.md)", OTHER, "image"),
        ("[Before reference][before]", TARGET, "reference"),
    ]) {
        let (start, end) = utf16_span(text, original);
        assert_eq!(row["targetId"], target);
        assert_eq!(row["kind"], kind);
        assert_eq!(row["original"], original);
        assert_eq!(row["start"], start);
        assert_eq!(row["end"], end);
    }
}

#[test]
fn rewrite_target_set_singleton_is_identical_to_legacy_target_id_output() {
    let text = "😀 [[Before#정리|Label]] [Before](Before.md#A%20B \"Keep title\") ![[Before]] [reference][ref]\n\n[ref]: Before.md\n";
    let documents = vec![
        document(SOURCE, "Source", text),
        document(TARGET, "Before", ""),
    ];
    let legacy = request(json!({"op":"rewrite_note_links","documents":documents,
        "sourceId":SOURCE,"targetId":TARGET,"text":text}));
    let batch = request(json!({"op":"rewrite_note_links","documents":documents,
        "sourceId":SOURCE,"targetIds":[TARGET],"text":text}));
    assert!(legacy.get("error").is_none(), "{legacy}");
    assert_eq!(batch, legacy);
}

#[test]
fn rewrite_target_set_accepts_empty_selection_without_changes() {
    let result = request(json!({"op":"rewrite_note_links",
        "documents":[document(SOURCE,"Source",""),document(TARGET,"Before","")],
        "sourceId":SOURCE,"targetIds":[],"text":"[[Before]] ![[Before]]"}));
    assert_eq!(result, json!({"replacements":[],"unsupported":[]}));
}

#[test]
fn rewrite_target_selection_requires_exactly_one_well_formed_known_identity_form() {
    for selector in [
        json!({}),
        json!({"targetId":TARGET,"targetIds":[TARGET]}),
        json!({"targetId":TARGET,"targetIds":[]}),
        json!({"targetId":TARGET,"targetIds":null}),
        json!({"targetId":null,"targetIds":[TARGET]}),
        json!({"targetId":[TARGET]}),
        json!({"targetId":"not-a-uuid"}),
        json!({"targetIds":null}),
        json!({"targetIds":TARGET}),
        json!({"targetIds":{}}),
        json!({"targetIds":[7]}),
        json!({"targetIds":[null]}),
        json!({"targetIds":[TARGET,TARGET]}),
        json!({"targetIds":[TARGET,OTHER]}),
        json!({"targetIds":["not-a-uuid"]}),
        json!({"targetIds":["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"]}),
        json!({"targetIds":["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"]}),
    ] {
        let mut value = json!({"op":"rewrite_note_links","documents":[
            document(SOURCE,"Source",""),document(TARGET,"Before",""),
            document("not-a-uuid","Invalid",""),
            document("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","Uppercase",""),
            document("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","Invalid version","")
        ],"sourceId":SOURCE,"text":"[[Before]]"});
        value
            .as_object_mut()
            .unwrap()
            .extend(selector.as_object().unwrap().clone());
        let result = request(value);
        assert_eq!(
            result["error"]["code"], "invalid_request",
            "selector={selector}, result={result}"
        );
    }
    let unknown_source = request(json!({"op":"rewrite_note_links",
        "documents":[document(SOURCE,"Source",""),document(TARGET,"Before","")],
        "sourceId":OTHER,"targetIds":[],"text":""}));
    assert_eq!(unknown_source["error"]["code"], "invalid_request");
}

#[test]
fn rewrite_target_set_allows_ten_thousand_known_ids_and_rejects_one_more() {
    let ids: Vec<String> = (0..10_001)
        .map(|index| format!("aaaaaaaa-aaaa-4aaa-8aaa-{index:012x}"))
        .collect();
    let mut documents = vec![document(SOURCE, "Source", "")];
    documents.extend(ids.iter().map(|id| document(id, id, "")));
    let accepted = request(json!({"op":"rewrite_note_links","documents":documents,
        "sourceId":SOURCE,"targetIds":&ids[..10_000],"text":""}));
    assert_eq!(accepted, json!({"replacements":[],"unsupported":[]}));
    let excessive = request(json!({"op":"rewrite_note_links","documents":documents,
        "sourceId":SOURCE,"targetIds":ids,"text":""}));
    assert_eq!(excessive["error"]["code"], "invalid_request");
}

fn anchor_result(anchor: &str, candidates: Value) -> Value {
    request(json!({"op":"resolve_markdown_anchor","anchor":anchor,"candidates":candidates}))
}

fn anchor_index(anchor: &str, candidates: Value) -> Value {
    let result = anchor_result(anchor, candidates);
    assert!(result.get("error").is_none(), "{result}");
    result["candidateIndex"].clone()
}

#[test]
fn rendered_heading_candidates_normalize_unicode_case_and_whitespace_without_losing_indices() {
    let candidates = json!([
        {"kind":"block","id":"unrelated"},
        {"kind":"heading","text":"  CAFÉ\u{a0}\t 정리\r\nSummary\u{2003}","level":2}
    ]);
    assert_eq!(anchor_index("cafe\u{301} 정리 Summary", candidates), 1);
}

#[test]
fn a_whole_literal_heading_containing_hash_wins_before_hierarchy_matching() {
    let candidates = json!([
        {"kind":"heading","text":"Parent","level":1},
        {"kind":"heading","text":"Child","level":2},
        {"kind":"heading","text":"Parent#Child","level":1}
    ]);
    assert_eq!(anchor_index("Parent#Child", candidates), 2);
}

#[test]
fn heading_hierarchy_uses_actual_ancestor_suffixes_and_direct_titles_choose_the_first_match() {
    let candidates = json!([
        {"kind":"heading","text":"Other","level":1},
        {"kind":"heading","text":"Child","level":2},
        {"kind":"heading","text":"Root","level":1},
        {"kind":"heading","text":"Parent","level":2},
        {"kind":"block","id":"between"},
        {"kind":"heading","text":"Child","level":4}
    ]);
    assert_eq!(anchor_index("Parent#Child", candidates.clone()), 5);
    assert_eq!(anchor_index("Root#Parent#Child", candidates.clone()), 5);
    assert_eq!(anchor_index("Child", candidates.clone()), 1);
    assert!(anchor_index("Parent#Missing", candidates).is_null());
}

#[test]
fn heading_slugs_remove_punctuation_and_duplicate_suffixes_keep_rendered_candidate_indices() {
    let candidates = json!([
        {"kind":"heading","text":"Second","level":1},
        {"kind":"block","id":"between"},
        {"kind":"heading","text":"Second","level":1},
        {"kind":"heading","text":"Hello, World!","level":1},
        {"kind":"heading","text":"연구 결과","level":1}
    ]);
    assert_eq!(anchor_index("second", candidates.clone()), 0);
    assert_eq!(anchor_index("second-1", candidates.clone()), 2);
    assert_eq!(anchor_index("hello-world", candidates.clone()), 3);
    assert_eq!(anchor_index("연구-결과", candidates), 4);
}

#[test]
fn literal_heading_titles_win_over_generated_slugs_and_generated_ids_remain_unique() {
    let candidates = json!([
        {"kind":"heading","text":"Foo","level":1},
        {"kind":"heading","text":"Foo-1","level":1},
        {"kind":"heading","text":"Foo","level":1}
    ]);
    assert_eq!(anchor_index("foo-1", candidates.clone()), 1);
    assert_eq!(anchor_index("foo-2", candidates), 2);
}

#[test]
fn block_ids_are_case_sensitive_unique_and_distinct_from_heading_text() {
    let candidates = json!([
        {"kind":"heading","text":"^ref","level":1},
        {"kind":"block","id":"ref"},
        {"kind":"block","id":"Ref"}
    ]);
    assert_eq!(anchor_index("^ref", candidates.clone()), 1);
    assert_eq!(anchor_index("^Ref", candidates.clone()), 2);
    assert!(anchor_index("^REF", candidates.clone()).is_null());
    let mut duplicated = candidates;
    duplicated
        .as_array_mut()
        .unwrap()
        .push(json!({"kind":"block","id":"ref"}));
    assert!(anchor_index("^ref", duplicated).is_null());
}

#[test]
fn anchors_are_already_decoded_and_empty_or_missing_targets_do_not_jump() {
    let candidates = json!([
        {"kind":"heading","text":"A%20B","level":1},
        {"kind":"heading","text":"A B","level":1}
    ]);
    assert_eq!(anchor_index("A%20B", candidates.clone()), 0);
    assert_eq!(anchor_index("A B", candidates.clone()), 1);
    assert!(anchor_index("", candidates.clone()).is_null());
    assert!(anchor_index("Missing", candidates).is_null());
    assert!(anchor_index("Any", json!([])).is_null());
}

#[test]
fn malformed_anchor_candidates_and_control_characters_are_explicit_errors() {
    for candidates in [
        json!({}),
        json!([{"kind":"unknown","text":"Heading","level":1}]),
        json!([{"kind":"heading","level":1}]),
        json!([{"kind":"block"}]),
        json!([{"kind":"heading","text":"Heading","level":0}]),
        json!([{"kind":"heading","text":"Heading","level":7}]),
        json!([{"kind":"heading","text":"Heading","level":1.5}]),
        json!([{"kind":"heading","text":"Heading","level":true}]),
        json!([{"kind":"heading","text":"bad\u{0}","level":1}]),
        json!([{"kind":"block","id":"bad\u{7}"}]),
    ] {
        let result = anchor_result("Heading", candidates);
        assert_eq!(result["error"]["code"], "invalid_request", "{result}");
    }
    for anchor in ["bad\nanchor", "bad\u{7f}anchor", "bad\u{85}anchor"] {
        assert_eq!(
            anchor_result(anchor, json!([]))["error"]["code"],
            "invalid_request"
        );
    }
}

#[test]
fn anchor_candidate_count_and_aggregate_utf8_text_are_bounded_before_normalization() {
    let excessive = vec![json!({"kind":"block","id":"a"}); 10_001];
    assert_eq!(
        anchor_result("^a", json!(excessive))["error"]["code"],
        "invalid_request"
    );
    let unicode = json!([{"kind":"heading","text":"한".repeat(400_000),"level":1}]);
    assert_eq!(
        anchor_result("Any", unicode)["error"]["code"],
        "invalid_request"
    );
    let aggregate = json!([
        {"kind":"heading","text":"a".repeat(600_000),"level":1},
        {"kind":"heading","text":"b".repeat(600_000),"level":1}
    ]);
    assert_eq!(
        anchor_result("Any", aggregate)["error"]["code"],
        "invalid_request"
    );
}
