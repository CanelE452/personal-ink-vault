use axum::{
    Json, Router,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
};
use ink_vault_mcp::{BridgeClient, BridgeConfig};
use serde_json::{Value, json};
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};

const TOKEN: &str = "synthetic-loopback-capability-token";
const NOTE: &str = "01234567-89ab-4cde-8fab-0123456789ab";
const REV: &str = "01234567-89ab-4cde-8fab-0123456789ac";

fn config(endpoint: String) -> BridgeConfig {
    BridgeConfig {
        version: 1,
        instance_id: "fixture-instance".into(),
        endpoint,
        token: TOKEN.into(),
        write_enabled: true,
    }
}

#[test]
fn only_numeric_loopback_origins_and_valid_private_config_are_accepted() {
    for endpoint in [
        "https://127.0.0.1:9999",
        "http://localhost:9999",
        "http://192.168.1.2:9999",
        "http://127.0.0.1:9999/path",
        "http://127.0.0.1:9999/?token=secret",
        "http://user@127.0.0.1:9999",
        "http://127.0.0.1",
    ] {
        assert!(
            BridgeClient::new(config(endpoint.into())).is_err(),
            "must reject {endpoint}"
        );
    }
    assert!(BridgeClient::new(config("http://127.0.0.1:9999".into())).is_ok());
    let mut invalid = config("http://127.0.0.1:9999".into());
    invalid.token = "bad\r\nheader".into();
    assert!(BridgeClient::new(invalid).is_err());
}

#[derive(Default)]
struct Received {
    calls: Vec<Value>,
}
async fn fixture(
    State(state): State<Arc<Mutex<Received>>>,
    headers: HeaderMap,
    Json(request): Json<Value>,
) -> Response {
    if headers.get("authorization").and_then(|v| v.to_str().ok())
        != Some(&format!("Bearer {TOKEN}"))
    {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"ok":false,"error":{"code":"unauthorized","message":"잘못된 연결 인증"}})),
        )
            .into_response();
    }
    assert!(
        !headers.contains_key("origin"),
        "stdio clients never acquire or forward browser origins"
    );
    state.lock().unwrap().calls.push(request.clone());
    match request["operation"].as_str().unwrap() {
        "read_document" => Json(json!({"ok":true,"result":{"noteId":NOTE,"markdown":"처음","revisionId":REV}})).into_response(),
        "update_document" if request["arguments"]["expectedRevisionId"] != REV => Json(json!({"ok":false,"error":{"code":"stale_revision","message":"이전 판본입니다"}})).into_response(),
        "update_document" => Json(json!({"ok":true,"result":{"noteId":NOTE,"markdown":request["arguments"]["content"],"revisionId":"01234567-89ab-4cde-8fab-0123456789ad"}})).into_response(),
        "vault_status" => Json(json!({"ok":true,"result":{"connected":true}})).into_response(),
        _ => Json(json!({"ok":true,"result":null})).into_response(),
    }
}

async fn server() -> (String, Arc<Mutex<Received>>, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let state = Arc::new(Mutex::new(Received::default()));
    let router = Router::new()
        .route("/v1/call", post(fixture))
        .with_state(state.clone());
    let task = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (endpoint, state, task)
}

#[tokio::test]
async fn actual_http_reads_updates_and_stale_errors_keep_the_bridge_contract() {
    let (endpoint, received, task) = server().await;
    let bridge = BridgeClient::new(config(endpoint)).unwrap();
    let read = bridge
        .call("read_document", json!({"noteId":NOTE}))
        .await
        .unwrap();
    assert_eq!(read["markdown"], "처음");
    let updated = bridge.call("update_document", json!({"noteId":NOTE,"target":"markdown","content":"새 글","expectedRevisionId":REV,"requestId":"write-1"})).await.unwrap();
    assert_eq!(updated["markdown"], "새 글");
    let stale = bridge.call("update_document", json!({"noteId":NOTE,"target":"markdown","content":"덮어쓰기","expectedRevisionId":"older","requestId":"write-2"})).await.unwrap_err();
    assert_eq!(stale.code, "stale_revision");
    assert_eq!(received.lock().unwrap().calls.len(), 3);
    task.abort();
}

#[tokio::test]
async fn read_only_and_unknown_operations_are_rejected_before_http() {
    let (endpoint, received, task) = server().await;
    let mut private = config(endpoint);
    private.write_enabled = false;
    let bridge = BridgeClient::new(private).unwrap();
    assert_eq!(
        bridge
            .call(
                "create_document",
                json!({"title":"금지","kind":"markdown","requestId":"x"})
            )
            .await
            .unwrap_err()
            .code,
        "read_only"
    );
    assert_eq!(
        bridge
            .call("delete_all_vaults", json!({}))
            .await
            .unwrap_err()
            .code,
        "unknown_operation"
    );
    assert!(received.lock().unwrap().calls.is_empty());
    bridge.call("database_query", json!({"noteId":NOTE,"expectedRevisionId":REV,"operations":[{"type":"value","rowId":NOTE,"propertyId":REV}]})).await.expect("query is allowed by a read-only connection");
    assert_eq!(
        received.lock().unwrap().calls.last().unwrap()["operation"],
        "database_query"
    );
    bridge.call("vault_status", json!({})).await.unwrap();
    task.abort();
}

#[tokio::test]
async fn page_history_read_allowlist_and_write_revocation_guard_http() {
    let (endpoint, received, task) = server().await;
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("bridge.json");
    let mut private = config(endpoint);
    private.write_enabled = false;
    write_config(&path, &private).await;
    let bridge = BridgeClient::from_file(path.clone()).unwrap();
    for (operation, arguments) in [
        ("list_revisions", json!({"noteId":NOTE})),
        (
            "list_revisions",
            json!({"noteId":NOTE,"target":"body","offset":3,"limit":2}),
        ),
        (
            "compare_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"offset":0,"limit":100}),
        ),
    ] {
        bridge
            .call(operation, arguments.clone())
            .await
            .expect("saved history reads work with write permission off");
        let last = received.lock().unwrap().calls.last().unwrap().clone();
        assert_eq!(last["operation"], operation);
        assert_eq!(last["arguments"], arguments);
    }
    let restore = json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,
        "expectedHeads":{"body":[REV],"metadata":[NOTE],"folder":[NOTE,REV]},
        "requestId":"restore-page-exact-heads"});
    let before = received.lock().unwrap().calls.len();
    assert_eq!(
        bridge
            .call("restore_page_revision", restore.clone())
            .await
            .unwrap_err()
            .code,
        "read_only"
    );
    assert_eq!(received.lock().unwrap().calls.len(), before);
    private.write_enabled = true;
    write_config(&path, &private).await;
    bridge
        .call("restore_page_revision", restore.clone())
        .await
        .unwrap();
    let last = received.lock().unwrap().calls.last().unwrap().clone();
    assert_eq!(last["operation"], "restore_page_revision");
    assert_eq!(last["arguments"], restore);
    let count = received.lock().unwrap().calls.len();
    private.write_enabled = false;
    write_config(&path, &private).await;
    assert_eq!(
        bridge
            .call("restore_page_revision", restore)
            .await
            .unwrap_err()
            .code,
        "read_only"
    );
    assert_eq!(received.lock().unwrap().calls.len(), count);
    task.abort();
}

#[tokio::test]
async fn auth_failures_never_expose_the_configured_token() {
    let (endpoint, _, task) = server().await;
    let mut wrong = config(endpoint);
    wrong.token = "different-private-token".into();
    let error = BridgeClient::new(wrong)
        .unwrap()
        .call("vault_status", json!({}))
        .await
        .unwrap_err();
    assert_eq!(error.code, "unauthorized");
    assert!(!format!("{error:?}").contains("different-private-token"));
    task.abort();
}

#[tokio::test]
async fn missing_app_redirects_and_oversized_responses_are_explicit_errors() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let error = BridgeClient::new(config(format!("http://{address}")))
        .unwrap()
        .call("vault_status", json!({}))
        .await
        .unwrap_err();
    assert_eq!(error.code, "app_not_running");

    for (mode, expected) in [
        ("redirect", "redirect_forbidden"),
        ("large", "response_too_large"),
    ] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let router = Router::new().route(
            "/v1/call",
            post(move || async move {
                if mode == "redirect" {
                    (
                        StatusCode::FOUND,
                        [("location", "http://example.invalid/")],
                        "redirect",
                    )
                        .into_response()
                } else {
                    Json(json!({"ok":true,"result":"x".repeat(8 * 1024 * 1024 + 100)}))
                        .into_response()
                }
            }),
        );
        let task = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        assert_eq!(
            BridgeClient::new(config(endpoint))
                .unwrap()
                .call("vault_status", json!({}))
                .await
                .unwrap_err()
                .code,
            expected
        );
        task.abort();
    }
}

#[tokio::test]
async fn configured_request_timeout_covers_the_http_response_body() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = [0_u8; 4096];
        let received = stream.read(&mut request).await.unwrap();
        assert!(received > 0);
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n{\"ok\":").await.unwrap();
        tokio::time::sleep(Duration::from_secs(1)).await;
    });
    let bridge = BridgeClient::with_timeout(config(endpoint), Duration::from_millis(40)).unwrap();
    assert_eq!(
        bridge
            .call("vault_status", json!({}))
            .await
            .unwrap_err()
            .code,
        "bridge_timeout"
    );
    task.abort();
}

async fn write_config(path: &std::path::Path, value: &BridgeConfig) {
    tokio::fs::write(path, serde_json::to_vec(value).unwrap())
        .await
        .unwrap();
}

#[tokio::test]
async fn file_backed_clones_reject_another_instance_before_sending_a_stale_client_write() {
    let (first_endpoint, first_received, first_task) = server().await;
    let (second_endpoint, second_received, second_task) = server().await;
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("bridge.json");
    write_config(&path, &config(first_endpoint)).await;
    let bridge = BridgeClient::from_file(path.clone()).unwrap();
    let clone = bridge.clone();
    let read = bridge
        .call("read_document", json!({"noteId":NOTE}))
        .await
        .unwrap();
    let mut other = config(second_endpoint);
    other.instance_id = "different-app-instance".into();
    write_config(&path, &other).await;
    let result = clone
        .call(
            "update_document",
            json!({
                "noteId":NOTE,"target":"markdown","content":"must remain in the original vault",
                "expectedRevisionId":read["revisionId"],"requestId":"instance-switch-write"
            }),
        )
        .await;
    assert!(
        result.is_err(),
        "a previous read must not authorize writing the same note/revision in another app instance"
    );
    let error = result.unwrap_err();
    assert_eq!(error.code, "bridge_instance_changed");
    assert!(error.message.contains("MCP 클라이언트를 다시 시작"));
    assert!(second_received.lock().unwrap().calls.is_empty());
    assert_eq!(first_received.lock().unwrap().calls.len(), 1);
    let restarted = BridgeClient::from_file(path).unwrap();
    restarted.call("vault_status", json!({})).await.unwrap();
    assert_eq!(second_received.lock().unwrap().calls.len(), 1);
    first_task.abort();
    second_task.abort();
}

#[tokio::test]
async fn same_instance_permissions_and_credentials_are_still_reloaded() {
    let (endpoint, received, task) = server().await;
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("bridge.json");
    let mut private = config(endpoint);
    write_config(&path, &private).await;
    let bridge = BridgeClient::from_file(path.clone()).unwrap();
    bridge.call("vault_status", json!({})).await.unwrap();
    private.write_enabled = false;
    write_config(&path, &private).await;
    assert_eq!(
        bridge
            .call(
                "update_document",
                json!({
                    "noteId":NOTE,"target":"markdown","content":"denied",
                    "expectedRevisionId":REV,"requestId":"permission-reload"
                })
            )
            .await
            .unwrap_err()
            .code,
        "read_only"
    );
    assert_eq!(received.lock().unwrap().calls.len(), 1);
    private.write_enabled = true;
    private.token = "rotated-invalid-synthetic-token".into();
    write_config(&path, &private).await;
    assert_eq!(
        bridge
            .call("vault_status", json!({}))
            .await
            .unwrap_err()
            .code,
        "unauthorized"
    );
    private.token = TOKEN.into();
    write_config(&path, &private).await;
    bridge.call("vault_status", json!({})).await.unwrap();
    assert_eq!(received.lock().unwrap().calls.len(), 2);
    task.abort();
}

#[tokio::test]
async fn the_initial_valid_config_remains_pinned_even_if_the_first_request_fails() {
    let (first_endpoint, _, first_task) = server().await;
    let (second_endpoint, received, second_task) = server().await;
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("bridge.json");
    let mut first = config(first_endpoint);
    first.token = "invalid-initial-synthetic-token".into();
    write_config(&path, &first).await;
    let bridge = BridgeClient::from_file(path.clone()).unwrap();
    assert_eq!(
        bridge
            .call("vault_status", json!({}))
            .await
            .unwrap_err()
            .code,
        "unauthorized"
    );
    let mut second = config(second_endpoint);
    second.instance_id = "successful-second-instance".into();
    write_config(&path, &second).await;
    assert_eq!(
        bridge
            .call("vault_status", json!({}))
            .await
            .unwrap_err()
            .code,
        "bridge_instance_changed"
    );
    assert!(received.lock().unwrap().calls.is_empty());
    first_task.abort();
    second_task.abort();
}

#[tokio::test]
async fn missing_or_invalid_configuration_does_not_prevent_later_initial_connection() {
    let (endpoint, received, task) = server().await;
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("bridge.json");
    let bridge = BridgeClient::from_file(path.clone()).unwrap();
    assert_eq!(
        bridge
            .call("vault_status", json!({}))
            .await
            .unwrap_err()
            .code,
        "app_not_running"
    );
    let mut invalid = config(endpoint.clone());
    invalid.instance_id = "invalid-instance".into();
    invalid.version = 2;
    write_config(&path, &invalid).await;
    assert_eq!(
        bridge
            .call("vault_status", json!({}))
            .await
            .unwrap_err()
            .code,
        "invalid_bridge_config"
    );
    write_config(&path, &config(endpoint)).await;
    bridge.call("vault_status", json!({})).await.unwrap();
    assert_eq!(received.lock().unwrap().calls.len(), 1);
    task.abort();
}

#[tokio::test]
async fn concurrent_first_calls_cannot_cross_instances_while_the_initial_read_is_pending() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let entered = Arc::new(tokio::sync::Semaphore::new(0));
    let release = Arc::new(tokio::sync::Semaphore::new(0));
    let router = Router::new().route(
        "/v1/call",
        post({
            let entered = entered.clone();
            let release = release.clone();
            move || {
                let entered = entered.clone();
                let release = release.clone();
                async move {
                    entered.add_permits(1);
                    release.acquire().await.unwrap().forget();
                    Json(json!({"ok":true,"result":{"noteId":NOTE,"revisionId":REV}}))
                }
            }
        }),
    );
    let first_task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let (second_endpoint, second_received, second_task) = server().await;
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("bridge.json");
    write_config(&path, &config(endpoint)).await;
    let bridge = BridgeClient::from_file(path.clone()).unwrap();
    let first_call = tokio::spawn({
        let bridge = bridge.clone();
        async move { bridge.call("read_document", json!({"noteId":NOTE})).await }
    });
    tokio::time::timeout(Duration::from_secs(2), entered.acquire())
        .await
        .unwrap()
        .unwrap()
        .forget();
    let mut other = config(second_endpoint);
    other.instance_id = "concurrent-other-instance".into();
    write_config(&path, &other).await;
    let second_call = tokio::spawn(async move {
        bridge
            .call(
                "update_document",
                json!({
                    "noteId":NOTE,"target":"markdown","content":"must not cross",
                    "expectedRevisionId":REV,"requestId":"concurrent-switch-write"
                }),
            )
            .await
    });
    release.add_permits(1);
    first_call.await.unwrap().unwrap();
    let result = tokio::time::timeout(Duration::from_secs(2), second_call)
        .await
        .unwrap()
        .unwrap();
    assert!(
        result.is_err(),
        "the pending initial read must establish one shared instance before another request is sent"
    );
    assert_eq!(result.unwrap_err().code, "bridge_instance_changed");
    assert!(second_received.lock().unwrap().calls.is_empty());
    first_task.abort();
    second_task.abort();
}
