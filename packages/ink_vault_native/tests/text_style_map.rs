use ink_vault_native::request_json;
use serde_json::{Value, json};
use std::collections::BTreeSet;

const PROTOCOL: &str = "piv-text-style-map-1";

fn request(old: &str, new: &str) -> Value {
    request_json(
        &json!({"op":"text_style_map","protocol":PROTOCOL,"oldText":old,"newText":new}).to_string(),
    )
}

fn keys(value: &Value) -> BTreeSet<&str> {
    value
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect()
}

fn slice_utf16(text: &str, start: usize, end: usize) -> String {
    let units: Vec<_> = text.encode_utf16().collect();
    String::from_utf16(&units[start..end]).expect("range must not split a surrogate pair")
}

fn offset(segment: &Value, key: &str) -> usize {
    segment[key]
        .as_u64()
        .expect("offset must be an unsigned integer") as usize
}

fn assert_plan(old: &str, new: &str) -> Value {
    let value = request(old, new);
    assert!(value.get("error").is_none(), "planning failed: {value}");
    assert_eq!(
        keys(&value),
        BTreeSet::from([
            "protocol",
            "oldUtf16Length",
            "newUtf16Length",
            "oldSha256",
            "newSha256",
            "paragraphs",
        ])
    );
    assert_eq!(value["protocol"], PROTOCOL);
    assert_eq!(value["oldUtf16Length"], old.encode_utf16().count());
    assert_eq!(value["newUtf16Length"], new.encode_utf16().count());
    for key in ["oldSha256", "newSha256"] {
        let hash = value[key].as_str().expect("hash must be text");
        assert_eq!(hash.len(), 64);
        assert!(
            hash.bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        );
    }
    let old_lines: Vec<_> = old.split('\n').collect();
    let new_lines: Vec<_> = new.split('\n').collect();
    let paragraphs = value["paragraphs"]
        .as_array()
        .expect("paragraphs must be an array");
    assert_eq!(paragraphs.len(), new_lines.len());
    for (paragraph, new_line) in paragraphs.iter().zip(new_lines) {
        assert_eq!(
            keys(paragraph),
            BTreeSet::from(["sourceParagraph", "segments"])
        );
        let source = paragraph["sourceParagraph"].as_u64().unwrap() as usize;
        assert!(source < old_lines.len());
        let old_line = old_lines[source];
        let old_length = old_line.encode_utf16().count();
        let new_length = new_line.encode_utf16().count();
        let segments = paragraph["segments"]
            .as_array()
            .expect("segments must be an array");
        assert!(!segments.is_empty());
        let mut cursor = 0;
        for segment in segments {
            assert_eq!(
                keys(segment),
                BTreeSet::from(["kind", "newStart", "newEnd", "oldStart", "oldEnd"])
            );
            let start = offset(segment, "newStart");
            let end = offset(segment, "newEnd");
            let old_start = offset(segment, "oldStart");
            let old_end = offset(segment, "oldEnd");
            assert_eq!(
                start, cursor,
                "new ranges must cover the paragraph without gaps"
            );
            assert!(start <= end && end <= new_length);
            assert!(old_start <= old_end && old_end <= old_length);
            let inserted = slice_utf16(new_line, start, end);
            let source = slice_utf16(old_line, old_start, old_end);
            match segment["kind"].as_str() {
                Some("retain") => {
                    assert!(start < end);
                    assert_eq!(
                        inserted, source,
                        "retention must preserve the complete original interval"
                    );
                }
                Some("inherit") => {
                    assert!(start < end || new_length == 0);
                    assert!(old_start < old_end || old_length == 0);
                }
                other => panic!("unsupported segment kind: {other:?}"),
            }
            cursor = end;
        }
        assert_eq!(cursor, new_length);
        if new_length == 0 {
            assert_eq!(segments.len(), 1);
            assert_eq!(segments[0]["kind"], "inherit");
        }
    }
    assert!(value.to_string().len() <= 1_048_576);
    value
}

fn segments(old: &str, new: &str) -> Value {
    assert_plan(old, new)["paragraphs"][0]["segments"].clone()
}

fn mapping(old: &str, new: &str) -> Vec<usize> {
    assert_plan(old, new)["paragraphs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|paragraph| paragraph["sourceParagraph"].as_u64().unwrap() as usize)
        .collect()
}

fn retain(new_start: usize, new_end: usize, old_start: usize, old_end: usize) -> Value {
    json!({"kind":"retain","newStart":new_start,"newEnd":new_end,"oldStart":old_start,"oldEnd":old_end})
}

fn inherit(new_start: usize, new_end: usize, old_start: usize, old_end: usize) -> Value {
    json!({"kind":"inherit","newStart":new_start,"newEnd":new_end,"oldStart":old_start,"oldEnd":old_end})
}

fn assert_limit(old: &str, new: &str) {
    let value = request(old, new);
    assert_eq!(keys(&value), BTreeSet::from(["error"]));
    assert_eq!(value["error"]["code"], "text_style_limit");
    assert!(
        value["error"]["message"]
            .as_str()
            .is_some_and(|message| !message.is_empty())
    );
}

#[test]
fn unchanged_text_returns_one_complete_source_interval() {
    assert_eq!(
        segments("plain text", "plain text"),
        json!([retain(0, 10, 0, 10)])
    );
}

#[test]
fn hashes_bind_exact_utf8_source_and_target() {
    let plan = assert_plan("", "abc");
    assert_eq!(
        plan["oldSha256"],
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        plan["newSha256"],
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

#[test]
fn insertion_inherits_the_preceding_original_grapheme() {
    assert_eq!(
        segments("abcd", "abXYcd"),
        json!([retain(0, 2, 0, 2), inherit(2, 4, 1, 2), retain(4, 6, 2, 4),])
    );
}

#[test]
fn insertion_at_start_inherits_the_first_original_grapheme() {
    assert_eq!(
        segments("ab", "XYab"),
        json!([inherit(0, 2, 0, 1), retain(2, 4, 0, 2)])
    );
}

#[test]
fn insertion_at_end_inherits_the_last_original_grapheme() {
    assert_eq!(
        segments("ab", "abXY"),
        json!([retain(0, 2, 0, 2), inherit(2, 4, 1, 2)])
    );
}

#[test]
fn replacement_inherits_the_first_replaced_grapheme() {
    assert_eq!(
        segments("abcdef", "aXYef"),
        json!([retain(0, 1, 0, 1), inherit(1, 3, 1, 2), retain(3, 5, 4, 6),])
    );
}

#[test]
fn independent_edits_retain_the_unchanged_middle() {
    assert_eq!(
        segments("abcDEFghiJKL", "abXDEFghiYKL"),
        json!([
            retain(0, 2, 0, 2),
            inherit(2, 3, 2, 3),
            retain(3, 9, 3, 9),
            inherit(9, 10, 9, 10),
            retain(10, 12, 10, 12),
        ])
    );
}

#[test]
fn deletion_keeps_disjoint_old_source_intervals() {
    assert_eq!(
        segments("abcdef", "abef"),
        json!([retain(0, 2, 0, 2), retain(2, 4, 4, 6)])
    );
}

#[test]
fn repeated_text_uses_deterministic_delete_before_insert_ties() {
    assert_eq!(
        segments("ab", "ba"),
        json!([retain(0, 1, 1, 2), inherit(1, 2, 1, 2)])
    );
    assert_eq!(
        segments("aaaa", "aaXaa"),
        json!([retain(0, 2, 0, 2), inherit(2, 3, 1, 2), retain(3, 5, 2, 4),])
    );
}

#[test]
fn canonical_equivalents_are_replaced_without_normalization() {
    assert_eq!(
        segments("caf\u{e9}", "cafe\u{301}"),
        json!([retain(0, 3, 0, 3), inherit(3, 5, 3, 4)])
    );
    let plan = assert_plan("\u{ac00}", "\u{1100}\u{1161}");
    assert_ne!(plan["oldSha256"], plan["newSha256"]);
    assert_eq!(
        plan["paragraphs"][0]["segments"],
        json!([inherit(0, 2, 0, 1)])
    );
}

#[test]
fn combining_sequence_is_one_inheritance_anchor() {
    assert_eq!(
        segments("e\u{301}z", "e\u{301}Xz"),
        json!([retain(0, 2, 0, 2), inherit(2, 3, 0, 2), retain(3, 4, 2, 3),])
    );
}

#[test]
fn emoji_zwj_cluster_retains_all_native_style_subintervals() {
    assert_eq!(
        segments("A👩‍💻B", "A👩‍💻XB"),
        json!([retain(0, 6, 0, 6), inherit(6, 7, 1, 6), retain(7, 8, 6, 7),])
    );
}

#[test]
fn regional_indicator_flag_is_one_inheritance_anchor() {
    assert_eq!(
        segments("🇰🇷!", "🇰🇷X!"),
        json!([retain(0, 4, 0, 4), inherit(4, 5, 0, 4), retain(5, 6, 4, 5),])
    );
}

#[test]
fn indic_conjunct_is_one_grapheme_and_uses_utf16_offsets() {
    assert_eq!(
        segments("क्ष!", "क्षX!"),
        json!([retain(0, 3, 0, 3), inherit(3, 4, 0, 3), retain(4, 5, 3, 4),])
    );
}

#[test]
fn empty_targets_keep_a_zero_length_typing_style_anchor() {
    assert_eq!(segments("abc", ""), json!([inherit(0, 0, 0, 1)]));
    assert_eq!(segments("", ""), json!([inherit(0, 0, 0, 0)]));
    assert_eq!(segments("", "👩‍💻abc"), json!([inherit(0, 8, 0, 0)]));
}

#[test]
fn equal_paragraph_counts_preserve_index_even_when_lines_move() {
    assert_eq!(mapping("A\nB", "B\nA"), [0, 1]);
}

#[test]
fn inserted_paragraphs_inherit_neighboring_source_and_keep_exact_anchors() {
    assert_eq!(mapping("A\nB\nC", "X\nA\nB\nY\nC"), [0, 0, 1, 1, 2]);
    let plan = assert_plan("A\nB\nC", "X\nA\nB\nY\nC");
    assert_eq!(
        plan["paragraphs"][1]["segments"],
        json!([retain(0, 1, 0, 1)])
    );
    assert_eq!(
        plan["paragraphs"][3]["segments"],
        json!([inherit(0, 1, 0, 1)])
    );
}

#[test]
fn deleted_paragraphs_keep_the_surviving_original_paragraph_indices() {
    assert_eq!(mapping("A\nB\nC\nD", "A\nD"), [0, 3]);
}

#[test]
fn repeated_paragraph_lcs_uses_delete_old_ties() {
    assert_eq!(mapping("A\nB", "B\nA\nX"), [1, 1, 1]);
}

#[test]
fn leading_trailing_and_consecutive_empty_paragraphs_are_preserved() {
    let plan = assert_plan("A\nB", "\nA\n\nB\n");
    assert_eq!(mapping("A\nB", "\nA\n\nB\n"), [0, 0, 0, 1, 1]);
    for index in [0, 2, 4] {
        assert_eq!(
            plan["paragraphs"][index]["segments"],
            json!([inherit(0, 0, 0, 1)])
        );
    }
}

#[test]
fn carriage_return_is_preserved_as_raw_text_not_rewritten() {
    let plan = assert_plan("a\r\nb\r", "a\r\nb\r");
    assert_eq!(plan["oldUtf16Length"], 5);
    assert_eq!(
        plan["paragraphs"][0]["segments"],
        json!([retain(0, 2, 0, 2)])
    );
    assert_eq!(
        plan["paragraphs"][1]["segments"],
        json!([retain(0, 2, 0, 2)])
    );
}

#[test]
fn request_requires_exact_protocol_fields_and_string_types() {
    let valid = json!({"op":"text_style_map","protocol":PROTOCOL,"oldText":"a","newText":"b"});
    let mut cases = Vec::new();
    for key in ["protocol", "oldText", "newText"] {
        let mut missing = valid.clone();
        missing.as_object_mut().unwrap().remove(key);
        cases.push(missing);
        for wrong in [Value::Null, json!(0), json!(false), json!([]), json!({})] {
            let mut request = valid.clone();
            request[key] = wrong;
            cases.push(request);
        }
    }
    let mut wrong_protocol = valid.clone();
    wrong_protocol["protocol"] = json!("piv-text-style-map-2");
    cases.push(wrong_protocol);
    let mut extra = valid;
    extra["selection"] = Value::Null;
    cases.push(extra);
    for request in cases {
        assert_eq!(
            request_json(&request.to_string())["error"]["code"],
            "invalid_request",
            "{request}"
        );
    }
}

#[test]
fn utf16_input_limits_accept_exact_boundaries_and_reject_one_more_unit() {
    assert_plan(&"😀".repeat(100_000), "");
    assert_limit(&("😀".repeat(100_000) + "x"), "");
    assert_plan("", &"😀".repeat(4096));
    assert_limit("", &("😀".repeat(4096) + "x"));
}

#[test]
fn paragraph_limits_accept_512_and_reject_513_on_each_side() {
    let at_limit = "\n".repeat(511);
    let over_limit = "\n".repeat(512);
    assert_plan(&at_limit, &at_limit);
    assert_limit(&over_limit, "");
    assert_limit("", &over_limit);
}

#[test]
fn large_middle_with_sparse_independent_edits_retains_exact_text() {
    let middle = "xy".repeat(2000);
    assert_eq!(
        segments(&format!("A{middle}B"), &format!("Z{middle}Q")),
        json!([
            inherit(0, 1, 0, 1),
            retain(1, 4001, 1, 4001),
            inherit(4001, 4002, 4001, 4002),
        ])
    );
}

#[test]
fn disjoint_full_replacement_has_an_exact_linear_inheritance_plan() {
    assert_eq!(
        segments(&"a".repeat(6000), &"b".repeat(6000)),
        json!([inherit(0, 6000, 0, 1)])
    );
}

#[test]
fn difficult_diff_returns_a_structured_limit_instead_of_flattening_styles() {
    assert_limit(&"ab".repeat(3000), &"bc".repeat(3000));
}

#[test]
fn mixed_unicode_plans_are_contiguous_exact_and_repeatable() {
    for (old, new) in [
        ("red green blue", "RED green BLUE"),
        ("한글 👨‍👩‍👧‍👦 끝", "한글 새 👨‍👩‍👧‍👦 끝!"),
        ("e\u{301}🇰🇷क्ष", "!e\u{301}🇰🇷क्ष?"),
        ("same\nsame\nlast", "same\nnew\nsame\nlast\n"),
        ("\0\ttext", "\0\tmore text"),
    ] {
        let first = assert_plan(old, new);
        for _ in 0..5 {
            assert_eq!(assert_plan(old, new), first);
        }
    }
}
