use super::*;

fn inspect(source: &Path, sha: &str, slide_index: Option<u32>) -> Value {
    let mut input = json!({
        "op":"pptx_table_merge_inspect","sourcePath":source,"sourceSha256":sha
    });
    if let Some(slide_index) = slide_index {
        input["slideIndex"] = json!(slide_index);
    }
    request_json(&input.to_string())
}

fn edit(source: &Path, sha: &str, output: &Path, action: &str) -> Value {
    json!({
        "op":"pptx_table_merge_edit","sourcePath":source,"sourceSha256":sha,
        "outputPath":output,"slideIndex":1,"shapeId":5,"action":action,
        "row":0,"column":0,"rowSpan":2,"columnSpan":2,
    })
}

#[test]
fn rejects_merge_that_would_hide_an_entire_grid_band_in_the_pdf_preview() {
    let directory = tempfile::tempdir().unwrap();
    let output = directory.path().join("never-written.pptx");
    for (name, heights, widths) in [
        (
            "column",
            &[120_000, 240_000][..],
            &[400_000, 600_000, 900_000][..],
        ),
        (
            "row",
            &[120_000, 240_000, 360_000][..],
            &[400_000, 600_000][..],
        ),
    ] {
        let source = directory.path().join(format!("{name}.pptx"));
        let slide = table_structure_slide(heights, widths);
        let original = fixture_with_second(&slide, &[]);
        fs::write(&source, &original).unwrap();
        let operation = edit(&source, &hash(&original), &output, "merge");
        let reply = request_json(&operation.to_string());
        assert_eq!(
            reply["error"]["code"], "unsafe_table_merge",
            "{name}: {reply}"
        );
        assert!(!output.exists());
        assert_eq!(fs::read(&source).unwrap(), original);
    }

    let source = directory.path().join("three-rows.pptx");
    let previous_merge = directory.path().join("previous-merge.pptx");
    let slide = table_structure_slide(&[120_000, 240_000, 360_000], &[400_000, 600_000, 900_000]);
    let original = fixture_with_second(&slide, &[]);
    fs::write(&source, &original).unwrap();
    let mut operation = edit(&source, &hash(&original), &previous_merge, "merge");
    operation["row"] = json!(2);
    operation["rowSpan"] = json!(1);
    let reply = request_json(&operation.to_string());
    let previous = fs::read(&previous_merge).unwrap_or_else(|_| panic!("{reply}"));
    let operation = edit(&previous_merge, &hash(&previous), &output, "merge");
    let reply = request_json(&operation.to_string());
    assert_eq!(reply["error"]["code"], "unsafe_table_merge", "{reply}");
    assert!(!output.exists());
    assert_eq!(fs::read(&previous_merge).unwrap(), previous);

    let external = directory.path().join("external-full-height.pptx");
    let reopened = directory.path().join("repaired.pptx");
    let slide = table_structure_slide(&[120_000, 240_000], &[400_000, 600_000, 900_000]);
    let mut pieces = slide.split("<d:tc>");
    let mut external_xml = pieces.next().unwrap().to_owned();
    for (index, tail) in pieces.enumerate() {
        external_xml.push_str(match index {
            0 => "<d:tc rowSpan='2' gridSpan='2'>",
            1 => "<d:tc rowSpan='2' hMerge='1'>",
            3 => "<d:tc gridSpan='2' vMerge='1'>",
            4 => "<d:tc hMerge='1' vMerge='1'>",
            _ => "<d:tc>",
        });
        external_xml.push_str(tail);
    }
    let original = fixture_with_second(&external_xml, &[]);
    let sha = hash(&original);
    fs::write(&external, &original).unwrap();
    assert_eq!(
        inspect(&external, &sha, Some(1))["tables"][0]["mergedRanges"],
        json!([{"row":0,"column":0,"rowSpan":2,"columnSpan":2}])
    );
    let operation = edit(&external, &sha, &reopened, "unmerge");
    let reply = request_json(&operation.to_string());
    let edited = fs::read(&reopened).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(reply["outputSha256"], hash(&edited));
    let xml = xml_parts(&edited);
    for label in ["셀 0·0", "셀 0·1", "셀 0·2", "셀 1·0", "셀 1·1", "셀 1·2"] {
        assert!(xml["ppt/slides/slide2.xml"].contains(label));
    }
    assert_eq!(fs::read(&external).unwrap(), original);
}

#[test]
fn merges_populated_rectangle_and_unmerges_without_changing_grid_or_other_parts() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("merged.pptx");
    let unmerged = directory.path().join("unmerged.pptx");
    let part = "ppt/slides/slide2.xml";
    let slide = table_structure_slide(&[120_000, 240_000, 360_000], &[400_000, 600_000, 900_000]);
    let original = fixture_with_second(&slide, &[("ppt/media/untouched.bin", "untouched")]);
    let original_sha = hash(&original);
    fs::write(&source, &original).unwrap();
    assert_eq!(
        inspect(&source, &original_sha, None)["slides"][1],
        json!({"index":1,"hidden":true,"title":"셀 0·0"})
    );
    assert_eq!(
        inspect(&source, &original_sha, Some(1))["tables"],
        json!([{"shapeId":5,"name":"표 🧪","rows":3,"columns":3,"mergedRanges":[]}])
    );
    let merge = edit(&source, &original_sha, &output, "merge");
    let reply = request_json(&merge.to_string());
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    let output_sha = hash(&bytes);
    assert_eq!(
        reply,
        json!({
            "sourceSha256":original_sha,"outputSha256":output_sha,"slideCount":2,
            "slideIndex":1,"shapeId":5,"action":"merge","row":0,"column":0,
            "rowSpan":2,"columnSpan":2,"rows":3,"columns":3
        })
    );
    assert_eq!(
        inspect(&output, &output_sha, Some(1))["tables"][0]["mergedRanges"],
        json!([{"row":0,"column":0,"rowSpan":2,"columnSpan":2}])
    );
    let parts = raw_parts(&bytes);
    let previous = raw_parts(&original);
    for (name, body) in previous.iter().filter(|(name, _)| **name != part) {
        assert_eq!(&parts[name], body, "{name}");
    }
    let merged_xml = std::str::from_utf8(&parts[part]).unwrap();
    let before = structure_report(&slide);
    let after = structure_report(merged_xml);
    assert_eq!(after.anchor, before.anchor);
    assert_eq!(after.frame_width, before.frame_width);
    assert_eq!(after.frame_height, before.frame_height);
    assert_eq!(after.heights, before.heights);
    assert_eq!(after.widths, before.widths);
    assert_eq!(after.siblings, before.siblings);
    assert_eq!(after.cells[0][2], before.cells[0][2]);
    assert_eq!(after.cells[1][2], before.cells[1][2]);
    assert_eq!(after.cells[2], before.cells[2]);
    let merged = roxmltree::Document::parse(merged_xml).unwrap();
    let cells: Vec<_> = merged
        .descendants()
        .filter(|n| n.has_tag_name((A, "tc")))
        .collect();
    let attrs = |cell: usize, name| cells[cell].attribute(name);
    assert_eq!(
        (attrs(0, "rowSpan"), attrs(0, "gridSpan")),
        (Some("2"), Some("2"))
    );
    assert_eq!(
        (attrs(1, "rowSpan"), attrs(1, "hMerge")),
        (Some("2"), Some("1"))
    );
    assert_eq!(
        (attrs(3, "gridSpan"), attrs(3, "vMerge")),
        (Some("2"), Some("1"))
    );
    assert_eq!(
        (attrs(4, "hMerge"), attrs(4, "vMerge")),
        (Some("1"), Some("1"))
    );
    for (index, expected) in [
        (0, vec!["셀 0·0", "셀 0·1", "셀 1·0", "셀 1·1"]),
        (1, vec![]),
        (3, vec![]),
        (4, vec![]),
    ] {
        let cell = cells[index];
        let texts: Vec<_> = cell
            .descendants()
            .filter(|n| n.has_tag_name((A, "t")))
            .filter_map(|n| n.text())
            .collect();
        assert_eq!(texts, expected);
        assert_eq!(
            cell.children()
                .find(|n| n.has_tag_name((A, "tcPr")))
                .unwrap()
                .attribute("marL"),
            Some("600")
        );
    }
    let mut request = edit(&output, &output_sha, &unmerged, "unmerge");
    request["columnSpan"] = json!(1);
    assert_eq!(
        request_json(&request.to_string())["error"]["code"],
        "invalid_request"
    );
    assert!(!unmerged.exists());
    request["columnSpan"] = json!(2);
    let reply = request_json(&request.to_string());
    let unmerged_bytes = fs::read(&unmerged).unwrap_or_else(|_| panic!("{reply}"));
    let unmerged_sha = hash(&unmerged_bytes);
    assert_eq!(reply["outputSha256"], unmerged_sha);
    assert_eq!(
        inspect(&unmerged, &unmerged_sha, Some(1))["tables"][0]["mergedRanges"],
        json!([])
    );
    let parts = raw_parts(&unmerged_bytes);
    let unmerged_xml = std::str::from_utf8(&parts[part]).unwrap();
    let after = structure_report(unmerged_xml);
    assert_eq!(after.widths, before.widths);
    assert_eq!(after.heights, before.heights);
    let anchor = after.cells[0][0];
    for label in ["셀 0·0", "셀 0·1", "셀 1·0", "셀 1·1"] {
        assert_eq!(anchor.matches(label).count(), 1);
    }
    assert_eq!(fs::read(&source).unwrap(), original);
    assert_eq!(fs::read(&output).unwrap(), bytes);
}

#[test]
fn rejects_unsafe_merge_overlap_and_preserves_covered_payload_on_unmerge() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.pptx");
    let output = directory.path().join("output.pptx");
    let slide = table_structure_slide(&[120_000, 240_000, 360_000], &[400_000, 600_000, 900_000]);
    let markers = slide
        .match_indices("<d:tc>")
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    let edited_slide = slide[..markers[1]].replacen("<d:tc>", "<d:tc gridSpan='2'>", 1)
        + &slide[markers[1]..].replacen("<d:tc>", "<d:tc hMerge='1'>", 1);
    let input = fixture_with_second(&edited_slide, &[]);
    let sha = hash(&input);
    fs::write(&source, &input).unwrap();
    let inspect_result = inspect(&source, &sha, Some(1));
    assert_eq!(
        inspect_result["tables"][0]["mergedRanges"],
        json!([{"row":0,"column":0,"rowSpan":1,"columnSpan":2}])
    );
    let request = edit(&source, &sha, &output, "merge");
    assert_eq!(
        request_json(&request.to_string())["error"]["code"],
        "invalid_request"
    );
    let mut request = edit(&source, &sha, &output, "unmerge");
    request["rowSpan"] = json!(1);
    let mut stale = request.clone();
    stale["sourceSha256"] = json!("0".repeat(64));
    assert_eq!(
        request_json(&stale.to_string())["error"]["code"],
        "source_changed"
    );
    assert!(!output.exists());
    let reply = request_json(&request.to_string());
    let after = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    let parts = raw_parts(&after);
    let unmerged = std::str::from_utf8(&parts["ppt/slides/slide2.xml"]).unwrap();
    assert!(structure_report(unmerged).cells[0][1].contains("셀 0·1"));
    let already_exists = request_json(&request.to_string());
    assert_eq!(already_exists["error"]["code"], "output_exists");
    assert_eq!(fs::read(&source).unwrap(), input);
    assert_eq!(fs::read(&output).unwrap(), after);
    for (i, replacement) in [
        "<d:fld id='x'><d:t>셀 0·1</d:t></d:fld>",
        "<d:r xmlns:d='urn:opaque'><d:t>셀 0·1</d:t></d:r>",
    ]
    .into_iter()
    .enumerate()
    {
        let unsafe_slide = slide.replace("<d:r><d:rPr b='1'/><d:t>셀 0·1</d:t></d:r>", replacement);
        let unsafe_source = directory.path().join(format!("unsafe-{i}.pptx"));
        let unsafe_output = directory.path().join(format!("rejected-{i}.pptx"));
        let bytes = fixture_with_second(&unsafe_slide, &[]);
        fs::write(&unsafe_source, &bytes).unwrap();
        let request = edit(&unsafe_source, &hash(&bytes), &unsafe_output, "merge");
        assert_eq!(
            request_json(&request.to_string())["error"]["code"],
            "invalid_request"
        );
        assert!(!unsafe_output.exists());
    }
}
