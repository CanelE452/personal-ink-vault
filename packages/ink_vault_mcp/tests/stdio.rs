use axum::{
    Json, Router,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
};
use ink_vault_mcp::BridgeConfig;
use rmcp::{
    ClientLifecycleMode, ClientServiceExt, RoleClient, ServiceExt,
    model::{CallToolRequestParams, ClientConfig, ProtocolVersion, ReadResourceRequestParams},
    service::RunningService,
    transport::TokioChildProcess,
};
use serde_json::{Value, json};
use std::{
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

const NOTE: &str = "01234567-89ab-4cde-8fab-0123456789ab";
const REV: &str = "01234567-89ab-4cde-8fab-0123456789ac";
const TOKEN: &str = "stdio-synthetic-private-token";
const PNG: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJPkAAAAASUVORK5CYII=";

#[tokio::test]
async fn actual_stdio_render_page_accepts_an_exact_office_target_on_a_read_only_bridge() {
    let (_temp, path, calls, task) = fixture().await;
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let client = client(&path, true).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "render_page")
        .unwrap();
    let hints = tool.annotations.as_ref().unwrap();
    assert_eq!(hints.read_only_hint, Some(true));
    assert_eq!(hints.destructive_hint, Some(false));
    let encoded = serde_json::to_value(tool).unwrap();
    let schema = &encoded["inputSchema"];
    assert_eq!(schema["required"], json!(["noteId"]));
    assert_eq!(schema["additionalProperties"], false);
    let target = &schema["properties"]["officePageTarget"];
    let target = match target["$ref"].as_str() {
        Some(reference) => schema
            .pointer(reference.strip_prefix('#').unwrap())
            .unwrap(),
        None => target,
    };
    assert_eq!(target["type"], "object");
    assert_eq!(target["additionalProperties"], false);
    assert_eq!(target["properties"].as_object().unwrap().len(), 3);
    let required = target["required"].as_array().unwrap();
    assert_eq!(required.len(), 3);
    for field in ["sourceRevisionId", "pdfBindingId", "pageId"] {
        assert!(required.contains(&json!(field)));
        assert_eq!(target["properties"][field]["type"], "string");
    }

    let exact = json!({"noteId": NOTE, "officePageTarget": {
        "sourceRevisionId": REV,
        "pdfBindingId": "01234567-89ab-4cde-8fab-0123456789ad",
        "pageId": "01234567-89ab-8cde-8fab-0123456789ae"
    }});
    let mut exact_with_legacy_nulls = exact.clone();
    exact_with_legacy_nulls["pageIndex"] = Value::Null;
    exact_with_legacy_nulls["revisionId"] = Value::Null;
    for request in [exact.clone(), exact_with_legacy_nulls] {
        let result = client
            .call_tool(
                CallToolRequestParams::new("render_page")
                    .with_arguments(request.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        let result = serde_json::to_value(result).unwrap();
        assert_eq!(
            result["structuredContent"]["officePageTarget"],
            exact["officePageTarget"]
        );
        assert_eq!(result["structuredContent"]["pageIndex"], 2);
        assert!(
            result["content"]
                .as_array()
                .unwrap()
                .iter()
                .any(|block| block["type"] == "image"
                    && block["mimeType"] == "image/png"
                    && block["data"] == PNG)
        );
        assert!(!result["structuredContent"].to_string().contains(PNG));
        let forwarded = calls.lock().unwrap();
        assert_eq!(forwarded.last().unwrap()["operation"], "render_page");
        assert_eq!(forwarded.last().unwrap()["arguments"], exact);
    }
    let legacy = json!({"noteId": NOTE, "pageIndex": 0, "revisionId": REV});
    let result = client
        .call_tool(
            CallToolRequestParams::new("render_page")
                .with_arguments(legacy.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(false));
    assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], legacy);

    for (field, value) in [("pageIndex", json!(0)), ("revisionId", json!(REV))] {
        let mut mixed = exact.clone();
        mixed[field] = value;
        let result = client
            .call_tool(
                CallToolRequestParams::new("render_page")
                    .with_arguments(mixed.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert_eq!(
            result.structured_content.unwrap()["code"],
            "invalid_arguments"
        );
    }
    let mut unknown = exact.clone();
    unknown["officePageTarget"]["path"] = json!("unowned");
    let mut missing = exact.clone();
    missing["officePageTarget"]
        .as_object_mut()
        .unwrap()
        .remove("pageId");
    let mut wrong_type = exact.clone();
    wrong_type["officePageTarget"]["pageId"] = json!(1);
    for invalid in [
        unknown,
        missing,
        wrong_type,
        json!({"noteId": NOTE, "officePageTarget": null}),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new("render_page")
                    .with_arguments(invalid.as_object().unwrap().clone()),
            )
            .await;
        if let Ok(result) = result {
            assert_eq!(result.is_error, Some(true));
        }
    }
    assert_eq!(
        calls.lock().unwrap().len(),
        3,
        "invalid selector reached the app"
    );
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_database_media_exposes_and_forwards_optional_non_null_row_selector() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, true).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "read_page_media")
        .unwrap();
    let schema = serde_json::to_value(tool).unwrap();
    assert_eq!(
        schema["inputSchema"]["properties"]["rowId"]["type"],
        "string"
    );
    assert!(
        !schema["inputSchema"]["required"]
            .as_array()
            .unwrap()
            .contains(&json!("rowId"))
    );
    let args = json!({"noteId":NOTE,"revisionId":REV,"rowId":REV,"blockId":NOTE});
    let result = client
        .call_tool(
            CallToolRequestParams::new("read_page_media")
                .with_arguments(args.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(false));
    assert_eq!(calls.lock().unwrap()[0]["arguments"], args);
    for value in [Value::Null, json!(7), json!({"path":"unowned"})] {
        let mut invalid = args.clone();
        invalid["rowId"] = value;
        let result = client
            .call_tool(
                CallToolRequestParams::new("read_page_media")
                    .with_arguments(invalid.as_object().unwrap().clone()),
            )
            .await;
        if let Ok(result) = result {
            assert_eq!(result.is_error, Some(true));
        }
        assert_eq!(calls.lock().unwrap().len(), 1);
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_page_media_is_owned_read_only_closed_and_preserves_image_content() {
    let (_temp, path, calls, task) = fixture().await;
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let client = client(&path, true).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "read_page_media")
        .expect("owned page media must be discoverable");
    assert_eq!(
        tool.annotations.as_ref().unwrap().read_only_hint,
        Some(true)
    );
    let schema = serde_json::to_value(tool).unwrap();
    assert_eq!(schema["inputSchema"]["additionalProperties"], false);
    let required = schema["inputSchema"]["required"].as_array().unwrap();
    for key in ["noteId", "revisionId", "blockId"] {
        assert!(required.contains(&json!(key)));
    }
    for mode in ["metadata", "bytes", "preview"] {
        let mut args = json!({"noteId":NOTE,"revisionId":REV,"blockId":NOTE,"mode":mode});
        if mode == "bytes" {
            args["offset"] = json!(0);
            args["limit"] = json!(262144);
        }
        if mode == "preview" {
            args["maxDimension"] = json!(1024);
        }
        let result = client
            .call_tool(
                CallToolRequestParams::new("read_page_media")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        let result = serde_json::to_value(result).unwrap();
        assert_eq!(result["structuredContent"]["revisionId"], REV);
        if mode == "preview" {
            assert!(
                result["content"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|block| block["type"] == "image" && block["mimeType"] == "image/png")
            );
            assert!(!result["structuredContent"].to_string().contains(PNG));
        }
    }
    let forwarded = calls.lock().unwrap().clone();
    assert_eq!(forwarded.len(), 3);
    assert!(
        forwarded
            .iter()
            .all(|call| call["operation"] == "read_page_media"
                && call["arguments"]["noteId"] == NOTE
                && call["arguments"]["revisionId"] == REV
                && call["arguments"]["blockId"] == NOTE)
    );
    let base = json!({"noteId":NOTE,"revisionId":REV,"blockId":NOTE});
    let mut invalid = Vec::new();
    for field in ["path", "hash", "url", "source"] {
        let mut value = base.clone();
        value[field] = json!("unowned");
        invalid.push(value);
    }
    for field in ["noteId", "revisionId", "blockId"] {
        let mut value = base.clone();
        value.as_object_mut().unwrap().remove(field);
        invalid.push(value);
        let mut value = base.clone();
        value[field] = Value::Null;
        invalid.push(value);
    }
    for (field, value) in [
        ("mode", Value::Null),
        ("mode", json!("execute")),
        ("offset", json!(-1)),
        ("offset", Value::Null),
        ("limit", json!(0)),
        ("limit", json!(262145)),
        ("maxDimension", json!(63)),
        ("maxDimension", json!(2049)),
        ("maxDimension", Value::Null),
    ] {
        let mut args = base.clone();
        if field == "offset" || field == "limit" {
            args["mode"] = json!("bytes");
        }
        if field == "maxDimension" {
            args["mode"] = json!("preview");
        }
        args[field] = value;
        invalid.push(args);
    }
    for args in invalid {
        let result = client
            .call_tool(
                CallToolRequestParams::new("read_page_media")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await;
        if let Ok(result) = result {
            assert_eq!(result.is_error, Some(true));
        }
        assert_eq!(
            calls.lock().unwrap().len(),
            3,
            "invalid selector reached the app"
        );
    }
    client.cancel().await.unwrap();
    task.abort();
}

async fn application(
    State(calls): State<Arc<Mutex<Vec<Value>>>>,
    headers: HeaderMap,
    Json(request): Json<Value>,
) -> Response {
    if headers.get("authorization").and_then(|v| v.to_str().ok())
        != Some("Bearer stdio-synthetic-private-token")
    {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"ok":false,"error":{"code":"unauthorized","message":"인증 실패"}})),
        )
            .into_response();
    }
    assert!(!headers.contains_key("origin"));
    calls.lock().unwrap().push(request.clone());
    let args = &request["arguments"];
    let result = match request["operation"].as_str().unwrap() {
        "vault_status" => json!({"running":true}),
        "list_documents" => {
            json!({"documents":[{"noteId":NOTE,"title":"연구 메모"}],"offset":0,"limit":100})
        }
        "search_documents" if args["query"] == "title:" => return Json(
            json!({"ok":false,"error":{"code":"invalid_search_expression","message":"검색식을 확인하세요."}}),
        )
        .into_response(),
        "search_documents" => json!({
            "matches": [{"noteId": NOTE, "title": "연구 메모", "path": "연구/연구 메모.md", "snippet": "연구 중", "score": 4}],
            "total": 1,
            "offset": args["offset"].as_u64().unwrap_or(0),
            "limit": args["limit"].as_u64().unwrap_or(50),
        }),
        "list_folders" => json!({"folders":[]}),
        "read_document" => json!({"noteId":NOTE,"markdown":"기존 내용","revisionId":REV}),
        "read_daily_note" | "ensure_daily_note" => {
            json!({"date":args["date"],"noteId":NOTE,"markdownRevisionId":REV})
        }
        "database_query" => {
            json!({"noteId":NOTE,"revisionId":REV,"results":[{"value":6}],"errors":[],"remainingBudget":997})
        }
        "database_task_links" => {
            json!({"noteId":NOTE,"revisionId":REV,"rowId":NOTE,"archived":false,"parentId":null,"predecessorIds":[REV]})
        }
        "query_dataview"
            if args["query"]
                .as_str()
                .is_some_and(|query| query.starts_with("LIST")) =>
        {
            json!({
                "mode": "list",
                "columns": [],
                "rows": [{"noteId": NOTE, "title": "연구 메모", "path": "연구/연구 메모.md", "values": []}],
            })
        }
        "query_dataview" => json!({
            "mode": "table",
            "columns": [{"field": "status", "label": "상태"}],
            "rows": [{"noteId": NOTE, "title": "연구 메모", "path": "연구/연구 메모.md", "values": ["진행"]}],
        }),
        "update_document" if args["expectedRevisionId"] != REV => return Json(
            json!({"ok":false,"error":{"code":"stale_revision","message":"판본이 바뀌었습니다"}}),
        )
        .into_response(),
        "update_document" => {
            json!({"noteId":NOTE,"markdown":args["content"],"revisionId":"01234567-89ab-4cde-8fab-0123456789ad"})
        }
        "render_page" if args.get("officePageTarget").is_some() => {
            json!({"noteId":NOTE,"officePageTarget":args["officePageTarget"],
                "pageIndex":2,"image":{"data":PNG,"mimeType":"image/png"}})
        }
        "render_page" => {
            json!({"noteId":NOTE,"pageIndex":0,"image":{"data":PNG,"mimeType":"image/png"}})
        }
        "read_page_media" => match args.get("mode").and_then(Value::as_str) {
            Some("preview") => json!({"noteId":NOTE,"revisionId":REV,"blockId":NOTE,
                "image":{"data":PNG,"mimeType":"image/png"}}),
            Some("bytes") => json!({"noteId":NOTE,"revisionId":REV,"blockId":NOTE,
                "offset":0,"dataBase64":"cGFnZSBtZWRpYQ==","eof":true}),
            _ => json!({"noteId":NOTE,"revisionId":REV,"blockId":NOTE,
                "media":{"name":"연구 사진.png","mimeType":"image/png","byteLength":68}}),
        },
        "create_document" | "document_action" | "office_edit" | "office_asset"
        | "database_action" => {
            json!({"noteId":NOTE,"operation":request["operation"]})
        }
        "list_revisions" => json!({"revisions":[{"revisionId":REV}]}),
        "read_revision" => json!({"noteId":NOTE,"revisionId":REV}),
        "compare_page_revision" => json!({
            "noteId":NOTE,"revisionId":args["revisionId"],"expectedRevisionId":REV,
            "expectedHeads":{"body":[REV],"metadata":[NOTE],"folder":[NOTE,REV]},
            "offset":args.get("offset").cloned().unwrap_or(json!(0)),
            "limit":args.get("limit").cloned().unwrap_or(json!(100)),
            "changes":[],"truncated":false
        }),
        "restore_page_revision" => json!({
            "noteId":NOTE,"revisionId":"01234567-89ab-4cde-8fab-0123456789ad",
            "restoredFromRevisionId":args["revisionId"]
        }),
        _ => panic!("unexpected app operation"),
    };
    Json(json!({"ok":true,"result":result})).into_response()
}

#[tokio::test]
async fn actual_stdio_office_range_and_chunk_upload_schema_is_discoverable_and_closed() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let asset = tools
        .iter()
        .find(|tool| tool.name == "office_asset")
        .expect("LLMs can upload real images without host paths or oversized requests");
    assert_eq!(
        asset.annotations.as_ref().unwrap().read_only_hint,
        Some(false)
    );
    let schema = serde_json::to_value(&asset.input_schema).unwrap();
    let branches = schema["oneOf"]
        .as_array()
        .expect("action-specific upload fields");
    assert_eq!(branches.len(), 5);
    for action in ["begin", "append", "seal", "status", "discard"] {
        let branch = branches
            .iter()
            .find(|item| item["properties"]["action"].to_string().contains(action))
            .expect(action);
        assert_eq!(branch["additionalProperties"], false);
    }
    let hash = "a".repeat(64);
    let cases = [
        (
            "office_asset",
            json!({"action":"begin","noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"mimeType":"image/png","byteLength":100,"sha256":hash}),
        ),
        (
            "office_asset",
            json!({"action":"append","noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"assetId":NOTE,"offset":0,"base64Data":"AQID"}),
        ),
        (
            "office_asset",
            json!({"action":"seal","noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"assetId":NOTE}),
        ),
        (
            "office_edit",
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":[
                {"op":"textReplace","targetKind":"paragraph","id":"paragraph-0","startUtf16":1,"endUtf16":3,"expectedTextSha256":hash,"text":"교체"},
                {"op":"textStyle","targetKind":"cell","id":"Table1","cell":"A1","startUtf16":0,"endUtf16":2,"expectedTextSha256":hash,"italic":true,"underline":true,"fontFamily":"Arial"},
                {"op":"imageAdd","id":"new-image","slideId":"slide-0","assetId":NOTE,"x":12.0,"y":20.0,"width":60.0,"height":30.0},
                {"op":"imageReplace","id":"slide-0/shape-1","assetId":NOTE}
            ]}),
        ),
    ];
    for (name, args) in cases {
        let response = client
            .call_tool(
                CallToolRequestParams::new(name).with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(response.is_error, Some(false));
        assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], args);
    }
    let before = calls.lock().unwrap().len();
    for (name, args) in [
        (
            "office_asset",
            json!({"action":"append","noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"assetId":NOTE,"offset":-1,"base64Data":"AQID"}),
        ),
        (
            "office_asset",
            json!({"action":"begin","noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"mimeType":"image/png","byteLength":100,"sha256":hash,"path":"C:/private/image.png"}),
        ),
        (
            "office_edit",
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":[{"op":"textStyle","targetKind":"header","id":"p0","startUtf16":0,"endUtf16":1,"expectedTextSha256":hash,"bold":true}]}),
        ),
        (
            "office_edit",
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":[{"op":"imageReplace","id":"image","assetId":NOTE,"url":"https://example.test/image.png"}]}),
        ),
    ] {
        let response = client
            .call_tool(
                CallToolRequestParams::new(name).with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(response.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), before);
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_word_photo_schema_and_transport_preserve_targets_aliases_and_ppt() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "office_edit")
        .unwrap();
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    let items = &schema["properties"]["operations"]["items"];
    let operation_schema = if let Some(reference) = items["$ref"].as_str() {
        schema
            .pointer(reference.strip_prefix('#').unwrap())
            .unwrap()
    } else {
        items
    };
    let branches = operation_schema["oneOf"].as_array().unwrap();
    assert_eq!(branches.len(), 37);
    for (name, fields) in [
        (
            "wordImageAdd",
            vec![
                "op",
                "id",
                "ownerId",
                "paragraphId",
                "offsetUtf16",
                "expectedTextSha256",
                "assetId",
                "width",
                "height",
            ],
        ),
        (
            "wordImageMove",
            vec![
                "op",
                "id",
                "ownerId",
                "paragraphId",
                "offsetUtf16",
                "expectedTextSha256",
            ],
        ),
        ("wordImageDelete", vec!["op", "id"]),
    ] {
        let branch = branches
            .iter()
            .find(|branch| branch["properties"]["op"]["const"] == name)
            .expect(name);
        assert_eq!(branch["additionalProperties"], false);
        let mut actual: Vec<_> = branch["required"]
            .as_array()
            .unwrap()
            .iter()
            .map(|field| field.as_str().unwrap())
            .collect();
        let mut expected = fields;
        actual.sort();
        expected.sort();
        assert_eq!(actual, expected);
        assert_eq!(
            branch["properties"].as_object().unwrap().len(),
            expected.len()
        );
        if name != "wordImageDelete" {
            assert_eq!(branch["properties"]["offsetUtf16"]["type"], "integer");
            assert_eq!(branch["properties"]["offsetUtf16"]["minimum"], 0);
            assert_eq!(branch["properties"]["offsetUtf16"]["maximum"], 20_000_000);
        }
        if name == "wordImageAdd" {
            assert_eq!(branch["properties"]["width"]["type"], "number");
            assert_eq!(branch["properties"]["height"]["type"], "number");
        }
    }
    let operations = json!([
        {"op":"wordImageAdd","id":"new-word-photo","ownerId":"body","paragraphId":"paragraph-0","offsetUtf16":3,"expectedTextSha256":"a".repeat(64),"assetId":NOTE,"width":25.4,"height":19.05},
        {"op":"wordImageMove","id":"new-word-photo","ownerId":"body","paragraphId":"paragraph-1","offsetUtf16":20_000_000,"expectedTextSha256":"b".repeat(64)},
        {"op":"imageReplace","id":"new-word-photo","assetId":NOTE},
        {"op":"wordImageDelete","id":"new-word-photo"},
        {"op":"imageAdd","id":"new-ppt-photo","slideId":"slide-0","assetId":NOTE,"x":12.5,"y":20.0,"width":60.0,"height":30.0}
    ]);
    let arguments =
        json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":operations});
    let response = client
        .call_tool(
            CallToolRequestParams::new("office_edit")
                .with_arguments(arguments.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(response.is_error, Some(false));
    assert_eq!(
        calls.lock().unwrap().last().unwrap()["arguments"],
        arguments
    );

    let before = calls.lock().unwrap().len();
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let denied = client
        .call_tool(
            CallToolRequestParams::new("office_edit")
                .with_arguments(arguments.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), before);
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_word_photo_closed_fields_and_scalar_types_reject_before_http() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let valid_add = json!({"op":"wordImageAdd","id":"new-word-photo","ownerId":"body","paragraphId":"paragraph-0","offsetUtf16":0,"expectedTextSha256":"a".repeat(64),"assetId":NOTE,"width":25.4,"height":19.05});
    let valid_move = json!({"op":"wordImageMove","id":"new-word-photo","ownerId":"body","paragraphId":"paragraph-1","offsetUtf16":0,"expectedTextSha256":"b".repeat(64)});
    let valid_delete = json!({"op":"wordImageDelete","id":"new-word-photo"});
    let mut invalid = Vec::new();
    for (value, required) in [
        (
            &valid_add,
            vec![
                "id",
                "ownerId",
                "paragraphId",
                "offsetUtf16",
                "expectedTextSha256",
                "assetId",
                "width",
                "height",
            ],
        ),
        (
            &valid_move,
            vec![
                "id",
                "ownerId",
                "paragraphId",
                "offsetUtf16",
                "expectedTextSha256",
            ],
        ),
        (&valid_delete, vec!["id"]),
    ] {
        for field in required {
            let mut value = value.clone();
            value.as_object_mut().unwrap().remove(field);
            invalid.push(value);
        }
    }
    for wrong in [
        json!(-1),
        json!(1.5),
        json!(true),
        json!("1"),
        Value::Null,
        json!(4_294_967_296_u64),
    ] {
        for base in [&valid_add, &valid_move] {
            let mut value = base.clone();
            value["offsetUtf16"] = wrong.clone();
            invalid.push(value);
        }
    }
    for field in ["width", "height"] {
        for wrong in [json!(true), json!("25.4"), Value::Null] {
            let mut value = valid_add.clone();
            value[field] = wrong;
            invalid.push(value);
        }
    }
    for (base, field, extra) in [
        (&valid_add, "path", json!("C:/foreign/photo.png")),
        (&valid_add, "url", json!("https://example.test/photo.png")),
        (&valid_add, "slideId", json!("slide-0")),
        (&valid_add, "x", json!(1)),
        (&valid_move, "assetId", json!(NOTE)),
        (&valid_move, "width", json!(25.4)),
        (&valid_move, "height", json!(19.05)),
        (&valid_move, "path", json!("C:/foreign/photo.png")),
        (&valid_delete, "ownerId", json!("body")),
        (&valid_delete, "offsetUtf16", json!(0)),
        (&valid_delete, "assetId", json!(NOTE)),
        (
            &valid_delete,
            "url",
            json!("https://example.test/photo.png"),
        ),
    ] {
        let mut value = base.clone();
        value[field] = extra;
        invalid.push(value);
    }
    let before = calls.lock().unwrap().len();
    for operation in invalid {
        let response = client.call_tool(CallToolRequestParams::new("office_edit")
            .with_arguments(json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":[operation]})
                .as_object().unwrap().clone())).await.unwrap();
        assert_eq!(response.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), before);
    }
    client.cancel().await.unwrap();
    task.abort();
}

async fn client(path: &Path, discover: bool) -> RunningService<RoleClient, ClientConfig> {
    let executable = std::env::var_os("INK_VAULT_MCP_TEST_EXE")
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_ink_vault_mcp").into());
    let mut command = tokio::process::Command::new(executable);
    command.arg("--bridge-file").arg(path);
    let transport = TokioChildProcess::new(command).unwrap();
    let config = ClientConfig::default();
    tokio::time::timeout(Duration::from_secs(8), async {
        if discover {
            config
                .serve_with_lifecycle(
                    transport,
                    ClientLifecycleMode::Discover {
                        preferred_versions: vec![ProtocolVersion::V_2026_07_28],
                    },
                )
                .await
        } else {
            config
                .with_protocol_version(ProtocolVersion::LATEST_WITH_INITIALIZE)
                .serve(transport)
                .await
        }
    })
    .await
    .expect("bounded actual stdio initialization")
    .expect("official rmcp client initializes the executable")
}

async fn fixture() -> (
    tempfile::TempDir,
    std::path::PathBuf,
    Arc<Mutex<Vec<Value>>>,
    tokio::task::JoinHandle<()>,
) {
    let temp = tempfile::tempdir().unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let config = BridgeConfig {
        version: 1,
        instance_id: "stdio-instance".into(),
        endpoint: format!("http://{}", listener.local_addr().unwrap()),
        token: TOKEN.into(),
        write_enabled: true,
    };
    let path = temp.path().join("bridge.json");
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let router = Router::new()
        .route("/v1/call", post(application))
        .with_state(calls.clone());
    let task = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (temp, path, calls, task)
}

#[tokio::test]
async fn real_stdio_initialize_tools_resources_read_update_stale_and_image() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let mut names: Vec<_> = tools.iter().map(|t| t.name.as_ref()).collect();
    names.sort();
    let mut expected = vec![
        "vault_status",
        "list_documents",
        "search_documents",
        "list_folders",
        "read_document",
        "read_daily_note",
        "list_page_discussions",
        "create_document",
        "ensure_daily_note",
        "update_document",
        "mutate_page_discussion",
        "document_action",
        "database_action",
        "database_query",
        "database_task_links",
        "query_dataview",
        "list_revisions",
        "read_revision",
        "compare_page_revision",
        "restore_page_revision",
        "office_edit",
        "office_asset",
        "render_page",
        "read_page_media",
    ];
    expected.sort();
    assert_eq!(names, expected);
    assert_eq!(
        tools
            .iter()
            .find(|t| t.name == "read_document")
            .unwrap()
            .annotations
            .as_ref()
            .unwrap()
            .read_only_hint,
        Some(true)
    );
    assert_eq!(
        tools
            .iter()
            .find(|t| t.name == "document_action")
            .unwrap()
            .annotations
            .as_ref()
            .unwrap()
            .destructive_hint,
        Some(true)
    );
    let read = client
        .call_tool(
            CallToolRequestParams::new("read_document")
                .with_arguments(json!({"noteId":NOTE}).as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(read.structured_content.unwrap()["markdown"], "기존 내용");
    let updated = client.call_tool(CallToolRequestParams::new("update_document").with_arguments(json!({"noteId":NOTE,"target":"markdown","content":"AI 정리","expectedRevisionId":REV,"requestId":"update-1"}).as_object().unwrap().clone())).await.unwrap();
    assert_eq!(updated.is_error, Some(false));
    assert_eq!(updated.structured_content.unwrap()["markdown"], "AI 정리");
    let stale = client.call_tool(CallToolRequestParams::new("update_document").with_arguments(json!({"noteId":NOTE,"target":"markdown","content":"덮어쓰기","expectedRevisionId":"old","requestId":"update-2"}).as_object().unwrap().clone())).await.unwrap();
    assert_eq!(stale.is_error, Some(true));
    assert_eq!(stale.structured_content.unwrap()["code"], "stale_revision");
    let resources = client.list_all_resources().await.unwrap();
    assert!(resources.iter().any(|r| r.uri == "inkvault://documents"));
    let resource = client
        .read_resource(ReadResourceRequestParams::new(format!(
            "inkvault://document/{NOTE}"
        )))
        .await
        .unwrap();
    let encoded = serde_json::to_value(resource).unwrap();
    assert!(encoded.to_string().contains("기존 내용"));
    let preview = client
        .call_tool(
            CallToolRequestParams::new("render_page")
                .with_arguments(json!({"noteId":NOTE}).as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    let preview = serde_json::to_value(preview).unwrap();
    assert!(
        preview["content"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["type"] == "image" && c["mimeType"] == "image/png")
    );
    assert!(!preview["structuredContent"].to_string().contains(PNG));
    assert!(
        calls
            .lock()
            .unwrap()
            .iter()
            .any(|call| call["operation"] == "update_document"
                && call["arguments"]["expectedRevisionId"] == REV)
    );
    for (tool, args) in [
        ("list_folders", json!({})),
        (
            "create_document",
            json!({"title":"새 메모","kind":"markdown","body":"내용","requestId":"create-allowed"}),
        ),
        (
            "document_action",
            json!({"noteId":NOTE,"action":"rename","title":"변경한 제목","expectedRevisionId":REV,"requestId":"rename-1"}),
        ),
        ("list_revisions", json!({"noteId":NOTE})),
        ("read_revision", json!({"noteId":NOTE,"revisionId":REV})),
        (
            "office_edit",
            json!({"noteId":NOTE,"expectedRevisionId":REV,"operations":[{"op":"paragraphText","id":"paragraph-0","text":"고친 문단"}],"requestId":"office-1"}),
        ),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new(tool).with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        let last = calls.lock().unwrap().last().unwrap().clone();
        assert_eq!(last["operation"], tool);
        assert_eq!(last["arguments"], args);
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_daily_notes_use_closed_calendar_and_current_write_permission() {
    let (_temp, path, calls, task) = fixture().await;
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    for (name, read_only, required) in [
        ("read_daily_note", true, json!(["date"])),
        ("ensure_daily_note", false, json!(["date", "requestId"])),
    ] {
        let tool = tools.iter().find(|tool| tool.name == name).unwrap();
        let annotations = tool.annotations.as_ref().unwrap();
        assert_eq!(annotations.read_only_hint, Some(read_only));
        assert_eq!(annotations.destructive_hint, Some(false));
        assert_eq!(annotations.open_world_hint, Some(false));
        let schema = serde_json::to_value(&tool.input_schema).unwrap();
        assert_eq!(schema["type"], "object");
        assert_eq!(schema["additionalProperties"], false);
        let actual = schema["required"].as_array().unwrap();
        let expected = required.as_array().unwrap();
        assert_eq!(actual.len(), expected.len());
        assert!(expected.iter().all(|field| actual.contains(field)));
        assert_eq!(schema["properties"]["date"]["type"], "string");
        assert_eq!(schema["properties"]["date"]["minLength"], 10);
        assert_eq!(schema["properties"]["date"]["maxLength"], 10);
        if !read_only {
            assert_eq!(schema["properties"]["requestId"]["type"], "string");
        }
    }

    for date in ["0001-01-01", "2000-02-29", "9999-12-31"] {
        let result = client
            .call_tool(
                CallToolRequestParams::new("read_daily_note")
                    .with_arguments(json!({"date": date}).as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        assert_eq!(result.structured_content.unwrap()["date"], date);
        assert_eq!(
            calls.lock().unwrap().last().unwrap(),
            &json!({"operation":"read_daily_note","arguments":{"date":date}})
        );
    }
    let ensure = json!({"date":"2026-11-10","requestId":NOTE});
    let before = calls.lock().unwrap().len();
    let denied = client
        .call_tool(
            CallToolRequestParams::new("ensure_daily_note")
                .with_arguments(ensure.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(denied.is_error, Some(true));
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), before);

    config.write_enabled = true;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let result = client
        .call_tool(
            CallToolRequestParams::new("ensure_daily_note")
                .with_arguments(ensure.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(false));
    assert_eq!(result.structured_content.unwrap()["noteId"], NOTE);
    assert_eq!(
        calls.lock().unwrap().last().unwrap(),
        &json!({"operation":"ensure_daily_note","arguments":ensure})
    );

    let before = calls.lock().unwrap().len();
    let schema_errors = [
        ("read_daily_note", json!({})),
        ("read_daily_note", json!({"date":null})),
        (
            "read_daily_note",
            json!({"date":"2026-11-10","noteId":NOTE}),
        ),
        ("ensure_daily_note", json!({"date":"2026-11-10"})),
        (
            "ensure_daily_note",
            json!({"date":"2026-11-10","requestId":null}),
        ),
        (
            "ensure_daily_note",
            json!({"date":"2026-11-10","requestId":NOTE,"body":"unsafe override"}),
        ),
    ];
    let invalid_arguments = [
        ("read_daily_note", json!({"date":"0000-01-01"})),
        ("read_daily_note", json!({"date":"1900-02-29"})),
        ("read_daily_note", json!({"date":"2026-04-31"})),
        ("read_daily_note", json!({"date":"2026-11-00"})),
        ("read_daily_note", json!({"date":"2026-13-01"})),
        ("read_daily_note", json!({"date":"2026-1-01"})),
        ("read_daily_note", json!({"date":"２０２６-11-10"})),
        ("read_daily_note", json!({"date":"2026-11-10\n"})),
        (
            "ensure_daily_note",
            json!({"date":"2026-02-29","requestId":NOTE}),
        ),
        (
            "ensure_daily_note",
            json!({"date":"2026-11-10","requestId":NOTE.to_uppercase()}),
        ),
        (
            "ensure_daily_note",
            json!({"date":"2026-11-10","requestId":NOTE.replace('-', "")}),
        ),
        (
            "ensure_daily_note",
            json!({"date":"2026-11-10","requestId":"01234567-89ab-0cde-8fab-0123456789ab"}),
        ),
        (
            "ensure_daily_note",
            json!({"date":"2026-11-10","requestId":"01234567-89ab-4cde-1fab-0123456789ab"}),
        ),
    ];
    for ((tool, args), expected_code) in schema_errors.into_iter().map(|case| (case, None)).chain(
        invalid_arguments
            .into_iter()
            .map(|case| (case, Some("invalid_arguments"))),
    ) {
        let rejected = client
            .call_tool(
                CallToolRequestParams::new(tool).with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(rejected.is_error, Some(true), "{tool} accepted {args}");
        let code = rejected
            .structured_content
            .as_ref()
            .and_then(|content| content["code"].as_str());
        assert_eq!(code, expected_code, "{tool} rejected {args}");
        assert_eq!(
            calls.lock().unwrap().len(),
            before,
            "{tool} forwarded {args}"
        );
    }
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let denied = client
        .call_tool(
            CallToolRequestParams::new("ensure_daily_note")
                .with_arguments(ensure.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), before);
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_page_history_schema_is_typed_closed_and_keeps_legacy_omissions() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    for (name, required, read_only) in [
        (
            "compare_page_revision",
            vec!["noteId", "revisionId", "expectedRevisionId"],
            true,
        ),
        (
            "restore_page_revision",
            vec![
                "noteId",
                "revisionId",
                "expectedRevisionId",
                "expectedHeads",
                "requestId",
            ],
            false,
        ),
        ("list_revisions", vec!["noteId"], true),
    ] {
        let tool = tools.iter().find(|tool| tool.name == name).expect(name);
        assert_eq!(
            tool.annotations.as_ref().unwrap().read_only_hint,
            Some(read_only)
        );
        assert_eq!(
            tool.annotations.as_ref().unwrap().destructive_hint,
            Some(!read_only)
        );
        let schema = serde_json::to_value(&tool.input_schema).unwrap();
        assert_eq!(schema["type"], "object");
        assert_eq!(schema["additionalProperties"], false);
        let mut actual = schema["required"].as_array().unwrap().clone();
        actual.sort_by_key(Value::to_string);
        let mut expected: Vec<_> = required.into_iter().map(|field| json!(field)).collect();
        expected.sort_by_key(Value::to_string);
        assert_eq!(actual, expected, "{name}");
        if name != "restore_page_revision" {
            assert_eq!(schema["properties"]["offset"]["type"], "integer");
            assert_eq!(
                schema["properties"]["offset"]["minimum"].as_f64(),
                Some(0.0)
            );
            assert_eq!(schema["properties"]["limit"]["type"], "integer");
            assert_eq!(schema["properties"]["limit"]["minimum"].as_f64(), Some(1.0));
            assert_eq!(
                schema["properties"]["limit"]["maximum"].as_f64(),
                Some(100.0)
            );
        } else {
            let heads = &schema["properties"]["expectedHeads"];
            assert_eq!(heads["type"], "object");
            assert_eq!(heads["additionalProperties"]["type"], "array");
            assert_eq!(heads["additionalProperties"]["items"]["type"], "string");
        }
    }
    for (name, args) in [
        ("list_revisions", json!({"noteId":NOTE})),
        (
            "list_revisions",
            json!({"noteId":NOTE,"target":"body","offset":2,"limit":1}),
        ),
        (
            "compare_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV}),
        ),
        (
            "compare_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"offset":0,"limit":100}),
        ),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new(name).with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        let received = calls.lock().unwrap().last().unwrap().clone();
        assert_eq!(received["operation"], name);
        assert_eq!(received["arguments"], args, "omitted fields stay omitted");
        if name == "list_revisions" && args.get("target").is_none() {
            assert_eq!(
                result.structured_content.unwrap(),
                json!({"revisions":[{"revisionId":REV}]})
            );
        }
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_page_history_rejects_unknown_missing_and_wrong_types_before_http() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let before = calls.lock().unwrap().len();
    for (name, args) in [
        ("list_revisions", json!({"noteId":NOTE,"target":"markdown"})),
        ("list_revisions", json!({"noteId":NOTE,"offset":-1})),
        ("list_revisions", json!({"noteId":NOTE,"limit":"1"})),
        ("list_revisions", json!({"noteId":NOTE,"path":"outside"})),
        (
            "compare_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE}),
        ),
        (
            "compare_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"offset":-1}),
        ),
        (
            "compare_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"limit":true}),
        ),
        (
            "compare_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"after":{}}),
        ),
        (
            "restore_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"requestId":"restore-1"}),
        ),
        (
            "restore_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"expectedHeads":{"body":REV},"requestId":"restore-1"}),
        ),
        (
            "restore_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"expectedHeads":{"body":[1]},"requestId":"restore-1"}),
        ),
        (
            "restore_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"expectedHeads":{},"requestId":1}),
        ),
        (
            "restore_page_revision",
            json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"expectedHeads":{},"requestId":"restore-1","content":{}}),
        ),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new(name).with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true), "{name}: {args}");
        let text = result
            .content
            .iter()
            .filter_map(|content| content.as_text())
            .map(|text| text.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            text.contains("failed to deserialize parameters"),
            "{name}: {text}"
        );
        assert_eq!(calls.lock().unwrap().len(), before, "{name}: {args}");
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_page_history_compare_is_read_only_and_restore_guards_survive_revocation() {
    let (_temp, path, calls, task) = fixture().await;
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let client = client(&path, false).await;
    let compared = client.call_tool(CallToolRequestParams::new("compare_page_revision")
        .with_arguments(json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,"offset":1,"limit":2})
            .as_object().unwrap().clone())).await.unwrap();
    assert_eq!(compared.is_error, Some(false));
    let comparison = compared.structured_content.unwrap();
    let restore = json!({"noteId":NOTE,"revisionId":NOTE,"expectedRevisionId":REV,
        "expectedHeads":comparison["expectedHeads"],"requestId":"restore-same-snapshot"});
    let before = calls.lock().unwrap().len();
    let denied = client
        .call_tool(
            CallToolRequestParams::new("restore_page_revision")
                .with_arguments(restore.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), before);
    config.write_enabled = true;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    for _ in 0..2 {
        let result = client
            .call_tool(
                CallToolRequestParams::new("restore_page_revision")
                    .with_arguments(restore.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], restore);
    }
    let count = calls.lock().unwrap().len();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let denied = client
        .call_tool(
            CallToolRequestParams::new("restore_page_revision")
                .with_arguments(restore.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), count);
    let untrash = json!({"noteId":NOTE,"action":"restore","expectedRevisionId":REV,"requestId":"untrash-only"});
    config.write_enabled = true;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let result = client
        .call_tool(
            CallToolRequestParams::new("document_action")
                .with_arguments(untrash.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(false));
    assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], untrash);
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_page_geometry_schema_preserves_optional_numbers_and_rejects_null() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "office_edit")
        .unwrap();
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    let items = &schema["properties"]["operations"]["items"];
    let operations = if let Some(reference) = items["$ref"].as_str() {
        schema
            .pointer(reference.strip_prefix('#').unwrap())
            .unwrap()
    } else {
        items
    };
    let operation = operations["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["properties"]["op"]["const"] == "pageGeometry")
        .expect("LLMs can discover the pageGeometry operation");
    assert_eq!(operation["additionalProperties"], false);
    let required = operation["required"].as_array().unwrap();
    assert!(required.contains(&json!("id")) && required.contains(&json!("expectedLayoutSha256")));
    assert!(!required.contains(&json!("width")));
    assert_eq!(operation["properties"]["width"]["type"], "number");
    assert_eq!(operation["properties"]["landscape"]["type"], "boolean");
    for op in [
        json!({"op":"pageGeometry","id":"page-0","expectedLayoutSha256":"b".repeat(64),
            "width":210.01,"height":297.0,"landscape":false,"leftMargin":0.0}),
        json!({"op":"pageGeometry","id":"page-0","expectedLayoutSha256":"b".repeat(64),"leftMargin":0.0}),
    ] {
        let arguments =
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":[op]});
        let response = client
            .call_tool(
                CallToolRequestParams::new("office_edit")
                    .with_arguments(arguments.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(response.is_error, Some(false));
        assert_eq!(
            calls.lock().unwrap().last().unwrap()["arguments"],
            arguments
        );
    }
    let before = calls.lock().unwrap().len();
    for invalid in [
        json!({"width":null,"leftMargin":0}),
        json!({"leftMargin":null}),
        json!({"landscape":null,"leftMargin":0}),
        json!({"leftMargin":true}),
        json!({"width":"210","height":297,"landscape":false}),
        json!({"headerIsOn":false}),
        json!({"headerIsShared":true}),
    ] {
        let mut op = invalid;
        let fields = op.as_object_mut().unwrap();
        fields.insert("op".into(), json!("pageGeometry"));
        fields.insert("id".into(), json!("page-0"));
        fields.insert("expectedLayoutSha256".into(), json!("b".repeat(64)));
        let response = client.call_tool(CallToolRequestParams::new("office_edit")
            .with_arguments(json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":[op]})
                .as_object().unwrap().clone())).await.unwrap();
        assert_eq!(response.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), before);
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_office_schema_describes_objects_and_rejects_unknown_edits_before_http() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "office_edit")
        .unwrap();
    assert_eq!(
        tool.annotations.as_ref().unwrap().read_only_hint,
        Some(false)
    );
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    let items = &schema["properties"]["operations"]["items"];
    let operation_schema = if let Some(reference) = items["$ref"].as_str() {
        schema
            .pointer(reference.strip_prefix('#').unwrap())
            .unwrap()
    } else {
        items
    };
    let branches = operation_schema["oneOf"]
        .as_array()
        .expect("LLMs discover the supported operation arguments");
    assert_eq!(branches.len(), 37);
    for name in [
        "docxTableStructureEdit",
        "presentationCellTextPatch",
        "pageGeometry",
        "paragraphText",
        "paragraphStyle",
        "tableCellText",
        "shapeText",
        "shapeStyle",
        "shapeGeometry",
        "slideAdd",
        "slideDuplicate",
        "pptxSlideSectionMove",
        "slideDelete",
        "slideMove",
        "shapeAdd",
        "shapeDelete",
        "shapeAppearance",
        "slideBackground",
        "textReplace",
        "textStyle",
        "imageAdd",
        "imageReplace",
        "imageRotate",
        "wordImageAdd",
        "wordImageMove",
        "wordImageDelete",
        "paragraphSplit",
        "paragraphInsert",
        "tableInsert",
        "tableStructure",
        "paragraphJoin",
        "paragraphDelete",
        "paragraphFormat",
        "slideDesign",
        "slideDisplay",
    ] {
        let branch = branches
            .iter()
            .find(|branch| branch["properties"]["op"].to_string().contains(name))
            .expect(name);
        assert_eq!(branch["additionalProperties"], false);
        assert!(
            branch["required"]
                .as_array()
                .unwrap()
                .iter()
                .any(|field| field == "op")
        );
    }
    let section_move = branches
        .iter()
        .find(|branch| branch["properties"]["op"]["const"] == "pptxSlideSectionMove")
        .unwrap();
    let expected: std::collections::BTreeSet<_> = [
        "op",
        "expectedSourceSha256",
        "sourceIndex",
        "targetIndex",
        "after",
    ]
    .into_iter()
    .collect();
    let properties = section_move["properties"].as_object().unwrap();
    assert_eq!(
        properties
            .keys()
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>(),
        expected
    );
    assert_eq!(
        section_move["required"]
            .as_array()
            .unwrap()
            .iter()
            .map(|field| field.as_str().unwrap())
            .collect::<std::collections::BTreeSet<_>>(),
        expected
    );
    assert_eq!(section_move["additionalProperties"], false);
    assert_eq!(
        properties["expectedSourceSha256"]["pattern"],
        "^[0-9a-f]{64}$"
    );
    assert_eq!(properties["after"]["type"], "boolean");
    for field in ["sourceIndex", "targetIndex"] {
        assert_eq!(properties[field]["type"], "integer");
        assert_eq!(properties[field]["minimum"].as_f64(), Some(0.0));
        assert_eq!(properties[field]["maximum"].as_f64(), Some(255.0));
    }
    let rotation = branches
        .iter()
        .find(|branch| branch["properties"]["op"]["const"] == "imageRotate")
        .unwrap();
    for name in ["expectedRotationHundredths", "rotationHundredths"] {
        assert_eq!(rotation["properties"][name]["type"], "integer");
        assert_eq!(rotation["properties"][name]["minimum"], 0);
        assert_eq!(rotation["properties"][name]["maximum"], 35999);
    }
    let shape_add = branches
        .iter()
        .find(|branch| branch["properties"]["op"]["const"] == "shapeAdd")
        .unwrap();
    let shape_kind = &shape_add["properties"]["shapeKind"];
    let shape_kind = match shape_kind["$ref"].as_str() {
        Some(reference) => schema
            .pointer(reference.strip_prefix('#').unwrap())
            .unwrap(),
        None => shape_kind,
    };
    let shape_kinds = shape_kind["enum"].as_array().unwrap();
    assert!(shape_kinds.contains(&json!("roundedRectangle")));
    assert!(shape_kinds.contains(&json!("rightArrow")));
    let operations = json!([
        {"op":"shapeAdd","id":"ai-line","slideId":"slide-0","shapeKind":"line","x":10.0,"y":20.0,"width":60.0,"height":0.0},
        {"op":"shapeAdd","id":"ai-round","slideId":"slide-0","shapeKind":"roundedRectangle","x":8.0,"y":8.0,"width":50.0,"height":20.0,"text":"발표"},
        {"op":"shapeAdd","id":"ai-arrow","slideId":"slide-0","shapeKind":"rightArrow","x":60.0,"y":8.0,"width":30.0,"height":16.0},
        {"op":"shapeAppearance","id":"ai-line","lineStyle":"solid","lineColor":1122867,"lineWidth":0.5},
        {"op":"shapeDelete","id":"slide-0/shape-0"},
        {"op":"slideBackground","id":"slide-0","fillStyle":"solid","fillColor":15786192},
        {"op":"paragraphText","id":"paragraph-0","text":"문단"},
        {"op":"paragraphStyle","id":"paragraph-0","bold":true},
        {"op":"tableCellText","tableId":"Table1","cell":"A1","text":"셀"},
        {"op":"shapeText","id":"ai-line","text":"literal macro://not-executed"},
        {"op":"shapeStyle","id":"ai-line","fontSize":18.0,"color":0},
        {"op":"shapeGeometry","id":"ai-line","x":0.0,"y":0.0,"width":10.0,"height":0.0},
        {"op":"slideAdd","id":"ai-slide","index":1},
        {"op":"slideMove","id":"ai-slide","index":0},
        {"op":"slideDelete","id":"ai-slide"},
        {"op":"paragraphSplit","id":"paragraph-0","newId":"ai-paragraph","offsetUtf16":1,"expectedTextSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        {"op":"paragraphInsert","id":"ai-insert","referenceId":"paragraph-0","position":"after","expectedTextSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text":"새 문단"},
        {"op":"paragraphJoin","id":"paragraph-0","nextId":"ai-insert","expectedTextSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expectedNextTextSha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
        {"op":"paragraphDelete","id":"ai-paragraph","expectedTextSha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
        {"op":"paragraphFormat","id":"paragraph-0","expectedTextSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","styleName":"Heading 1","alignment":"center","listKind":"number","listLevel":2,"pageBreakBefore":true},
        {"op":"slideDesign","id":"slide-0","changeId":"design-1","expectedDesignSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","masterId":"master-0","layoutCode":0},
        {"op":"slideDisplay","id":"slide-0","visible":false,"showMasterObjects":false},
        {"op":"imageRotate","id":"slide-0/shape-1","expectedRotationHundredths":34800,"rotationHundredths":7800}
    ]);
    let args =
        json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":operations});
    let response = client
        .call_tool(
            CallToolRequestParams::new("office_edit")
                .with_arguments(args.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(response.is_error, Some(false));
    assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], args);
    let before = calls.lock().unwrap().len();
    for invalid in [
        json!({"op":"runMacro","id":"ai-line"}),
        json!({"op":"shapeDelete","id":"ai-line","path":"outside"}),
        json!({"op":"shapeAdd","id":"new","slideId":"slide-0","shapeKind":"image","x":0,"y":0,"width":1,"height":1}),
        json!({"op":"shapeAdd","id":"new","slideId":"slide-0","shapeKind":"rightarrow","x":0,"y":0,"width":1,"height":1}),
        json!({"op":"shapeAppearance","id":"ai-line","fillStyle":"gradient"}),
        json!({"op":"shapeAppearance","id":"ai-line","lineColor":true}),
        json!({"op":"slideBackground","id":"slide-0","fillColor":1.5}),
        json!({"op":"paragraphSplit","id":"paragraph-0","newId":"n","offsetUtf16":-1,"expectedTextSha256":"a"}),
        json!({"op":"paragraphInsert","id":"n","referenceId":"paragraph-0","position":"inside","text":"x","expectedTextSha256":"a"}),
        json!({"op":"paragraphFormat","id":"paragraph-0","expectedTextSha256":"a","alignment":"diagonal"}),
        json!({"op":"paragraphFormat","id":"paragraph-0","expectedTextSha256":"a","listKind":"customScript"}),
        json!({"op":"paragraphDelete","id":"paragraph-0","expectedTextSha256":"a","path":"outside"}),
        json!({"op":"slideDesign","id":"slide-0","changeId":"design-1","expectedDesignSha256":"a","layoutCode":-1}),
        json!({"op":"slideDesign","id":"slide-0","changeId":"design-1","expectedDesignSha256":"a","layoutCode":2}),
        json!({"op":"slideDisplay","id":"slide-0","visible":"false"}),
        json!({"op":"slideDisplay","id":"slide-0","showMasterBackground":false}),
        json!({"op":"imageRotate","id":"slide-0/shape-1","expectedRotationHundredths":34800,"rotationHundredths":7799}),
        json!({"op":"imageRotate","id":"slide-0/shape-1","expectedRotationHundredths":36000,"rotationHundredths":9000}),
        json!({"op":"imageRotate","id":"slide-0/shape-1","rotationHundredths":7800}),
    ] {
        let response = client.call_tool(CallToolRequestParams::new("office_edit")
            .with_arguments(json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":[invalid]})
                .as_object().unwrap().clone())).await.unwrap();
        assert_eq!(response.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), before);
    }
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let denied = client
        .call_tool(
            CallToolRequestParams::new("office_edit")
                .with_arguments(args.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), before);
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_hwpx_table_structure_is_closed_bounded_and_alone() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "office_edit")
        .unwrap();
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    let resolve = |node: &Value| {
        node["$ref"]
            .as_str()
            .and_then(|reference| schema.pointer(reference.strip_prefix('#')?))
    };
    let items = &schema["properties"]["operations"]["items"];
    let branch = resolve(items).unwrap_or(items)["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .find(|branch| branch["properties"]["op"]["const"] == "tableStructure")
        .expect("HWPX existing-table structure is discoverable");
    assert_eq!(branch["additionalProperties"], false);
    let required = branch["required"].as_array().unwrap();
    assert_eq!(required.len(), 4);
    assert!(
        ["op", "id", "action", "index"]
            .into_iter()
            .all(|name| required.contains(&json!(name)))
    );
    assert_eq!(branch["properties"]["index"]["minimum"], 0);
    assert_eq!(branch["properties"]["index"]["maximum"], 64);
    let action_schema = &branch["properties"]["action"];
    let actions = ["insertRow", "deleteRow", "insertColumn", "deleteColumn"];
    assert_eq!(
        resolve(action_schema).unwrap_or(action_schema)["enum"],
        json!(actions)
    );

    let args = |operations| json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":operations});
    let valid = json!({"op":"tableStructure","id":"s0:p3:t0","action":"insertRow","index":0});
    for action in actions {
        let mut operation = valid.clone();
        operation["action"] = json!(action);
        let input = args(json!([operation]));
        let result = client
            .call_tool(
                CallToolRequestParams::new("office_edit")
                    .with_arguments(input.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], input);
    }

    let mut invalid = vec![json!([valid.clone(), valid.clone()])];
    for (key, value) in [
        ("id", json!("s0:p3")),
        ("id", json!("s0:p3:t00")),
        ("action", json!("mergeCells")),
        ("index", json!(-1)),
        ("index", json!(65)),
        ("index", json!(2.0)),
        ("path", json!("outside.hwpx")),
    ] {
        let mut operation = valid.clone();
        operation[key] = value;
        invalid.push(json!([operation]));
    }
    let count = calls.lock().unwrap().len();
    for operations in invalid {
        let input = args(operations);
        let result = client
            .call_tool(
                CallToolRequestParams::new("office_edit")
                    .with_arguments(input.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), count);
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_hwpx_table_insert_is_closed_bounded_and_alone() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "office_edit")
        .unwrap();
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    let resolve = |node: &Value| {
        node["$ref"]
            .as_str()
            .and_then(|reference| schema.pointer(reference.strip_prefix('#')?))
    };
    let items = &schema["properties"]["operations"]["items"];
    let operation_schema = resolve(items).unwrap_or(items);
    let table = operation_schema["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .find(|branch| branch["properties"]["op"]["const"] == "tableInsert")
        .expect("HWPX table insertion is discoverable");
    assert_eq!(table["additionalProperties"], false);
    let fields = [
        "op",
        "id",
        "referenceId",
        "position",
        "expectedTextSha256",
        "rows",
        "columns",
    ];
    let required = table["required"].as_array().unwrap();
    assert_eq!(required.len(), fields.len());
    for field in fields {
        assert!(required.contains(&json!(field)));
    }
    for (dimension, max) in [("rows", 8), ("columns", 6)] {
        let schema = &table["properties"][dimension];
        assert_eq!(schema["type"], "integer");
        assert_eq!(schema["minimum"], 1);
        assert_eq!(schema["maximum"], max);
    }
    let position = &table["properties"]["position"];
    let position = resolve(position).unwrap_or(position);
    assert!(position["enum"] == json!(["after"]) || position["const"] == "after");
    let cells = &table["properties"]["cells"];
    assert_eq!(cells["type"], "array");
    assert_eq!(cells["minItems"], 1);
    assert_eq!(cells["maxItems"], 8);
    assert_eq!(cells["items"]["type"], "array");
    assert_eq!(cells["items"]["minItems"], 1);
    assert_eq!(cells["items"]["maxItems"], 6);
    assert_eq!(cells["items"]["items"]["type"], "string");
    assert_eq!(cells["items"]["items"]["maxLength"], 120);
    assert!(!required.contains(&json!("cells")));

    let valid = json!({
        "op":"tableInsert","id":"new-table","referenceId":"s0:p3","position":"after",
        "expectedTextSha256":"a".repeat(64),"rows":8,"columns":6
    });
    let args = |operations| {
        json!({
            "noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":operations
        })
    };
    for (rows, columns) in [(8, 6), (1, 1)] {
        let mut operation = valid.clone();
        operation["rows"] = json!(rows);
        operation["columns"] = json!(columns);
        let input = args(json!([operation]));
        let result = client
            .call_tool(
                CallToolRequestParams::new("office_edit")
                    .with_arguments(input.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], input);
    }
    let mut populated = valid.clone();
    populated["rows"] = json!(2);
    populated["columns"] = json!(2);
    populated["cells"] = json!([["  한글 & <A>  ", ""], ["a".repeat(120), "😀".repeat(60)]]);
    let input = args(json!([populated]));
    let result = client
        .call_tool(
            CallToolRequestParams::new("office_edit")
                .with_arguments(input.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(false));
    assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], input);
    let mut invalid = vec![
        json!([valid.clone(), valid.clone()]),
        json!([valid.clone(), {"op":"paragraphText","id":"s0:p3","text":"other"}]),
    ];
    for (field, value) in [
        ("id", json!(" ")),
        ("id", json!("s0:p3")),
        ("id", json!("x".repeat(257))),
        ("referenceId", json!("s00:p3")),
        ("referenceId", json!("paragraph-3")),
        ("position", json!("before")),
        ("expectedTextSha256", json!("A".repeat(64))),
        ("expectedTextSha256", json!("a".repeat(63))),
        ("rows", json!(0)),
        ("rows", json!(9)),
        ("rows", json!(2.0)),
        ("columns", json!(0)),
        ("columns", json!(7)),
        ("columns", json!(true)),
        ("path", json!("outside")),
    ] {
        let mut operation = valid.clone();
        operation[field] = value;
        invalid.push(json!([operation]));
    }
    for cells in [
        json!(null),
        json!([["a", "b"]]),
        json!([["a", "b"], ["c"]]),
        json!([["a", "b"], ["c", "d", "e"]]),
        json!([["a", "b"], ["c", 1]]),
        json!([["a", "b"], ["c", "😀".repeat(61)]]),
        json!([["a", "b"], ["c", "x\nx"]]),
        json!([["a", "b"], ["c", "x\u{0085}x"]]),
        json!([["a", "b"], ["c", "x\u{2028}x"]]),
        json!([["a", "b"], ["c", "x\u{fffe}x"]]),
    ] {
        let mut operation = populated.clone();
        operation["cells"] = cells;
        invalid.push(json!([operation]));
    }
    for operations in invalid {
        let result = client
            .call_tool(
                CallToolRequestParams::new("office_edit")
                    .with_arguments(args(operations).as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), 3);
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_database_action_schema_null_values_and_write_revocation() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "database_action")
        .unwrap();
    assert_eq!(
        tool.annotations.as_ref().unwrap().read_only_hint,
        Some(false)
    );
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    assert_eq!(schema["type"], "object");
    assert!(
        schema["oneOf"]
            .as_array()
            .unwrap()
            .iter()
            .all(|branch| branch["additionalProperties"] == false)
    );
    let task_links = schema["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .find(|branch| branch["properties"]["action"]["const"] == "set_task_links")
        .unwrap();
    assert!(
        task_links["required"]
            .as_array()
            .unwrap()
            .contains(&json!("parentId"))
    );
    assert_eq!(
        task_links["properties"]["parentId"]["type"],
        json!(["string", "null"])
    );
    for (action, fields) in [
        ("run_button", json!({"ruleId":NOTE,"rowId":REV})),
        ("add_row", json!({"values":{NOTE:"AI 항목"}})),
        (
            "add_row",
            json!({"templateId":REV,"parentTaskId":NOTE,"values":{NOTE:"AI 항목"}}),
        ),
        (
            "create_row_template",
            json!({"rowId":NOTE,"name":"기록 템플릿"}),
        ),
        ("delete_row_template", json!({"templateId":REV})),
        (
            "set_cell",
            json!({"rowId":NOTE,"propertyId":REV,"value":null}),
        ),
        (
            "set_task_links",
            json!({"rowId":NOTE,"parentId":null,"predecessorIds":[REV]}),
        ),
        (
            "put_rule",
            json!({"rule":{"id":NOTE,"name":"규칙","actions":[]}}),
        ),
        ("archive_rule", json!({"ruleId":NOTE})),
    ] {
        let mut args =
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"action":action});
        args.as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        let response = client
            .call_tool(
                CallToolRequestParams::new("database_action")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(response.is_error, Some(false));
        let last = calls.lock().unwrap().last().unwrap().clone();
        assert_eq!(last["operation"], "database_action");
        assert_eq!(last["arguments"], args);
    }
    let before = calls.lock().unwrap().len();
    for (args, detail) in [
        (
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"action":"unknown"}),
            "unknown variant `unknown`",
        ),
        (
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"action":"add_row","shell":"outside"}),
            "unknown field `shell`",
        ),
        (
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"action":"set_cell","rowId":NOTE,"propertyId":REV}),
            "missing field `value`",
        ),
        (
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"action":"set_task_links","rowId":NOTE,"predecessorIds":[]}),
            "missing field `parentId`",
        ),
        (
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"action":"set_task_links","rowId":NOTE,"parentId":true,"predecessorIds":[]}),
            "parentId must be text or null",
        ),
        (
            json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"action":"add_row","rowId":NOTE}),
            "unknown field `rowId`",
        ),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new("database_action")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        let text = result
            .content
            .iter()
            .filter_map(|content| content.as_text())
            .map(|text| text.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(text.contains("failed to deserialize parameters"), "{text}");
        assert!(text.contains(detail), "{text}");
        assert_eq!(calls.lock().unwrap().len(), before);
    }
    assert_eq!(calls.lock().unwrap().len(), before);
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let denied = client.call_tool(CallToolRequestParams::new("database_action").with_arguments(json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"action":"add_row","values":{}}).as_object().unwrap().clone())).await.unwrap();
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), before);
    let read_args = json!({"noteId":NOTE,"expectedRevisionId":REV,"rowId":NOTE});
    let read_tool = tools
        .iter()
        .find(|tool| tool.name == "database_task_links")
        .unwrap();
    assert_eq!(
        read_tool.annotations.as_ref().unwrap().read_only_hint,
        Some(true)
    );
    let read = client
        .call_tool(
            CallToolRequestParams::new("database_task_links")
                .with_arguments(read_args.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(read.is_error, Some(false));
    assert_eq!(
        read.structured_content.unwrap()["predecessorIds"],
        json!([REV])
    );
    let last = calls.lock().unwrap().last().unwrap().clone();
    assert_eq!(last["operation"], "database_task_links");
    assert_eq!(last["arguments"], read_args);
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_database_query_is_read_only_typed_and_forwards_snapshot_constraints() {
    let (_temp, path, calls, task) = fixture().await;
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "database_query")
        .expect("read-only Rust query tool is registered");
    assert_eq!(
        tool.annotations.as_ref().unwrap().read_only_hint,
        Some(true)
    );
    assert_eq!(
        tool.annotations.as_ref().unwrap().destructive_hint,
        Some(false)
    );
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    assert_eq!(schema["type"], "object");
    assert_eq!(schema["additionalProperties"], false);
    let args = json!({"noteId":NOTE,"expectedRevisionId":REV,"relatedDatabases":[{"noteId":REV,"expectedRevisionId":NOTE}],"capturedAtUtc":"2026-10-30T12:00:00.000Z","maxDepth":32,"budget":1000,"operations":[{"type":"value","rowId":NOTE,"propertyId":REV}]});
    let result = client
        .call_tool(
            CallToolRequestParams::new("database_query")
                .with_arguments(args.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(false));
    assert_eq!(result.structured_content.unwrap()["results"][0]["value"], 6);
    assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], args);
    let before = calls.lock().unwrap().len();
    for invalid in [
        json!({"noteId":NOTE,"expectedRevisionId":REV,"operations":[],"database":{}}),
        json!({"noteId":NOTE,"expectedRevisionId":REV,"operations":[{"type":"execute_shell","command":"outside"}]}),
        json!({"noteId":NOTE,"expectedRevisionId":REV,"relatedDatabases":[{"noteId":REV,"expectedRevisionId":NOTE,"path":"outside"}],"operations":[]}),
        json!({"noteId":NOTE,"expectedRevisionId":REV,"operations":[{"type":"value","rowId":NOTE,"propertyId":REV,"value":"outside"}]}),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new("database_query")
                    .with_arguments(invalid.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), before);
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_query_dataview_is_closed_bounded_and_read_only() {
    let (_temp, path, calls, task) = fixture().await;
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "query_dataview")
        .expect("read-only Dataview tool is registered");
    let annotations = tool.annotations.as_ref().unwrap();
    assert_eq!(annotations.read_only_hint, Some(true));
    assert_eq!(annotations.destructive_hint, Some(false));
    assert_eq!(annotations.open_world_hint, Some(false));
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    assert_eq!(schema["type"], "object");
    assert_eq!(schema["additionalProperties"], false);
    assert_eq!(schema["required"], json!(["query"]));
    assert_eq!(schema["properties"]["query"]["type"], "string");
    assert_eq!(schema["properties"]["query"]["minLength"], 1);
    assert_eq!(schema["properties"]["query"]["maxLength"], 4096);

    for (query, expected) in [
        (
            "TABLE status AS \"상태\" FROM #연구 WHERE status = \"진행\" LIMIT 3".into(),
            json!({
                "mode": "table",
                "columns": [{"field": "status", "label": "상태"}],
                "rows": [{"noteId": NOTE, "title": "연구 메모", "path": "연구/연구 메모.md", "values": ["진행"]}],
            }),
        ),
        (
            format!("LIST{}", " ".repeat(4092)),
            json!({
                "mode": "list",
                "columns": [],
                "rows": [{"noteId": NOTE, "title": "연구 메모", "path": "연구/연구 메모.md", "values": []}],
            }),
        ),
    ] {
        let args = json!({"query": query});
        let result = client
            .call_tool(
                CallToolRequestParams::new("query_dataview")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        assert_eq!(result.structured_content.unwrap(), expected);
        assert_eq!(
            calls.lock().unwrap().last().unwrap(),
            &json!({"operation": "query_dataview", "arguments": args})
        );
    }
    let before = calls.lock().unwrap().len();
    for args in [
        json!({}),
        json!({"query": null}),
        json!({"query": 7}),
        json!({"query": "LIST", "vaultId": NOTE}),
        json!({"query": ""}),
        json!({"query": " \r\n\t"}),
        json!({"query": format!("LIST {}", "😀".repeat(2046))}),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new("query_dataview")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), before);
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_search_documents_is_read_only_bounded_and_preserves_expression() {
    let (_temp, path, calls, task) = fixture().await;
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "search_documents")
        .expect("read-only document search tool is registered");
    let annotations = tool.annotations.as_ref().unwrap();
    assert_eq!(annotations.read_only_hint, Some(true));
    assert_eq!(annotations.destructive_hint, Some(false));
    assert_eq!(annotations.open_world_hint, Some(false));
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    assert_eq!(schema["additionalProperties"], false);
    assert_eq!(schema["required"], json!(["query"]));
    assert_eq!(schema["properties"]["query"]["type"], "string");
    assert_eq!(schema["properties"]["query"]["minLength"], 1);
    assert_eq!(schema["properties"]["query"]["maxLength"], 2048);
    for (key, min, max) in [("limit", 1, 100), ("offset", 0, 1_000_000)] {
        let property = &schema["properties"][key];
        assert_eq!(property["type"], json!(["integer", "null"]));
        assert_eq!(property["minimum"], min);
        assert_eq!(property["maximum"], max);
    }

    for (args, offset, limit) in [
        (
            json!({"query":"  path:\"연구 자료\" (tag:#중요 OR content:\"시험\") -file:초안  "}),
            0,
            50,
        ),
        (
            json!({"query":"😀".repeat(1024),"limit":100,"offset":1_000_000}),
            1_000_000,
            100,
        ),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new("search_documents")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        assert_eq!(
            result.structured_content.unwrap(),
            json!({
                "matches": [{"noteId": NOTE, "title": "연구 메모", "path": "연구/연구 메모.md", "snippet": "연구 중", "score": 4}],
                "total": 1, "offset": offset, "limit": limit,
            })
        );
        assert_eq!(
            calls.lock().unwrap().last().unwrap(),
            &json!({"operation": "search_documents", "arguments": args})
        );
    }
    let result = client
        .call_tool(
            CallToolRequestParams::new("search_documents").with_arguments(
                json!({"query": "tag:#중요", "limit": null, "offset": null})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        )
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(false));
    assert_eq!(
        calls.lock().unwrap().last().unwrap(),
        &json!({"operation": "search_documents", "arguments": {"query": "tag:#중요"}})
    );

    let args = json!({"query": "title:"});
    let result = client
        .call_tool(
            CallToolRequestParams::new("search_documents")
                .with_arguments(args.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(true));
    assert_eq!(
        result.structured_content.unwrap()["code"],
        "invalid_search_expression"
    );
    assert_eq!(
        calls.lock().unwrap().last().unwrap(),
        &json!({"operation": "search_documents", "arguments": args})
    );

    let before = calls.lock().unwrap().len();
    for args in [
        json!({}),
        json!({"query": null}),
        json!({"query": " \r\n\t"}),
        json!({"query": format!("{} ", "😀".repeat(1024))}),
        json!({"query": "memo", "vaultId": NOTE}),
        json!({"query": "memo", "limit": 0}),
        json!({"query": "memo", "limit": 101}),
        json!({"query": "memo", "limit": 1.5}),
        json!({"query": "memo", "offset": -1}),
        json!({"query": "memo", "offset": 1_000_001}),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new("search_documents")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), before);
    }
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_pptx_table_structure_has_closed_schema_and_preserves_authority() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    fn resolve<'a>(root: &'a Value, schema: &'a Value) -> &'a Value {
        if let Some(reference) = schema["$ref"].as_str() {
            root.pointer(reference.strip_prefix('#').unwrap()).unwrap()
        } else {
            schema
        }
    }
    let read = tools
        .iter()
        .find(|tool| tool.name == "read_document")
        .unwrap();
    let read_schema = serde_json::to_value(&read.input_schema).unwrap();
    let query = resolve(
        &read_schema,
        &read_schema["properties"]["pptxTableStructure"],
    );
    assert_eq!(query["type"], "object");
    assert_eq!(query["additionalProperties"], false);
    assert_eq!(query["properties"].as_object().unwrap().len(), 3);
    for (field, min, max) in [
        ("slideIndex", 0.0, 255.0),
        ("tableOffset", 0.0, 400.0),
        ("tableLimit", 1.0, 32.0),
    ] {
        let numeric = &query["properties"][field];
        assert_eq!(numeric["type"], "integer");
        assert_eq!(numeric["minimum"].as_f64(), Some(min));
        assert_eq!(numeric["maximum"].as_f64(), Some(max));
    }
    let edit = tools
        .iter()
        .find(|tool| tool.name == "office_edit")
        .unwrap();
    let edit_schema = serde_json::to_value(&edit.input_schema).unwrap();
    let operation = resolve(
        &edit_schema,
        &edit_schema["properties"]["operations"]["items"],
    )["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .find(|branch| branch["properties"]["op"]["const"] == "presentationTableStructureEdit")
        .unwrap();
    assert_eq!(operation["additionalProperties"], false);
    let properties = operation["properties"].as_object().unwrap();
    let expected = [
        "op",
        "expectedSourceSha256",
        "slideIndex",
        "shapeId",
        "action",
        "index",
    ]
    .into_iter()
    .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(
        properties
            .keys()
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>(),
        expected
    );
    assert_eq!(
        operation["required"]
            .as_array()
            .unwrap()
            .iter()
            .map(|field| field.as_str().unwrap())
            .collect::<std::collections::BTreeSet<_>>(),
        expected
    );
    assert_eq!(
        properties["expectedSourceSha256"]["pattern"],
        "^[0-9a-f]{64}$"
    );
    assert_eq!(properties["shapeId"]["minimum"].as_f64(), Some(1.0));
    assert_eq!(
        properties["shapeId"]["maximum"].as_f64(),
        Some(4_294_967_295.0)
    );
    let actions = resolve(&edit_schema, &properties["action"]);
    assert_eq!(
        actions["enum"],
        json!([
            "insertRowBefore",
            "insertRowAfter",
            "insertColumnBefore",
            "insertColumnAfter",
            "deleteRow",
            "deleteColumn",
        ])
    );

    for query in [
        json!({}),
        json!({"slideIndex": 255, "tableOffset": 400, "tableLimit": 32}),
    ] {
        let args = json!({"noteId": NOTE, "pptxTableStructure": query});
        let response = client
            .call_tool(
                CallToolRequestParams::new("read_document")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(response.is_error, Some(false));
        assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], args);
    }
    let baseline = calls.lock().unwrap().len();
    for args in [
        json!({"noteId": NOTE, "revisionId": REV, "pptxTableStructure": {}}),
        json!({"noteId": NOTE, "pptxTableStructure": {"tableOffset": 0}}),
        json!({"noteId": NOTE, "pptxTableStructure": {"tableLimit": 16}}),
        json!({"noteId": NOTE, "pptxTableStructure": {"slideIndex": 0, "tableOffset": 401}}),
        json!({"noteId": NOTE, "pptxTableStructure": {"slideIndex": 0, "tableLimit": 0}}),
        json!({"noteId": NOTE, "pptxTableStructure": {"slideIndex": 0, "tableLimit": 33}}),
        json!({"noteId": NOTE, "pptxTableStructure": {"slideIndex": null}}),
        json!({"noteId": NOTE, "pptxTableStructure": {"slideIndex": 0, "path": "outside.pptx"}}),
    ] {
        let response = client
            .call_tool(
                CallToolRequestParams::new("read_document")
                    .with_arguments(args.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(response.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), baseline);
    }
    let patch = json!({
        "op": "presentationTableStructureEdit", "expectedSourceSha256": "a".repeat(64),
        "slideIndex": 2, "shapeId": 32, "action": "deleteColumn", "index": 1,
    });
    let args = json!({"noteId": NOTE, "expectedRevisionId": REV, "requestId": NOTE, "operations": [patch]});
    let response = client
        .call_tool(
            CallToolRequestParams::new("office_edit")
                .with_arguments(args.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(response.is_error, Some(false));
    assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], args);

    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let before = calls.lock().unwrap().len();
    let denied = client
        .call_tool(
            CallToolRequestParams::new("office_edit")
                .with_arguments(args.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), before);
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_docx_table_structure_keeps_typed_authority_and_write_permission() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    fn resolve<'a>(root: &'a Value, schema: &'a Value) -> &'a Value {
        if let Some(reference) = schema["$ref"].as_str() {
            root.pointer(reference.strip_prefix('#').unwrap()).unwrap()
        } else {
            schema
        }
    }
    let schema = |name| {
        let tool = tools.iter().find(|tool| tool.name == name).unwrap();
        serde_json::to_value(&tool.input_schema).unwrap()
    };
    let read_schema = schema("read_document");
    let query = resolve(
        &read_schema,
        &read_schema["properties"]["docxTableStructure"],
    );
    assert_eq!(query["type"], "object");
    assert_eq!(query["additionalProperties"], false);
    assert_eq!(query["properties"].as_object().unwrap().len(), 2);
    for (field, min, max) in [("tableOffset", 0.0, 512.0), ("tableLimit", 1.0, 32.0)] {
        let property = &query["properties"][field];
        assert_eq!(property["type"], "integer");
        assert_eq!(property["minimum"].as_f64(), Some(min));
        assert_eq!(property["maximum"].as_f64(), Some(max));
    }
    let edit_schema = schema("office_edit");
    let operation = resolve(
        &edit_schema,
        &edit_schema["properties"]["operations"]["items"],
    )["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .find(|branch| branch["properties"]["op"]["const"] == "docxTableStructureEdit")
        .unwrap();
    assert_eq!(operation["additionalProperties"], false);
    assert_eq!(operation["properties"].as_object().unwrap().len(), 6);
    assert_eq!(operation["required"].as_array().unwrap().len(), 5);
    assert!(
        !operation["required"]
            .as_array()
            .unwrap()
            .contains(&json!("anchorIndex"))
    );
    let properties = &operation["properties"];
    assert_eq!(
        properties["expectedSourceSha256"]["pattern"],
        "^[0-9a-f]{64}$"
    );
    assert_eq!(properties["tableIndex"]["maximum"].as_f64(), Some(511.0));
    assert_eq!(properties["anchorIndex"]["type"], "integer");
    assert_eq!(
        resolve(&edit_schema, &properties["action"])["enum"],
        json!(["insertRow", "deleteRow", "insertColumn", "deleteColumn"])
    );

    let args = json!({"noteId":NOTE,"docxTableStructure":{"tableOffset":512,"tableLimit":32}});
    let patch = json!({"op":"docxTableStructureEdit","expectedSourceSha256":"a".repeat(64),
        "tableIndex":511,"action":"insertColumn","index":32,"anchorIndex":31});
    let edit =
        json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":[patch]});
    for (tool, request) in [
        (
            "read_document",
            json!({"noteId":NOTE,"docxTableStructure":{}}),
        ),
        ("read_document", args.clone()),
        ("office_edit", edit.clone()),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new(tool)
                    .with_arguments(request.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(false));
        assert_eq!(calls.lock().unwrap().last().unwrap()["arguments"], request);
    }
    let baseline = calls.lock().unwrap().len();
    for request in [
        json!({"noteId":NOTE,"revisionId":REV,"docxTableStructure":{}}),
        json!({"noteId":NOTE,"revisionId":null,"docxTableStructure":{}}),
        json!({"noteId":NOTE,"pptxTableStructure":{},"docxTableStructure":{}}),
        json!({"noteId":NOTE,"docxTableStructure":{"tableOffset":513}}),
        json!({"noteId":NOTE,"docxTableStructure":{"tableLimit":0}}),
        json!({"noteId":NOTE,"docxTableStructure":{"tableLimit":33}}),
        json!({"noteId":NOTE,"docxTableStructure":{"tableLimit":null}}),
    ] {
        let result = client
            .call_tool(
                CallToolRequestParams::new("read_document")
                    .with_arguments(request.as_object().unwrap().clone()),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true), "{request}");
        assert_eq!(calls.lock().unwrap().len(), baseline);
    }

    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let denied = client
        .call_tool(
            CallToolRequestParams::new("office_edit")
                .with_arguments(edit.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), baseline);
    let still_readable = client
        .call_tool(
            CallToolRequestParams::new("read_document")
                .with_arguments(args.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(still_readable.is_error, Some(false));
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_discover_client_and_runtime_permission_rotation_use_the_same_sdk_server() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, true).await;
    client
        .call_tool(CallToolRequestParams::new("vault_status"))
        .await
        .unwrap();
    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let count = calls.lock().unwrap().len();
    let denied = client
        .call_tool(
            CallToolRequestParams::new("create_document").with_arguments(
                json!({"title":"AI 메모","kind":"markdown","requestId":"create-1"})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        )
        .await
        .unwrap();
    assert_eq!(denied.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), count);
    config.write_enabled = true;
    config.token = "wrong-token-not-logged".into();
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let auth = client
        .call_tool(CallToolRequestParams::new("vault_status"))
        .await
        .unwrap();
    assert_eq!(auth.structured_content.unwrap()["code"], "unauthorized");
    config.token = TOKEN.into();
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let count = calls.lock().unwrap().len();
    let invalid = client
        .call_tool(
            CallToolRequestParams::new("read_document").with_arguments(
                json!({"noteId":NOTE,"origin":"https://outside.invalid"})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        )
        .await
        .unwrap();
    assert_eq!(invalid.is_error, Some(true));
    assert!(
        serde_json::to_value(invalid)
            .unwrap()
            .to_string()
            .contains("origin")
    );
    assert_eq!(calls.lock().unwrap().len(), count);
    assert!(
        client
            .read_resource(ReadResourceRequestParams::new("file:///outside"))
            .await
            .is_err()
    );
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn missing_app_still_exposes_an_explicit_tool_error_after_stdio_initialize() {
    let temp = tempfile::tempdir().unwrap();
    let client = client(&temp.path().join("missing.json"), false).await;
    let result = client
        .call_tool(CallToolRequestParams::new("vault_status"))
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(true));
    assert_eq!(
        result.structured_content.unwrap()["code"],
        "app_not_running"
    );
    client.cancel().await.unwrap();
}

#[tokio::test]
async fn environment_bridge_path_uses_the_same_executable_stdio_contract() {
    let (_temp, path, _calls, task) = fixture().await;
    let executable = std::env::var_os("INK_VAULT_MCP_TEST_EXE")
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_ink_vault_mcp").into());
    let mut command = tokio::process::Command::new(executable);
    command.env("INK_VAULT_MCP_BRIDGE", path);
    let transport = TokioChildProcess::new(command).unwrap();
    let client = ClientConfig::default()
        .with_protocol_version(ProtocolVersion::LATEST_WITH_INITIALIZE)
        .serve(transport)
        .await
        .unwrap();
    let result = client
        .call_tool(CallToolRequestParams::new("vault_status"))
        .await
        .unwrap();
    assert_eq!(result.structured_content.unwrap()["running"], true);
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_slide_duplicate_accepts_only_one_saved_slide_on_write_connection() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "office_edit")
        .unwrap();
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    let items = &schema["properties"]["operations"]["items"];
    let operations = if let Some(reference) = items["$ref"].as_str() {
        schema
            .pointer(reference.strip_prefix('#').unwrap())
            .unwrap()
    } else {
        items
    };
    let branch = operations["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["properties"]["op"]["const"] == "slideDuplicate")
        .expect("slide duplication is discoverable as a closed operation");
    assert_eq!(branch["additionalProperties"], false);
    assert_eq!(branch["properties"].as_object().unwrap().len(), 2);
    assert!(
        branch["required"]
            .as_array()
            .unwrap()
            .contains(&json!("id"))
    );
    assert_eq!(branch["properties"]["id"]["maxLength"], 12);

    let duplicate = json!({"op":"slideDuplicate","id":"slide-0"});
    let args = |operations: Vec<Value>| {
        json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":operations})
            .as_object()
            .unwrap()
            .clone()
    };
    let valid = args(vec![duplicate.clone()]);
    let result = client
        .call_tool(CallToolRequestParams::new("office_edit").with_arguments(valid.clone()))
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(false));
    assert_eq!(
        calls.lock().unwrap()[0],
        json!({"operation":"office_edit","arguments":valid})
    );

    for invalid in [
        vec![json!({"op":"slideDuplicate","id":"slide-01"})],
        vec![json!({"op":"slideDuplicate","id":"slide-1000000"})],
        vec![json!({"op":"slideDuplicate","id":"master-0"})],
        vec![json!({"op":"slideDuplicate","id":"slide-0\n"})],
        vec![json!({"op":"slideDuplicate","id":"slide-0","index":4})],
        vec![
            duplicate.clone(),
            json!({"op":"slideMove","id":"slide-0","index":1}),
        ],
        vec![duplicate.clone(), duplicate.clone()],
    ] {
        let result = client
            .call_tool(CallToolRequestParams::new("office_edit").with_arguments(args(invalid)))
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert_eq!(
            calls.lock().unwrap().len(),
            1,
            "invalid edit reached the app"
        );
    }

    let mut config: BridgeConfig =
        serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    config.write_enabled = false;
    tokio::fs::write(&path, serde_json::to_vec(&config).unwrap())
        .await
        .unwrap();
    let result = client
        .call_tool(CallToolRequestParams::new("office_edit").with_arguments(valid))
        .await
        .unwrap();
    assert_eq!(result.is_error, Some(true));
    assert_eq!(result.structured_content.unwrap()["code"], "read_only");
    assert_eq!(calls.lock().unwrap().len(), 1);
    client.cancel().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn actual_stdio_source_text_patch_schema_is_flat_closed_and_preserves_every_guard() {
    let (_temp, path, calls, task) = fixture().await;
    let client = client(&path, false).await;
    let tools = client.list_all_tools().await.unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name == "office_edit")
        .unwrap();
    let schema = serde_json::to_value(&tool.input_schema).unwrap();
    let items = &schema["properties"]["operations"]["items"];
    let operations = if let Some(reference) = items["$ref"].as_str() {
        schema
            .pointer(reference.strip_prefix('#').unwrap())
            .unwrap()
    } else {
        items
    };
    let branch = operations["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["properties"]["op"]["const"] == "presentationCellTextPatch")
        .expect("source text operation is discoverable as a flat independent branch");
    assert_eq!(branch["additionalProperties"], false);
    let mut required: Vec<_> = branch["required"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    required.sort();
    let mut expected = vec![
        "op",
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
    ];
    expected.sort();
    assert_eq!(required, expected);
    assert_eq!(branch["properties"].as_object().unwrap().len(), 13);
    assert_eq!(branch["properties"]["authorityVersion"]["minimum"], 1);
    assert_eq!(branch["properties"]["authorityVersion"]["maximum"], 1);
    assert_eq!(branch["properties"]["startUtf16"]["minimum"], 0);
    assert_eq!(branch["properties"]["endUtf16"]["maximum"], 131072);
    let operation = json!({
        "op":"presentationCellTextPatch","authorityVersion":1,
        "ownerId":"slide-0","tableId":"slide-0/shape-7","cellId":"stable-cell-42",
        "expectedSourceSha256":"a".repeat(64),"sourcePart":"ppt/slides/slide1.xml","shapeId":"0009",
        "expectedSourceFrameSha256":"b".repeat(64),"expectedTextSha256":"c".repeat(64),
        "startUtf16":0,"endUtf16":4,"text":""
    });
    let arguments = json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":[operation.clone()]});
    let response = client
        .call_tool(
            CallToolRequestParams::new("office_edit")
                .with_arguments(arguments.as_object().unwrap().clone()),
        )
        .await
        .unwrap();
    assert_eq!(response.is_error, Some(false));
    assert_eq!(
        calls.lock().unwrap().last().unwrap()["arguments"],
        arguments
    );
    let before = calls.lock().unwrap().len();
    let mut invalid = Vec::new();
    for (name, value) in [
        ("extra", json!(1)),
        ("authorityVersion", json!(2)),
        ("expectedSourceFrameSha256", json!("B".repeat(64))),
        ("startUtf16", json!(true)),
        ("endUtf16", json!(131073)),
        ("sourcePart", json!("../slide.xml")),
        ("shapeId", json!("shape-9")),
    ] {
        let mut value_op = operation.clone();
        value_op[name] = value;
        invalid.push(vec![value_op]);
    }
    invalid.push(vec![operation.clone(); 101]);
    invalid.push(vec![
        operation,
        json!({"op":"shapeText","id":"shape-0","text":""}),
    ]);
    for operations in invalid {
        let response = client.call_tool(CallToolRequestParams::new("office_edit")
            .with_arguments(json!({"noteId":NOTE,"expectedRevisionId":REV,"requestId":NOTE,"operations":operations})
                .as_object().unwrap().clone())).await.unwrap();
        assert_eq!(response.is_error, Some(true));
        assert_eq!(calls.lock().unwrap().len(), before);
    }
    client.cancel().await.unwrap();
    task.abort();
}
