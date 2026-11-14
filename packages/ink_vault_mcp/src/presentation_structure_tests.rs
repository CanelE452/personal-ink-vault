use super::*;

fn operation() -> Value {
    json!({
        "op":"presentationSourceTableAdd", "authorityVersion":1,
        "id":"new-table-fixture_1", "ownerId":"slide-0",
        "expectedSourceSha256":"a".repeat(64),
        "sourcePart":"ppt/slides/slide1.xml",
        "expectedSourcePartSha256":"b".repeat(64),
        "expectedShapeIdInventorySha256":"c".repeat(64),
        "xMm":0.29, "yMm":-0.29,
        "columnWidthsMm":[30,40.01], "rowHeightsMm":[12,12]
    })
}

fn envelope(operations: Vec<Value>) -> Value {
    json!({"noteId":"01234567-89ab-4cde-8fab-0123456789ab",
        "expectedRevisionId":"01234567-89ab-4cde-8fab-0123456789ac",
        "requestId":"source-structure-batch", "operations":operations})
}

#[test]
fn source_structure_flat_closed_operation_roundtrips_exact_hundredths_and_origin_guards() {
    let value = operation();
    let parsed: OfficeOperation = serde_json::from_value(value.clone())
        .expect("the source-created TableShape operation must be a typed variant");
    assert_eq!(serde_json::to_value(parsed).unwrap(), value);
}

#[test]
fn source_structure_rejects_unknown_missing_or_invalid_authority_and_alias_fields() {
    for (key, value) in [
        ("extra", json!(true)), ("authorityVersion", json!(2)),
        ("authorityVersion", json!(true)), ("id", json!("slide-0/shape-0")),
        ("id", json!("new-table-")), ("id", json!("new-table-안됨")),
        ("id", json!(format!("new-table-{}", "x".repeat(65)))),
        ("ownerId", json!("")), ("ownerId", json!("slide-\u{0001}")),
        ("ownerId", json!("x".repeat(257))),
        ("expectedSourceSha256", json!("A".repeat(64))),
        ("expectedSourcePartSha256", json!("b".repeat(63))),
        ("expectedShapeIdInventorySha256", json!("not-a-sha")),
        ("sourcePart", json!("../slide.xml")),
        ("sourcePart", json!("ppt\\slides\\slide1.xml")),
        ("sourcePart", json!("ppt/slides/a%20.xml")),
    ] {
        let mut invalid = operation();
        invalid[key] = value;
        assert!(serde_json::from_value::<OfficeOperation>(invalid).is_err(), "{key}");
    }
    for key in operation().as_object().unwrap().keys() {
        let mut invalid = operation();
        invalid.as_object_mut().unwrap().remove(key);
        assert!(serde_json::from_value::<OfficeOperation>(invalid).is_err(), "{key}");
    }
}

#[test]
fn source_structure_rejects_booleans_non_hundredth_geometry_and_non_positive_sizes() {
    for key in ["xMm", "yMm", "columnWidthsMm", "rowHeightsMm"] {
        for value in [json!(true), json!("1"), json!(null), json!(0.001), json!(1000.01), json!(-1000.01)] {
            let mut invalid = operation();
            invalid[key] = if key.ends_with("sMm") { json!([value]) } else { value };
            assert!(serde_json::from_value::<OfficeOperation>(invalid).is_err(), "{key}");
        }
    }
    for key in ["columnWidthsMm", "rowHeightsMm"] {
        for value in [json!([]), json!([0]), json!([-1]), json!([500,500.01]), json!(10)] {
            let mut invalid = operation(); invalid[key] = value;
            assert!(serde_json::from_value::<OfficeOperation>(invalid).is_err(), "{key}");
        }
    }
}

#[test]
fn source_structure_logical_cell_budget_accepts_one_hundred_and_rejects_one_hundred_one() {
    let mut value = operation();
    value["xMm"] = json!(-1000); value["yMm"] = json!(1000);
    value["columnWidthsMm"] = json!(vec![1;10]); value["rowHeightsMm"] = json!(vec![1;10]);
    assert!(serde_json::from_value::<OfficeOperation>(value.clone()).is_ok());
    value["columnWidthsMm"] = json!(vec![1;101]); value["rowHeightsMm"] = json!([1]);
    assert!(serde_json::from_value::<OfficeOperation>(value).is_err());
}

#[test]
fn source_structure_batches_require_unique_aliases_and_source_only_at_most_one_hundred() {
    let values = (0..100).map(|index| {
        let mut value = operation(); value["id"] = json!(format!("new-table-{index}")); value
    }).collect::<Vec<_>>();
    assert!(serde_json::from_value::<OfficeEdit>(envelope(values.clone())).is_ok());
    let mut too_many = values.clone();
    let mut last = operation(); last["id"] = json!("new-table-100"); too_many.push(last);
    assert!(serde_json::from_value::<OfficeEdit>(envelope(too_many)).is_err());
    assert!(serde_json::from_value::<OfficeEdit>(envelope(vec![operation(), operation()])).is_err());
    let legacy = json!({"op":"tableCellText","tableId":"WordTable1","cell":"A1","text":""});
    assert!(serde_json::from_value::<OfficeEdit>(envelope(vec![operation(), legacy.clone()])).is_err());
    assert!(serde_json::from_value::<OfficeEdit>(envelope(vec![legacy;128])).is_ok());
}

#[test]
fn source_structure_sdk_schema_exposes_closed_origin_guards_and_numeric_arrays() {
    let schema = serde_json::to_value(schemars::schema_for!(OfficeOperation)).unwrap();
    let text = serde_json::to_string(&schema).unwrap();
    for field in ["presentationSourceTableAdd", "expectedSourcePartSha256", "expectedShapeIdInventorySha256", "columnWidthsMm", "rowHeightsMm"] {
        assert!(text.contains(field), "missing SDK schema field {field}");
    }
    fn source_nodes(value: &Value, path: &str, output: &mut Vec<Value>) {
        if value.get("properties").and_then(|properties| properties.get("op"))
            .and_then(|operation| operation.get("const")).and_then(Value::as_str)
            == Some("presentationSourceTableAdd") {
            output.push(json!({"path":path,"additionalProperties":value["additionalProperties"],
                "required":value["required"],"properties":value["properties"]}));
        }
        if let Some(object) = value.as_object() {
            for (key, child) in object { source_nodes(child, &format!("{path}/{key}"), output); }
        } else if let Some(array) = value.as_array() {
            for (index, child) in array.iter().enumerate() { source_nodes(child, &format!("{path}/{index}"), output); }
        }
    }
    let mut nodes = Vec::new();
    source_nodes(&schema, "$", &mut nodes);
    eprintln!("SOURCE_STRUCTURE_SCHEMA_NODES={}", serde_json::to_string(&nodes).unwrap());
    assert_eq!(nodes.len(), 1, "expected exactly one op-discriminated schema branch");
    let source = &nodes[0];
    assert_eq!(source["additionalProperties"], false);
    assert_eq!(source["properties"]["op"]["const"], "presentationSourceTableAdd");
    let expected = ["op", "authorityVersion", "id", "ownerId", "expectedSourceSha256",
        "sourcePart", "expectedSourcePartSha256", "expectedShapeIdInventorySha256",
        "xMm", "yMm", "columnWidthsMm", "rowHeightsMm"]
        .into_iter().collect::<std::collections::BTreeSet<_>>();
    let properties = source["properties"].as_object().unwrap().keys().map(String::as_str)
        .collect::<std::collections::BTreeSet<_>>();
    let required = source["required"].as_array().unwrap().iter().map(|value| value.as_str().unwrap())
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(properties, expected);
    assert_eq!(required, expected);
    for field in ["columnWidthsMm", "rowHeightsMm"] {
        let values = &source["properties"][field];
        assert_eq!(values["type"], "array");
        assert_eq!(values["items"]["type"], "number");
        assert_eq!(values["minItems"].as_u64(), Some(1));
        assert_eq!(values["maxItems"].as_u64(), Some(100));
    }
    for field in ["xMm", "yMm"] {
        let number = &source["properties"][field];
        assert_eq!(number["type"], "number");
        assert_eq!(number["minimum"].as_f64(), Some(-1000.0));
        assert_eq!(number["maximum"].as_f64(), Some(1000.0));
    }
}

#[test]
fn pptx_table_structure_rejects_invalid_operation_shape_and_mixed_batches() {
    let operation = json!({
        "op": "presentationTableStructureEdit",
        "expectedSourceSha256": "a".repeat(64),
        "slideIndex": 255,
        "shapeId": u32::MAX,
        "action": "insertRowBefore",
        "index": 255,
    });
    for action in [
        "insertRowBefore",
        "insertRowAfter",
        "insertColumnBefore",
        "insertColumnAfter",
        "deleteRow",
        "deleteColumn",
    ] {
        let mut value = operation.clone();
        value["action"] = json!(action);
        let parsed: OfficeOperation = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(parsed).unwrap(), value);
        assert!(serde_json::from_value::<OfficeEdit>(envelope(vec![value])).is_ok());
    }
    for (field, value) in [
        ("expectedSourceSha256", json!("A".repeat(64))),
        ("expectedSourceSha256", json!("a".repeat(63))),
        ("expectedSourceSha256", json!("g".repeat(64))),
        ("slideIndex", json!(256)),
        ("slideIndex", json!(-1)),
        ("slideIndex", json!(1.5)),
        ("shapeId", json!(0)),
        ("shapeId", json!(u64::from(u32::MAX) + 1)),
        ("shapeId", json!("12")),
        ("action", json!("insert_row_before")),
        ("action", json!("mergeCells")),
        ("index", json!(256)),
        ("index", json!(false)),
        ("sourcePath", json!("outside.pptx")),
    ] {
        let mut invalid = operation.clone();
        invalid[field] = value;
        assert!(
            serde_json::from_value::<OfficeOperation>(invalid).is_err(),
            "{field}"
        );
    }
    for field in operation.as_object().unwrap().keys() {
        let mut invalid = operation.clone();
        invalid.as_object_mut().unwrap().remove(field);
        assert!(
            serde_json::from_value::<OfficeOperation>(invalid).is_err(),
            "{field}"
        );
    }
    assert!(
        serde_json::from_value::<OfficeEdit>(envelope(vec![operation.clone(), operation.clone(),]))
            .is_err()
    );
    assert!(
        serde_json::from_value::<OfficeEdit>(envelope(vec![
            json!({"op": "slideDuplicate", "id": "slide-0"}),
            operation.clone(),
        ]))
        .is_err()
    );
    assert!(
        serde_json::from_value::<OfficeEdit>(envelope(vec![
            operation,
            json!({"op": "tableCellText", "tableId": "WordTable1", "cell": "A1", "text": ""}),
        ]))
        .is_err()
    );
}

#[test]
fn pptx_table_structure_query_preserves_ordinary_read_and_rejects_null_or_unknown_fields() {
    for value in [
        json!({"noteId": "note"}),
        json!({"noteId": "note", "revisionId": null}),
    ] {
        let parsed: ReadDocument = serde_json::from_value(value).unwrap();
        assert_eq!(
            serde_json::to_value(parsed).unwrap(),
            json!({"noteId": "note"})
        );
    }
    for query in [
        json!({}),
        json!({"slideIndex": 0}),
        json!({"slideIndex": 255, "tableOffset": 400, "tableLimit": 32}),
    ] {
        let value = json!({"noteId": "note", "pptxTableStructure": query});
        let parsed: ReadDocument = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(parsed).unwrap(), value);
    }
    for query in [
        json!(null),
        json!({"slideIndex": null}),
        json!({"slideIndex": -1}),
        json!({"slideIndex": 256}),
        json!({"slideIndex": true}),
        json!({"slideIndex": 1, "tableOffset": null}),
        json!({"slideIndex": 1, "tableLimit": null}),
        json!({"slideIndex": 1, "tableLimit": "1"}),
        json!({"slideIndex": 1, "tablePath": "ppt/slides/slide2.xml"}),
    ] {
        let value = json!({"noteId": "note", "pptxTableStructure": query});
        assert!(serde_json::from_value::<ReadDocument>(value).is_err());
    }
}

#[test]
fn docx_table_structure_operation_enforces_selected_band_and_closed_shape() {
    let operation = json!({
        "op":"docxTableStructureEdit", "expectedSourceSha256":"a".repeat(64),
        "tableIndex":511, "action":"insertRow", "index":64, "anchorIndex":63,
    });
    for (action, index, anchor) in [
        ("insertRow", 64, Some(63)),
        ("insertRow", 63, Some(63)),
        ("insertColumn", 32, Some(31)),
        ("insertColumn", 0, Some(0)),
        ("deleteRow", 63, None),
        ("deleteColumn", 31, None),
    ] {
        let mut value = operation.clone();
        value["action"] = json!(action);
        value["index"] = json!(index);
        value.as_object_mut().unwrap().remove("anchorIndex");
        if let Some(anchor) = anchor {
            value["anchorIndex"] = json!(anchor);
        }
        let parsed: OfficeEdit = serde_json::from_value(envelope(vec![value.clone()])).unwrap();
        assert_eq!(serde_json::to_value(&parsed.operations[0]).unwrap(), value);
    }
    for (field, value) in [
        ("expectedSourceSha256", json!("A".repeat(64))),
        ("expectedSourceSha256", json!("a".repeat(63))),
        ("tableIndex", json!(512)),
        ("tableIndex", json!(-1)),
        ("tableIndex", json!("12")),
        ("index", json!(65)),
        ("index", json!(62)),
        ("anchorIndex", json!(null)),
        ("anchorIndex", json!(64)),
        ("anchorIndex", json!(0)),
        ("action", json!("insertColumn")),
        ("action", json!("deleteRow")),
        ("action", json!("mergeCells")),
        ("sourcePath", json!("outside.docx")),
    ] {
        let mut invalid = operation.clone();
        invalid[field] = value;
        assert!(
            serde_json::from_value::<OfficeEdit>(envelope(vec![invalid])).is_err(),
            "{field}"
        );
    }
    for field in operation.as_object().unwrap().keys() {
        let mut invalid = operation.clone();
        invalid.as_object_mut().unwrap().remove(field);
        assert!(
            serde_json::from_value::<OfficeEdit>(envelope(vec![invalid])).is_err(),
            "{field}"
        );
    }
    assert!(
        serde_json::from_value::<OfficeEdit>(envelope(vec![
            operation,
            json!({"op":"tableCellText","tableId":"WordTable1","cell":"A1","text":"unchanged"}),
        ]))
        .is_err()
    );
}

#[test]
fn docx_table_structure_query_roundtrips_closed_non_null_options() {
    for query in [json!({}), json!({"tableOffset":512,"tableLimit":32})] {
        let value = json!({"noteId":"note","docxTableStructure":query});
        let parsed: ReadDocument = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(parsed).unwrap(), value);
    }
    for query in [
        json!(null),
        json!({"tableOffset":null}),
        json!({"tableLimit":null}),
        json!({"tableOffset":-1}),
        json!({"tableLimit":"16"}),
        json!({"slideIndex":0}),
    ] {
        let value = json!({"noteId":"note","docxTableStructure":query});
        assert!(serde_json::from_value::<ReadDocument>(value).is_err());
    }
}
