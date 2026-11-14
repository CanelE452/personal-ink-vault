use super::{fixture, hash, reorder, reorder_fixture, stored_parts, zip};
use ink_vault_native::request_json;
use serde_json::{Value, json};
use std::fs;
use std::path::Path;

fn match_slides(previous: &Path, previous_sha: &str, current: &Path, current_sha: &str) -> Value {
    request_json(
        &json!({
            "op":"pptx_slide_identity_match",
            "previousPath":previous,"previousSha256":previous_sha,
            "currentPath":current,"currentSha256":current_sha,
        })
        .to_string(),
    )
}

#[test]
fn slide_identity_matches_moved_hidden_slides_in_source_order() {
    let directory = tempfile::tempdir().unwrap();
    let previous = directory.path().join("previous.pptx");
    let current = directory.path().join("current.pptx");
    let original = reorder_fixture(256);
    let previous_sha = hash(&original);
    fs::write(&previous, &original).unwrap();
    let moved = reorder(&previous, &previous_sha, &current, 0, 2, true);
    assert_eq!(moved["destinationIndex"], 2, "{moved}");
    let current_bytes = fs::read(&current).unwrap();
    let current_sha = hash(&current_bytes);

    assert_eq!(
        match_slides(&previous, &previous_sha, &current, &current_sha),
        json!({
            "previousSha256":previous_sha,"currentSha256":current_sha,
            "currentSlideCount":3,"previousToCurrent":[2,0,1],
        }),
    );
    assert_eq!(fs::read(previous).unwrap(), original);
    assert_eq!(fs::read(current).unwrap(), current_bytes);
}

#[test]
fn slide_identity_leaves_removed_id_unmapped_despite_reused_part() {
    let directory = tempfile::tempdir().unwrap();
    let previous = directory.path().join("previous.pptx");
    let current = directory.path().join("current.pptx");
    let original = fixture();
    let mut members = stored_parts(&original);
    let presentation = members["ppt/presentation.xml"].replace(
        "<p:sldId id='256' r:id='slideA'/><p:sldId id='257' r:id='slideB'/>",
        "<p:sldId id='258' r:id='slideB'/><p:sldId id='256' r:id='slideA'/>",
    );
    members.insert("ppt/presentation.xml", &presentation);
    let changed = zip(&members.into_iter().collect::<Vec<_>>());
    fs::write(&previous, &original).unwrap();
    fs::write(&current, &changed).unwrap();

    let reply = match_slides(&previous, &hash(&original), &current, &hash(&changed));
    assert_eq!(reply["previousToCurrent"], json!([1, null]), "{reply}");
    assert_eq!(reply["currentSlideCount"], 2, "{reply}");
}

#[test]
fn slide_identity_rejects_stale_inputs_and_duplicate_ids() {
    let directory = tempfile::tempdir().unwrap();
    let previous = directory.path().join("previous.pptx");
    let current = directory.path().join("current.pptx");
    let original = fixture();
    let original_sha = hash(&original);
    let stale = "0".repeat(64);
    fs::write(&previous, &original).unwrap();
    fs::write(&current, &original).unwrap();

    for (previous_sha, current_sha) in [(&stale, &original_sha), (&original_sha, &stale)] {
        let reply = match_slides(&previous, previous_sha, &current, current_sha);
        assert_eq!(reply["error"]["code"], "source_changed", "{reply}");
    }
    let mut members = stored_parts(&original);
    let presentation = members["ppt/presentation.xml"].replace("id='257'", "id='256'");
    members.insert("ppt/presentation.xml", &presentation);
    let duplicate = zip(&members.into_iter().collect::<Vec<_>>());
    fs::write(&current, &duplicate).unwrap();
    let reply = match_slides(&previous, &original_sha, &current, &hash(&duplicate));
    assert_eq!(reply["error"]["code"], "invalid_pptx", "{reply}");
}
