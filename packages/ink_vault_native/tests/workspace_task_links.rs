use ink_vault_native::request_json;
use serde_json::{Value, json};

const A: &str = "10000000-0000-4000-8000-000000000001";
const B: &str = "10000000-0000-4000-8000-000000000002";
const C: &str = "10000000-0000-4000-8000-000000000003";
const D: &str = "10000000-0000-4000-8000-000000000004";
const ABSENT: &str = "10000000-0000-4000-8000-000000000005";

fn rows(archived: &[&str]) -> Value {
    json!([A, B, C, D].map(|id| json!({"id": id, "archived": archived.contains(&id)})))
}

fn envelope(items: Value) -> Value {
    json!({"schemaVersion": 1, "items": items})
}

fn set(
    rows: Value,
    task_links: Value,
    row_id: &str,
    parent: Option<&str>,
    predecessors: &[&str],
) -> Value {
    request_json(
        &json!({
            "op": "workspace_task_links",
            "rows": rows,
            "taskLinks": task_links,
            "rowId": row_id,
            "parentId": parent,
            "predecessorIds": predecessors,
        })
        .to_string(),
    )
}

#[test]
fn replaces_one_task_and_omits_empty_fields() {
    let original = envelope(json!({(B): {"parentId": D, "predecessorIds": []}}));
    let response = set(rows(&[]), original, A, Some(D), &[B, C]);
    assert_eq!(
        response,
        json!({"taskLinks": envelope(json!({
            (A): {"parentId": D, "predecessorIds": [B, C]},
            (B): {"parentId": D},
        }))}),
    );
    let cleared = set(rows(&[]), response["taskLinks"].clone(), A, None, &[]);
    assert_eq!(
        cleared,
        json!({"taskLinks": envelope(json!({(B): {"parentId": D}}))}),
    );
    assert_eq!(
        set(rows(&[]), Value::Null, A, None, &[]),
        json!({"taskLinks": envelope(json!({}))}),
    );
}

#[test]
fn checks_parent_and_predecessor_cycles_independently() {
    let previous = envelope(json!({
        (A): {"parentId": B},
        (B): {"parentId": C},
    }));
    assert_eq!(
        set(rows(&[]), previous.clone(), C, Some(A), &[])["error"]["code"],
        "task_link_cycle",
    );
    assert_eq!(
        set(rows(&[]), previous, C, None, &[A])["taskLinks"]["items"][C]["predecessorIds"],
        json!([A]),
    );
    let previous = envelope(json!({
        (A): {"predecessorIds": [B]},
        (B): {"predecessorIds": [C]},
    }));
    assert_eq!(
        set(rows(&[]), previous.clone(), C, None, &[A])["error"]["code"],
        "task_link_cycle",
    );
    assert_eq!(
        set(rows(&[]), previous, C, Some(A), &[])["taskLinks"]["items"][C]["parentId"],
        A,
    );
}

#[test]
fn retains_archived_targets_but_checks_latent_cycles_before_restore() {
    let previous = envelope(json!({
        (A): {"parentId": B, "predecessorIds": [B]},
        (B): {"parentId": C, "predecessorIds": [C]},
    }));
    assert_eq!(
        set(rows(&[B]), previous.clone(), A, Some(B), &[B, D])["taskLinks"]["items"][A],
        json!({"parentId": B, "predecessorIds": [B, D]}),
    );
    assert_eq!(
        set(rows(&[B]), previous.clone(), C, Some(B), &[])["error"]["code"],
        "archived_task",
    );
    assert_eq!(
        set(rows(&[B]), previous.clone(), C, Some(A), &[])["error"]["code"],
        "task_link_cycle",
    );
    assert_eq!(
        set(rows(&[B]), previous.clone(), C, None, &[A])["error"]["code"],
        "task_link_cycle",
    );
    assert_eq!(
        set(rows(&[B]), previous.clone(), B, None, &[])["error"]["code"],
        "archived_task",
    );
    assert_eq!(
        set(rows(&[B]), previous, A, None, &[])["taskLinks"]["items"],
        json!({(B): {"parentId": C, "predecessorIds": [C]}}),
    );
}

#[test]
fn prunes_legacy_orphans_but_rejects_new_invalid_links_and_unknown_metadata() {
    let previous = envelope(json!({
        (ABSENT): {"parentId": B},
        (A): {"parentId": ABSENT, "predecessorIds": [ABSENT, B]},
    }));
    assert_eq!(
        set(rows(&[]), previous.clone(), C, Some(D), &[])["taskLinks"]["items"],
        json!({(A): {"predecessorIds": [B]}, (C): {"parentId": D}}),
    );
    assert_eq!(
        set(rows(&[]), previous, C, Some(ABSENT), &[])["error"]["code"],
        "missing_task",
    );
    assert_eq!(
        set(rows(&[]), Value::Null, A, None, &[A])["error"]["code"],
        "self_task_link",
    );
    assert_eq!(
        set(rows(&[]), Value::Null, A, None, &[B, B])["error"]["code"],
        "duplicate_task_link",
    );
    assert_eq!(
        set(
            rows(&[]),
            json!({"schemaVersion": 2, "items": {}}),
            A,
            None,
            &[]
        )["error"]["code"],
        "unsupported_task_links",
    );
    assert!(
        set(
            rows(&[]),
            envelope(json!({(A): {"parentId": B, "unknown": true}})),
            A,
            None,
            &[],
        )["error"]
            .is_object(),
    );
}

#[test]
fn handles_deep_links_iteratively_and_caps_rows_and_predecessors() {
    let ids: Vec<String> = (0..10_001)
        .map(|id| format!("10000000-0000-4000-8000-{id:012x}"))
        .collect();
    let rows: Vec<Value> = ids
        .iter()
        .map(|id| json!({"id": id, "archived": false}))
        .collect();
    let graph = ids[..10_000]
        .windows(2)
        .map(|pair| (pair[0].clone(), json!({"parentId": pair[1]})))
        .collect();
    let previous = envelope(Value::Object(graph));
    let last = &ids[9_999];
    assert_eq!(
        set(json!(rows[..10_000]), previous, last, Some(&ids[0]), &[])["error"]["code"],
        "task_link_cycle",
    );
    assert_eq!(
        set(json!(rows), Value::Null, &ids[0], None, &[])["error"]["code"],
        "task_links_limit",
    );
    let predecessors: Vec<&str> = ids[1..66].iter().map(String::as_str).collect();
    assert_eq!(
        set(
            json!(rows[..100]),
            Value::Null,
            &ids[0],
            None,
            &predecessors
        )["error"]["code"],
        "task_links_limit",
    );
}
