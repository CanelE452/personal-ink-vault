use super::*;
use crate::{BridgeConfig, READ_OPERATIONS, WRITE_OPERATIONS};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::time::Duration;

const NOTE: &str = "10000000-0000-4000-8000-000000000001";
const METADATA: &str = "10000000-0000-4000-8000-000000000002";
const REQUEST: &str = "10000000-0000-4000-8000-000000000003";

fn server(endpoint: &str, write_enabled: bool) -> InkVaultServer {
    InkVaultServer::new(
        BridgeClient::with_timeout(
            BridgeConfig {
                version: 1,
                instance_id: "discussion-wire-probe".into(),
                endpoint: endpoint.into(),
                token: "synthetic-discussion-probe-token".into(),
                write_enabled,
            },
            Duration::from_secs(3),
        )
        .unwrap(),
    )
}

#[test]
fn actual_mcp_router_exposes_strict_discussion_tool_schemas_and_access_annotations() {
    let server = server("http://127.0.0.1:1", false);
    let tools = server.tool_router.list_all();
    for (name, read_only) in [
        ("list_page_discussions", true),
        ("mutate_page_discussion", false),
    ] {
        let tool = tools
            .iter()
            .find(|tool| tool.name.as_ref() == name)
            .unwrap();
        let annotations = tool.annotations.as_ref().unwrap();
        assert_eq!(annotations.read_only_hint, Some(read_only));
        assert_eq!(annotations.open_world_hint, Some(false));
        assert_eq!(tool.input_schema["additionalProperties"], false);
        assert_eq!(READ_OPERATIONS.contains(&name), read_only);
        assert_eq!(WRITE_OPERATIONS.contains(&name), !read_only);
    }
    let mutate = tools
        .iter()
        .find(|tool| tool.name.as_ref() == "mutate_page_discussion")
        .unwrap();
    let required = mutate.input_schema["required"].as_array().unwrap();
    assert!(required.contains(&json!("expectedBody")));
    assert!(required.contains(&json!("requestId")));
}

fn serve_one(listener: &TcpListener) -> Value {
    let (mut stream, _) = listener.accept().unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut reader = BufReader::new(&mut stream);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.starts_with("POST /v1/call HTTP/"), "{line}");
    let mut content_length = None;
    loop {
        line.clear();
        assert_ne!(reader.read_line(&mut line).unwrap(), 0);
        if line == "\r\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = Some(value.trim().parse::<usize>().unwrap());
            }
        }
    }
    let mut data = vec![0; content_length.unwrap()];
    reader.read_exact(&mut data).unwrap();
    let parsed = serde_json::from_slice(&data).unwrap();
    let response = br#"{"ok":true,"result":{"fixture":"local-loopback"}}"#;
    write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", response.len()).unwrap();
    stream.write_all(response).unwrap();
    parsed
}

#[tokio::test]
async fn discussion_routes_forward_exact_payload_and_respect_existing_write_gate() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let backend = std::thread::spawn(move || [serve_one(&listener), serve_one(&listener)]);
    let read_only = server(&endpoint, false);
    let writable = server(&endpoint, true);
    let list = json!({"noteId": NOTE, "limit": 2});
    let mutation = json!({
        "noteId": NOTE,
        "expectedMetadataRevisionId": METADATA,
        "expectedBody": {"kind": "empty"},
        "requestId": REQUEST,
        "action": {"type": "create_thread", "anchor": {"kind": "page"}, "body": "시험"},
    });
    let read_result = read_only
        .list_page_discussions(Parameters(serde_json::from_value(list.clone()).unwrap()))
        .await;
    assert_eq!(
        read_result.structured_content,
        Some(json!({"fixture":"local-loopback"}))
    );
    let denied = read_only
        .mutate_page_discussion(Parameters(
            serde_json::from_value(mutation.clone()).unwrap(),
        ))
        .await;
    assert_eq!(denied.is_error, Some(true));
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    let allowed = writable
        .mutate_page_discussion(Parameters(
            serde_json::from_value(mutation.clone()).unwrap(),
        ))
        .await;
    assert_eq!(
        allowed.structured_content,
        Some(json!({"fixture":"local-loopback"}))
    );
    assert_eq!(
        backend.join().unwrap(),
        [
            json!({"operation": "list_page_discussions", "arguments": list}),
            json!({"operation": "mutate_page_discussion", "arguments": mutation}),
        ]
    );
}
