use flate2::read::DeflateDecoder;
use ink_vault_native::request_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fs, io::Read, path::Path};

const W: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const R: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const REL: &str = "http://schemas.openxmlformats.org/package/2006/relationships";
const CT: &str = "http://schemas.openxmlformats.org/package/2006/content-types";
const MIME: &str = "application/vnd.openxmlformats-officedocument.wordprocessingml.";
const MAIN: &str = "word/document.xml";

fn zip(parts: &BTreeMap<&str, String>) -> Vec<u8> {
    let mut local = Vec::new();
    let mut central = Vec::new();
    for (name, data) in parts {
        let offset = local.len() as u32;
        let size = data.len() as u32;
        let crc = crc32fast::hash(data.as_bytes());
        local.extend(0x0403_4b50u32.to_le_bytes());
        for value in [20u16, 0x800, 0, 0, 0] {
            local.extend(value.to_le_bytes());
        }
        for value in [crc, size, size] {
            local.extend(value.to_le_bytes());
        }
        local.extend((name.len() as u16).to_le_bytes());
        local.extend([0; 2]);
        local.extend(name.as_bytes());
        local.extend(data.as_bytes());

        central.extend(0x0201_4b50u32.to_le_bytes());
        for value in [20u16, 20, 0x800, 0, 0, 0] {
            central.extend(value.to_le_bytes());
        }
        for value in [crc, size, size] {
            central.extend(value.to_le_bytes());
        }
        central.extend((name.len() as u16).to_le_bytes());
        central.extend([0; 12]);
        central.extend(offset.to_le_bytes());
        central.extend(name.as_bytes());
    }
    let offset = local.len() as u32;
    local.extend(&central);
    local.extend(0x0605_4b50u32.to_le_bytes());
    for value in [0u16, 0, parts.len() as u16, parts.len() as u16] {
        local.extend(value.to_le_bytes());
    }
    local.extend((central.len() as u32).to_le_bytes());
    local.extend(offset.to_le_bytes());
    local.extend([0; 2]);
    local
}

fn read_parts(bytes: &[u8]) -> BTreeMap<&str, (String, &[u8])> {
    let word = |at| u16::from_le_bytes(bytes[at..at + 2].try_into().unwrap()) as usize;
    let long = |at| u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
    let mut at = 0;
    let mut parts = BTreeMap::new();
    while long(at) == 0x0403_4b50 {
        let size = long(at + 18);
        let name_size = word(at + 26);
        let extra_size = word(at + 28);
        let name = std::str::from_utf8(&bytes[at + 30..at + 30 + name_size]).unwrap();
        let start = at + 30 + name_size + extra_size;
        let end = start + size;
        let mut plain = String::new();
        match word(at + 8) {
            0 => plain.push_str(std::str::from_utf8(&bytes[start..end]).unwrap()),
            8 => {
                DeflateDecoder::new(&bytes[start..end])
                    .read_to_string(&mut plain)
                    .unwrap();
            }
            method => panic!("Unexpected compression method {method}"),
        }
        assert_eq!(crc32fast::hash(plain.as_bytes()), long(at + 14) as u32);
        assert!(parts.insert(name, (plain, &bytes[at..end])).is_none());
        at = end;
    }
    assert_eq!(long(at), 0x0201_4b50);
    parts
}

fn fixture(body: &str, settings: &str) -> Vec<u8> {
    zip(&BTreeMap::from([
        (
            "[Content_Types].xml",
            format!(
                "<Types xmlns='{CT}'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Override PartName='/{MAIN}' ContentType='{MIME}document.main+xml'/><Override PartName='/word/settings.xml' ContentType='{MIME}settings+xml'/></Types>"
            ),
        ),
        (
            "_rels/.rels",
            format!(
                "<Relationships xmlns='{REL}'><Relationship Id='root' Type='{R}/officeDocument' Target='{MAIN}'/></Relationships>"
            ),
        ),
        (
            MAIN,
            format!(
                "<w:document xmlns:w='{W}' xmlns:r='{R}'><w:body>{body}<w:sectPr/></w:body></w:document>"
            ),
        ),
        (
            "word/_rels/document.xml.rels",
            format!(
                "<Relationships xmlns='{REL}'><Relationship Id='settings' Type='{R}/settings' Target='settings.xml'/></Relationships>"
            ),
        ),
        (
            "word/settings.xml",
            format!("<w:settings xmlns:w='{W}'>{settings}</w:settings>"),
        ),
    ]))
}

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn inspect(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"docx_text_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn replace(
    source: &Path,
    sha: &str,
    output: &Path,
    paragraph: usize,
    run: usize,
    text: &str,
) -> Value {
    request_json(
        &json!({
            "op":"docx_text_replace","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "paragraphIndex":paragraph,"runIndex":run,"text":text,
        })
        .to_string(),
    )
}

fn inspect_cells(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"docx_text_inspect","sourcePath":source,"sourceSha256":sha,"tableCells":true})
            .to_string(),
    )
}

fn replace_cell(
    source: &Path,
    sha: &str,
    output: &Path,
    coordinates: [usize; 5],
    text: &str,
) -> Value {
    let [table, row, cell, paragraph, run] = coordinates;
    request_json(
        &json!({
            "op":"docx_text_replace","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "tableIndex":table,"rowIndex":row,"cellIndex":cell,
            "paragraphIndex":paragraph,"runIndex":run,"text":text,
        })
        .to_string(),
    )
}

fn find_preview(source: &Path, sha: &str, find: &str) -> Value {
    request_json(
        &json!({"op":"docx_find_replace_preview","sourcePath":source,"sourceSha256":sha,"find":find})
            .to_string(),
    )
}

fn find_apply(
    source: &Path,
    sha: &str,
    output: &Path,
    find: &str,
    replacement: &str,
    count: usize,
) -> Value {
    request_json(
        &json!({
            "op":"docx_find_replace_apply","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "find":find,"replacement":replacement,"expectedMatchCount":count,
        })
        .to_string(),
    )
}

#[test]
fn find_replace_all_spans_ordinary_runs_and_preserves_the_rest_of_the_package() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.docx");
    let output = dir.path().join("output.docx");
    let needle = "긴 & 찾기";
    let replacement = " 새 <🙂> & ";
    let prefix = "<w:t>접두 긴 &amp;</w:t>";
    let suffix = "<w:t xml:space='preserve'> 찾기 접미</w:t>";
    let repeated = "<w:t>긴 &amp; 찾기와 긴 &amp; 찾기</w:t>";
    let excluded = concat!(
        "<w:p><w:r><w:t>긴 &amp;</w:t></w:r><w:r><w:tab/></w:r>",
        "<w:r><w:t xml:space='preserve'> 찾기</w:t></w:r>",
        "<w:hyperlink w:anchor='ref'><w:r><w:t>긴 &amp; 찾기</w:t></w:r></w:hyperlink>",
        "<w:ins w:id='1'><w:r><w:t>긴 &amp; 찾기</w:t></w:r></w:ins></w:p>",
        "<w:p><w:r><w:fldChar w:fldCharType='begin'/></w:r>",
        "<w:r><w:t>긴 &amp; 찾기</w:t></w:r><w:r><w:fldChar w:fldCharType='end'/></w:r></w:p>",
        "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>긴 &amp; 찾기</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
    );
    let original = fixture(
        &format!(
            "<w:p><w:r><w:rPr><w:b/></w:rPr>{prefix}</w:r><w:r><w:rPr><w:i/></w:rPr>{suffix}</w:r></w:p><w:p><w:r>{repeated}</w:r></w:p>{excluded}"
        ),
        "",
    );
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    assert_eq!(
        find_preview(&source, &sha, needle),
        json!({
            "sourceSha256":sha,"matchCount":3,"paragraphCount":2,
            "matches":[
                {"paragraphIndex":0,"snippet":"접두 긴 & 찾기 접미","count":1},
                {"paragraphIndex":1,"snippet":"긴 & 찾기와 긴 & 찾기","count":2},
            ]
        })
    );
    let result = find_apply(&source, &sha, &output, needle, replacement, 3);
    assert!(result.get("error").is_none(), "{result}");
    let edited = fs::read(&output).unwrap();
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":hash(&edited),"matchCount":3,"paragraphCount":2})
    );
    assert_eq!(fs::read(&source).unwrap(), original);
    let old_parts = read_parts(&original);
    let new_parts = read_parts(&edited);
    assert_eq!(
        old_parts.keys().collect::<Vec<_>>(),
        new_parts.keys().collect::<Vec<_>>()
    );
    for (name, part) in &old_parts {
        if *name != MAIN {
            assert_eq!(part, &new_parts[name]);
        }
    }
    let xml = &new_parts[MAIN].0;
    let parsed = roxmltree::Document::parse(xml).unwrap();
    let run_texts: Vec<_> = parsed
        .descendants()
        .filter(|node| node.has_tag_name((W, "t")))
        .take(3)
        .collect();
    assert_eq!(run_texts[0].text(), Some("접두  새 <🙂> & "));
    assert_eq!(run_texts[1].text(), Some(" 접미"));
    assert_eq!(run_texts[2].text(), Some(" 새 <🙂> & 와  새 <🙂> & "));
    for node in &run_texts {
        assert_eq!(
            node.attribute(("http://www.w3.org/XML/1998/namespace", "space")),
            Some("preserve")
        );
    }
    let original_runs = [prefix, suffix, repeated];
    let mut restored = xml.clone();
    for (node, raw) in run_texts.into_iter().zip(original_runs).rev() {
        restored.replace_range(node.range(), raw);
    }
    assert_eq!(restored, old_parts[MAIN].0);
}

#[test]
fn find_replace_revalidates_preview_bounds_hash_and_output_before_writing() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.docx");
    let output = dir.path().join("output.docx");
    let before = fixture("<w:p><w:r><w:t>aaa AAA</w:t></w:r></w:p>", "");
    let sha = hash(&before);
    fs::write(&source, &before).unwrap();
    assert_eq!(find_preview(&source, &sha, "aa")["matchCount"], 1);
    assert_eq!(
        find_preview(&source, &sha, "absent"),
        json!({"sourceSha256":sha,"matchCount":0,"paragraphCount":0,"matches":[]})
    );
    let wrong_sha = "0".repeat(64);
    for (hash, needle, replacement, count) in [
        (sha.as_str(), "aa", "", 2),
        (sha.as_str(), "aa", "aa", 1),
        (sha.as_str(), "aa", "\n", 1),
        (sha.as_str(), "", "", 1),
        (sha.as_str(), "absent", "", 0),
        (wrong_sha.as_str(), "aa", "", 1),
    ] {
        assert!(
            find_apply(&source, hash, &output, needle, replacement, count)["error"].is_object()
        );
        assert!(!output.exists());
    }
    fs::write(&output, "existing").unwrap();
    assert!(find_apply(&source, &sha, &output, "aa", "", 1)["error"].is_object());
    assert_eq!(fs::read(&output).unwrap(), b"existing");
    let empty = dir.path().join("empty.docx");
    assert!(find_apply(&source, &sha, &empty, "aa", "", 1)["error"].is_null());
    assert_eq!(
        inspect(&empty, &hash(&fs::read(&empty).unwrap()))["paragraphs"][0]["runs"][0]["text"],
        "a AAA"
    );

    let too_many = fixture(
        &format!("<w:p><w:r><w:t>{}</w:t></w:r></w:p>", "x".repeat(201)),
        "",
    );
    let crowded = dir.path().join("crowded.docx");
    fs::write(&crowded, &too_many).unwrap();
    assert!(find_preview(&crowded, &hash(&too_many), "x")["error"].is_object());

    let long_text = fixture(
        &format!(
            "<w:p><w:r><w:t>{}needle{}</w:t></w:r></w:p>",
            "🙂".repeat(100),
            "🧭".repeat(100)
        ),
        "",
    );
    let long = dir.path().join("long.docx");
    fs::write(&long, &long_text).unwrap();
    let preview = find_preview(&long, &hash(&long_text), "needle");
    let snippet = preview["matches"][0]["snippet"].as_str().unwrap();
    assert!(snippet.contains("needle") && snippet.encode_utf16().count() <= 160);
    assert!(snippet.starts_with('…') && snippet.ends_with('…'));

    for (name, settings) in [
        ("tracked", "<w:trackRevisions/>"),
        ("protected", "<w:documentProtection w:enforcement='true'/>"),
    ] {
        let blocked = fixture("<w:p><w:r><w:t>aa</w:t></w:r></w:p>", settings);
        let path = dir.path().join(format!("{name}.docx"));
        fs::write(&path, &blocked).unwrap();
        assert!(find_preview(&path, &hash(&blocked), "aa")["error"].is_object());
    }
}

#[test]
fn replaces_one_body_run_and_preserves_non_target_xml_and_package_members() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("edited.docx");
    let selected = "<w:t>원래 &amp; 내용 🧭</w:t>";
    let before = fixture(
        &format!(
            "<w:p w:rsidR='01020304'><w:pPr><w:keepNext/></w:pPr><w:r><w:rPr><w:b/><w:i/></w:rPr>{selected}</w:r><w:r><w:t>그대로</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>표 보존</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        ),
        "",
    );
    let sha = hash(&before);
    fs::write(&source, &before).unwrap();
    assert_eq!(
        inspect(&source, &sha),
        json!({"sourceSha256":sha,"paragraphs":[{"paragraphIndex":0,"runs":[{"runIndex":0,"text":"원래 & 내용 🧭"},{"runIndex":1,"text":"그대로"}]}]}),
    );
    let changed = " <새> '🙂' & \"한글\" ";
    let result = replace(&source, &sha, &output, 0, 0, changed);
    assert!(result.get("error").is_none(), "{result}");
    let after = fs::read(&output).unwrap();
    let after_sha = hash(&after);
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":after_sha,"paragraphIndex":0,"runIndex":0})
    );
    assert_eq!(fs::read(&source).unwrap(), before);
    let before = read_parts(&before);
    let after = read_parts(&after);
    assert_eq!(
        before.keys().collect::<Vec<_>>(),
        after.keys().collect::<Vec<_>>()
    );
    for (name, part) in &before {
        if *name != MAIN {
            assert_eq!(part, &after[name]);
        }
    }
    let xml = &after[MAIN].0;
    let parsed = roxmltree::Document::parse(xml).unwrap();
    let new_text = parsed
        .descendants()
        .find(|n| n.has_tag_name((W, "t")))
        .unwrap();
    assert_eq!(new_text.text(), Some(changed));
    assert_eq!(
        new_text.attribute(("http://www.w3.org/XML/1998/namespace", "space")),
        Some("preserve")
    );
    assert_eq!(
        xml.replace(&xml[new_text.range()], selected),
        before[MAIN].0
    );
    assert_eq!(
        inspect(&output, &after_sha)["paragraphs"][0]["runs"][0]["text"],
        changed
    );
}

#[test]
fn writes_and_reopens_empty_and_self_closing_text_without_rewriting_style() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let inserted = directory.path().join("inserted.docx");
    let emptied = directory.path().join("emptied.docx");
    let before = fixture(
        "<w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space='default'/></w:r></w:p>",
        "",
    );
    let sha = hash(&before);
    fs::write(&source, &before).unwrap();
    assert_eq!(
        inspect(&source, &sha)["paragraphs"][0]["runs"][0]["text"],
        ""
    );
    let result = replace(&source, &sha, &inserted, 0, 0, "  새 내용  ");
    assert!(result.get("error").is_none(), "{result}");
    let text = fs::read(&inserted).unwrap();
    assert!(
        read_parts(&text)[MAIN]
            .0
            .contains("<w:rPr><w:b/></w:rPr><w:t xml:space='preserve'>  새 내용  </w:t>")
    );
    let result = replace(&inserted, &hash(&text), &emptied, 0, 0, "");
    assert!(result.get("error").is_none(), "{result}");
    let bytes = fs::read(&emptied).unwrap();
    assert!(
        read_parts(&bytes)[MAIN]
            .0
            .contains("<w:rPr><w:b/></w:rPr><w:t xml:space='preserve'></w:t>")
    );
    assert_eq!(
        inspect(&emptied, &hash(&bytes))["paragraphs"][0]["runs"][0]["text"],
        ""
    );
}

#[test]
fn adds_preserved_space_to_self_closing_text_without_changing_its_prefix() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let before = fixture(&format!("<w:p><w:r><q:t xmlns:q='{W}'/></w:r></w:p>"), "");
    let sha = hash(&before);
    fs::write(&source, &before).unwrap();
    let result = replace(&source, &sha, &output, 0, 0, " 첫 입력 ");
    assert!(result.get("error").is_none(), "{result}");
    let edited = fs::read(&output).unwrap();
    let xml = &read_parts(&edited)[MAIN].0;
    assert!(xml.contains(&format!(
        "<q:t xmlns:q='{W}' xml:space=\"preserve\"> 첫 입력 </q:t>"
    )));
}

#[test]
fn catalogs_only_ordinary_direct_runs_outside_nested_regions_and_spanning_fields() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let before = fixture(
        concat!(
            "<w:p><w:r><w:t>first</w:t></w:r>",
            "<w:r><w:t>mixed</w:t><w:br/></w:r>",
            "<w:hyperlink w:anchor='inside'><w:r><w:t>link</w:t></w:r></w:hyperlink>",
            "<w:ins w:id='9'><w:r><w:t>revision</w:t></w:r></w:ins>",
            "<w:r><w:rPr><w:rPrChange w:id='3'/></w:rPr><w:t>revised format</w:t></w:r>",
            "<w:sdt><w:sdtPr><w:lock w:val='sdtLocked'/></w:sdtPr><w:sdtContent><w:r><w:t>locked</w:t></w:r></w:sdtContent></w:sdt>",
            "<w:r><w:t>after</w:t></w:r></w:p>",
            "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>table</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
            "<w:p><w:r><w:fldChar w:fldCharType='begin'/></w:r><w:r><w:instrText>FIELD</w:instrText></w:r></w:p>",
            "<w:p><w:r><w:fldChar w:fldCharType='separate'/></w:r><w:r><w:t>field result</w:t></w:r></w:p>",
            "<w:p><w:r><w:fldChar w:fldCharType='end'/></w:r></w:p>",
            "<w:p><w:r><w:t>last</w:t></w:r></w:p>",
        ),
        "",
    );
    let sha = hash(&before);
    fs::write(&source, &before).unwrap();
    assert_eq!(
        inspect(&source, &sha)["paragraphs"],
        json!([
            {"paragraphIndex":0,"runs":[{"runIndex":0,"text":"first"},{"runIndex":3,"text":"after"}]},
            {"paragraphIndex":4,"runs":[{"runIndex":0,"text":"last"}]},
        ])
    );
    for (paragraph, run) in [(0, 1), (0, 2), (1, 0), (2, 1), (3, 0)] {
        assert_eq!(
            replace(&source, &sha, &output, paragraph, run, "blocked")["error"]["code"],
            "invalid_request"
        );
    }
    assert!(!output.exists());
}

#[test]
fn protects_cross_paragraph_move_ranges_and_keeps_later_indices() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let bytes = fixture(
        concat!(
            "<w:p><w:moveToRangeStart w:id='7'/></w:p>",
            "<w:p><w:r><w:t>within the moved range</w:t></w:r></w:p>",
            "<w:p><w:moveToRangeEnd w:id='7'/><w:r><w:t>marker paragraph</w:t></w:r></w:p>",
            "<w:p><w:r><w:t>safe later paragraph</w:t></w:r></w:p>",
        ),
        "",
    );
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        inspect(&source, &sha)["paragraphs"],
        json!([
            {"paragraphIndex":3,"runs":[{"runIndex":0,"text":"safe later paragraph"}]},
        ])
    );
    assert_eq!(
        replace(&source, &sha, &output, 1, 0, "forbidden")["error"]["code"],
        "invalid_request"
    );
    assert!(!output.exists());
}

#[test]
fn rejects_protected_track_change_and_malformed_documents_without_publishing() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let ordinary = "<w:p><w:r><w:t>ordinary</w:t></w:r></w:p>";
    let unbalanced = format!("{ordinary}<w:p><w:r><w:fldChar w:fldCharType='begin'/></w:r></w:p>");
    for (body, settings) in [
        (ordinary, "<w:documentProtection w:enforcement='1'/>"),
        (ordinary, "<w:trackRevisions/>"),
        (ordinary, "<w:writeProtection/>"),
        (&unbalanced, ""),
    ] {
        let bytes = fixture(body, settings);
        let sha = hash(&bytes);
        fs::write(&source, &bytes).unwrap();
        assert_eq!(
            inspect(&source, &sha)["error"]["code"],
            "unsupported_document"
        );
        assert_eq!(
            replace(&source, &sha, &output, 0, 0, "replacement")["error"]["code"],
            "unsupported_document"
        );
        assert!(!output.exists());
    }
    let malformed = fixture("<w:p><w:r><w:t>open", "");
    fs::write(&source, &malformed).unwrap();
    assert!(inspect(&source, &hash(&malformed)).get("error").is_some());
    assert!(!output.exists());
}

#[test]
fn rejects_stale_no_op_invalid_and_existing_output() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let bytes = fixture("<w:p><w:r><w:t>ordinary</w:t></w:r></w:p>", "");
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        replace(&source, &"0".repeat(64), &output, 0, 0, "stale")["error"]["code"],
        "source_changed"
    );
    for text in ["ordinary", "control\n", "\u{2028}", &"🙂".repeat(1001)] {
        assert_eq!(
            replace(&source, &sha, &output, 0, 0, text)["error"]["code"],
            "invalid_request"
        );
    }
    assert_eq!(
        replace(&source, &sha, &output, 0, 512, "invalid index")["error"]["code"],
        "invalid_request"
    );
    assert!(!output.exists());
    fs::write(&output, b"existing output").unwrap();
    assert_eq!(
        replace(&source, &sha, &output, 0, 0, "replacement")["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), b"existing output");
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn table_cell_edits_formatted_run_in_a_later_paragraph_and_preserves_package() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let selected = "<w:t>원래 &amp; 내용 🧭</w:t>";
    let bytes = fixture(
        &format!(
            "<w:p><w:r><w:t>본문</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>다른 셀</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>첫 문단</w:t></w:r></w:p><w:p><w:pPr><w:keepNext/></w:pPr><w:r><w:rPr><w:b/><w:i/></w:rPr>{selected}</w:r><w:r><w:t>인접 구간</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        ),
        "",
    );
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        inspect_cells(&source, &sha),
        json!({"sourceSha256":sha,"cells":[
            {"tableIndex":0,"rowIndex":0,"cellIndex":0,"paragraphs":[
                {"paragraphIndex":0,"runs":[{"runIndex":0,"text":"다른 셀"}]}
            ]},
            {"tableIndex":0,"rowIndex":0,"cellIndex":1,"paragraphs":[
                {"paragraphIndex":0,"runs":[{"runIndex":0,"text":"첫 문단"}]},
                {"paragraphIndex":1,"runs":[{"runIndex":0,"text":"원래 & 내용 🧭"},{"runIndex":1,"text":"인접 구간"}]}
            ]}
        ]})
    );
    assert_eq!(
        inspect(&source, &sha),
        json!({"sourceSha256":sha,"paragraphs":[{"paragraphIndex":0,"runs":[{"runIndex":0,"text":"본문"}]}]})
    );
    let changed = " <새> '🙂' & \"한글\" ";
    let result = replace_cell(&source, &sha, &output, [0, 0, 1, 1, 0], changed);
    assert!(result.get("error").is_none(), "{result}");
    let edited = fs::read(&output).unwrap();
    let edited_sha = hash(&edited);
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":edited_sha,"tableIndex":0,"rowIndex":0,
            "cellIndex":1,"paragraphIndex":1,"runIndex":0})
    );
    assert_eq!(fs::read(&source).unwrap(), bytes);
    let before = read_parts(&bytes);
    let after = read_parts(&edited);
    for (name, part) in &before {
        if *name != MAIN {
            assert_eq!(part, &after[name]);
        }
    }
    let xml = &after[MAIN].0;
    let parsed = roxmltree::Document::parse(xml).unwrap();
    let target = parsed
        .descendants()
        .find(|node| node.has_tag_name((W, "t")) && node.text() == Some(changed))
        .unwrap();
    assert_eq!(xml.replace(&xml[target.range()], selected), before[MAIN].0);
    assert_eq!(
        inspect_cells(&output, &edited_sha)["cells"][1]["paragraphs"][1]["runs"][0]["text"],
        changed
    );
}

#[test]
fn table_cell_fills_a_truly_empty_app_created_cell_and_keeps_the_other_cells() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let inserted = directory.path().join("inserted.docx");
    let output = directory.path().join("edited.docx");
    let bytes = fixture("<w:p><w:r><w:t>anchor</w:t></w:r></w:p>", "");
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let table = request_json(
        &json!({"op":"docx_table_insert","sourcePath":source,"sourceSha256":sha,
            "outputPath":inserted,"afterParagraphIndex":0,"cells":[["left",""],["","other"]]})
        .to_string(),
    );
    assert!(table.get("error").is_none(), "{table}");
    let before = fs::read(&inserted).unwrap();
    let before_sha = hash(&before);
    assert_eq!(
        inspect_cells(&inserted, &before_sha)["cells"][1],
        json!({"tableIndex":0,"rowIndex":0,"cellIndex":1,"paragraphs":[
            {"paragraphIndex":0,"runs":[{"runIndex":0,"text":""}]}
        ]})
    );
    let result = replace_cell(
        &inserted,
        &before_sha,
        &output,
        [0, 0, 1, 0, 0],
        " 표 & 값 ",
    );
    assert!(result.get("error").is_none(), "{result}");
    let edited = fs::read(&output).unwrap();
    let old = read_parts(&before);
    let new = read_parts(&edited);
    assert_eq!(
        new[MAIN].0.replace(
            "<w:p><w:r><w:t xml:space=\"preserve\"> 표 &amp; 값 </w:t></w:r></w:p>",
            "<w:p/>"
        ),
        old[MAIN].0
    );
    let cells = inspect_cells(&output, &hash(&edited));
    assert_eq!(
        cells["cells"][1]["paragraphs"][0]["runs"][0]["text"],
        " 표 & 값 "
    );
    assert_eq!(cells["cells"][2]["paragraphs"][0]["runs"][0]["text"], "");
}

#[test]
fn table_cell_skips_ambiguous_rows_nested_cells_and_field_results() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let bytes = fixture(
        concat!(
            "<w:tbl><w:tblGrid><w:gridCol/><w:gridCol/><w:gridCol/></w:tblGrid>",
            "<w:tr><w:tc><w:tcPr><w:gridSpan w:val='2'/></w:tcPr><w:p><w:r><w:t>merged</w:t></w:r></w:p></w:tc><w:tc><w:p/></w:tc></w:tr>",
            "<w:tr><w:tc><w:tbl><w:tr><w:tc><w:p><w:r><w:t>nested</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p/></w:tc>",
            "<w:tc><w:p><w:r><w:fldChar w:fldCharType='begin'/></w:r><w:r><w:instrText>FIELD</w:instrText></w:r><w:r><w:fldChar w:fldCharType='separate'/></w:r><w:r><w:t>field result</w:t></w:r><w:r><w:fldChar w:fldCharType='end'/></w:r></w:p></w:tc>",
            "<w:tc><w:p><w:r><w:t>editable</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
            "<w:tbl><w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc><w:tc><w:p><w:r><w:t>other table</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
        ),
        "",
    );
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        inspect_cells(&source, &sha)["cells"],
        json!([
            {"tableIndex":0,"rowIndex":1,"cellIndex":2,"paragraphs":[
                {"paragraphIndex":0,"runs":[{"runIndex":0,"text":"editable"}]}
            ]},
            {"tableIndex":1,"rowIndex":0,"cellIndex":1,"paragraphs":[
                {"paragraphIndex":0,"runs":[{"runIndex":0,"text":"other table"}]}
            ]},
        ])
    );
    for coordinates in [
        [0, 0, 0, 0, 0],
        [0, 1, 0, 0, 0],
        [0, 1, 1, 0, 3],
        [1, 0, 0, 0, 0],
    ] {
        assert_eq!(
            replace_cell(&source, &sha, &output, coordinates, "blocked")["error"]["code"],
            "invalid_request"
        );
    }
    assert!(!output.exists());
}

#[test]
fn table_cell_uses_body_flow_ordinals_after_read_only_wrapped_tables() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let bytes = fixture(
        concat!(
            "<w:sdt><w:sdtPr><w:lock w:val='sdtLocked'/></w:sdtPr><w:sdtContent>",
            "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>wrapped first</w:t></w:r></w:p>",
            "<w:tbl><w:tr><w:tc><w:p/></w:tc></w:tr></w:tbl></w:tc></w:tr></w:tbl>",
            "</w:sdtContent></w:sdt>",
            "<w:customXml w:element='wrapped'><w:tbl><w:tr><w:tc><w:p><w:r><w:t>wrapped second</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:customXml>",
            "<w:p><w:r><w:pict><w:txbxContent><w:tbl><w:tr><w:tc><w:p/></w:tc></w:tr></w:tbl></w:txbxContent></w:pict></w:r></w:p>",
            "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>direct third</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
        ),
        "",
    );
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        inspect_cells(&source, &sha)["cells"],
        json!([{"tableIndex":2,"rowIndex":0,"cellIndex":0,"paragraphs":[
            {"paragraphIndex":0,"runs":[{"runIndex":0,"text":"direct third"}]}
        ]}])
    );
    assert_eq!(
        replace_cell(&source, &sha, &output, [0, 0, 0, 0, 0], "wrong table")["error"]["code"],
        "invalid_request"
    );
    assert!(!output.exists());
    let result = replace_cell(&source, &sha, &output, [2, 0, 0, 0, 0], "edited third");
    assert_eq!(result["tableIndex"], 2, "{result}");
    let written = fs::read(&output).unwrap();
    assert_eq!(
        read_parts(&written)[MAIN].0,
        read_parts(&bytes)[MAIN]
            .0
            .replace("direct third", "edited third")
    );
}

#[test]
fn table_cell_refuses_ambiguous_markup_table_ordinal_without_changing_body_inspection() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let bytes = fixture(
        concat!(
            "<w:p><w:r><w:t>body</w:t></w:r></w:p>",
            "<mc:AlternateContent xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006'>",
            "<mc:Choice Requires='w'><w:tbl><w:tr><w:tc><w:p/></w:tc></w:tr></w:tbl></mc:Choice>",
            "<mc:Fallback><w:p/></mc:Fallback></mc:AlternateContent>",
            "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>direct</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
        ),
        "",
    );
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        inspect_cells(&source, &sha)["error"]["code"],
        "unsupported_document"
    );
    assert_eq!(
        replace_cell(&source, &sha, &output, [0, 0, 0, 0, 0], "ambiguous")["error"]["code"],
        "unsupported_document"
    );
    assert_eq!(
        inspect(&source, &sha)["paragraphs"][0]["runs"][0]["text"],
        "body"
    );
    assert!(!output.exists());
}

#[test]
fn table_cell_excludes_tables_or_rows_with_ambiguous_visible_positions() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let bytes = fixture(
        concat!(
            "<w:tbl><w:tblGrid><w:gridCol/></w:tblGrid>",
            "<w:tr><w:trPr><w:del w:id='1'/></w:trPr><w:tc><w:p/></w:tc></w:tr>",
            "<w:tr><w:tc><w:p><w:r><w:t>shifted row</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
            "<w:tbl><w:tblGrid><w:gridCol/><w:gridCol/></w:tblGrid>",
            "<w:tr><w:tc><w:tcPr><x:geometry xmlns:x='urn:test' xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' mc:Ignorable='x' mc:ProcessContent='x:geometry'>",
            "<w:gridSpan w:val='2'/></x:geometry></w:tcPr><w:p/></w:tc>",
            "<w:tc><w:p><w:r><w:t>shifted column</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
            "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>unrelated table</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
        ),
        "",
    );
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        inspect_cells(&source, &sha)["cells"],
        json!([{"tableIndex":2,"rowIndex":0,"cellIndex":0,"paragraphs":[
            {"paragraphIndex":0,"runs":[{"runIndex":0,"text":"unrelated table"}]}
        ]}])
    );
}

fn inspect_paragraph_anchors(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"docx_paragraph_insert_inspect","sourcePath":source,"sourceSha256":sha})
            .to_string(),
    )
}

fn insert_body_paragraph(
    source: &Path,
    sha: &str,
    output: &Path,
    anchor: usize,
    position: &str,
    text: &str,
) -> Value {
    request_json(
        &json!({
            "op":"docx_paragraph_insert","sourcePath":source,"sourceSha256":sha,
            "outputPath":output,"anchorParagraphIndex":anchor,"position":position,"text":text,
        })
        .to_string(),
    )
}

#[test]
fn paragraph_insert_preserves_original_xml_and_package_before_or_after_an_anchor() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let first = "<w:p><w:pPr><w:pStyle w:val='Title'/></w:pPr><w:r><w:t>First</w:t></w:r></w:p>";
    let table = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>";
    let last = "<w:p><w:r><w:t>Last</w:t></w:r></w:p>";
    let bytes = fixture(&format!("{first}\n{table}{last}"), "");
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let inspected = inspect_paragraph_anchors(&source, &sha);
    assert_eq!(inspected["sourceSha256"], sha, "{inspected}");
    assert_eq!(
        inspected["paragraphs"],
        json!([
            {"index":0,"text":"First","canBefore":true,"canAfter":true},
            {"index":1,"text":"Last","canBefore":true,"canAfter":true},
        ])
    );
    let original = read_parts(&bytes);
    for (anchor, position, inserted_index, left, right) in [
        (0, "before", 0, "<w:body>", first),
        (0, "after", 1, first, "\n"),
        (1, "after", 2, last, "<w:sectPr/>"),
    ] {
        let output = directory
            .path()
            .join(format!("edited-{anchor}-{position}.docx"));
        let result =
            insert_body_paragraph(&source, &sha, &output, anchor, position, " 한글 & <값> 🙂 ");
        assert_eq!(result["sourceSha256"], sha, "{result}");
        assert_eq!(result["paragraphIndex"], inserted_index);
        let changed = fs::read(&output).unwrap();
        assert_eq!(result["outputSha256"], hash(&changed));
        let parts = read_parts(&changed);
        assert_eq!(
            parts.keys().collect::<Vec<_>>(),
            original.keys().collect::<Vec<_>>()
        );
        for (name, payload) in &original {
            if *name != MAIN {
                assert_eq!(parts[name], *payload, "unchanged {name}");
            }
        }
        let parsed = roxmltree::Document::parse(&parts[MAIN].0).unwrap();
        let inserted = parsed
            .root_element()
            .first_element_child()
            .unwrap()
            .children()
            .filter(|node| node.has_tag_name((W, "p")))
            .nth(inserted_index)
            .unwrap();
        let run = inserted.first_element_child().unwrap();
        assert!(run.has_tag_name((W, "r")));
        let text = run.first_element_child().unwrap();
        assert_eq!(text.text(), Some(" 한글 & <값> 🙂 "));
        assert_eq!(
            text.attribute(("http://www.w3.org/XML/1998/namespace", "space")),
            Some("preserve")
        );
        let range = inserted.range();
        assert!(parts[MAIN].0[..range.start].ends_with(left));
        assert!(parts[MAIN].0[range.end..].starts_with(right));
        let mut restored = parts[MAIN].0.clone();
        restored.replace_range(range, "");
        assert_eq!(restored, original[MAIN].0);
    }
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn paragraph_insert_only_exposes_boundaries_outside_open_word_ranges() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    for (start, end) in [
        (
            "<w:bookmarkStart w:id='2' w:name='Mark'/>",
            "<w:bookmarkEnd w:id='2'/>",
        ),
        (
            "<w:commentRangeStart w:id='2'/>",
            "<w:commentRangeEnd w:id='2'/>",
        ),
        (
            "<w:permStart w:id='2' w:edGrp='everyone'/>",
            "<w:permEnd w:id='2'/>",
        ),
        (
            "<w:moveFromRangeStart w:id='2' w:name='Move'/>",
            "<w:moveFromRangeEnd w:id='2'/>",
        ),
        (
            "<w:r><w:fldChar w:fldCharType='begin'/></w:r>",
            "<w:r><w:fldChar w:fldCharType='end'/></w:r>",
        ),
    ] {
        let bytes = fixture(
            &format!("<w:p>{start}</w:p><w:p/><!-- between --><w:p>{end}</w:p>"),
            "",
        );
        fs::write(&source, &bytes).unwrap();
        let sha = hash(&bytes);
        let inspected = inspect_paragraph_anchors(&source, &sha);
        assert_eq!(inspected["sourceSha256"], sha, "{inspected}");
        let flags = |index: usize| {
            let node = &inspected["paragraphs"][index];
            (node["canBefore"].as_bool(), node["canAfter"].as_bool())
        };
        assert_eq!(flags(0), (Some(true), Some(false)));
        assert_eq!(flags(1), (Some(false), Some(false)));
        assert_eq!(flags(2), (Some(false), Some(true)));
        for (anchor, position) in [(0, "after"), (1, "before"), (1, "after"), (2, "before")] {
            assert_eq!(
                insert_body_paragraph(&source, &sha, &output, anchor, position, "outside")["error"]
                    ["code"],
                "invalid_request"
            );
            assert!(!output.exists());
        }
    }
    let bytes = fixture("<w:p><w:bookmarkStart w:id='3' w:name='Open'/></w:p>", "");
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        inspect_paragraph_anchors(&source, &hash(&bytes))["error"]["code"],
        "unsupported_document"
    );
}

#[test]
fn paragraph_insert_refuses_unsafe_and_stale_requests_without_publishing() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let anchor = "<w:p><w:pPr><w:sectPr/></w:pPr><w:r><w:t>Section</w:t></w:r></w:p>";
    for settings in [
        "<w:trackRevisions/>",
        "<w:documentProtection w:enforcement='1'/>",
        "<w:writeProtection/>",
    ] {
        let bytes = fixture(anchor, settings);
        fs::write(&source, &bytes).unwrap();
        let sha = hash(&bytes);
        assert_eq!(
            inspect_paragraph_anchors(&source, &sha)["error"]["code"],
            "unsupported_document"
        );
        assert_eq!(
            insert_body_paragraph(&source, &sha, &output, 0, "before", "Blocked")["error"]["code"],
            "unsupported_document"
        );
        assert!(!output.exists());
    }
    let bytes = fixture(anchor, "");
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let inspected = inspect_paragraph_anchors(&source, &sha);
    assert_eq!(
        inspected["paragraphs"][0],
        json!({"index":0,"text":"Section","canBefore":true,"canAfter":false})
    );
    assert_eq!(
        insert_body_paragraph(&source, &"0".repeat(64), &output, 0, "before", "Stale")["error"]["code"],
        "source_changed"
    );
    for (anchor, position, value) in [
        (0, "before", "   "),
        (0, "before", "line\nbreak"),
        (0, "before", "line\u{2029}break"),
        (0, "before", &"🙂".repeat(1001)),
        (0, "after", "Across section"),
        (1, "before", "Missing"),
    ] {
        assert_eq!(
            insert_body_paragraph(&source, &sha, &output, anchor, position, value)["error"]["code"],
            "invalid_request"
        );
        assert!(!output.exists());
    }
    fs::write(&output, b"existing output").unwrap();
    assert_eq!(
        insert_body_paragraph(&source, &sha, &output, 0, "before", "Fresh")["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), b"existing output");
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

fn regular_structure_table(widths: &[u32], rows: usize, kind: &str) -> String {
    let grid = widths
        .iter()
        .map(|width| format!("<w:gridCol w:w='{width}'/>"))
        .collect::<String>();
    let rows = (0..rows)
        .map(|row| {
            let cells = widths.iter().enumerate().map(|(column, width)| {
                let fill = format!("0000{row}{column}");
                format!("<w:tc xmlns:s='{W}'><w:tcPr><w:tcW w:w='{width}' w:type='{kind}'/><s:shd s:fill='{fill}'/></w:tcPr><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>셀-{row}-{column}</w:t></w:r></w:p></w:tc>")
            }).collect::<String>();
            format!("<w:tr>{cells}</w:tr>")
        })
        .collect::<String>();
    format!(
        "<w:tbl><w:tblPr><w:tblW w:w='0' w:type='auto'/></w:tblPr><w:tblGrid>{grid}</w:tblGrid>{rows}</w:tbl>"
    )
}

fn inspect_structure(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"docx_table_structure_inspect","sourcePath":source,"sourceSha256":sha})
            .to_string(),
    )
}

fn edit_structure(
    source: &Path,
    sha: &str,
    output: &Path,
    table: usize,
    action: &str,
    index: usize,
    anchor: Option<usize>,
) -> Value {
    let mut request = json!({
        "op":"docx_table_structure_edit","sourcePath":source,"sourceSha256":sha,
        "outputPath":output,"tableIndex":table,"action":action,"index":index,
    });
    if let Some(anchor) = anchor {
        request["anchorIndex"] = json!(anchor);
    }
    request_json(&request.to_string())
}

#[test]
fn table_structure_preserves_other_parts_and_fills_new_cells() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let grid = [1700, 2721, 2382];
    let regular = regular_structure_table(&grid, 3, "dxa");
    let wrapped = format!(
        "<w:sdt><w:sdtPr/><w:sdtContent>{}</w:sdtContent></w:sdt>",
        regular_structure_table(&[1000], 1, "dxa")
    );
    let after = "<w:p><w:r><w:t>Outside the edited table</w:t></w:r></w:p>";
    let before = fixture(&format!("{wrapped}{regular}{after}"), "");
    fs::write(&source, &before).unwrap();
    let sha = hash(&before);
    assert_eq!(
        inspect_structure(&source, &sha),
        json!({"sourceSha256":sha,"tables":[{"tableIndex":1,"rowCount":3,"columnCount":3,"preview":"셀-0-0"}]})
    );
    let original_parts = read_parts(&before);
    for (action, index, anchor, dimensions, expected_grid, blank) in [
        (
            "insertRow",
            1,
            Some(0),
            (4, 3),
            grid.to_vec(),
            Some(([1, 1, 0, 0, 0], "000000")),
        ),
        ("deleteRow", 0, None, (2, 3), grid.to_vec(), None),
        (
            "insertColumn",
            2,
            Some(1),
            (3, 4),
            vec![1214, 1943, 1944, 1702],
            Some(([1, 0, 2, 0, 0], "000001")),
        ),
        ("deleteColumn", 1, None, (3, 2), vec![3060, 3743], None),
    ] {
        let output = directory.path().join(format!("{action}.docx"));
        let result = edit_structure(&source, &sha, &output, 1, action, index, anchor);
        assert!(result.get("error").is_none(), "{action}: {result}");
        let written = fs::read(&output).unwrap();
        let output_sha = hash(&written);
        assert_eq!(
            result,
            json!({"sourceSha256":sha,"outputSha256":output_sha,"tableIndex":1,"rowCount":dimensions.0,"columnCount":dimensions.1})
        );
        let parts = read_parts(&written);
        for (name, original) in &original_parts {
            if *name != MAIN {
                assert_eq!(&parts[name], original);
            }
        }
        let xml = &parts[MAIN].0;
        assert!(xml.contains(&wrapped));
        assert!(xml.contains(after));
        let document = roxmltree::Document::parse(xml).unwrap();
        let body = document.root_element().first_element_child().unwrap();
        let table = body
            .children()
            .find(|node| node.has_tag_name((W, "tbl")))
            .unwrap();
        let table_xml = &xml[table.range()];
        let grid = table
            .children()
            .find(|node| node.has_tag_name((W, "tblGrid")))
            .unwrap();
        assert_eq!(
            grid.children()
                .filter(|node| node.is_element())
                .map(|node| node.attribute((W, "w")).unwrap().parse::<u32>().unwrap())
                .collect::<Vec<_>>(),
            expected_grid
        );
        for row in 0..3 {
            for column in 0..3 {
                let text = format!("셀-{row}-{column}");
                let removed = action == "deleteRow" && row == index
                    || action == "deleteColumn" && column == index;
                assert_eq!(
                    table_xml.contains(&format!("<w:rPr><w:b/></w:rPr><w:t>{text}</w:t>")),
                    !removed,
                    "{action}: {text}"
                );
            }
        }
        if let Some((coordinates, anchor_fill)) = blank {
            let row = table
                .children()
                .filter(|node| node.has_tag_name((W, "tr")))
                .nth(coordinates[1])
                .unwrap();
            let cell = row
                .children()
                .filter(|node| node.has_tag_name((W, "tc")))
                .nth(coordinates[2])
                .unwrap();
            assert!(cell.descendants().all(|node| !node.has_tag_name((W, "t"))));
            let shading = cell
                .descendants()
                .find(|node| node.has_tag_name((W, "shd")))
                .unwrap();
            assert_eq!(shading.attribute((W, "fill")), Some(anchor_fill));
            let filled = directory.path().join(format!("{action}-filled.docx"));
            let reply = replace_cell(&output, &output_sha, &filled, coordinates, "새 셀");
            assert!(reply.get("error").is_none(), "{action}: {reply}");
        }
    }
    assert_eq!(fs::read(source).unwrap(), before);
}

#[test]
fn table_structure_handles_app_percentage_widths_and_refuses_unsafe_requests() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.docx");
    let output = directory.path().join("edited.docx");
    let regular = regular_structure_table(&[2500, 2500], 2, "pct");
    let single = regular_structure_table(&[5000], 1, "pct");
    let merged = regular.replacen("</w:tcPr>", "<w:vMerge w:val='restart'/></w:tcPr>", 1);
    let nested = regular.replacen("</w:tc>", &format!("{single}<w:p/></w:tc>"), 1);
    let revised = regular.replacen("</w:tcPr>", "<w:cellDel w:id='1'/></w:tcPr>", 1);
    let ranged = format!(
        "<w:p><w:bookmarkStart w:id='8' w:name='Outer'/></w:p>{regular}<w:p><w:bookmarkEnd w:id='8'/></w:p>"
    );
    let bytes = fixture(
        &format!("{merged}{nested}{revised}{single}{regular}{ranged}"),
        "",
    );
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let inspected = inspect_structure(&source, &sha);
    assert_eq!(
        inspected["tables"],
        json!([
            {"tableIndex":3,"rowCount":1,"columnCount":1,"preview":"셀-0-0"},
            {"tableIndex":4,"rowCount":2,"columnCount":2,"preview":"셀-0-0"},
        ])
    );
    for (table, action, index, anchor) in [
        (0, "insertColumn", 0, Some(0)),
        (1, "insertRow", 0, Some(0)),
        (2, "deleteRow", 0, None),
        (3, "deleteRow", 0, None),
        (3, "deleteColumn", 0, None),
        (4, "insertColumn", 3, Some(1)),
        (4, "deleteColumn", 2, None),
        (4, "replaceRow", 0, None),
        (5, "insertRow", 0, Some(0)),
        (4, "insertColumn", 0, None),
        (4, "deleteRow", 0, Some(0)),
    ] {
        assert!(
            edit_structure(&source, &sha, &output, table, action, index, anchor)
                .get("error")
                .is_some()
        );
        assert!(!output.exists());
    }
    assert_eq!(
        edit_structure(
            &source,
            &"0".repeat(64),
            &output,
            4,
            "insertColumn",
            0,
            Some(0)
        )["error"]["code"],
        "source_changed"
    );
    assert!(!output.exists());
    let reply = edit_structure(&source, &sha, &output, 4, "insertColumn", 0, Some(0));
    assert_eq!(reply["columnCount"], 3, "{reply}");
    let written = fs::read(output).unwrap();
    assert!(
        read_parts(&written)[MAIN]
            .0
            .contains("w:w='1666' w:type='pct'")
    );
    for settings in [
        "<w:trackRevisions/>",
        "<w:documentProtection w:enforcement='1'/>",
    ] {
        let bytes = fixture(&regular, settings);
        fs::write(&source, &bytes).unwrap();
        assert_eq!(
            inspect_structure(&source, &hash(&bytes))["error"]["code"],
            "unsupported_document"
        );
    }
}
