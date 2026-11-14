use ink_vault_native::request_json;
use serde_json::{Value, json};

fn scan(markdown: &str) -> Value {
    request_json(&json!({"op": "dataview_task_markers", "markdown": markdown}).to_string())
}

#[test]
fn tasks_keep_raw_status_and_utf16_source_position() {
    let markdown = "한😀 머리말\r\n\r\n- [ ] 시작\r\n  - [X] 대문자\r\n\r\n> 1. [x] 인용\r\n> 2. [!] 표시\r\n> 3. [🌱] 다음\r\n";
    let expected = [
        (3, " ", "[ ] 시작"),
        (4, "X", "[X] 대문자"),
        (6, "x", "[x] 인용"),
        (7, "!", "[!] 표시"),
        (8, "🌱", "[🌱] 다음"),
    ]
    .into_iter()
    .map(|(line, status, marker)| {
        let bracket = markdown.find(marker).unwrap();
        json!({
            "line": line,
            "statusOffset": markdown[..bracket + 1].encode_utf16().count(),
            "status": status,
        })
    })
    .collect::<Vec<_>>();
    assert_eq!(scan(markdown), json!({"tasks": expected}));
}

#[test]
fn code_html_links_and_continuation_lines_are_not_tasks() {
    let markdown = concat!(
        "~~~md\n- [ ] fenced\n~~~\n\n",
        "    - [X] indented\n\n",
        "<div>\n- [!] HTML\n</div>\n\n",
        "Ordinary [ ] text\n\n",
        "- [!](/url) link\n",
        "- \\[ ] escaped\n",
        "- a plain item\n  [!] continuation\n",
        "-     [!] item code\n",
        "- [?!] multi-character marker\n",
        "- [!]joined\n",
        "- [ ] actual task\n"
    );
    let actual = markdown.find("[ ] actual task").unwrap() + 1;
    assert_eq!(
        scan(markdown),
        json!({"tasks": [{
            "line": markdown[..actual].bytes().filter(|byte| *byte == b'\n').count() + 1,
            "statusOffset": actual,
            "status": " ",
        }]})
    );
}

#[test]
fn rejects_invalid_input_and_over_limit_result_without_partial_rows() {
    for request in [
        json!({"op": "dataview_task_markers"}),
        json!({"op": "dataview_task_markers", "markdown": true}),
        json!({"op": "dataview_task_markers", "markdown": "", "path": "x"}),
        json!({"op": "dataview_task_markers", "markdown": "가".repeat(349_526)}),
        json!({"op": "dataview_task_markers", "markdown": "- [ ] a\n".repeat(5001)}),
    ] {
        let result = request_json(&request.to_string());
        assert_eq!(result["error"]["code"], "invalid_request");
        assert!(result.get("tasks").is_none());
    }
    assert_eq!(scan("")["tasks"], json!([]));
    assert_eq!(
        scan(&"- [ ] a\n".repeat(5000))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        5000
    );
}
