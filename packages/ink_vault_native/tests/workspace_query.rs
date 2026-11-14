use ink_vault_native::request_json;
use serde_json::{Value, json};

const DB: &str = "11111111-1111-4111-8111-111111111111";
const ROW: &str = "22222222-2222-4222-8222-222222222222";
const NUMBER: &str = "33333333-3333-4333-8333-333333333333";

fn pack(value: &Value, nodes: &mut Vec<Value>) -> usize {
    let node = match value {
        Value::String(value) => json!(["s", value.encode_utf16().collect::<Vec<_>>()]),
        Value::Array(values) => {
            let children = values.iter().map(|v| pack(v, nodes)).collect::<Vec<_>>();
            json!(["a", children])
        }
        Value::Object(values) => {
            let entries = values
                .iter()
                .map(|(key, value)| {
                    let child = pack(value, nodes);
                    json!([key.encode_utf16().collect::<Vec<_>>(), child])
                })
                .collect::<Vec<_>>();
            json!(["o", entries])
        }
        primitive => primitive.clone(),
    };
    let index = nodes.len();
    nodes.push(node);
    index
}

fn unpack(index: usize, nodes: &[Value]) -> Value {
    let node = &nodes[index];
    let Some(tagged) = node.as_array() else {
        return node.clone();
    };
    match tagged[0].as_str().unwrap() {
        "s" => Value::String(
            String::from_utf16(
                &tagged[1]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_u64().unwrap() as u16)
                    .collect::<Vec<_>>(),
            )
            .unwrap(),
        ),
        "a" => Value::Array(
            tagged[1]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| unpack(v.as_u64().unwrap() as usize, nodes))
                .collect(),
        ),
        "o" => Value::Object(
            tagged[1]
                .as_array()
                .unwrap()
                .iter()
                .map(|entry| {
                    let key = String::from_utf16(
                        &entry[0]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|v| v.as_u64().unwrap() as u16)
                            .collect::<Vec<_>>(),
                    )
                    .unwrap();
                    (key, unpack(entry[1].as_u64().unwrap() as usize, nodes))
                })
                .collect(),
        ),
        _ => panic!("unexpected native codec tag"),
    }
}

fn query(budget: i64, operations: Value) -> Value {
    let logical = json!({
        "op":"workspace_query", "schemaVersion":1,
        "database":{
            "schemaVersion":1,"id":DB,
            "properties":[{"id":NUMBER,"name":"수량","type":"number","config":{}}],
            "rows":[{"id":ROW,"values":{NUMBER:3},"archived":false,"body":{"version":1,"blocks":[]}}],
            "views":[],"future":{"preserved":true}
        },
        "databases":[],"budget":budget,"operations":operations
    });
    let mut nodes = Vec::new();
    let root = pack(&logical, &mut nodes);
    let raw = request_json(
        &json!({
            "op":"workspace_query","schemaVersion":1,"encoding":"utf16-v1",
            "payload":{"root":root,"nodes":nodes}
        })
        .to_string(),
    );
    assert!(raw.get("error").is_none(), "{raw}");
    assert_eq!(raw["encoding"], "utf16-v1");
    unpack(
        raw["payload"]["root"].as_u64().unwrap() as usize,
        raw["payload"]["nodes"].as_array().unwrap(),
    )
}

#[test]
fn a_batch_shares_budget_even_when_the_second_value_is_cached() {
    let result = query(
        1,
        json!([
            {"type":"value","rowId":ROW,"propertyId":NUMBER},
            {"type":"value","rowId":ROW,"propertyId":NUMBER}
        ]),
    );
    assert_eq!(result["results"][0], json!({"value":3}));
    assert_eq!(result["results"][1]["value"], Value::Null);
    assert_eq!(result["results"][1]["error"]["code"], "budget_exceeded");
    assert_eq!(result["errors"].as_array().unwrap().len(), 1);
    assert_eq!(result["remainingBudget"], -1);
}

#[test]
fn a_flat_node_cannot_alias_another_child_to_amplify_the_query() {
    let response = request_json(
        &json!({
            "op":"workspace_query","schemaVersion":1,"encoding":"utf16-v1",
            "payload":{"root":1,"nodes":[1,["a",[0,0]]]}
        })
        .to_string(),
    );
    assert_eq!(response["error"]["code"], "invalid_request");
}

#[test]
fn repeated_apply_cannot_accumulate_unbounded_uuid_copies_before_encoding() {
    let rows = (0..1000)
        .map(|index| {
            json!({
                "id":format!("{index:08x}-2222-4222-8222-222222222222"),"values":{}
            })
        })
        .collect::<Vec<_>>();
    let operations = (0..128)
        .map(|_| json!({"type":"apply","view":{}}))
        .collect::<Vec<_>>();
    let logical = json!({"op":"workspace_query","schemaVersion":1,
        "database":{"id":DB,"properties":[],"rows":rows},"operations":operations});
    let mut nodes = Vec::new();
    let root = pack(&logical, &mut nodes);
    let response = request_json(
        &json!({"op":"workspace_query","schemaVersion":1,
        "encoding":"utf16-v1","payload":{"root":root,"nodes":nodes}})
        .to_string(),
    );
    assert_eq!(response["error"]["code"], "query_too_large");
    assert!(response.get("results").is_none());
    assert!(response.get("payload").is_none());
}

#[test]
fn an_invalid_later_operation_never_returns_an_earlier_partial_result() {
    let logical = json!({"op":"workspace_query","schemaVersion":1,
        "database":{"id":DB,"properties":[],"rows":[]},
        "operations":[{"type":"apply","view":{}},{"type":"invalid"}]});
    let mut nodes = Vec::new();
    let root = pack(&logical, &mut nodes);
    let response = request_json(
        &json!({"op":"workspace_query","schemaVersion":1,
        "encoding":"utf16-v1","payload":{"root":root,"nodes":nodes}})
        .to_string(),
    );
    assert_eq!(response["error"]["code"], "invalid_request");
    assert!(response.get("results").is_none());
    assert!(response.get("payload").is_none());
}

#[derive(Debug, PartialEq, Eq)]
enum Observed {
    Null,
    Bool(bool),
    Int(i64),
    Float(u64),
    Text(Vec<u16>),
    Array(Vec<Observed>),
    Object(Vec<(Vec<u16>, Observed)>),
}

fn observed(payload: &Value) -> Observed {
    fn at(index: usize, nodes: &[Value], raw: bool, top: bool) -> Observed {
        let value = &nodes[index];
        if value.is_null() {
            return Observed::Null;
        }
        if let Some(value) = value.as_bool() {
            return Observed::Bool(value);
        }
        if let Some(value) = value.as_number() {
            return if value.is_f64() {
                Observed::Float(value.as_f64().unwrap().to_bits())
            } else {
                Observed::Int(value.as_i64().unwrap())
            };
        }
        match value[0].as_str().unwrap() {
            "s" => Observed::Text(
                value[1]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_u64().unwrap() as u16)
                    .collect(),
            ),
            "a" => Observed::Array(
                value[1]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| at(v.as_u64().unwrap() as usize, nodes, raw, false))
                    .collect(),
            ),
            "o" => {
                let mut result = Vec::new();
                for entry in value[1].as_array().unwrap() {
                    let key = entry[0]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| v.as_u64().unwrap() as u16)
                        .collect::<Vec<_>>();
                    if top && key == "remainingBudget".encode_utf16().collect::<Vec<_>>() {
                        continue;
                    }
                    let preserve = raw || key == "value".encode_utf16().collect::<Vec<_>>();
                    result.push((
                        key,
                        at(entry[1].as_u64().unwrap() as usize, nodes, preserve, false),
                    ));
                }
                if !raw {
                    result.sort_by(|a, b| a.0.cmp(&b.0));
                }
                Observed::Object(result)
            }
            _ => panic!("unexpected native node"),
        }
    }
    at(
        payload["root"].as_u64().unwrap() as usize,
        payload["nodes"].as_array().unwrap(),
        false,
        true,
    )
}

#[test]
fn all_shared_dart_oracle_vectors_preserve_values_types_errors_and_raw_object_order() {
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/workspace_query_vectors.json")).unwrap();
    let mut failures = Vec::new();
    for case in fixture["cases"].as_array().unwrap() {
        let actual = request_json(&case["request"].to_string());
        if actual.get("error").is_some() {
            eprintln!("{}: {actual}", case["name"]);
            failures.push(case["name"].as_str().unwrap());
            continue;
        }
        let actual = observed(&actual["payload"]);
        let expected = observed(&case["expected"]);
        if actual != expected {
            eprintln!(
                "{}\nexpected: {:?}\nactual: {:?}",
                case["name"], expected, actual
            );
            failures.push(case["name"].as_str().unwrap());
        }
    }
    assert!(failures.is_empty(), "Dart oracle mismatches: {failures:?}");
}
