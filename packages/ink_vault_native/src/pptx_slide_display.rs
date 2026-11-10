use super::shape_text::{read_slide_index, require_unprotected};
use super::{
    Deck, MAX_PACKAGE, MAX_PART, MAX_XML, document, edit, expected_hash, open_source, path,
    require, require_fresh_output, source_changed,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let index = read_slide_index(&request["slideIndex"])?;
    let expected_hidden = request["expectedHidden"].as_bool().ok_or_else(invalid)?;
    let hidden = request["hidden"].as_bool().ok_or_else(invalid)?;
    if source_path.parent() != output_path.parent() || expected_hidden == hidden {
        return Err(invalid());
    }

    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    require_unprotected(&deck)?;
    let slide = deck.slides.get(index).ok_or_else(invalid)?;
    if slide.hidden != expected_hidden {
        return Err(source_changed());
    }

    let xml = &deck.xml[&slide.part];
    let parsed = document(xml)?;
    let root = parsed.root_element();
    let (range, replacement) = match root
        .attributes()
        .find(|attribute| attribute.namespace().is_none() && attribute.name() == "show")
    {
        Some(attribute) => (attribute.range_value(), if hidden { "0" } else { "1" }),
        None => {
            // Insert at the end of the root name, before any quoted attributes.
            let start = root.range().start + 1;
            let name_end = start
                + xml[start..]
                    .find(|c| matches!(c, ' ' | '\t' | '\n' | '\r' | '>' | '/'))
                    .ok_or_else(invalid_zip)?;
            (name_end..name_end, " show=\"0\"")
        }
    };
    let changed = edit(xml, vec![(range, replacement.to_owned())])?;
    let growth = changed.len().saturating_sub(xml.len());
    require(
        changed.len() <= MAX_PART
            && deck.xml_bytes + growth <= MAX_XML
            && deck.layout.expanded + growth <= MAX_PACKAGE,
    )?;
    let edits = PackageEdits {
        changed: BTreeMap::from([(slide.part.clone(), changed)]),
        ..PackageEdits::default()
    };
    let slide_count = deck.slides.len();
    let output_sha =
        deck.write_candidate(source, (source_path, output_path), sha, &edits, |written| {
            require(
                written.slides.len() == slide_count
                    && written.slides.iter().zip(&deck.slides).enumerate().all(
                        |(position, (new, old))| {
                            new.part == old.part
                                && new.identity == old.identity
                                && new.relationship_id == old.relationship_id
                                && new.title == old.title
                                && new.hidden
                                    == if position == index {
                                        hidden
                                    } else {
                                        old.hidden
                                    }
                        },
                    ),
            )
        })?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":slide_count,
        "slideIndex":index,"hidden":hidden
    }))
}
