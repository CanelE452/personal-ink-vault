use super::*;

const NOTES: &str = "ppt/notesSlides/notesSlide1.xml";
const NOTES_RELS: &str = "ppt/notesSlides/_rels/notesSlide1.xml.rels";
const MASTER: &str = "ppt/notesMasters/notesMaster1.xml";
const PRESENTATION: &str = "ppt/presentation.xml";
const PRESENTATION_RELS: &str = "ppt/_rels/presentation.xml.rels";
const FIRST_SLIDE_RELS: &str = "ppt/slides/_rels/slide1.xml.rels";
const CONTENT_TYPES: &str = "[Content_Types].xml";

fn deck(body: Option<&str>, master: bool, back: &str) -> Vec<u8> {
    let base = fixture();
    let mut parts = stored_parts(&base);
    let mut types = parts[CONTENT_TYPES].to_owned();
    if body.is_none() {
        parts.remove(NOTES);
        parts.remove(NOTES_RELS);
        parts.remove(FIRST_SLIDE_RELS);
        types = types.replace(
            &format!("<Override PartName='/{NOTES}' ContentType='{MIME}notesSlide+xml'/>"),
            "",
        );
    }
    let presentation = parts[PRESENTATION].replace(
        "<p:sldIdLst>",
        "<p:notesMasterIdLst><p:notesMasterId r:id='master'/></p:notesMasterIdLst><p:sldIdLst>",
    );
    let relationships = parts[PRESENTATION_RELS].replace(
        "</Relationships>",
        &format!("<Relationship Id='master' Type='{R}/notesMaster' Target='notesMasters/notesMaster1.xml'/></Relationships>"),
    );
    let master_xml = format!(
        "<p:notesMaster xmlns:p='{P}'><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMap bg1='lt1' tx1='dk1' bg2='lt2' tx2='dk2' accent1='accent1' accent2='accent2' accent3='accent3' accent4='accent4' accent5='accent5' accent6='accent6' hlink='hlink' folHlink='folHlink'/></p:notesMaster>"
    );
    if master {
        parts.insert(PRESENTATION, &presentation);
        parts.insert(PRESENTATION_RELS, &relationships);
        types = types.replace(
            "</Types>",
            &format!(
                "<Override PartName='/{MASTER}' ContentType='{MIME}notesMaster+xml'/></Types>"
            ),
        );
        parts.insert(MASTER, &master_xml);
    }
    parts.insert(CONTENT_TYPES, &types);
    let placeholder = match body {
        Some("") | None => String::new(),
        Some(paragraphs) => format!(
            "<p:sp><p:nvSpPr><p:cNvPr id='3' name='Body'/><p:cNvSpPr/><p:nvPr><p:ph type='body' idx='1'/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>{paragraphs}</p:txBody></p:sp>"
        ),
    };
    let notes = format!(
        "<p:notes xmlns:p='{P}' xmlns:a='{A}' xmlns:r='{R}'><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id='2' name='Page number'/><p:cNvSpPr/><p:nvPr><p:ph type='sldNum' idx='5'/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:p><a:r><a:t>unrelated shape</a:t></a:r></a:p></p:txBody></p:sp>{placeholder}<p:extLst/></p:spTree></p:cSld></p:notes>"
    );
    let notes_rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='parent' Type='{R}/slide' Target='../slides/{back}'/><Relationship Id='master' Type='{R}/notesMaster' Target='../notesMasters/notesMaster1.xml'/></Relationships>"
    );
    if body.is_some() {
        parts.insert(NOTES, &notes);
        parts.insert(NOTES_RELS, &notes_rels);
    }
    zip(&parts.into_iter().collect::<Vec<_>>())
}

fn inspect(source: &Path, sha: &str, slide: Option<usize>) -> Value {
    let mut request =
        json!({"op":"pptx_speaker_notes_inspect","sourcePath":source,"sourceSha256":sha});
    if let Some(slide) = slide {
        request["slideIndex"] = json!(slide);
    }
    request_json(&request.to_string())
}

fn edit(source: &Path, sha: &str, output: &Path, slide: usize, text: &str) -> Value {
    request_json(&json!({"op":"pptx_speaker_notes_edit","sourcePath":source,"sourceSha256":sha,"outputPath":output,"slideIndex":slide,"text":text}).to_string())
}

#[test]
fn speaker_notes_updates_and_clears_only_the_body() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("input.pptx");
    let output = dir.path().join("output.pptx");
    let cleared = dir.path().join("cleared.pptx");
    let input = deck(
        Some(
            "<a:p><a:pPr lvl='1'/><a:r><a:rPr b='1'/><a:t>old text</a:t></a:r><a:endParaRPr lang='en-US'/></a:p>",
        ),
        true,
        "slide1.xml",
    );
    fs::write(&source, &input).unwrap();
    let sha = hash(&input);
    let summary = inspect(&source, &sha, None);
    assert_eq!(
        summary["slides"],
        json!([{"index":0,"hidden":false,"title":"원본 슬라이드"},{"index":1,"hidden":true}]),
        "{summary}"
    );
    let selected = inspect(&source, &sha, Some(0));
    assert_eq!(selected["text"], "old text", "{selected}");
    let updated = "  한글 🙂 & < >\t\n\n둘째 줄\n";
    let saved = edit(&source, &sha, &output, 0, updated);
    let output_bytes = fs::read(&output).unwrap_or_else(|_| panic!("{saved}"));
    assert_eq!(saved["outputSha256"], hash(&output_bytes));
    assert_eq!(fs::read(&source).unwrap(), input);
    let before = stored_parts(&input);
    let after = stored_parts(&output_bytes);
    for (name, value) in before {
        if name != NOTES {
            assert_eq!(after[name], value, "changed {name}");
        }
    }
    assert!(after[NOTES].contains("unrelated shape"));
    assert!(after[NOTES].contains("<a:rPr b='1'/>"));
    assert!(after[NOTES].contains("<a:pPr lvl='1'/>"));
    let saved_sha = hash(&output_bytes);
    let selected = inspect(&output, &saved_sha, Some(0));
    assert_eq!(selected["text"], updated, "{selected}");
    let result = edit(&output, &saved_sha, &cleared, 0, "");
    let bytes = fs::read(&cleared).unwrap_or_else(|_| panic!("{result}"));
    let selected = inspect(&cleared, &hash(&bytes), Some(0));
    assert_eq!(selected["text"], "", "{selected}");
    assert!(stored_parts(&bytes)[NOTES].contains("unrelated shape"));
}

#[test]
fn speaker_notes_creates_body_part_and_master_only_as_needed() {
    for (body, master) in [(None, false), (None, true), (Some(""), true)] {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("input.pptx");
        let output = dir.path().join("output.pptx");
        let input = deck(body, master, "slide1.xml");
        fs::write(&source, &input).unwrap();
        let sha = hash(&input);
        let selected = inspect(&source, &sha, Some(0));
        assert_eq!(selected["editable"], true, "{selected}");
        assert_eq!(selected["hasNotes"], false, "{selected}");
        assert_eq!(
            edit(&source, &sha, &output, 0, "")["error"]["code"],
            "no_change"
        );
        let saved = edit(&source, &sha, &output, 0, "처음 발표 노트");
        let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{saved}"));
        let before = stored_parts(&input);
        let after = raw_parts(&bytes);
        for (name, value) in before {
            let permitted = name == NOTES
                || (body.is_none() && name == CONTENT_TYPES)
                || (!master && [PRESENTATION, PRESENTATION_RELS].contains(&name));
            if !permitted {
                assert_eq!(after[name].as_ref(), value.as_bytes(), "changed {name}");
            }
        }
        let part = |name| std::str::from_utf8(&after[name]).unwrap();
        assert!(part(FIRST_SLIDE_RELS).contains("/notesSlide"));
        assert!(part(NOTES_RELS).contains("../slides/slide1.xml"));
        assert!(part(NOTES_RELS).contains("../notesMasters/notesMaster1.xml"));
        assert!(part(PRESENTATION).contains("notesMasterIdLst"));
        assert!(part(MASTER).contains("notesMaster"));
        let selected = inspect(&output, &hash(&bytes), Some(0));
        assert_eq!(selected["text"], "처음 발표 노트", "{selected}");
        assert_eq!(selected["hasNotes"], true, "{selected}");
    }
}

#[test]
fn speaker_notes_rejects_stale_cross_refs_rich_and_invalid_edits() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("input.pptx");
    let output = dir.path().join("output.pptx");
    let rich = "<a:p><a:fld id='{12345678-1234-1234-1234-123456789ABC}' type='slidenum'><a:t>42</a:t></a:fld></a:p>";
    let input = deck(Some(rich), true, "slide1.xml");
    fs::write(&source, &input).unwrap();
    let sha = hash(&input);
    let result = inspect(&source, &sha, Some(0));
    assert_eq!(result["text"], "42", "{result}");
    assert_eq!(result["editable"], false, "{result}");
    assert_eq!(
        edit(&source, &sha, &output, 0, "safe")["error"]["code"],
        "unsupported_notes"
    );
    assert_eq!(
        edit(&source, &"0".repeat(64), &output, 0, "safe")["error"]["code"],
        "source_changed"
    );
    for text in [
        "\r".into(),
        "\u{0001}".into(),
        "\u{FFFE}".into(),
        "🙂".repeat(4001),
        "\n".repeat(128),
    ] {
        assert_eq!(
            edit(&source, &sha, &output, 0, &text)["error"]["code"],
            "invalid_request"
        );
    }
    assert!(!output.exists());
    assert_eq!(fs::read(&source).unwrap(), input);
    let input = deck(Some(rich), true, "slide2.xml");
    fs::write(&source, &input).unwrap();
    let sha = hash(&input);
    assert!(inspect(&source, &sha, Some(0))["error"].is_object());
    assert!(edit(&source, &sha, &output, 0, "safe")["error"].is_object());
    assert!(!output.exists());
}
