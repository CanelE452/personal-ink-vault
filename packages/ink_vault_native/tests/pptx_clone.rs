use ink_vault_native::request_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

const P: &str = "http://schemas.openxmlformats.org/presentationml/2006/main";
const A: &str = "http://schemas.openxmlformats.org/drawingml/2006/main";
const R: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const REL: &str = "http://schemas.openxmlformats.org/package/2006/relationships";
const TYPES: &str = "http://schemas.openxmlformats.org/package/2006/content-types";
const MIME: &str = "application/vnd.openxmlformats-officedocument.presentationml.";
const P14: &str = "http://schemas.microsoft.com/office/powerpoint/2010/main";
const A16: &str = "http://schemas.microsoft.com/office/drawing/2014/main";

#[path = "support/pptx_speaker_notes.rs"]
mod speaker_notes;
#[path = "support/pptx_slide_identity.rs"]
mod slide_identity;
#[path = "support/pptx_table_merge.rs"]
mod table_merge;

fn zip(members: &[(&str, &str)]) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut central = Vec::new();
    for (name, data) in members {
        let offset = bytes.len() as u32;
        let size = data.len() as u32;
        let crc = crc32fast::hash(data.as_bytes());
        bytes.extend(0x0403_4b50u32.to_le_bytes());
        for value in [20u16, 0x800, 0, 0, 0] {
            bytes.extend(value.to_le_bytes());
        }
        for value in [crc, size, size] {
            bytes.extend(value.to_le_bytes());
        }
        bytes.extend((name.len() as u16).to_le_bytes());
        bytes.extend([0, 0]);
        bytes.extend(name.as_bytes());
        bytes.extend(data.as_bytes());

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
    let offset = bytes.len() as u32;
    bytes.extend(&central);
    bytes.extend(0x0605_4b50u32.to_le_bytes());
    for value in [0u16, 0, members.len() as u16, members.len() as u16] {
        bytes.extend(value.to_le_bytes());
    }
    bytes.extend((central.len() as u32).to_le_bytes());
    bytes.extend(offset.to_le_bytes());
    bytes.extend([0, 0]);
    bytes
}

fn fixture() -> Vec<u8> {
    let second = format!("<p:sld xmlns:p='{P}' show='0'><p:cSld><p:spTree/></p:cSld></p:sld>");
    fixture_with_second(&second, &[])
}

fn fixture_with_second(second: &str, extra_members: &[(&str, &str)]) -> Vec<u8> {
    let types = format!(
        "<Types xmlns='{TYPES}'><Override PartName='/ppt/presentation.xml' ContentType='{MIME}presentation.main+xml'/><Override PartName='/ppt/slides/slide1.xml' ContentType='{MIME}slide+xml'/><Override PartName='/ppt/slides/slide2.xml' ContentType='{MIME}slide+xml'/><Override PartName='/ppt/notesSlides/notesSlide1.xml' ContentType='{MIME}notesSlide+xml'/></Types>"
    );
    let root = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='doc' Type='{R}/officeDocument' Target='ppt/presentation.xml'/></Relationships>"
    );
    let main = format!(
        "<p:presentation xmlns:p='{P}' xmlns:r='{R}'><p:sldIdLst><p:sldId id='256' r:id='slideA'/><p:sldId id='257' r:id='slideB'/></p:sldIdLst></p:presentation>"
    );
    let main_rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='slideA' Type='{R}/slide' Target='slides/slide1.xml'/><Relationship Id='slideB' Type='{R}/slide' Target='slides/slide2.xml'/></Relationships>"
    );
    let first = format!(
        "<p:sld xmlns:p='{P}' xmlns:a='{A}'><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>  원본 슬라이드  </a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
    );
    let first_rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='notes' Type='{R}/notesSlide' Target='../notesSlides/notesSlide1.xml'/></Relationships>"
    );
    let notes = format!("<p:notes xmlns:p='{P}'><p:cSld><p:spTree/></p:cSld></p:notes>");
    let notes_rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='parent' Type='{R}/slide' Target='../slides/slide1.xml'/></Relationships>"
    );
    let mut members: Vec<(&str, &str)> = vec![
        ("[Content_Types].xml", &types),
        ("_rels/.rels", &root),
        ("ppt/presentation.xml", &main),
        ("ppt/_rels/presentation.xml.rels", &main_rels),
        ("ppt/slides/slide1.xml", &first),
        ("ppt/slides/slide2.xml", second),
        ("ppt/slides/_rels/slide1.xml.rels", &first_rels),
        ("ppt/notesSlides/notesSlide1.xml", &notes),
        ("ppt/notesSlides/_rels/notesSlide1.xml.rels", &notes_rels),
    ];
    members.extend_from_slice(extra_members);
    zip(&members)
}

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn inspect(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"pptx_clone_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn apply(source: &Path, sha: &str, output: &Path) -> Value {
    apply_at(source, sha, output, 0)
}

fn apply_at(source: &Path, sha: &str, output: &Path, index: usize) -> Value {
    request_json(&json!({"op":"pptx_clone_apply","sourcePath":source,"sourceSha256":sha,"outputPath":output,"slideIndex":index}).to_string())
}

#[test]
fn clones_notes_and_preserves_source_and_deck_order_on_repeat() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let first = directory.path().join("clone.pptx");
    let second = directory.path().join("clone-again.pptx");
    let original = fixture();
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();

    let inspected = inspect(&source, &sha);
    assert_eq!(
        inspected["slides"],
        json!([
            {"index":0,"canDuplicate":true,"hidden":false,"title":"원본 슬라이드"},
            {"index":1,"canDuplicate":true,"hidden":true},
        ]),
        "{inspected}"
    );
    let result = apply(&source, &sha, &first);
    let cloned = fs::read(&first).unwrap_or_else(|_| panic!("{result}"));
    assert_eq!(
        result,
        json!({
            "sourceSha256":sha,"outputSha256":hash(&cloned),"slideCount":3,"duplicateIndex":1
        })
    );
    let result = apply(&first, &hash(&cloned), &second);
    assert_eq!(result["slideCount"], 4, "{result}");
    assert_eq!(fs::read(&source).unwrap(), original);
    let result = inspect(&second, &hash(&fs::read(&second).unwrap()));
    let slides = result["slides"].as_array().unwrap();
    assert_eq!(
        slides
            .iter()
            .map(|s| s["hidden"].as_bool().unwrap())
            .collect::<Vec<_>>(),
        [false, false, false, true]
    );
    assert!(slides.iter().all(|slide| slide["canDuplicate"] == true));
}

#[test]
fn stale_hash_and_existing_destination_fail_without_a_write() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let existing = directory.path().join("existing.pptx");
    let absent = directory.path().join("absent.pptx");
    let original = fixture();
    fs::write(&source, &original).unwrap();
    fs::write(&existing, b"sentinel").unwrap();
    assert_eq!(
        apply(&source, &"0".repeat(64), &absent)["error"]["code"],
        "source_changed"
    );
    assert!(!absent.exists());
    assert_eq!(
        apply(&source, &hash(&original), &existing)["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&existing).unwrap(), b"sentinel");
}

#[test]
fn chart_dependency_blocks_only_its_own_slide_and_leaves_the_destination_absent() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("charts.pptx");
    let output = directory.path().join("rejected.pptx");
    let slide = format!("<p:sld xmlns:p='{P}'><p:cSld><p:spTree/></p:cSld></p:sld>");
    let rel = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='chart' Type='{R}/chart' Target='../charts/chart1.xml'/></Relationships>"
    );
    let bytes = fixture_with_second(
        &slide,
        &[
            ("ppt/slides/_rels/slide2.xml.rels", &rel),
            ("ppt/charts/chart1.xml", "<chart/>"),
        ],
    );
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let result = inspect(&source, &sha);
    assert_eq!(result["slides"][0]["canDuplicate"], true, "{result}");
    assert_eq!(result["slides"][1]["canDuplicate"], false, "{result}");
    let result = apply_at(&source, &sha, &output, 1);
    assert_eq!(result["error"]["code"], "unsupported_slide", "{result}");
    assert!(!output.exists());
    let moved = reorder(&source, &sha, &output, 1, 0, false);
    assert_eq!(moved["destinationIndex"], 0, "{moved}");
    let moved_bytes = fs::read(&output).unwrap();
    let mut old_parts = stored_parts(&bytes);
    let mut new_parts = stored_parts(&moved_bytes);
    old_parts.remove("ppt/presentation.xml");
    new_parts.remove("ppt/presentation.xml");
    assert_eq!(old_parts, new_parts);
    let inspected = inspect(&output, moved["outputSha256"].as_str().unwrap());
    assert_eq!(inspected["slides"][0]["canDuplicate"], false, "{inspected}");
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn modern_connector_refs_remain_resolvable_after_copy_and_repeat() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("modern.pptx");
    let output = directory.path().join("modern-copy.pptx");
    let repeat = directory.path().join("modern-repeat.pptx");
    let start = "{00000000-0000-4000-8000-000000000001}";
    let end = "{00000000-0000-4000-8000-000000000002}";
    let slide = format!(
        "<p:sld xmlns:p='{P}' xmlns:p14='{P14}' xmlns:a16='{A16}'><p:cSld><p:spTree><a16:creationId id='{start}'/><a16:creationId id='{end}'/><a16:cxnDERefs st='{start}' end='{end}'/></p:spTree><p14:creationId val='42'/></p:cSld></p:sld>"
    );
    let bytes = fixture_with_second(&slide, &[]);
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let result = apply_at(&source, &sha, &output, 1);
    assert_eq!(result["duplicateIndex"], 2, "{result}");
    let result = apply_at(
        &output,
        result["outputSha256"].as_str().unwrap(),
        &repeat,
        2,
    );
    assert_eq!(result["duplicateIndex"], 3, "{result}");

    let bad_slide = slide.replace("a16:cxnDERefs", "a16:unknownRef");
    let bad_bytes = fixture_with_second(&bad_slide, &[]);
    fs::write(&source, &bad_bytes).unwrap();
    let result = inspect(&source, &hash(&bad_bytes));
    assert_eq!(result["slides"][1]["canDuplicate"], false, "{result}");
}

fn stored_parts(bytes: &[u8]) -> BTreeMap<&str, &str> {
    xml_parts(bytes)
        .into_iter()
        .map(|(name, data)| match data {
            Cow::Borrowed(xml) => (name, xml),
            Cow::Owned(_) => panic!("expected stored ZIP member {name}"),
        })
        .collect()
}

fn xml_parts(bytes: &[u8]) -> BTreeMap<&str, Cow<'_, str>> {
    raw_parts(bytes)
        .into_iter()
        .map(|(name, data)| {
            let xml = match data {
                Cow::Borrowed(bytes) => Cow::Borrowed(std::str::from_utf8(bytes).unwrap()),
                Cow::Owned(bytes) => Cow::Owned(String::from_utf8(bytes).unwrap()),
            };
            (name, xml)
        })
        .collect()
}

fn raw_parts(bytes: &[u8]) -> BTreeMap<&str, Cow<'_, [u8]>> {
    let u16_at = |i| u16::from_le_bytes(bytes[i..i + 2].try_into().unwrap()) as usize;
    let u32_at = |i| u32::from_le_bytes(bytes[i..i + 4].try_into().unwrap()) as usize;
    let mut result = BTreeMap::new();
    let mut offset = 0;
    while u32_at(offset) == 0x0403_4b50 {
        let name = offset + 30..offset + 30 + u16_at(offset + 26);
        let start = name.end + u16_at(offset + 28);
        let end = start + u32_at(offset + 18);
        let data = &bytes[start..end];
        let payload = match u16_at(offset + 8) {
            0 => Cow::Borrowed(data),
            8 => {
                let mut payload = Vec::new();
                flate2::read::DeflateDecoder::new(data)
                    .read_to_end(&mut payload)
                    .unwrap();
                Cow::Owned(payload)
            }
            method => panic!("unsupported test ZIP compression method {method}"),
        };
        result.insert(std::str::from_utf8(&bytes[name]).unwrap(), payload);
        offset = end;
    }
    assert_eq!(u32_at(offset), 0x0201_4b50);
    result
}

const CUSTOM_SHOW: &str = "<p:custShowLst><p:custShow id='1' name='다른 순서'><p:sldLst><p:sld r:id='slideC'/><p:sld r:id='slideA'/></p:sldLst></p:custShow></p:custShowLst>";

fn reorder_fixture(first_section: u32) -> Vec<u8> {
    let original = fixture();
    let mut members = stored_parts(&original);
    let sections = format!(
        "<p:extLst><p:ext uri='{{521415D9-36F7-43E2-AB2F-B90AF26B5E84}}'><p14:sectionLst xmlns:p14='{P14}'><p14:section name='처음' id='{{00000000-0000-4000-8000-000000000001}}'><a:sldIdLst xmlns:a='{P14}'><a:sldId id='{first_section}'/></a:sldIdLst></p14:section><p14:section name='다음' id='{{00000000-0000-4000-8000-000000000002}}'><b:sldIdLst xmlns:b='{P14}'><b:sldId id='257'/><b:sldId id='258'/></b:sldIdLst></p14:section></p14:sectionLst></p:ext></p:extLst>"
    );
    let presentation = members["ppt/presentation.xml"]
        .replace(
            "</p:sldIdLst>",
            "<p:sldId id='258' r:id='slideC'/></p:sldIdLst>",
        )
        .replace(
            "</p:presentation>",
            &format!("{CUSTOM_SHOW}{sections}</p:presentation>"),
        );
    let relationships = members["ppt/_rels/presentation.xml.rels"].replace(
        "</Relationships>",
        &format!("<Relationship Id='slideC' Type='{R}/slide' Target='slides/slide3.xml'/></Relationships>"),
    );
    let types = members["[Content_Types].xml"].replace(
        "</Types>",
        &format!(
            "<Override PartName='/ppt/slides/slide3.xml' ContentType='{MIME}slide+xml'/></Types>"
        ),
    );
    let third = format!("<p:sld xmlns:p='{P}'><p:cSld><p:spTree/></p:cSld></p:sld>");
    members.insert("ppt/presentation.xml", &presentation);
    members.insert("ppt/_rels/presentation.xml.rels", &relationships);
    members.insert("[Content_Types].xml", &types);
    members.insert("ppt/slides/slide3.xml", &third);
    zip(&members.into_iter().collect::<Vec<_>>())
}

fn insert_fixture(jump: bool) -> Vec<u8> {
    let original = reorder_fixture(256);
    let mut members = stored_parts(&original);
    let types = members["[Content_Types].xml"].replace(
        "</Types>",
        &format!("<Override PartName='/ppt/slideLayouts/slideLayout1.xml' ContentType='{MIME}slideLayout+xml'/><Override PartName='/ppt/slideMasters/slideMaster1.xml' ContentType='{MIME}slideMaster+xml'/></Types>"),
    );
    let layout = format!("<p:sldLayout xmlns:p='{P}'><p:cSld><p:spTree/></p:cSld></p:sldLayout>");
    let layout_rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='master' Type='{R}/slideMaster' Target='../slideMasters/slideMaster1.xml'/></Relationships>"
    );
    let master = format!("<p:sldMaster xmlns:p='{P}'><p:cSld><p:spTree/></p:cSld></p:sldMaster>");
    let link = format!(
        "<Relationship Id='layout' Type='{R}/slideLayout' Target='../slideLayouts/slideLayout1.xml'/>"
    );
    let anchor_rels = members["ppt/slides/_rels/slide1.xml.rels"]
        .replace("</Relationships>", &format!("{link}</Relationships>"));
    let slide_rels = format!("<Relationships xmlns='{REL}'>{link}</Relationships>");
    let second = members["ppt/slides/slide2.xml"].replace(
        "<p:spTree/>",
        &format!(
            "<p:spTree>{}</p:spTree>",
            action_shape("hlinkClick", "ppaction://hlinkshowjump?jump=3")
        ),
    );
    members.extend([
        ("[Content_Types].xml", types.as_str()),
        ("ppt/slideLayouts/slideLayout1.xml", layout.as_str()),
        (
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
            layout_rels.as_str(),
        ),
        ("ppt/slideMasters/slideMaster1.xml", master.as_str()),
        ("ppt/slides/_rels/slide1.xml.rels", anchor_rels.as_str()),
        ("ppt/slides/_rels/slide2.xml.rels", slide_rels.as_str()),
        ("ppt/slides/_rels/slide3.xml.rels", slide_rels.as_str()),
    ]);
    if jump {
        members.insert("ppt/slides/slide2.xml", &second);
    }
    zip(&members.into_iter().collect::<Vec<_>>())
}

fn insert_inspect(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"pptx_insert_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn insert(source: &Path, sha: &str, output: &Path, anchor: usize) -> Value {
    request_json(&json!({"op":"pptx_insert_apply","sourcePath":source,"sourceSha256":sha,"outputPath":output,"slideIndex":anchor}).to_string())
}

const ANCHOR_BLANK_LAYOUT: u32 = 2_147_483_649;
const ANCHOR_CONTENT_LAYOUT: u32 = 2_147_483_655;
const FOREIGN_LAYOUT: u32 = 2_147_483_661;

fn insert_layout_fixture() -> Vec<u8> {
    let original = insert_fixture(false);
    let mut parts = stored_parts(&original);
    let types = parts["[Content_Types].xml"].replace(
        "</Types>",
        &format!(
            "<Override PartName='/ppt/slideMasters/slideMaster2.xml' ContentType='{MIME}slideMaster+xml'/>
            <Override PartName='/ppt/slideLayouts/slideLayout2.xml' ContentType='{MIME}slideLayout+xml'/>
            <Override PartName='/ppt/slideLayouts/slideLayout3.xml' ContentType='{MIME}slideLayout+xml'/></Types>"
        ),
    );
    let presentation = parts["ppt/presentation.xml"].replace(
        "<p:sldIdLst>",
        "<p:sldMasterIdLst><p:sldMasterId id='2147483648' r:id='masterA'/>
        <p:sldMasterId id='2147483659' r:id='masterB'/></p:sldMasterIdLst><p:sldIdLst>",
    );
    let presentation_rels = parts["ppt/_rels/presentation.xml.rels"].replace(
        "</Relationships>",
        &format!(
            "<Relationship Id='masterA' Type='{R}/slideMaster' Target='slideMasters/slideMaster1.xml'/>
            <Relationship Id='masterB' Type='{R}/slideMaster' Target='slideMasters/slideMaster2.xml'/></Relationships>"
        ),
    );
    let master = |layout_ids: &str| {
        format!(
            "<p:sldMaster xmlns:p='{P}' xmlns:r='{R}'><p:cSld><p:spTree/></p:cSld>
            <p:clrMap bg1='lt1' tx1='dk1' bg2='lt2' tx2='dk2' accent1='accent1' accent2='accent2'
                accent3='accent3' accent4='accent4' accent5='accent5' accent6='accent6' hlink='hlink' folHlink='folHlink'/>
            <p:sldLayoutIdLst>{layout_ids}</p:sldLayoutIdLst></p:sldMaster>"
        )
    };
    let first_master = master(&format!(
        "<p:sldLayoutId id='{ANCHOR_BLANK_LAYOUT}' r:id='blank'/><p:sldLayoutId id='{ANCHOR_CONTENT_LAYOUT}' r:id='content'/>"
    ));
    let second_master = master(&format!(
        "<p:sldLayoutId id='{FOREIGN_LAYOUT}' r:id='foreign'/>"
    ));
    let first_master_rels = format!(
        "<Relationships xmlns='{REL}'>
        <Relationship Id='blank' Type='{R}/slideLayout' Target='../slideLayouts/slideLayout1.xml'/>
        <Relationship Id='content' Type='{R}/slideLayout' Target='../slideLayouts/slideLayout2.xml'/></Relationships>"
    );
    let second_master_rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='foreign' Type='{R}/slideLayout'
        Target='../slideLayouts/slideLayout3.xml'/></Relationships>"
    );
    let placeholder = |id: u32, name: &str, attributes: &str| {
        format!(
            "<p:sp><p:nvSpPr><p:cNvPr id='{id}' name='{name}'/><p:cNvSpPr/><p:nvPr>
            <p:ph {attributes}/></p:nvPr></p:nvSpPr><p:spPr/>
            <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>Layout prompt</a:t></a:r></a:p></p:txBody></p:sp>"
        )
    };
    let layout = |kind: &str, name: &str, shapes: &str| {
        format!(
            "<p:sldLayout xmlns:p='{P}' xmlns:a='{A}' type='{kind}'><p:cSld name='{name}'>
            <p:spTree><p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
            <p:grpSpPr/>{shapes}</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        )
    };
    let blank = layout("blank", "빈 레이아웃", "");
    let content = layout(
        "obj",
        "제목과 내용",
        &format!(
            "{}{}",
            placeholder(2, "Title", "type='title'"),
            placeholder(3, "Content", "type='obj' idx='7'")
        ),
    );
    let foreign = layout("blank", "다른 마스터", "");
    let first_backlink = parts["ppt/slideLayouts/_rels/slideLayout1.xml.rels"];
    let second_backlink = first_backlink.replace("slideMaster1.xml", "slideMaster2.xml");
    parts.extend([
        ("[Content_Types].xml", types.as_str()),
        ("ppt/presentation.xml", presentation.as_str()),
        (
            "ppt/_rels/presentation.xml.rels",
            presentation_rels.as_str(),
        ),
        ("ppt/slideMasters/slideMaster1.xml", first_master.as_str()),
        ("ppt/slideMasters/slideMaster2.xml", second_master.as_str()),
        (
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            first_master_rels.as_str(),
        ),
        (
            "ppt/slideMasters/_rels/slideMaster2.xml.rels",
            second_master_rels.as_str(),
        ),
        ("ppt/slideLayouts/slideLayout1.xml", blank.as_str()),
        ("ppt/slideLayouts/slideLayout2.xml", content.as_str()),
        ("ppt/slideLayouts/slideLayout3.xml", foreign.as_str()),
        (
            "ppt/slideLayouts/_rels/slideLayout2.xml.rels",
            first_backlink,
        ),
        (
            "ppt/slideLayouts/_rels/slideLayout3.xml.rels",
            second_backlink.as_str(),
        ),
    ]);
    zip(&parts.into_iter().collect::<Vec<_>>())
}

fn insert_with_layout(source: &Path, sha: &str, output: &Path, layout_id: u32) -> Value {
    request_json(
        &json!({"op":"pptx_insert_apply","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "slideIndex":1,"layoutId":layout_id})
        .to_string(),
    )
}

#[test]
fn insert_selected_anchor_master_layout_creates_editable_placeholders() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let original = insert_layout_fixture();
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();

    let legacy = insert_inspect(&source, &sha);
    assert_eq!(
        legacy["slides"][1],
        json!({"index":1,"hidden":true,"canInsert":true,"sectionName":"다음"}),
        "{legacy}"
    );
    let inspection = request_json(
        &json!({"op":"pptx_insert_inspect","sourcePath":source,"sourceSha256":sha,"includeLayouts":true})
            .to_string(),
    );
    assert_eq!(
        inspection["slides"][1]["layouts"],
        json!([
            {"id":ANCHOR_BLANK_LAYOUT,"name":"빈 레이아웃","kind":"blank"},
            {"id":ANCHOR_CONTENT_LAYOUT,"name":"제목과 내용","kind":"obj"}
        ]),
        "{inspection}"
    );

    let output = directory.path().join("selected.pptx");
    let applied = insert_with_layout(&source, &sha, &output, ANCHOR_CONTENT_LAYOUT);
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{applied}"));
    assert_eq!(
        applied,
        json!({"sourceSha256":sha,"outputSha256":hash(&bytes),"slideCount":4,"insertedIndex":2,
            "layoutId":ANCHOR_CONTENT_LAYOUT})
    );
    assert_eq!(fs::read(&source).unwrap(), original);

    let new = xml_parts(&bytes);
    let changed = [
        "[Content_Types].xml",
        "ppt/presentation.xml",
        "ppt/_rels/presentation.xml.rels",
    ];
    for (part, data) in stored_parts(&original) {
        if !changed.contains(&part) {
            assert_eq!(new[part], data, "changed {part}");
        }
    }
    let relations = roxmltree::Document::parse(&new["ppt/slides/_rels/slide4.xml.rels"]).unwrap();
    let links = relations
        .root_element()
        .children()
        .filter(|node| node.is_element())
        .collect::<Vec<_>>();
    assert_eq!(links.len(), 1);
    assert_eq!(
        links[0].attribute("Target"),
        Some("../slideLayouts/slideLayout2.xml")
    );

    let slide = roxmltree::Document::parse(&new["ppt/slides/slide4.xml"]).unwrap();
    assert!(slide.root_element().attribute("show").is_none());
    let shapes = slide
        .descendants()
        .filter(|node| node.has_tag_name((P, "sp")))
        .map(|shape| {
            assert!(
                shape
                    .children()
                    .any(|node| node.has_tag_name((P, "txBody")))
            );
            assert!(!shape.descendants().any(|node| node.has_tag_name((A, "t"))
                && node.text().is_some_and(|text| !text.is_empty())));
            let ph = shape
                .descendants()
                .find(|node| node.has_tag_name((P, "ph")))
                .unwrap();
            (ph.attribute("type"), ph.attribute("idx"))
        })
        .collect::<Vec<_>>();
    assert_eq!(shapes, [(Some("title"), None), (Some("obj"), Some("7"))]);
}

#[test]
fn insert_rejects_layout_ids_outside_anchor_master_without_output() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("rejected.pptx");
    let original = insert_layout_fixture();
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();

    for id in [FOREIGN_LAYOUT, u32::MAX] {
        let applied = insert_with_layout(&source, &sha, &output, id);
        assert!(applied["error"].is_object(), "{applied}");
        assert!(!output.exists());
    }
    assert_eq!(fs::read(&source).unwrap(), original);
}

const COMPATIBLE_LAYOUT: u32 = 2_147_483_666;

fn change_layout_fixture(target_object_index: u32) -> Vec<u8> {
    let original = insert_layout_fixture();
    let mut parts = stored_parts(&original);
    let types = parts["[Content_Types].xml"].replace(
        "</Types>",
        &format!(
            "<Override PartName='/ppt/slideLayouts/slideLayout4.xml' ContentType='{MIME}slideLayout+xml'/><Default Extension='png' ContentType='image/png'/></Types>"
        ),
    );
    let master = parts["ppt/slideMasters/slideMaster1.xml"].replace(
        "</p:sldLayoutIdLst>",
        &format!("<p:sldLayoutId id='{COMPATIBLE_LAYOUT}' r:id='alternate'/></p:sldLayoutIdLst>"),
    );
    let master_rels = parts["ppt/slideMasters/_rels/slideMaster1.xml.rels"].replace(
        "</Relationships>",
        &format!(
            "<Relationship Id='alternate' Type='{R}/slideLayout' Target='../slideLayouts/slideLayout4.xml'/></Relationships>"
        ),
    );
    let alternate = parts["ppt/slideLayouts/slideLayout2.xml"]
        .replace("제목과 내용", "왼쪽 제목과 내용")
        .replace(
            "type='title'",
            "type='title' idx='0' sz='full' orient='horz'",
        )
        .replace(
            "type='obj' idx='7'",
            &format!("idx='{target_object_index}'"),
        );
    let populated = parts["ppt/slideLayouts/slideLayout2.xml"]
        .replace("sldLayout", "sld")
        .replace(" type='obj'", "")
        .replace("Layout prompt", "작성한 내용")
        .replacen("작성한 내용", "작성한 제목", 1);
    let notes = parts["ppt/notesSlides/notesSlide1.xml"].replace(
        "<p:spTree/>",
        &format!(
            "<p:spTree xmlns:a='{A}'><p:sp><p:txBody><a:p><a:r><a:t>발표자 노트</a:t></a:r></a:p></p:txBody></p:sp></p:spTree>"
        ),
    );
    let slide_rels = parts["ppt/slides/_rels/slide1.xml.rels"]
        .replace("slideLayout1.xml", "slideLayout2.xml")
        .replace(
            "</Relationships>",
            &format!(
                "<Relationship Id='image' Type='{R}/image' Target='../media/image1.png'/></Relationships>"
            ),
        );
    let backlink = parts["ppt/slideLayouts/_rels/slideLayout2.xml.rels"];
    parts.extend([
        ("[Content_Types].xml", types.as_str()),
        ("ppt/slideMasters/slideMaster1.xml", master.as_str()),
        (
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            master_rels.as_str(),
        ),
        ("ppt/slideLayouts/slideLayout4.xml", alternate.as_str()),
        ("ppt/slideLayouts/_rels/slideLayout4.xml.rels", backlink),
        ("ppt/slides/slide1.xml", populated.as_str()),
        ("ppt/slides/_rels/slide1.xml.rels", slide_rels.as_str()),
        ("ppt/notesSlides/notesSlide1.xml", notes.as_str()),
        ("ppt/media/image1.png", "unchanged media bytes"),
    ]);
    zip(&parts.into_iter().collect::<Vec<_>>())
}

fn inspect_layout_change(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"pptx_layout_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn change_layout(source: &Path, sha: &str, output: &Path, slide_id: u32, layout_id: u32) -> Value {
    request_json(
        &json!({"op":"pptx_layout_apply","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "slideIndex":0,"slideId":slide_id,"layoutId":layout_id})
        .to_string(),
    )
}

#[test]
fn change_layout_preserves_populated_slide_notes_and_every_unselected_member() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("output.pptx");
    let original = change_layout_fixture(7);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();

    let inspected = inspect_layout_change(&source, &sha);
    assert_eq!(inspected["slideCount"], 3, "{inspected}");
    assert_eq!(
        inspected["slides"][0],
        json!({"index":0,"slideId":256,"title":"작성한 제목","hidden":false,"sectionName":"처음",
            "layouts":[{"id":COMPATIBLE_LAYOUT,"name":"왼쪽 제목과 내용","kind":"obj"}]}),
        "{inspected}"
    );
    assert_eq!(inspected["slides"][1]["hidden"], true);
    let result = change_layout(&source, &sha, &output, 256, COMPATIBLE_LAYOUT);
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    let output_sha = hash(&bytes);
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":output_sha,"slideCount":3,
            "slideIndex":0,"slideId":256,"layoutId":COMPATIBLE_LAYOUT})
    );
    assert_eq!(fs::read(&source).unwrap(), original);
    let before = stored_parts(&original);
    let after = xml_parts(&bytes);
    assert!(before.keys().eq(after.keys()));
    for (part, content) in before {
        if part == "ppt/slides/_rels/slide1.xml.rels" {
            assert_eq!(
                after[part],
                content.replace("slideLayout2.xml", "slideLayout4.xml")
            );
        } else {
            assert_eq!(after[part], content, "{part}");
        }
    }
    assert_eq!(
        inspect_layout_change(&output, &output_sha)["slides"][0]["layouts"][0]["id"],
        ANCHOR_CONTENT_LAYOUT
    );
}

#[test]
fn change_layout_rejects_incompatible_foreign_current_and_stale_edits_without_output() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("rejected.pptx");
    let original = change_layout_fixture(0);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    let inspection = inspect_layout_change(&source, &sha);
    assert_eq!(
        inspection["slides"][0]["layouts"],
        json!([]),
        "{inspection}"
    );
    for (hash, slide_id, layout_id) in [
        (sha.as_str(), 256, COMPATIBLE_LAYOUT),
        (sha.as_str(), 256, FOREIGN_LAYOUT),
        (sha.as_str(), 256, ANCHOR_CONTENT_LAYOUT),
        (sha.as_str(), 256, ANCHOR_BLANK_LAYOUT),
        (sha.as_str(), 257, COMPATIBLE_LAYOUT),
        (&"0".repeat(64), 256, COMPATIBLE_LAYOUT),
    ] {
        let rejected = change_layout(&source, hash, &output, slide_id, layout_id);
        assert!(rejected["error"].is_object(), "{rejected}");
        assert!(!output.exists());
    }
    assert_eq!(fs::read(&source).unwrap(), original);
}

#[test]
fn insert_blank_after_hidden_slide_preserves_existing_members_and_section_order() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("output.pptx");
    let original = insert_fixture(false);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    let before = insert_inspect(&source, &sha);
    assert_eq!(
        before["slides"][1],
        json!({"index":1,"hidden":true,"canInsert":true,"sectionName":"다음"}),
        "{before}"
    );
    let result = insert(&source, &sha, &output, 1);
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    let out_sha = hash(&bytes);
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":out_sha,"slideCount":4,"insertedIndex":2})
    );
    assert_eq!(fs::read(&source).unwrap(), original);

    let old = stored_parts(&original);
    let new = xml_parts(&bytes);
    let edited = [
        "[Content_Types].xml",
        "ppt/presentation.xml",
        "ppt/_rels/presentation.xml.rels",
    ];
    for (part, data) in old {
        if !edited.contains(&part) {
            assert_eq!(new[part], data, "changed {part}");
        }
    }
    let slide = roxmltree::Document::parse(&new["ppt/slides/slide4.xml"]).unwrap();
    assert_eq!(slide.root_element().attribute("showMasterSp"), Some("0"));
    assert!(slide.root_element().attribute("show").is_none());
    assert_eq!(
        slide
            .descendants()
            .find(|n| n.has_tag_name((P, "spTree")))
            .unwrap()
            .children()
            .filter(|n| n.is_element())
            .map(|n| n.tag_name().name())
            .collect::<Vec<_>>(),
        ["nvGrpSpPr", "grpSpPr"]
    );
    let relation = roxmltree::Document::parse(&new["ppt/slides/_rels/slide4.xml.rels"]).unwrap();
    let relations = relation
        .root_element()
        .children()
        .filter(|n| n.is_element())
        .collect::<Vec<_>>();
    assert_eq!(relations.len(), 1);
    assert_eq!(
        relations[0].attribute("Target"),
        Some("../slideLayouts/slideLayout1.xml")
    );
    let presentation = roxmltree::Document::parse(&new["ppt/presentation.xml"]).unwrap();
    assert!(new["ppt/presentation.xml"].contains(CUSTOM_SHOW));
    let mut section_lists = presentation
        .descendants()
        .filter(|n| n.has_tag_name((P14, "sldIdLst")));
    assert_eq!(
        section_lists
            .nth(1)
            .unwrap()
            .children()
            .filter_map(|n| n.attribute("id"))
            .collect::<Vec<_>>(),
        ["257", "259", "258"]
    );
    let after = insert_inspect(&output, &out_sha);
    assert_eq!(
        after["slides"][2],
        json!({"index":2,"hidden":false,"canInsert":true,"sectionName":"다음"}),
        "{after}"
    );
}

#[test]
fn insert_protects_position_dependent_links_and_uses_no_clobber() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("output.pptx");
    let original = insert_fixture(true);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    let view = insert_inspect(&source, &sha);
    assert_eq!(
        view["slides"]
            .as_array()
            .unwrap_or_else(|| panic!("{view}"))
            .iter()
            .map(|slide| slide["canInsert"].as_bool().unwrap())
            .collect::<Vec<_>>(),
        [false, false, true]
    );
    assert_eq!(
        insert(&source, &sha, &output, 1)["error"]["code"],
        "unsupported_slide"
    );
    assert_eq!(
        insert(&source, &"0".repeat(64), &output, 2)["error"]["code"],
        "source_changed"
    );
    assert!(!output.exists());
    fs::write(&output, b"occupied").unwrap();
    assert_eq!(
        insert(&source, &sha, &output, 2)["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), b"occupied");
    let valid_output = directory.path().join("valid.pptx");
    assert_eq!(insert(&source, &sha, &valid_output, 2)["insertedIndex"], 3);
    assert_eq!(fs::read(&source).unwrap(), original);
}

#[test]
fn insert_respects_show_ranges_and_requires_an_anchor_layout() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("output.pptx");
    let original = insert_fixture(false);
    let mut parts = stored_parts(&original);
    let properties = format!(
        "<p:presentationPr xmlns:p='{P}'><p:showPr><p:sldRg st='1' end='2'/></p:showPr></p:presentationPr>"
    );
    let presentation_rels = parts["ppt/_rels/presentation.xml.rels"].replace(
        "</Relationships>",
        &format!("<Relationship Id='showSettings' Type='{R}/presProps' Target='presProps.xml'/></Relationships>"),
    );
    let types = parts["[Content_Types].xml"].replace(
        "</Types>",
        &format!(
            "<Override PartName='/ppt/presProps.xml' ContentType='{MIME}presProps+xml'/></Types>"
        ),
    );
    parts.insert("ppt/presProps.xml", &properties);
    parts.insert("ppt/_rels/presentation.xml.rels", &presentation_rels);
    parts.insert("[Content_Types].xml", &types);
    parts.remove("ppt/slides/_rels/slide3.xml.rels");
    let bytes = zip(&parts.into_iter().collect::<Vec<_>>());
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let view = insert_inspect(&source, &sha);
    assert_eq!(
        view["slides"]
            .as_array()
            .unwrap()
            .iter()
            .map(|slide| slide["canInsert"].as_bool().unwrap())
            .collect::<Vec<_>>(),
        [false, true, false]
    );
    for anchor in [0, 2] {
        assert_eq!(
            insert(&source, &sha, &output, anchor)["error"]["code"],
            "unsupported_slide"
        );
        assert!(!output.exists());
    }
    let applied = insert(&source, &sha, &output, 1);
    assert_eq!(applied["insertedIndex"], 2, "{applied}");
    assert_eq!(
        xml_parts(&fs::read(&output).unwrap())["ppt/presProps.xml"].as_ref(),
        properties.as_str(),
    );
}

fn reorder_inspect(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"pptx_reorder_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn reorder(
    source: &Path,
    sha: &str,
    output: &Path,
    from: usize,
    target: usize,
    after: bool,
) -> Value {
    request_json(&json!({"op":"pptx_reorder_apply","sourcePath":source,"sourceSha256":sha,"outputPath":output,"sourceIndex":from,"targetIndex":target,"after":after}).to_string())
}

fn set_slide_display(
    source: &Path,
    sha: &str,
    output: &Path,
    index: usize,
    expected_hidden: bool,
    hidden: bool,
) -> Value {
    request_json(
        &json!({
            "op":"pptx_slide_display","sourcePath":source,"sourceSha256":sha,
            "outputPath":output,"slideIndex":index,"expectedHidden":expected_hidden,"hidden":hidden
        })
        .to_string(),
    )
}

#[test]
fn slide_display_preserves_the_deck_and_changes_only_the_selected_slide_attribute() {
    let directory = tempfile::tempdir().unwrap();
    let mut source = directory.path().join("input.pptx");
    let original = reorder_fixture(256);
    let mut bytes = original.clone();
    fs::write(&source, &bytes).unwrap();
    for (index, before, after) in [(0, false, true), (1, true, false), (0, true, false)] {
        let sha = hash(&bytes);
        let output = directory.path().join(format!("slide-{index}-{after}.pptx"));
        let result = set_slide_display(&source, &sha, &output, index, before, after);
        let changed = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
        let changed_sha = hash(&changed);
        assert_eq!(
            result,
            json!({
                "sourceSha256":sha,"outputSha256":changed_sha,"slideCount":3,
                "slideIndex":index,"hidden":after
            })
        );
        let part = format!("ppt/slides/slide{}.xml", index + 1);
        let mut previous_parts = stored_parts(&bytes);
        let previous_slide = previous_parts.remove(part.as_str()).unwrap();
        let mut next_parts = stored_parts(&changed);
        let next_slide = next_parts.remove(part.as_str()).unwrap();
        assert_eq!(previous_parts, next_parts);
        let previous_xml = roxmltree::Document::parse(previous_slide).unwrap();
        let next_xml = roxmltree::Document::parse(next_slide).unwrap();
        assert_eq!(
            next_xml.root_element().attribute("show"),
            Some(if after { "0" } else { "1" })
        );
        assert_eq!(
            previous_slide[previous_xml
                .root_element()
                .first_element_child()
                .unwrap()
                .range()
                .start..],
            next_slide[next_xml
                .root_element()
                .first_element_child()
                .unwrap()
                .range()
                .start..]
        );
        let mut expected = reorder_inspect(&source, &sha)["slides"].clone();
        expected[index]["hidden"] = json!(after);
        assert_eq!(reorder_inspect(&output, &changed_sha)["slides"], expected);
        assert_eq!(fs::read(&source).unwrap(), bytes);
        source = output;
        bytes = changed;
    }
    assert_eq!(
        fs::read(directory.path().join("input.pptx")).unwrap(),
        original
    );
}

#[test]
fn slide_display_rejects_stale_noop_invalid_and_protected_requests_without_writing() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("output.pptx");
    let bytes = fixture();
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    for (index, expected_hidden, hidden, expected_error) in [
        (0, true, false, "source_changed"),
        (0, false, false, "invalid_request"),
        (2, false, true, "invalid_request"),
    ] {
        let result = set_slide_display(&source, &sha, &output, index, expected_hidden, hidden);
        assert_eq!(result["error"]["code"], expected_error, "{result}");
        assert!(!output.exists());
    }
    let result = set_slide_display(&source, &"0".repeat(64), &output, 0, false, true);
    assert_eq!(result["error"]["code"], "source_changed", "{result}");
    let foreign = tempfile::tempdir().unwrap();
    let result = set_slide_display(
        &source,
        &sha,
        &foreign.path().join("output.pptx"),
        0,
        false,
        true,
    );
    assert_eq!(result["error"]["code"], "invalid_request", "{result}");
    assert_eq!(fs::read_dir(foreign.path()).unwrap().count(), 0);
    fs::write(&output, b"sentinel").unwrap();
    let result = set_slide_display(&source, &sha, &output, 0, false, true);
    assert_eq!(result["error"]["code"], "output_exists", "{result}");
    assert_eq!(fs::read(&output).unwrap(), b"sentinel");
    assert_eq!(fs::read(&source).unwrap(), bytes);
    let rejected = directory.path().join("rejected.pptx");
    for (protected, signed) in [(true, false), (false, true)] {
        let bytes = text_box_fixture(protected, signed);
        fs::write(&source, &bytes).unwrap();
        let result = set_slide_display(&source, &hash(&bytes), &rejected, 0, false, true);
        assert_eq!(result["error"]["code"], "invalid_pptx", "{result}");
        assert!(!rejected.exists());
        assert_eq!(fs::read(&source).unwrap(), bytes);
    }
}

#[test]
fn slide_background_adds_replaces_and_resets_only_the_selected_hidden_slide() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let second = format!(
        "<x:sld xmlns:x='{P}' xmlns:p='urn:other' show='0'><x:cSld name='Hidden'>\n<x:spTree/><x:extLst/></x:cSld></x:sld>"
    );
    let bytes = fixture_with_second(&second, &[]);
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let initial = inspect_slide_background(&source, &sha);
    assert_eq!(initial["sourceSha256"], sha);
    assert_eq!(initial["slideCount"], 2);
    assert_eq!(initial["slides"][0]["background"], "inherited");
    assert_eq!(
        initial["slides"][1],
        json!({"index":1,"hidden":true,"background":"inherited"})
    );

    let mut previous = source.clone();
    let mut previous_bytes = bytes.clone();
    for (index, (before, after)) in [
        ("inherited", "#123ABC"),
        ("#123ABC", "#1122EE"),
        ("#1122EE", "inherited"),
    ]
    .into_iter()
    .enumerate()
    {
        let previous_sha = hash(&previous_bytes);
        let output = directory.path().join(format!("edited-{index}.pptx"));
        let result = set_slide_background(&previous, &previous_sha, &output, 1, before, after);
        let changed = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
        let changed_sha = hash(&changed);
        assert_eq!(
            result,
            json!({"sourceSha256":previous_sha,"outputSha256":changed_sha,
                                 "slideCount":2,"slideIndex":1,"background":after})
        );
        let mut parts = xml_parts(&changed);
        let edited = parts.remove("ppt/slides/slide2.xml").unwrap();
        let mut original_parts = xml_parts(&bytes);
        original_parts.remove("ppt/slides/slide2.xml");
        assert_eq!(parts, original_parts);
        let xml = roxmltree::Document::parse(&edited).unwrap();
        let root = xml.root_element();
        assert_eq!(root.attribute("show"), Some("0"));
        let common = root.first_element_child().unwrap();
        let nodes: Vec<_> = common
            .children()
            .filter(roxmltree::Node::is_element)
            .collect();
        if let Some(color) = after.strip_prefix('#') {
            assert_eq!(nodes[0].tag_name().name(), "bg");
            assert_eq!(nodes[0].tag_name().namespace(), Some(P));
            let rgb = nodes[0]
                .descendants()
                .find(|n| n.has_tag_name((A, "srgbClr")))
                .unwrap();
            assert_eq!(rgb.attribute("val"), Some(color));
            assert_eq!(nodes[1].tag_name().name(), "spTree");
            let span = nodes[0].range();
            assert_eq!(
                format!("{}{}", &edited[..span.start], &edited[span.end..]),
                second
            );
        } else {
            assert_eq!(edited, second);
        }
        let mut expected = initial["slides"].clone();
        expected[1]["background"] = json!(after);
        assert_eq!(
            inspect_slide_background(&output, &changed_sha)["slides"],
            expected
        );
        assert_eq!(fs::read(&previous).unwrap(), previous_bytes);
        previous = output;
        previous_bytes = changed;
    }
    assert_eq!(fs::read(source).unwrap(), bytes);
}

#[test]
fn slide_background_reads_existing_rgb_and_blocks_complex_backgrounds() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("edited.pptx");
    let solid = "<p:bg><p:bgPr shadeToTitle='0'><a:solidFill><a:srgbClr val='aabbcc'/></a:solidFill><a:effectLst/></p:bgPr></p:bg>";
    let build = |background: &str| {
        let slide = format!(
            "<p:sld xmlns:p='{P}' xmlns:a='{A}'><p:cSld>{background}<p:spTree/></p:cSld></p:sld>"
        );
        fixture_with_second(&slide, &[])
    };
    let bytes = build(solid);
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    assert_eq!(
        inspect_slide_background(&source, &sha)["slides"][1]["background"],
        "#AABBCC"
    );
    let result = set_slide_background(&source, &sha, &output, 1, "#AABBCC", "#FE0010");
    let changed = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    assert_eq!(
        xml_parts(&changed)["ppt/slides/slide2.xml"],
        xml_parts(&bytes)["ppt/slides/slide2.xml"].replace("val='aabbcc'", "val='FE0010'")
    );

    let rejected = directory.path().join("rejected.pptx");
    for background in [
        "<p:bg><p:bgRef idx='1001'><a:schemeClr val='bg1'/></p:bgRef></p:bg>".to_string(),
        "<p:bg><p:bgPr><a:gradFill/></p:bgPr></p:bg>".to_string(),
        solid.replace(
            "<a:srgbClr val='aabbcc'/>",
            "<a:srgbClr val='aabbcc'><a:alpha val='90000'/></a:srgbClr>",
        ),
        solid.replace(
            "<a:effectLst/>",
            "<a:effectLst><a:blur rad='0'/></a:effectLst>",
        ),
        format!("{solid}{solid}"),
    ] {
        let bytes = build(&background);
        fs::write(&source, &bytes).unwrap();
        let sha = hash(&bytes);
        assert_eq!(
            inspect_slide_background(&source, &sha)["slides"][1]["background"],
            "unsupported"
        );
        let result = set_slide_background(&source, &sha, &rejected, 1, "inherited", "#FE0010");
        assert_eq!(result["error"]["code"], "invalid_pptx", "{result}");
        assert!(!rejected.exists());
        assert_eq!(fs::read(&source).unwrap(), bytes);
    }
}

#[test]
fn slide_background_rejects_stale_protected_and_colliding_requests() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("output.pptx");
    let bytes = fixture();
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    for (index, before, after, code) in [
        (0, "#000000", "#000001", "source_changed"),
        (0, "inherited", "inherited", "invalid_request"),
        (0, "inherited", "#aBcDef", "invalid_request"),
        (0, "unsupported", "#ABCDEF", "invalid_request"),
        (2, "inherited", "#ABCDEF", "invalid_request"),
    ] {
        let result = set_slide_background(&source, &sha, &output, index, before, after);
        assert_eq!(result["error"]["code"], code, "{result}");
        assert!(!output.exists());
    }
    let result = set_slide_background(&source, &"0".repeat(64), &output, 0, "inherited", "#ABCDEF");
    assert_eq!(result["error"]["code"], "source_changed", "{result}");
    let foreign = tempfile::tempdir().unwrap();
    let result = set_slide_background(
        &source,
        &sha,
        &foreign.path().join("output.pptx"),
        0,
        "inherited",
        "#ABCDEF",
    );
    assert_eq!(result["error"]["code"], "invalid_request", "{result}");
    assert_eq!(fs::read_dir(foreign.path()).unwrap().count(), 0);
    fs::write(&output, b"sentinel").unwrap();
    let result = set_slide_background(&source, &sha, &output, 0, "inherited", "#ABCDEF");
    assert_eq!(result["error"]["code"], "output_exists", "{result}");
    assert_eq!(fs::read(&output).unwrap(), b"sentinel");
    assert_eq!(fs::read(&source).unwrap(), bytes);

    let rejected = directory.path().join("rejected.pptx");
    for (protected, signed) in [(true, false), (false, true)] {
        let bytes = text_box_fixture(protected, signed);
        fs::write(&source, &bytes).unwrap();
        let sha = hash(&bytes);
        let inspect = inspect_slide_background(&source, &sha);
        assert_eq!(inspect["error"]["code"], "invalid_pptx", "{inspect}");
        let result = set_slide_background(&source, &sha, &rejected, 0, "inherited", "#ABCDEF");
        assert_eq!(result["error"]["code"], "invalid_pptx", "{result}");
        assert!(!rejected.exists());
        assert_eq!(fs::read(&source).unwrap(), bytes);
    }
}

fn inspect_slide_background(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"pptx_slide_background_inspect","sourcePath":source,"sourceSha256":sha})
            .to_string(),
    )
}

fn set_slide_background(
    source: &Path,
    sha: &str,
    output: &Path,
    index: usize,
    before: &str,
    after: &str,
) -> Value {
    request_json(&json!({"op":"pptx_slide_background_apply","sourcePath":source,"sourceSha256":sha,
                       "outputPath":output,"slideIndex":index,"expectedBackground":before,"background":after}).to_string())
}

#[test]
fn reorder_preserves_slide_parts_custom_show_and_empty_sections() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("reorder.pptx");
    let output = directory.path().join("reordered.pptx");
    let repeat = directory.path().join("repeat.pptx");
    let bytes = reorder_fixture(256);
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let view = reorder_inspect(&source, &sha);
    assert_eq!(view["sourceSha256"], sha, "{view}");
    assert_eq!(
        view["slides"],
        json!([
            {"index":0,"hidden":false,"title":"원본 슬라이드","sectionTitle":"처음","sectionGroup":0},
            {"index":1,"hidden":true,"sectionTitle":"다음","sectionGroup":1},
            {"index":2,"hidden":false,"sectionTitle":"다음","sectionGroup":1},
        ])
    );
    let result = reorder(&source, &sha, &output, 0, 2, true);
    assert_eq!(result["destinationIndex"], 2, "{result}");
    let changed = fs::read(&output).unwrap();
    let changed_sha = hash(&changed);
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":changed_sha,"slideCount":3,"sourceIndex":0,"destinationIndex":2})
    );
    let mut parts = stored_parts(&changed);
    let updated = parts.remove("ppt/presentation.xml").unwrap();
    let mut original = stored_parts(&bytes);
    original.remove("ppt/presentation.xml");
    assert_eq!(parts, original);
    assert!(updated.contains(CUSTOM_SHOW));
    let doc = roxmltree::Document::parse(updated).unwrap();
    let listing = doc
        .root_element()
        .children()
        .find(|n| n.has_tag_name((P, "sldIdLst")))
        .unwrap();
    assert_eq!(
        listing
            .children()
            .filter_map(|n| n.attribute((R, "id")))
            .collect::<Vec<_>>(),
        ["slideB", "slideC", "slideA"]
    );
    let sections = doc
        .descendants()
        .filter(|n| n.has_tag_name((P14, "section")))
        .collect::<Vec<_>>();
    assert_eq!(sections.len(), 2);
    let section_ids = |section: roxmltree::Node| {
        section
            .descendants()
            .filter(|n| n.has_tag_name((P14, "sldId")))
            .map(|n| n.attribute("id").unwrap().parse::<u32>().unwrap())
            .collect::<Vec<_>>()
    };
    assert!(section_ids(sections[0]).is_empty());
    assert_eq!(section_ids(sections[1]), [257, 258, 256]);
    let view = reorder_inspect(&output, &changed_sha);
    assert_eq!(view["slides"][0]["hidden"], true, "{view}");
    assert_eq!(view["slides"][2]["sectionTitle"], "다음", "{view}");
    let result = reorder(&output, &changed_sha, &repeat, 2, 0, false);
    assert_eq!(result["destinationIndex"], 0, "{result}");
    let repeated = reorder_inspect(&repeat, result["outputSha256"].as_str().unwrap());
    assert_eq!(
        repeated["slides"][0]["title"], "원본 슬라이드",
        "{repeated}"
    );
    assert_eq!(repeated["slides"][0]["sectionTitle"], "다음", "{repeated}");
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn reorder_moves_section_membership_without_changing_slide_order() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("section-boundary.pptx");
    let original = reorder_fixture(256);
    let mut original_parts = stored_parts(&original);
    let presentation = original_parts["ppt/presentation.xml"].replace("name='다음'", "name='처음'");
    original_parts.insert("ppt/presentation.xml", &presentation);
    let original = zip(&original_parts
        .iter()
        .map(|(&name, &xml)| (name, xml))
        .collect::<Vec<_>>());
    original_parts.remove("ppt/presentation.xml");
    fs::write(&source, &original).unwrap();
    let sha = hash(&original);

    for (from, target, after, expected_sections, expected_groups) in [
        (0, 1, false, [vec![], vec![256, 257, 258]], [0, 0, 0]),
        (1, 0, true, [vec![256, 257], vec![258]], [0, 0, 1]),
    ] {
        let output = directory.path().join(format!("result-{from}.pptx"));
        let result = reorder(&source, &sha, &output, from, target, after);
        assert_eq!(result["sourceIndex"], from, "{result}");
        assert_eq!(result["destinationIndex"], from, "{result}");
        assert_eq!(result["slideCount"], 3, "{result}");

        let changed = fs::read(&output).unwrap();
        let changed_sha = hash(&changed);
        assert_eq!(result["sourceSha256"], sha);
        assert_eq!(result["outputSha256"], changed_sha);
        assert_ne!(original, changed);
        let mut parts = stored_parts(&changed);
        let updated = parts.remove("ppt/presentation.xml").unwrap();
        assert_eq!(parts, original_parts);

        let section_list_range = |xml: &str| {
            roxmltree::Document::parse(xml)
                .unwrap()
                .descendants()
                .find(|node| node.has_tag_name((P14, "sectionLst")))
                .unwrap()
                .range()
        };
        let before_range = section_list_range(&presentation);
        let after_range = section_list_range(updated);
        assert_eq!(
            presentation[..before_range.start],
            updated[..after_range.start]
        );
        assert_eq!(presentation[before_range.end..], updated[after_range.end..]);

        let updated_xml = roxmltree::Document::parse(updated).unwrap();
        let sections = updated_xml
            .descendants()
            .filter(|node| node.has_tag_name((P14, "section")))
            .collect::<Vec<_>>();
        assert_eq!(sections.len(), 2);
        for (index, (section, expected_ids)) in
            sections.into_iter().zip(expected_sections).enumerate()
        {
            let guid = format!("{{00000000-0000-4000-8000-00000000000{}}}", index + 1);
            assert_eq!(section.attribute("id"), Some(guid.as_str()));
            assert_eq!(section.attribute("name"), Some("처음"));
            let ids = section
                .descendants()
                .filter(|node| node.has_tag_name((P14, "sldId")))
                .map(|node| node.attribute("id").unwrap().parse::<u32>().unwrap())
                .collect::<Vec<_>>();
            assert_eq!(ids, expected_ids);
        }
        let inspected = reorder_inspect(&output, &changed_sha);
        for (row, group) in inspected["slides"]
            .as_array()
            .unwrap()
            .iter()
            .zip(expected_groups)
        {
            assert_eq!(row["sectionGroup"], group, "{inspected}");
        }
        assert_eq!(fs::read(&source).unwrap(), original);
    }
}

#[test]
fn reorder_inspection_exposes_membership_independent_of_section_names() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("sections.pptx");
    let original = reorder_fixture(256);
    let mut parts = stored_parts(&original);
    let unnamed = parts["ppt/presentation.xml"].replace(" name='처음'", "");
    parts.insert("ppt/presentation.xml", &unnamed);
    let sectioned = zip(&parts.into_iter().collect::<Vec<_>>());
    fs::write(&source, &sectioned).unwrap();

    let inspected = reorder_inspect(&source, &hash(&sectioned));
    let rows = inspected["slides"].as_array().unwrap();
    assert_eq!(rows[0].get("sectionTitle"), None);
    assert_eq!(rows[0]["sectionGroup"], 0, "{inspected}");
    assert_eq!(rows[1]["sectionGroup"], 1, "{inspected}");
    assert_eq!(rows[2]["sectionGroup"], 1, "{inspected}");

    let sectionless = fixture();
    fs::write(&source, &sectionless).unwrap();
    let inspected = reorder_inspect(&source, &hash(&sectionless));
    assert!(
        inspected["slides"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row.get("sectionGroup").is_none())
    );
}

#[test]
fn reorder_rejects_malformed_sections_stale_noop_and_existing_output() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("reorder.pptx");
    let output = directory.path().join("reordered.pptx");
    let bad = reorder_fixture(257);
    fs::write(&source, &bad).unwrap();
    let sha = hash(&bad);
    let result = reorder_inspect(&source, &sha);
    assert_eq!(result["error"]["code"], "invalid_pptx", "{result}");
    let result = reorder(&source, &sha, &output, 0, 2, true);
    assert_eq!(result["error"]["code"], "invalid_pptx", "{result}");
    let valid = reorder_fixture(256);
    fs::write(&source, &valid).unwrap();
    let sha = hash(&valid);
    let result = reorder(&source, &"0".repeat(64), &output, 0, 2, true);
    assert_eq!(result["error"]["code"], "source_changed", "{result}");
    for (from, target, after) in [(1, 2, false), (2, 1, true), (2, 2, true), (1, 3, false)] {
        let result = reorder(&source, &sha, &output, from, target, after);
        assert_eq!(result["error"]["code"], "invalid_request", "{result}");
    }
    let sectionless = fixture();
    let sectionless_source = directory.path().join("sectionless.pptx");
    fs::write(&sectionless_source, &sectionless).unwrap();
    let result = reorder(
        &sectionless_source,
        &hash(&sectionless),
        &output,
        0,
        1,
        false,
    );
    assert_eq!(result["error"]["code"], "invalid_request", "{result}");
    assert!(!output.exists());
    fs::write(&output, b"sentinel").unwrap();
    let result = reorder(&source, &sha, &output, 0, 2, true);
    assert_eq!(result["error"]["code"], "output_exists", "{result}");
    assert_eq!(fs::read(&output).unwrap(), b"sentinel");
}

fn delete_inspect(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"pptx_delete_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn delete(source: &Path, sha: &str, output: &Path, index: usize) -> Value {
    request_json(&json!({"op":"pptx_delete_apply","sourcePath":source,"sourceSha256":sha,"outputPath":output,"slideIndex":index}).to_string())
}

fn delete_fixture(inbound: bool) -> Vec<u8> {
    let original = reorder_fixture(256);
    let mut members = stored_parts(&original);
    let slide_relationships = members["ppt/slides/_rels/slide1.xml.rels"].replace(
        "</Relationships>",
        &format!(
            "<Relationship Id='own' Type='{R}/image' Target='../media/own.png'/><Relationship Id='shared' Type='{R}/image' Target='../media/shared.png'/><Relationship Id='chart' Type='{R}/chart' Target='../charts/chart1.xml'/></Relationships>"
        ),
    );
    let cross_link = if inbound {
        format!("<Relationship Id='other' Type='{R}/slide' Target='slide1.xml'/>")
    } else {
        String::new()
    };
    let other_relationships = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='shared' Type='{R}/image' Target='../media/shared.png'/>{cross_link}</Relationships>"
    );
    let chart_relationships = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='table' Type='{R}/package' Target='../embeddings/data.xlsx'/></Relationships>"
    );
    let types = members["[Content_Types].xml"].replace(
        "</Types>",
        "<Default Extension='png' ContentType='image/png'/><Override PartName='/ppt/charts/chart1.xml' ContentType='application/vnd.openxmlformats-officedocument.drawingml.chart+xml'/><Override PartName='/ppt/embeddings/data.xlsx' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'/></Types>",
    );
    members.insert("[Content_Types].xml", &types);
    members.insert("ppt/slides/_rels/slide1.xml.rels", &slide_relationships);
    members.insert("ppt/slides/_rels/slide2.xml.rels", &other_relationships);
    members.insert("ppt/charts/_rels/chart1.xml.rels", &chart_relationships);
    members.insert(
        "ppt/charts/chart1.xml",
        "<c:chartSpace xmlns:c='http://schemas.openxmlformats.org/drawingml/2006/chart'/>",
    );
    members.insert("ppt/embeddings/data.xlsx", "private data");
    members.insert("ppt/media/own.png", "private photo");
    members.insert("ppt/media/shared.png", "shared photo");
    members.insert("ppt/media/unrelated.png", "unrelated orphan");
    zip(&members.into_iter().collect::<Vec<_>>())
}

#[test]
fn delete_removes_slide_and_exclusive_relationship_graph_from_new_package() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("deleted.pptx");
    let bytes = delete_fixture(false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let view = delete_inspect(&source, &sha);
    assert_eq!(
        view["slides"],
        json!([
            {"index":0,"title":"원본 슬라이드","hidden":false,"sectionName":"처음","canDelete":true},
            {"index":1,"hidden":true,"sectionName":"다음","canDelete":true},
            {"index":2,"hidden":false,"sectionName":"다음","canDelete":true},
        ]),
        "{view}"
    );
    let result = delete(&source, &sha, &output, 0);
    let changed = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":hash(&changed),"slideCount":2,"deletedIndex":0})
    );
    let actual = stored_parts(&changed);
    let original = stored_parts(&bytes);
    let removed = [
        "ppt/slides/slide1.xml",
        "ppt/slides/_rels/slide1.xml.rels",
        "ppt/notesSlides/notesSlide1.xml",
        "ppt/notesSlides/_rels/notesSlide1.xml.rels",
        "ppt/charts/chart1.xml",
        "ppt/charts/_rels/chart1.xml.rels",
        "ppt/embeddings/data.xlsx",
        "ppt/media/own.png",
    ];
    for name in removed {
        assert!(!actual.contains_key(name), "{name}");
    }
    assert_eq!(actual.len() + removed.len(), original.len());
    let edited = [
        "ppt/presentation.xml",
        "ppt/_rels/presentation.xml.rels",
        "[Content_Types].xml",
    ];
    for (name, value) in actual.iter().filter(|(name, _)| !edited.contains(name)) {
        assert_eq!(*value, original[name], "{name}");
    }
    assert!(!actual["ppt/presentation.xml"].contains("slideA"));
    assert!(!actual["ppt/presentation.xml"].contains("id='256'"));
    assert!(actual["ppt/presentation.xml"].contains("<p:sld r:id='slideC'/>"));
    assert!(!actual["ppt/_rels/presentation.xml.rels"].contains("slideA"));
    for name in removed {
        assert!(!actual["[Content_Types].xml"].contains(name), "{name}");
    }
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn delete_blocks_surviving_inbound_slide_relationship_and_existing_output() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("deleted.pptx");
    let bytes = delete_fixture(true);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let view = delete_inspect(&source, &sha);
    assert_eq!(view["slides"][0]["canDelete"], false, "{view}");
    assert_eq!(view["slides"][1]["canDelete"], true, "{view}");
    let result = delete(&source, &sha, &output, 0);
    assert_eq!(result["error"]["code"], "unsupported_slide", "{result}");
    let result = delete(&source, &"0".repeat(64), &output, 1);
    assert_eq!(result["error"]["code"], "source_changed", "{result}");
    assert!(!output.exists());
    fs::write(&output, b"sentinel").unwrap();
    let result = delete(&source, &sha, &output, 1);
    assert_eq!(result["error"]["code"], "output_exists", "{result}");
    assert_eq!(fs::read(&output).unwrap(), b"sentinel");
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn delete_keeps_a_deck_with_one_slide_and_removes_empty_custom_shows() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let two = directory.path().join("two.pptx");
    let one = directory.path().join("one.pptx");
    let invalid = directory.path().join("invalid.pptx");
    let bytes = reorder_fixture(256);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let first = delete(&source, &sha, &two, 0);
    let second = delete(&two, first["outputSha256"].as_str().unwrap(), &one, 1);
    let one_bytes = fs::read(&one).unwrap_or_else(|_| panic!("{second}"));
    let one_sha = hash(&one_bytes);
    let remaining = stored_parts(&one_bytes);
    assert!(!remaining["ppt/presentation.xml"].contains("custShow"));
    let view = delete_inspect(&one, &one_sha);
    assert_eq!(view["slideCount"], 1, "{view}");
    assert_eq!(view["slides"][0]["canDelete"], false, "{view}");
    let result = delete(&one, &one_sha, &invalid, 0);
    assert_eq!(result["error"]["code"], "unsupported_slide", "{result}");
    assert!(!invalid.exists());
}

#[test]
fn delete_protects_affected_slide_ranges_and_selected_custom_shows() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("deleted.pptx");
    let original = reorder_fixture(256);
    let mut members = stored_parts(&original);
    let relationships = members["ppt/_rels/presentation.xml.rels"].replace(
        "</Relationships>",
        &format!(
            "<Relationship Id='props' Type='{R}/presProps' Target='presProps.xml'/></Relationships>"
        ),
    );
    let props = format!(
        "<p:presentationPr xmlns:p='{P}'><p:showPr><p:sldRg st='1' end='2'/></p:showPr></p:presentationPr>"
    );
    members.insert("ppt/_rels/presentation.xml.rels", &relationships);
    members.insert("ppt/presProps.xml", &props);
    let bytes = zip(&members
        .iter()
        .map(|(&key, &value)| (key, value))
        .collect::<Vec<_>>());
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let view = delete_inspect(&source, &sha);
    assert_eq!(view["slides"][0]["canDelete"], false, "{view}");
    assert_eq!(view["slides"][1]["canDelete"], false, "{view}");
    assert_eq!(view["slides"][2]["canDelete"], true, "{view}");
    let refused = delete(&source, &sha, &output, 0);
    assert_eq!(refused["error"]["code"], "unsupported_slide", "{refused}");
    assert!(!output.exists());
    let allowed = delete(&source, &sha, &output, 2);
    let changed = fs::read(&output).unwrap_or_else(|_| panic!("{allowed}"));
    assert_eq!(stored_parts(&changed)["ppt/presProps.xml"], props);

    let configured = format!(
        "<p:presentationPr xmlns:p='{P}'><p:showPr><p:custShow id='1'/></p:showPr></p:presentationPr>"
    );
    members.insert("ppt/presProps.xml", &configured);
    let bytes = zip(&members.into_iter().collect::<Vec<_>>());
    fs::write(&source, &bytes).unwrap();
    let second = directory.path().join("second.pptx");
    let result = delete(&source, &hash(&bytes), &second, 0);
    let sha = result["outputSha256"]
        .as_str()
        .unwrap_or_else(|| panic!("{result}"));
    let view = delete_inspect(&second, sha);
    assert_eq!(view["slides"][1]["canDelete"], false, "{view}");
    let invalid = directory.path().join("invalid.pptx");
    let refused = delete(&second, sha, &invalid, 1);
    assert_eq!(refused["error"]["code"], "unsupported_slide", "{refused}");
    assert!(!invalid.exists());
}

fn action_shape(tag: &str, action: &str) -> String {
    format!(
        "<p:sp><p:nvSpPr><p:cNvPr id='7' name='Link'><a:{tag} xmlns:a='{A}' xmlns:r='{R}' r:id='' action='{action}'/></p:cNvPr><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp>"
    )
}

#[test]
fn delete_blocks_emptied_custom_show_if_link_survives() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("deleted.pptx");
    let original = reorder_fixture(256);
    let mut members = stored_parts(&original);
    let main = members["ppt/presentation.xml"].replace("<p:sld r:id='slideC'/>", "");
    let action = action_shape(
        "hlinkClick",
        "&#x70;paction://customshow?id=1&amp;return=true",
    );
    let second = members["ppt/slides/slide2.xml"]
        .replace("<p:spTree/>", &format!("<p:spTree>{action}</p:spTree>"));
    members.insert("ppt/presentation.xml", &main);
    members.insert("ppt/slides/slide2.xml", &second);
    let bytes = zip(&members.into_iter().collect::<Vec<_>>());
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let view = delete_inspect(&source, &sha);
    assert_eq!(view["slides"][0]["canDelete"], false, "{view}");
    assert_eq!(view["slides"][1]["canDelete"], true, "{view}");
    assert_eq!(view["slides"][2]["canDelete"], true, "{view}");
    let result = delete(&source, &sha, &output, 0);
    assert_eq!(result["error"]["code"], "unsupported_slide", "{result}");
    assert!(!output.exists());
    let result = delete(&source, &sha, &output, 1);
    assert_eq!(result["slideCount"], 2, "{result}");
}

#[test]
fn delete_blocks_shifted_numeric_jump_only_when_owner_survives() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("deleted.pptx");
    let original = reorder_fixture(256);
    let mut members = stored_parts(&original);
    let numeric = action_shape("hlinkHover", "ppaction://hlinkshowjump?jump=2");
    let notes = members["ppt/notesSlides/notesSlide1.xml"]
        .replace("<p:spTree/>", &format!("<p:spTree>{numeric}</p:spTree>"));
    let relative = action_shape("hlinkClick", "ppaction://hlinkshowjump?jump=nextslide");
    let external = action_shape("hlinkMouseOver", "ppaction://hlinkpres?slideindex=3");
    let third = members["ppt/slides/slide3.xml"].replace(
        "<p:spTree/>",
        &format!("<p:spTree>{relative}{external}</p:spTree>"),
    );
    members.insert("ppt/notesSlides/notesSlide1.xml", &notes);
    members.insert("ppt/slides/slide3.xml", &third);
    let bytes = zip(&members.into_iter().collect::<Vec<_>>());
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let view = delete_inspect(&source, &sha);
    assert_eq!(view["slides"][0]["canDelete"], true, "{view}");
    assert_eq!(view["slides"][1]["canDelete"], false, "{view}");
    assert_eq!(view["slides"][2]["canDelete"], true, "{view}");
    let result = delete(&source, &sha, &output, 1);
    assert_eq!(result["error"]["code"], "unsupported_slide", "{result}");
    assert!(!output.exists());
    let result = delete(&source, &sha, &output, 2);
    assert_eq!(result["slideCount"], 2, "{result}");
    assert_eq!(
        stored_parts(&fs::read(output).unwrap())["ppt/notesSlides/notesSlide1.xml"],
        notes
    );
}

#[test]
fn delete_preserves_jump_owned_by_a_shared_slide_layout() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("deleted.pptx");
    let original = reorder_fixture(256);
    let mut members = stored_parts(&original);
    let action = action_shape("hlinkMouseOver", "ppaction://hlinkshowjump?jump=1");
    let layout = format!(
        "<p:sldLayout xmlns:p='{P}'><p:cSld><p:spTree>{action}</p:spTree></p:cSld></p:sldLayout>"
    );
    let relationships = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='layout' Type='{R}/slideLayout' Target='../slideLayouts/slideLayout1.xml'/></Relationships>"
    );
    members.insert("ppt/slideLayouts/slideLayout1.xml", &layout);
    members.insert("ppt/slides/_rels/slide2.xml.rels", &relationships);
    members.insert("ppt/slides/_rels/slide3.xml.rels", &relationships);
    let bytes = zip(&members.into_iter().collect::<Vec<_>>());
    fs::write(&source, &bytes).unwrap();
    let sha = hash(&bytes);
    let view = delete_inspect(&source, &sha);
    assert_eq!(view["slides"][0]["canDelete"], false, "{view}");
    assert_eq!(view["slides"][1]["canDelete"], true, "{view}");
    let result = delete(&source, &sha, &output, 1);
    assert_eq!(result["slideCount"], 2, "{result}");
    assert_eq!(
        stored_parts(&fs::read(output).unwrap())["ppt/slideLayouts/slideLayout1.xml"],
        layout
    );
}

fn text_box_fixture(protected: bool, signed: bool) -> Vec<u8> {
    let second = format!(
        "<p:sld xmlns:p='{P}' xmlns:a='{A}' show='0'><p:cSld><p:spTree>
         <p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
         <p:grpSp><p:nvGrpSpPr><p:cNvPr id='2' name='Group'/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
         <p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id='3' name='Nested'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
         <p:spPr/></p:sp></p:grpSp>
         <p:sp><p:nvSpPr><p:cNvPr id='7' name='Existing'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp>
         <p:extLst><p:ext uri='urn:test:keep'/></p:extLst>
         </p:spTree></p:cSld></p:sld>"
    );
    let original = fixture_with_second(&second, &[]);
    let mut parts = stored_parts(&original);
    let verifier = if protected {
        "<p:modifyVerifier cryptAlgorithmClass='hash'/>"
    } else {
        ""
    };
    let presentation = parts["ppt/presentation.xml"].replace(
        "</p:presentation>",
        &format!("<p:sldSz cx='12192000' cy='6858000'/>{verifier}</p:presentation>"),
    );
    parts.insert("ppt/presentation.xml", &presentation);
    let roots = parts["_rels/.rels"].replace(
        "</Relationships>",
        "<Relationship Id='signature' Type='http://schemas.openxmlformats.org/package/2006/relationships/digital-signature/origin' Target='custom/origin.sigs'/></Relationships>",
    );
    if signed {
        parts.insert("_rels/.rels", &roots);
        parts.insert("custom/origin.sigs", "<origin/>");
    }
    zip(&parts.into_iter().collect::<Vec<_>>())
}

fn inspect_text_box(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"pptx_text_box_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn shape_text_fixture(duplicate_id: bool) -> (Vec<u8>, String) {
    let other_id = if duplicate_id { 7 } else { 8 };
    let slide = format!(
        "<p:sld xmlns:p='{P}' xmlns:d='{A}' xmlns:r='{R}' show='0'><p:cSld><p:spTree>
         <p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
         <p:grpSp><p:nvGrpSpPr><p:cNvPr id='2' name='Group'/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
         <p:sp><p:nvSpPr><p:cNvPr id='7' name='기존 상자'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/>
         <p:txBody><d:bodyPr/><d:lstStyle/><d:p><d:pPr algn='l'/>
         <d:r><d:rPr b='1'/><d:t xml:space='preserve' kept='x > y'>  Start &amp; 😀  </d:t></d:r>
         <d:fld id='{{C8A26F68-3D58-4D1D-9517-88A58B58451D}}' type='slidenum'><d:t>2</d:t></d:fld>
         <d:r><d:rPr><d:hlinkClick r:id='link'/></d:rPr><d:t>링크</d:t></d:r><d:br/>
         <d:r><d:rPr i='1'/><d:t><![CDATA[<끝>]]></d:t></d:r></d:p>
         <d:p><d:r><d:t xml:space='preserve'/></d:r></d:p></p:txBody></p:sp></p:grpSp>
         <p:sp><p:nvSpPr><p:cNvPr id='{other_id}' name='Keep'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/>
         <p:txBody><d:bodyPr/><d:p><d:r><d:t>keep</d:t></d:r></d:p></p:txBody></p:sp>
         </p:spTree></p:cSld></p:sld>"
    );
    let link_rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='link' Type='{R}/hyperlink' Target='https://example.com/' TargetMode='External'/></Relationships>"
    );
    (
        fixture_with_second(&slide, &[("ppt/slides/_rels/slide2.xml.rels", &link_rels)]),
        slide,
    )
}

fn find_replace_shape(id: u32, shape_lock: &str, paragraphs: &str) -> String {
    format!(
        "<p:sp><p:nvSpPr><p:cNvPr id='{id}' name='Find'/><p:cNvSpPr>{shape_lock}</p:cNvSpPr><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><d:bodyPr/>{paragraphs}</p:txBody></p:sp>"
    )
}

fn find_replace_deck(shapes: &str) -> String {
    format!(
        "<p:sld xmlns:p='{P}' xmlns:d='{A}' xmlns:r='{R}' show='0'><p:cSld><p:spTree>{shapes}</p:spTree></p:cSld></p:sld>"
    )
}

fn find_replace_preview(source: &Path, sha: &str, find: &str) -> Value {
    request_json(
        &json!({"op":"pptx_find_replace_preview","sourcePath":source,"sourceSha256":sha,"find":find})
            .to_string(),
    )
}

fn find_replace_apply(
    source: &Path,
    sha: &str,
    output: &Path,
    find: &str,
    replacement: &str,
    expected: usize,
) -> Value {
    request_json(
        &json!({
            "op":"pptx_find_replace_apply","sourcePath":source,"sourceSha256":sha,
            "find":find,"replacement":replacement,"expectedMatchCount":expected,"outputPath":output,
        })
        .to_string(),
    )
}

#[test]
fn find_replace_spans_adjacent_runs_and_preserves_unmatched_bytes_and_boundaries() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.pptx");
    let output = directory.path().join("output.pptx");
    let find = "Ink+한😀";
    let first = find_replace_deck(&find_replace_shape(
        3,
        "",
        "<d:p><d:r><d:t>Ink+한😀 Ink+한😀 ink+한😀</d:t></d:r></d:p>",
    ));
    let ordinary = "<d:p><d:r><d:rPr b='1'/><d:t>&#x50;refix Ink+</d:t></d:r><d:r><d:rPr i='1'/><d:t><![CDATA[한😀]]> &#x53;uffix</d:t></d:r></d:p>";
    let barriers = "<d:p><d:r><d:t>Ink+</d:t></d:r><d:br/><d:r><d:t>한😀 Ink+</d:t></d:r><d:fld id='{C8A26F68-3D58-4D1D-9517-88A58B58451D}' type='slidenum'><d:t>Ink+한😀</d:t></d:fld><d:r><d:t>한😀 Ink+</d:t></d:r><d:r><d:rPr><d:hlinkClick r:id='link'/></d:rPr><d:t>Ink+한😀</d:t></d:r><d:r><d:t>한😀 Ink+</d:t></d:r></d:p><d:p><d:r><d:t>한😀</d:t></d:r></d:p>";
    let group = find_replace_shape(7, "", "<d:p><d:r><d:t>Ink+한😀</d:t></d:r></d:p>");
    let second = find_replace_deck(&format!(
        "{}{}{}<p:grpSp>{group}</p:grpSp>",
        find_replace_shape(4, "", &format!("{ordinary}{barriers}")),
        find_replace_shape(
            5,
            "<d:spLocks noTextEdit='true'/>",
            "<d:p><d:r><d:t>Ink+한😀</d:t></d:r></d:p>"
        ),
        find_replace_shape(6, "", "<d:p><d:r><d:t>한😀</d:t></d:r></d:p>"),
    ));
    let link_rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='link' Type='{R}/hyperlink' Target='https://example.com/' TargetMode='External'/></Relationships>"
    );
    let template =
        fixture_with_second(&second, &[("ppt/slides/_rels/slide2.xml.rels", &link_rels)]);
    let mut original = xml_parts(&template);
    original.insert("ppt/slides/slide1.xml", Cow::Borrowed(&first));
    let bytes = zip(&original
        .iter()
        .map(|(&part, xml)| (part, xml.as_ref()))
        .collect::<Vec<_>>());
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        find_replace_preview(&source, &sha, find),
        json!({"sourceSha256":sha,"slideCount":2,"matchCount":3,"matches":[
            {"slideIndex":0,"snippet":"Ink+한😀 Ink+한😀 ink+한😀","count":2},
            {"slideIndex":1,"snippet":"Prefix Ink+한😀 Suffix","count":1}
        ]}),
    );
    let reply = find_replace_apply(&source, &sha, &output, find, "<새 & 🧪>", 3);
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(
        reply,
        json!({"sourceSha256":sha,"outputSha256":hash(&written),"slideCount":2,"matchCount":3})
    );
    let reopened = find_replace_preview(&output, &hash(&written), "<새 & 🧪>");
    assert_eq!(reopened["matchCount"], 3, "{reopened}");
    original.insert(
        "ppt/slides/slide1.xml",
        Cow::Owned(first.replace(find, "&lt;새 &amp; 🧪&gt;")),
    );
    original.insert(
        "ppt/slides/slide2.xml",
        Cow::Owned(second.replace(ordinary, "<d:p><d:r><d:rPr b='1'/><d:t>&#x50;refix &lt;새 &amp; 🧪&gt;</d:t></d:r><d:r><d:rPr i='1'/><d:t><![CDATA[]]> &#x53;uffix</d:t></d:r></d:p>")),
    );
    assert_eq!(xml_parts(&written), original);
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn find_replace_reports_no_match_and_rejects_stale_or_unsafe_writes() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.pptx");
    let output = directory.path().join("output.pptx");
    let paragraph = |text: &str| format!("<d:p><d:r><d:t>{text}</d:t></d:r></d:p>");
    let slide = find_replace_deck(&find_replace_shape(
        2,
        "",
        &paragraph(&format!("{}aaa", "😀".repeat(200))),
    ));
    let bytes = fixture_with_second(&slide, &[]);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        find_replace_preview(&source, &sha, "missing"),
        json!({"sourceSha256":sha,"slideCount":2,"matchCount":0,"matches":[]})
    );
    let preview = find_replace_preview(&source, &sha, "aa");
    assert_eq!(preview["matchCount"], 1, "{preview}");
    let snippet = preview["matches"][0]["snippet"].as_str().unwrap();
    assert!(snippet.ends_with("aaa") && snippet.encode_utf16().count() <= 160);
    for (find, replacement, count, hash, code) in [
        ("aa", "new", 2, sha.clone(), "invalid_request"),
        ("aa", "aa", 1, sha.clone(), "invalid_request"),
        ("aa", "one\ntwo", 1, sha.clone(), "invalid_request"),
        ("aa", "new", 1, "0".repeat(64), "source_changed"),
    ] {
        let result = find_replace_apply(&source, &hash, &output, find, replacement, count);
        assert_eq!(result["error"]["code"], code, "{result}");
        assert!(!output.exists());
    }
    for find in [String::new(), "😀".repeat(1001), "line\nbreak".to_string()] {
        let result = find_replace_preview(&source, &sha, &find);
        assert_eq!(result["error"]["code"], "invalid_request", "{result}");
    }
    let result = find_replace_apply(&source, &sha, &output, "aa", "", 1);
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    assert_eq!(result["matchCount"], 1);
    assert_eq!(
        xml_parts(&written)["ppt/slides/slide2.xml"],
        slide.replace("aaa", "a")
    );
    assert_eq!(
        find_replace_apply(&source, &sha, &output, "aa", "new", 1)["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), written);
    assert_eq!(fs::read(&source).unwrap(), bytes);

    let capped = find_replace_deck(&find_replace_shape(2, "", &paragraph(&"a".repeat(201))));
    let capped_bytes = fixture_with_second(&capped, &[]);
    fs::write(&source, &capped_bytes).unwrap();
    let capped_sha = hash(&capped_bytes);
    let unused = directory.path().join("unused.pptx");
    assert_eq!(
        find_replace_preview(&source, &capped_sha, "a")["error"]["code"],
        "pptx_match_limit"
    );
    assert_eq!(
        find_replace_apply(&source, &capped_sha, &unused, "a", "b", 200)["error"]["code"],
        "pptx_match_limit"
    );
    assert!(!unused.exists());
    for protected in [text_box_fixture(true, false), text_box_fixture(false, true)] {
        fs::write(&source, &protected).unwrap();
        let sha = hash(&protected);
        assert!(
            find_replace_preview(&source, &sha, "a")
                .get("error")
                .is_some()
        );
        assert!(
            find_replace_apply(&source, &sha, &unused, "a", "b", 1)
                .get("error")
                .is_some()
        );
        assert!(!unused.exists());
    }
}

fn inspect_shape_text(source: &Path, sha: &str, index: Option<usize>) -> Value {
    let mut request = json!({
        "op":"pptx_shape_text_inspect","sourcePath":source,"sourceSha256":sha
    });
    if let Some(index) = index {
        request["slideIndex"] = json!(index);
    }
    request_json(&request.to_string())
}

fn replace_shape_text(
    source: &Path,
    sha: &str,
    output: &Path,
    shape_id: u32,
    changes: Value,
) -> Value {
    request_json(
        &json!({
            "op":"pptx_shape_text_replace","sourcePath":source,"sourceSha256":sha,
            "outputPath":output,"slideIndex":1,"shapeId":shape_id,"changes":changes
        })
        .to_string(),
    )
}

#[test]
fn shape_text_reopens_editing_only_selected_run_text_in_a_grouped_shape() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("existing-text.pptx");
    let (bytes, slide) = shape_text_fixture(false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let index = inspect_shape_text(&source, &sha, None);
    assert_eq!(index["slideCount"], 2, "{index}");
    assert_eq!(
        index["slides"][1],
        json!({"index":1,"hidden":true,"title":"Start & 😀"})
    );
    let plan = inspect_shape_text(&source, &sha, Some(1));
    assert_eq!(
        plan,
        json!({
            "sourceSha256":sha,"slideCount":2,"slideIndex":1,"shapes":[
                {"shapeId":7,"name":"기존 상자","runs":[
                    {"paragraphIndex":0,"runIndex":0,"text":"  Start & 😀  "},
                    {"paragraphIndex":0,"runIndex":2,"text":"<끝>"},
                    {"paragraphIndex":1,"runIndex":0,"text":""}
                ]},
                {"shapeId":8,"name":"Keep","runs":[{"paragraphIndex":0,"runIndex":0,"text":"keep"}]}
            ]
        })
    );
    let replaced = replace_shape_text(
        &source,
        &sha,
        &output,
        7,
        json!([
            {"paragraphIndex":1,"runIndex":0,"text":" 새 줄 "},
            {"paragraphIndex":0,"runIndex":0,"text":"  한글 & <끝> 😀  "},
            {"paragraphIndex":0,"runIndex":2,"text":""}
        ]),
    );
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{replaced}"));
    assert_eq!(
        replaced,
        json!({"sourceSha256":sha,"outputSha256":hash(&written),"slideCount":2,"slideIndex":1,"shapeId":7})
    );
    let actual = xml_parts(&written);
    let mut expected = xml_parts(&bytes);
    expected.insert(
        "ppt/slides/slide2.xml",
        Cow::Owned(
            slide
                .replace("  Start &amp; 😀  ", "  한글 &amp; &lt;끝&gt; 😀  ")
                .replace("<![CDATA[<끝>]]>", "")
                .replace(
                    "<d:t xml:space='preserve'/>",
                    "<d:t xml:space='preserve'> 새 줄 </d:t>",
                ),
        ),
    );
    assert_eq!(actual, expected);
    assert_eq!(fs::read(&source).unwrap(), bytes);
    let reopened = inspect_shape_text(&output, &hash(&written), Some(1));
    assert_eq!(
        reopened["shapes"][0]["runs"][0]["text"],
        "  한글 & <끝> 😀  "
    );
    assert_eq!(reopened["shapes"][0]["runs"][1]["text"], "");
    assert_eq!(reopened["shapes"][0]["runs"][2]["text"], " 새 줄 ");
}

#[test]
fn shape_text_rejects_protected_targets_and_stale_or_partial_writes() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("existing-text.pptx");
    let (bytes, _) = shape_text_fixture(false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let change = json!({"paragraphIndex":0,"runIndex":0,"text":"새 문구"});
    for (shape_id, edits) in [
        (7, json!([])),
        (7, json!([change, change])),
        (
            7,
            json!([change, {"paragraphIndex":0,"runIndex":1,"text":"보호됨"}]),
        ),
        (
            7,
            json!([{"paragraphIndex":0,"runIndex":0,"text":"two\nlines"}]),
        ),
        (
            7,
            json!([{"paragraphIndex":0,"runIndex":0,"text":"😀".repeat(1001)}]),
        ),
        (
            7,
            json!([{"paragraphIndex":0,"runIndex":0,"text":"  Start & 😀  "}]),
        ),
        (19, json!([change])),
    ] {
        assert!(replace_shape_text(&source, &sha, &output, shape_id, edits)["error"].is_object());
        assert!(!output.exists());
    }
    assert_eq!(
        replace_shape_text(&source, &"0".repeat(64), &output, 7, json!([change]))["error"]["code"],
        "source_changed"
    );
    fs::write(&output, b"keep").unwrap();
    assert_eq!(
        replace_shape_text(&source, &sha, &output, 7, json!([change]))["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), b"keep");
    let (duplicated, _) = shape_text_fixture(true);
    fs::write(&source, &duplicated).unwrap();
    assert!(inspect_shape_text(&source, &hash(&duplicated), Some(1))["error"].is_object());
}

fn shape_text_format_request(source: &Path, sha: &str, output: &Path) -> Value {
    json!({
        "op":"pptx_shape_text_format","sourcePath":source,"sourceSha256":sha,
        "outputPath":output,"slideIndex":1,"shapeId":7,"paragraphIndex":0,"runIndex":0,
        "start":8,"end":12,"styles":{"bold":false,"italic":true,"underline":true}
    })
}

#[test]
fn shape_paragraph_alignment_reopens_without_changing_runs_or_other_slides() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("aligned.pptx");
    let (_, slide) = shape_text_fixture(false);
    let slide = slide.replace("<d:pPr algn='l'/>", "<d:pPr marL='7' algn='l'><d:buNone/></d:pPr>");
    let bytes = fixture_with_second(&slide, &[]);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let mut request = json!({
        "op":"pptx_shape_paragraph_alignment","sourcePath":source,"sourceSha256":sha,"slideIndex":1
    });
    let inspected = request_json(&request.to_string());
    let paragraphs = &inspected["shapes"][0]["paragraphs"];
    assert_eq!(inspected["shapes"][0]["shapeId"], 7, "{inspected}");
    assert_eq!(paragraphs[0]["index"], 0);
    assert_eq!(paragraphs[0]["alignment"], "l");
    assert_eq!(paragraphs[1]["index"], 1);
    assert_eq!(paragraphs[1]["alignment"], Value::Null);

    request["outputPath"] = json!(output);
    request["shapeId"] = json!(7);
    request["paragraphIndex"] = json!(0);
    request["alignment"] = json!("just");
    let reply = request_json(&request.to_string());
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(reply["outputSha256"], hash(&written));
    assert_eq!(fs::read(&source).unwrap(), bytes);
    let mut expected = xml_parts(&bytes);
    expected.insert(
        "ppt/slides/slide2.xml",
        slide.replace("algn='l'", "algn='just'").into(),
    );
    assert_eq!(xml_parts(&written), expected);

    let inherited = directory.path().join("inherited.pptx");
    request["sourcePath"] = json!(output);
    request["sourceSha256"] = json!(hash(&written));
    request["outputPath"] = json!(inherited);
    request["alignment"] = Value::Null;
    let reply = request_json(&request.to_string());
    let restored = fs::read(inherited).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(
        xml_parts(&restored)["ppt/slides/slide2.xml"],
        slide.replace(" algn='l'", ""),
    );
}

#[test]
fn shape_paragraph_alignment_inserts_properties_and_rejects_stale_or_unchanged_requests() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("aligned.pptx");
    let (bytes, slide) = shape_text_fixture(false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let mut request = json!({
        "op":"pptx_shape_paragraph_alignment","sourcePath":source,"sourceSha256":sha,
        "outputPath":output,"slideIndex":1,"shapeId":7,"paragraphIndex":1,"alignment":null
    });
    assert!(request_json(&request.to_string())["error"].is_object());
    assert!(!output.exists());
    request["alignment"] = json!("ctr");
    request["sourceSha256"] = json!("0".repeat(64));
    assert_eq!(request_json(&request.to_string())["error"]["code"], "source_changed");
    assert!(!output.exists());
    request["sourceSha256"] = json!(sha);
    let reply = request_json(&request.to_string());
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(
        xml_parts(&written)["ppt/slides/slide2.xml"],
        slide.replace(
            "<d:p><d:r><d:t xml:space='preserve'/>",
            "<d:p><d:pPr algn=\"ctr\"/><d:r><d:t xml:space='preserve'/>",
        ),
    );
}

#[test]
fn shape_text_format_splits_selected_graphemes_and_preserves_the_rest_of_the_deck() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("formatted.pptx");
    let (bytes, slide) = shape_text_fixture(false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();

    let reply = request_json(&shape_text_format_request(&source, &sha, &output).to_string());
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(
        reply,
        json!({"sourceSha256":sha,"outputSha256":hash(&written),"slideCount":2,"slideIndex":1,"shapeId":7})
    );
    assert_eq!(fs::read(&source).unwrap(), bytes);

    let mut after = xml_parts(&written);
    let updated_slide = after.remove("ppt/slides/slide2.xml").unwrap();
    let mut before = xml_parts(&bytes);
    before.remove("ppt/slides/slide2.xml");
    assert_eq!(after, before);
    let first_run = slide.find("<d:r><d:rPr b='1'/>").unwrap();
    let next_field = slide.find("<d:fld").unwrap();
    assert!(updated_slide.starts_with(&slide[..first_run]));
    assert!(updated_slide.ends_with(&slide[next_field..]));

    let doc = roxmltree::Document::parse(&updated_slide).unwrap();
    let runs: Vec<_> = doc
        .descendants()
        .find(|node| node.has_tag_name((A, "p")))
        .unwrap()
        .children()
        .filter(|node| node.has_tag_name((A, "r")))
        .collect();
    assert_eq!(runs.len(), 5);
    for (node, (value, bold, italic, underline)) in runs.iter().take(3).zip([
        ("  Start ", Some("1"), None, None),
        ("& 😀", Some("0"), Some("1"), Some("sng")),
        ("  ", Some("1"), None, None),
    ]) {
        let properties = node.first_element_child().unwrap();
        assert_eq!(properties.attribute("b"), bold);
        assert_eq!(properties.attribute("i"), italic);
        assert_eq!(properties.attribute("u"), underline);
        let text = properties.next_sibling_element().unwrap();
        assert_eq!(text.text(), Some(value));
        assert_eq!(text.attribute("kept"), Some("x > y"));
        assert_eq!(
            text.attribute(("http://www.w3.org/XML/1998/namespace", "space")),
            Some("preserve")
        );
    }
    let reopened = inspect_shape_text(&output, &hash(&written), Some(1));
    let first = &reopened["shapes"][0]["runs"];
    assert_eq!(first[0]["text"], "  Start ");
    assert_eq!(first[1]["text"], "& 😀");
    assert_eq!(first[2]["text"], "  ");
    assert_eq!(
        first[3],
        json!({"paragraphIndex":0,"runIndex":4,"text":"<끝>"})
    );
}

#[test]
fn shape_text_format_can_remove_a_whole_run_style_without_reencoding_text() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("formatted.pptx");
    let (bytes, original_slide) = shape_text_fixture(false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();

    let mut request = shape_text_format_request(&source, &sha, &output);
    request["runIndex"] = json!(2);
    request["start"] = json!(0);
    request["end"] = json!(3);
    request["styles"] = json!({"italic":false,"underline":false});
    let reply = request_json(&request.to_string());
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    let part = &xml_parts(&written)["ppt/slides/slide2.xml"];
    assert_eq!(part.matches("<![CDATA[<끝>]]>").count(), 1);
    assert!(part.starts_with(&original_slide[..original_slide.find("<d:rPr i='1'").unwrap()]));
    let doc = roxmltree::Document::parse(part).unwrap();
    let formatted = doc
        .descendants()
        .find(|node| node.has_tag_name((A, "t")) && node.text() == Some("<끝>"))
        .unwrap();
    let properties = formatted.prev_sibling_element().unwrap();
    assert_eq!(properties.attribute("i"), Some("0"));
    assert_eq!(properties.attribute("u"), Some("none"));
    assert_eq!(properties.attribute("b"), None);
}

#[test]
fn shape_text_format_font_controls_replace_only_the_selected_fill_and_size() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("formatted.pptx");
    let (bytes, slide) = shape_text_fixture(false);
    let parts = xml_parts(&bytes);
    let relationship = "ppt/slides/_rels/slide2.xml.rels";
    let original_properties = concat!(
        "<d:rPr b='1' sz='1800'><d:ln w='9525'><d:solidFill>",
        "<d:srgbClr val='111111'/></d:solidFill></d:ln>",
        "<d:solidFill><d:schemeClr val='accent1'><d:tint val='50000'/>",
        "</d:schemeClr></d:solidFill><d:latin typeface='Calibri'/></d:rPr>",
    );
    let slide = slide.replacen("<d:rPr b='1'/>", original_properties, 1);
    let bytes = fixture_with_second(&slide, &[(relationship, &parts[relationship])]);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let mut request = shape_text_format_request(&source, &sha, &output);
    request["styles"] = json!({
        "bold": false, "italic": true, "underline": true,
        "fontSize": 2375, "fontColor": "a3Bc4D"
    });
    let reply = request_json(&request.to_string());
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(reply["outputSha256"], hash(&written));
    assert_eq!(fs::read(&source).unwrap(), bytes);
    let mut after = xml_parts(&written);
    let updated_slide = after.remove("ppt/slides/slide2.xml").unwrap();
    let mut before = xml_parts(&bytes);
    before.remove("ppt/slides/slide2.xml");
    assert_eq!(after, before);
    assert_eq!(updated_slide.matches(original_properties).count(), 2);
    assert!(updated_slide.ends_with(&slide[slide.find("<d:fld").unwrap()..]));

    let parsed = roxmltree::Document::parse(&updated_slide).unwrap();
    let text = parsed
        .descendants()
        .find(|node| node.has_tag_name((A, "t")) && node.text() == Some("& 😀"))
        .unwrap();
    let properties = text.prev_sibling_element().unwrap();
    for (name, value) in [("b", "0"), ("i", "1"), ("u", "sng"), ("sz", "2375")] {
        assert_eq!(properties.attribute(name), Some(value));
    }
    let children: Vec<_> = properties
        .children()
        .filter(roxmltree::Node::is_element)
        .collect();
    assert_eq!(
        children
            .iter()
            .map(|node| node.tag_name().name())
            .collect::<Vec<_>>(),
        ["ln", "solidFill", "latin"]
    );
    assert_eq!(children[0].attribute("w"), Some("9525"));
    assert!(
        children[0]
            .descendants()
            .any(|node| node.attribute("val") == Some("111111"))
    );
    let rgb = children[1].first_element_child().unwrap();
    assert!(rgb.has_tag_name((A, "srgbClr")));
    assert_eq!(rgb.attribute("val"), Some("A3BC4D"));
    assert_eq!(rgb.children().count(), 0);
    assert_eq!(children[2].attribute("typeface"), Some("Calibri"));
}

#[test]
fn shape_text_format_font_controls_insert_with_or_without_existing_properties() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let (bytes, slide) = shape_text_fixture(false);
    let parts = xml_parts(&bytes);
    let relationship = "ppt/slides/_rels/slide2.xml.rels";
    for (properties, expected_properties) in [
        (
            "",
            r#"<rPr sz="100"><solidFill><srgbClr val="0A0B0C"/></solidFill></rPr>"#,
        ),
        (
            "<rPr b='1' />",
            r#"<rPr b='1'  sz="100"><solidFill><srgbClr val="0A0B0C"/></solidFill></rPr>"#,
        ),
        (
            "<rPr><ln/><latin typeface='Keep'/></rPr>",
            r#"<rPr sz="100"><ln/><solidFill><srgbClr val="0A0B0C"/></solidFill><latin typeface='Keep'/></rPr>"#,
        ),
    ] {
        let slide = slide.replace(
            "<d:r><d:t>keep</d:t></d:r>",
            &format!("<r xmlns='{A}'>{properties}<t>keep</t></r>"),
        );
        let bytes = fixture_with_second(&slide, &[(relationship, &parts[relationship])]);
        let sha = hash(&bytes);
        fs::write(&source, &bytes).unwrap();
        let output = directory
            .path()
            .join(format!("formatted-{}.pptx", properties.len()));
        let mut request = shape_text_format_request(&source, &sha, &output);
        request["shapeId"] = json!(8);
        request["start"] = json!(0);
        request["end"] = json!(4);
        request["styles"] = json!({"fontSize": 100, "fontColor": "0a0b0c"});
        let reply = request_json(&request.to_string());
        let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
        let part = &xml_parts(&written)["ppt/slides/slide2.xml"];
        assert!(part.contains(expected_properties), "{part}");

        let no_op = directory.path().join("no-op.pptx");
        request["sourcePath"] = json!(output);
        request["sourceSha256"] = json!(hash(&written));
        request["outputPath"] = json!(no_op);
        assert!(request_json(&request.to_string())["error"].is_object());
        assert!(!no_op.exists());
    }
}

#[test]
fn shape_text_format_font_controls_reject_fill_hidden_in_compatibility_markup() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("formatted.pptx");
    let (bytes, slide) = shape_text_fixture(false);
    let parts = xml_parts(&bytes);
    let relationship = "ppt/slides/_rels/slide2.xml.rels";
    let markup = concat!(
        "<mc:AlternateContent xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006'>",
        "<mc:Choice Requires='d'><d:solidFill><d:srgbClr val='AABBCC'/></d:solidFill></mc:Choice>",
        "<mc:Fallback><d:solidFill><d:srgbClr val='DDEEFF'/></d:solidFill></mc:Fallback>",
        "</mc:AlternateContent>",
    );
    let properties = format!("<d:rPr b='1'>{markup}</d:rPr>");
    let slide = slide.replacen("<d:rPr b='1'/>", &properties, 1);
    let bytes = fixture_with_second(&slide, &[(relationship, &parts[relationship])]);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let mut request = shape_text_format_request(&source, &sha, &output);
    request["start"] = json!(0);
    request["end"] = json!(14);
    request["styles"] = json!({"fontSize": 2400, "fontColor": "012345"});
    let reply = request_json(&request.to_string());
    assert!(reply["error"].is_object(), "{reply}");
    assert!(!output.exists());
    assert_eq!(fs::read(&source).unwrap(), bytes);

    request["styles"] = json!({"fontSize": 2400, "bold": false});
    let reply = request_json(&request.to_string());
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    let updated = &xml_parts(&written)["ppt/slides/slide2.xml"];
    assert_eq!(updated.matches(markup).count(), 1);
    assert!(updated.contains(&format!("<d:rPr b='0' sz=\"2400\">{markup}</d:rPr>")));
}

#[test]
fn shape_text_format_rejects_grapheme_splits_noops_and_protected_targets() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("formatted.pptx");
    let (bytes, _) = shape_text_fixture(false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    for (key, invalid) in [
        ("start", json!(11)), // Low surrogate inside the selected emoji.
        ("end", json!(11)),
        ("end", json!(8)),
        ("end", json!(15)),
        ("runIndex", json!(1)), // Hyperlinked run.
        ("styles", json!({"bold":true})),
        ("styles", json!({"bold":1})),
        ("styles", json!({"color":true})),
        ("styles", json!({"fontSize":99})),
        ("styles", json!({"fontSize":400001})),
        ("styles", json!({"fontSize":2000.5})),
        ("styles", json!({"fontSize":"2000"})),
        ("styles", json!({"fontColor":"#CAFE22"})),
        ("styles", json!({"fontColor":"CAFE2Z"})),
        ("styles", json!({"fontColor":"０ABC"})),
        ("styles", json!({"fontColor":123456})),
        ("styles", json!({})),
        ("shapeId", json!(37)),
    ] {
        let mut request = shape_text_format_request(&source, &sha, &output);
        request[key] = invalid;
        assert!(
            request_json(&request.to_string())["error"].is_object(),
            "{request}"
        );
        assert!(!output.exists(), "{request}");
    }
    assert_eq!(
        request_json(&shape_text_format_request(&source, &"0".repeat(64), &output).to_string())["error"]
            ["code"],
        "source_changed"
    );
    fs::write(&output, b"keep").unwrap();
    assert_eq!(
        request_json(&shape_text_format_request(&source, &sha, &output).to_string())["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), b"keep");
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn shape_text_format_uses_the_run_namespace_when_inserting_missing_properties() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("formatted.pptx");
    let (bytes, slide) = shape_text_fixture(false);
    let parts = xml_parts(&bytes);
    let relationship = "ppt/slides/_rels/slide2.xml.rels";
    let slide = slide.replace(
        "<d:r><d:t>keep</d:t></d:r>",
        &format!("<r xmlns='{A}'><t>keep</t></r>"),
    );
    let bytes = fixture_with_second(&slide, &[(relationship, &parts[relationship])]);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let mut request = shape_text_format_request(&source, &sha, &output);
    request["shapeId"] = json!(8);
    request["start"] = json!(1);
    request["end"] = json!(3);
    request["styles"] = json!({"italic":true});
    let reply = request_json(&request.to_string());
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    let part = &xml_parts(&written)["ppt/slides/slide2.xml"];
    let doc = roxmltree::Document::parse(part).unwrap();
    let props = doc
        .descendants()
        .find(|node| {
            node.has_tag_name((A, "rPr"))
                && node.attribute("i") == Some("1")
                && node
                    .next_sibling_element()
                    .is_some_and(|sibling| sibling.text() == Some("ee"))
        })
        .unwrap();
    assert_eq!(props.range().len(), "<rPr i=\"1\"/>".len());
    let reopened = inspect_shape_text(&output, &hash(&written), Some(1));
    assert_eq!(
        reopened["shapes"][1]["runs"],
        json!([
            {"paragraphIndex":0,"runIndex":0,"text":"k"},
            {"paragraphIndex":0,"runIndex":1,"text":"ee"},
            {"paragraphIndex":0,"runIndex":2,"text":"p"}
        ])
    );
}

#[test]
fn shape_text_format_preserves_identity_on_whole_runs_and_rejects_unsafe_splits() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("formatted.pptx");
    let (bytes, slide) = shape_text_fixture(false);
    let parts = xml_parts(&bytes);
    let relationship = "ppt/slides/_rels/slide2.xml.rels";
    let slide = slide.replace("kept='x > y'", "xml:id='once'");
    let bytes = fixture_with_second(&slide, &[(relationship, &parts[relationship])]);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let mut request = shape_text_format_request(&source, &sha, &output);
    assert!(request_json(&request.to_string())["error"].is_object());
    assert!(!output.exists());

    request["start"] = json!(0);
    request["end"] = json!(14);
    let reply = request_json(&request.to_string());
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    let part = &xml_parts(&written)["ppt/slides/slide2.xml"];
    assert_eq!(part.matches("xml:id='once'").count(), 1);
    assert!(part.contains("  Start &amp; 😀  "));
}

fn add_text_box(
    source: &Path,
    sha: &str,
    output: &Path,
    text: &str,
    placement: &str,
    font_size: u32,
) -> Value {
    request_json(
        &json!({
            "op":"pptx_text_box_add","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "slideIndex":1,"text":text,"placement":placement,"fontSize":font_size
        })
        .to_string(),
    )
}

#[test]
fn text_box_reopens_unicode_preserving_other_members_and_nested_ids() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("with-text.pptx");
    let bytes = text_box_fixture(false, false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let plan = inspect_text_box(&source, &sha);
    assert_eq!(plan["sourceSha256"], sha, "{plan}");
    assert_eq!(plan["slideCount"], 2, "{plan}");
    assert_eq!(
        plan["slides"][1],
        json!({"index":1,"hidden":true,"canAdd":true}),
        "{plan}"
    );

    let content = "  첫 줄 & <문장> 😀  \n\n다음 줄";
    let added = add_text_box(&source, &sha, &output, content, "middle", 24);
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{added}"));
    assert_eq!(
        added,
        json!({
            "sourceSha256":sha,"outputSha256":hash(&written),"slideCount":2,"slideIndex":1,"shapeId":4
        })
    );
    let old_parts = xml_parts(&bytes);
    let new_parts = xml_parts(&written);
    assert_eq!(old_parts.len(), new_parts.len());
    for (name, value) in old_parts
        .iter()
        .filter(|(name, _)| **name != "ppt/slides/slide2.xml")
    {
        assert_eq!(new_parts[name], *value, "{name}");
    }
    let new_slide = &new_parts["ppt/slides/slide2.xml"];
    let doc = roxmltree::Document::parse(new_slide).unwrap();
    assert_eq!(doc.root_element().attribute("show"), Some("0"));
    let tree = doc
        .descendants()
        .find(|node| node.has_tag_name((P, "spTree")))
        .unwrap();
    let extension = tree.last_element_child().unwrap();
    assert!(extension.has_tag_name((P, "extLst")));
    let shape = extension.prev_sibling_element().unwrap();
    assert!(shape.has_tag_name((P, "sp")));
    assert_eq!(
        shape
            .descendants()
            .find(|node| node.has_tag_name((P, "cNvPr")))
            .unwrap()
            .attribute("id"),
        Some("4")
    );
    assert_eq!(
        shape
            .descendants()
            .find(|node| node.has_tag_name((P, "cNvSpPr")))
            .unwrap()
            .attribute("txBox"),
        Some("1")
    );
    let paragraphs = shape
        .descendants()
        .filter(|node| node.has_tag_name((A, "p")))
        .map(|paragraph| {
            paragraph
                .descendants()
                .filter(|node| node.has_tag_name((A, "t")))
                .filter_map(|node| node.text())
                .collect::<String>()
        })
        .collect::<Vec<_>>();
    assert_eq!(paragraphs.join("\n"), content);
    let range = shape.range();
    assert_eq!(
        format!("{}{}", &new_slide[..range.start], &new_slide[range.end..]),
        old_parts["ppt/slides/slide2.xml"]
    );
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn text_box_validates_bounds_inputs_and_does_not_overwrite() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("box.pptx");
    let bytes = text_box_fixture(false, false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let too_many_units = "😀".repeat(301);
    for (value, placement, font_size) in [
        (" \n ", "top", 24),
        (&too_many_units, "top", 24),
        ("a\nb\nc\nd\ne\nf\ng\nh\ni", "top", 24),
        ("a\tb", "top", 24),
        ("a\r\nb", "top", 24),
        ("a\u{fffe}b", "top", 24),
        ("a\u{2028}b", "top", 24),
        ("a", "off-slide", 24),
        ("a", "bottom", 11),
        ("a", "bottom", 41),
    ] {
        let rejected = add_text_box(&source, &sha, &output, value, placement, font_size);
        assert_eq!(rejected["error"]["code"], "invalid_request", "{rejected}");
        assert!(!output.exists());
    }
    assert_eq!(
        add_text_box(&source, &"0".repeat(64), &output, "Valid", "top", 12)["error"]["code"],
        "source_changed"
    );
    assert!(!output.exists());
    let maximum = format!("{}\nb\nc\nd\ne\nf\ng\nh", "😀".repeat(293));
    assert_eq!(maximum.encode_utf16().count(), 600);
    let accepted = add_text_box(&source, &sha, &output, &maximum, "bottom", 40);
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{accepted}"));
    assert_eq!(accepted["outputSha256"], hash(&written));
    let parts = xml_parts(&written);
    let doc = roxmltree::Document::parse(&parts["ppt/slides/slide2.xml"]).unwrap();
    let position = doc
        .descendants()
        .find(|node| node.has_tag_name((A, "off")))
        .unwrap();
    let size = doc
        .descendants()
        .find(|node| node.has_tag_name((A, "ext")))
        .unwrap();
    let coord = |node: roxmltree::Node, key| node.attribute(key).unwrap().parse::<u64>().unwrap();
    assert!(coord(position, "x") + coord(size, "cx") <= 12_192_000);
    assert!(coord(position, "y") + coord(size, "cy") <= 6_858_000);
    assert_eq!(
        add_text_box(&source, &sha, &output, "New", "top", 24)["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), written);
}

#[test]
fn text_box_refuses_protected_and_signed_presentations() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("rejected.pptx");
    for (protected, signed) in [(true, false), (false, true)] {
        let bytes = text_box_fixture(protected, signed);
        let sha = hash(&bytes);
        fs::write(&source, &bytes).unwrap();
        let plan = inspect_text_box(&source, &sha);
        assert_eq!(plan["error"]["code"], "invalid_pptx", "{plan}");
        let rejected = add_text_box(&source, &sha, &output, "Keep", "top", 24);
        assert_eq!(rejected["error"]["code"], "invalid_pptx", "{rejected}");
        assert!(!output.exists());
    }
}

fn preset_shape_request(source: &Path, sha: &str, output: &Path) -> Value {
    json!({
        "op":"pptx_preset_shape_add","sourcePath":source,"sourceSha256":sha,"outputPath":output,
        "slideIndex":1,"preset":"rectangle","text":"  요약 & <그림> 😀  \n\n두 번째 줄",
        "placement":"middle","fontSize":18,"fillColor":"123456","lineColor":"AABBCC"
    })
}

#[test]
fn preset_shapes_reopen_as_editable_geometry_and_preserve_other_bytes() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let bytes = text_box_fixture(false, false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let plan = request_json(
        &json!({"op":"pptx_preset_shape_inspect","sourcePath":source,"sourceSha256":sha})
            .to_string(),
    );
    assert_eq!(plan["sourceSha256"], sha, "{plan}");
    assert_eq!(plan["slideCount"], 2, "{plan}");
    assert_eq!(
        plan["slides"][1],
        json!({"index":1,"hidden":true,"canAdd":true}),
        "{plan}"
    );

    let old = xml_parts(&bytes);
    let slide_part = "ppt/slides/slide2.xml";
    for (preset, geometry, fill, position, label) in [
        (
            "rectangle",
            "rect",
            Some("123456"),
            "top",
            "  요약 & <그림> 😀  \n\n두 번째 줄",
        ),
        (
            "roundedRectangle",
            "roundRect",
            Some("FFFFFF"),
            "middle",
            "둥근 모서리",
        ),
        ("ellipse", "ellipse", None, "bottom", ""),
        ("rightArrow", "rightArrow", Some("FFCC00"), "middle", "다음"),
    ] {
        let output = directory.path().join(format!("{preset}.pptx"));
        let mut request = preset_shape_request(&source, &sha, &output);
        request["preset"] = json!(preset);
        request["fillColor"] = json!(fill);
        request["placement"] = json!(position);
        request["text"] = json!(label);
        let reply = request_json(&request.to_string());
        let written = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
        assert_eq!(
            reply,
            json!({"sourceSha256":sha,"outputSha256":hash(&written),"slideCount":2,
                   "slideIndex":1,"shapeId":4})
        );
        let fresh = xml_parts(&written);
        assert_eq!(old.len(), fresh.len());
        for (name, value) in old.iter().filter(|(name, _)| **name != slide_part) {
            assert_eq!(fresh[name], *value, "{name}");
        }
        let slide = &fresh[slide_part];
        let doc = roxmltree::Document::parse(slide).unwrap();
        let tree = doc
            .descendants()
            .find(|n| n.has_tag_name((P, "spTree")))
            .unwrap();
        let extension = tree.last_element_child().unwrap();
        assert!(extension.has_tag_name((P, "extLst")));
        let shape = extension.prev_sibling_element().unwrap();
        assert!(shape.has_tag_name((P, "sp")));
        let range = shape.range();
        assert_eq!(
            format!("{}{}", &slide[..range.start], &slide[range.end..]),
            old[slide_part]
        );
        let descendant = |namespace, name| {
            shape
                .descendants()
                .find(|n| n.has_tag_name((namespace, name)))
                .unwrap()
        };
        assert_eq!(descendant(P, "cNvPr").attribute("id"), Some("4"));
        assert_eq!(descendant(P, "cNvSpPr").attribute("txBox"), None);
        assert_eq!(descendant(A, "prstGeom").attribute("prst"), Some(geometry));
        let style = descendant(P, "spPr");
        let direct_fill = style.children().find(|n| n.has_tag_name((A, "solidFill")));
        let rgb = |node: roxmltree::Node<'_, '_>| {
            node.descendants()
                .find(|n| n.has_tag_name((A, "srgbClr")))
                .and_then(|n| n.attribute("val"))
                .map(str::to_owned)
        };
        assert_eq!(direct_fill.and_then(rgb).as_deref(), fill);
        if fill.is_none() {
            assert!(style.children().any(|n| n.has_tag_name((A, "noFill"))));
        }
        assert_eq!(rgb(descendant(A, "ln")).as_deref(), Some("AABBCC"));
        let off = descendant(A, "off");
        let ext = descendant(A, "ext");
        let number = |n: roxmltree::Node, key| n.attribute(key).unwrap().parse::<u64>().unwrap();
        let (x, y, width, height) = (
            number(off, "x"),
            number(off, "y"),
            number(ext, "cx"),
            number(ext, "cy"),
        );
        assert!(width > 0 && height > 0 && x + width <= 12_192_000 && y + height <= 6_858_000);
        let midpoint = y + height / 2;
        match position {
            "top" => assert!(midpoint < 6_858_000 / 2),
            "bottom" => assert!(midpoint > 6_858_000 / 2),
            _ => assert!(midpoint.abs_diff(6_858_000 / 2) <= 1),
        }
        let lines = shape
            .descendants()
            .filter(|n| n.has_tag_name((A, "p")))
            .map(|p| {
                p.descendants()
                    .find(|n| n.has_tag_name((A, "t")))
                    .and_then(|n| n.text())
                    .unwrap_or_default()
            })
            .collect::<Vec<_>>();
        assert_eq!(lines.join("\n"), label);
        if !label.is_empty() {
            let text_rgb = rgb(descendant(A, "rPr")).unwrap();
            let contrast = if fill == Some("123456") {
                "FFFFFF"
            } else {
                "000000"
            };
            assert_eq!(text_rgb, contrast);
            let reopened = request_json(&json!({
                "op":"pptx_shape_text_inspect","sourcePath":output,"sourceSha256":hash(&written),
                "slideIndex":1
            }).to_string());
            assert!(
                reopened["shapes"]
                    .as_array()
                    .is_some_and(|shapes| shapes.iter().any(|candidate| candidate["shapeId"] == 4)),
                "{reopened}"
            );
        }
    }
    assert_eq!(fs::read(source).unwrap(), bytes);
}

#[test]
fn preset_shapes_reject_bad_inputs_protected_source_and_existing_output() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("inserted.pptx");
    let bytes = text_box_fixture(false, false);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    for (key, value) in [
        ("preset", json!("unknown")),
        ("placement", json!("off-slide")),
        ("fillColor", json!("#123456")),
        ("fillColor", json!("aabbcc")),
        ("lineColor", Value::Null),
        ("fontSize", json!(41)),
        ("text", json!("control\u{2028}character")),
        ("slideIndex", json!(256)),
    ] {
        let mut request = preset_shape_request(&source, &sha, &output);
        request[key] = value;
        let reply = request_json(&request.to_string());
        assert_eq!(reply["error"]["code"], "invalid_request", "{reply}");
        assert!(!output.exists());
    }
    let request = preset_shape_request(&source, &"0".repeat(64), &output);
    let reply = request_json(&request.to_string());
    assert_eq!(reply["error"]["code"], "source_changed", "{reply}");
    assert!(!output.exists());
    for (protected, signed) in [(true, false), (false, true)] {
        let bytes = text_box_fixture(protected, signed);
        fs::write(&source, &bytes).unwrap();
        let reply =
            request_json(&preset_shape_request(&source, &hash(&bytes), &output).to_string());
        assert_eq!(reply["error"]["code"], "invalid_pptx", "{reply}");
        assert!(!output.exists());
    }
    fs::write(&source, &bytes).unwrap();
    fs::write(&output, b"keep existing output").unwrap();
    let reply = request_json(&preset_shape_request(&source, &sha, &output).to_string());
    assert_eq!(reply["error"]["code"], "output_exists", "{reply}");
    assert_eq!(fs::read(output).unwrap(), b"keep existing output");
}

#[test]
fn preset_shapes_do_not_reuse_shape_ids_already_referenced_in_slide_xml() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("inserted.pptx");
    let fixture = text_box_fixture(false, false);
    let mut parts = stored_parts(&fixture);
    let slide = parts["ppt/slides/slide2.xml"].replace(
        "<p:extLst>",
        "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id='9' name='Existing connector'/><p:cNvCxnSpPr><a:stCxn id='5' idx='0'/><a:endCxn id='6' idx='0'/></p:cNvCxnSpPr><p:nvPr/></p:nvCxnSpPr><p:spPr/></p:cxnSp><p:extLst>",
    ).replace(
        "</p:sld>",
        "<p:timing><p:tnLst><p:par><p:cTn id='1'><p:childTnLst><p:set><p:cBhvr><p:cTn id='2'/><p:tgtEl><p:spTgt spid='4'/></p:tgtEl></p:cBhvr></p:set></p:childTnLst></p:cTn></p:par></p:tnLst></p:timing></p:sld>",
    );
    parts.insert("ppt/slides/slide2.xml", &slide);
    let bytes = zip(&parts.into_iter().collect::<Vec<_>>());
    fs::write(&source, &bytes).unwrap();
    let reply = request_json(&preset_shape_request(&source, &hash(&bytes), &output).to_string());
    assert_eq!(reply["shapeId"], 8, "{reply}");
}

fn table_add_request(source: &Path, sha: &str, output: &Path) -> Value {
    json!({
        "op":"pptx_table_add","sourcePath":source,"sourceSha256":sha,"outputPath":output,
        "slideIndex":1,"rows":3,"columns":4,
    })
}

#[test]
fn table_add_reopens_editable_grid_and_preserves_prior_parts_on_repeat() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let first = directory.path().join("first.pptx");
    let second = directory.path().join("second.pptx");
    let fixture = text_box_fixture(false, false);
    let slide_part = "ppt/slides/slide2.xml";
    let mut parts = stored_parts(&fixture);
    let slide = parts[slide_part].replace(
        "<p:extLst>",
        "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id='9' name='Connector'/><p:cNvCxnSpPr><a:stCxn id='4' idx='0'/></p:cNvCxnSpPr><p:nvPr/></p:nvCxnSpPr><p:spPr/></p:cxnSp><p:extLst>",
    );
    parts.insert(slide_part, &slide);
    let original = zip(&parts.into_iter().collect::<Vec<_>>());
    let source_sha = hash(&original);
    fs::write(&source, &original).unwrap();
    let plan = request_json(
        &json!({"op":"pptx_table_add_inspect","sourcePath":source,"sourceSha256":source_sha})
            .to_string(),
    );
    assert_eq!(plan["sourceSha256"], source_sha);
    assert_eq!(plan["slideCount"], 2);
    assert_eq!(plan["slides"][0]["canAdd"], false, "{plan}");
    assert_eq!(
        plan["slides"][1],
        json!({"index":1,"hidden":true,"canAdd":true})
    );

    for (input, output, rows, columns, expected_id) in
        [(&source, &first, 3, 4, 5), (&first, &second, 10, 10, 6)]
    {
        let input_bytes = fs::read(input).unwrap();
        let sha = hash(&input_bytes);
        let mut request = table_add_request(input, &sha, output);
        request["rows"] = json!(rows);
        request["columns"] = json!(columns);
        let reply = request_json(&request.to_string());
        let result = fs::read(output).unwrap_or_else(|_| panic!("{reply}"));
        assert_eq!(
            reply,
            json!({"sourceSha256":sha,"outputSha256":hash(&result),"slideCount":2,
                   "slideIndex":1,"shapeId":expected_id,"rows":rows,"columns":columns})
        );
        let before = xml_parts(&input_bytes);
        let after = xml_parts(&result);
        assert_eq!(before.len(), after.len());
        for (name, content) in before.iter().filter(|(name, _)| **name != slide_part) {
            assert_eq!(after[name], *content, "{name}");
        }
        let slide = &after[slide_part];
        let doc = roxmltree::Document::parse(slide).unwrap();
        let tree = doc
            .descendants()
            .find(|n| n.has_tag_name((P, "spTree")))
            .unwrap();
        let extensions = tree.last_element_child().unwrap();
        assert!(extensions.has_tag_name((P, "extLst")));
        let frame = extensions.prev_sibling_element().unwrap();
        assert!(frame.has_tag_name((P, "graphicFrame")));
        let range = frame.range();
        assert_eq!(
            format!("{}{}", &slide[..range.start], &slide[range.end..]),
            before[slide_part]
        );

        let descendant = |namespace, name| {
            frame
                .descendants()
                .find(|n| n.has_tag_name((namespace, name)))
                .unwrap()
        };
        let number =
            |node: roxmltree::Node, key| node.attribute(key).unwrap().parse::<u64>().unwrap();
        assert_eq!(number(descendant(P, "cNvPr"), "id"), expected_id);
        let data = descendant(A, "graphicData");
        assert_eq!(
            data.attribute("uri"),
            Some("http://schemas.openxmlformats.org/drawingml/2006/table")
        );
        let grid: Vec<_> = descendant(A, "tblGrid")
            .children()
            .filter(|node| node.has_tag_name((A, "gridCol")))
            .map(|node| number(node, "w"))
            .collect();
        assert_eq!(grid.len(), columns);
        let width = grid.iter().sum::<u64>();
        let mut height = 0;
        let actual_rows: Vec<_> = descendant(A, "tbl")
            .children()
            .filter(|node| node.has_tag_name((A, "tr")))
            .collect();
        assert_eq!(actual_rows.len(), rows);
        for row in actual_rows {
            height += number(row, "h");
            let cells: Vec<_> = row
                .children()
                .filter(|node| node.has_tag_name((A, "tc")))
                .collect();
            assert_eq!(cells.len(), columns);
            for cell in cells {
                assert_eq!(cell.attributes().len(), 0);
                assert!(cell.children().any(|node| node.has_tag_name((A, "txBody"))));
            }
        }
        assert_eq!(number(descendant(A, "ext"), "cx"), width);
        assert_eq!(number(descendant(A, "ext"), "cy"), height);
        assert!(width > 0 && height > 0);
        assert!(number(descendant(A, "off"), "x") + width <= 12_192_000);
        assert!(number(descendant(A, "off"), "y") + height <= 6_858_000);
        assert_eq!(fs::read(input).unwrap(), input_bytes);
    }
    assert_eq!(fs::read(source).unwrap(), original);
}

#[test]
fn table_add_rejects_bad_dimensions_stale_hash_unusable_slide_and_existing_output() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("input.pptx");
    let output = directory.path().join("table.pptx");
    let original = text_box_fixture(false, false);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    for (key, value, error) in [
        ("rows", json!(0), "invalid_request"),
        ("rows", json!(11), "invalid_request"),
        ("columns", json!(-1), "invalid_request"),
        ("columns", json!(2.5), "invalid_request"),
        ("columns", json!("2"), "invalid_request"),
        ("slideIndex", json!(0), "invalid_pptx"),
        ("slideIndex", json!(2), "invalid_request"),
        ("sourceSha256", json!("0".repeat(64)), "source_changed"),
    ] {
        let mut request = table_add_request(&source, &sha, &output);
        request[key] = value;
        let reply = request_json(&request.to_string());
        assert_eq!(reply["error"]["code"], error, "{reply}");
        assert!(!output.exists());
    }
    let mut request = table_add_request(&source, &sha, &output);
    request["unexpected"] = json!(true);
    let reply = request_json(&request.to_string());
    assert_eq!(reply["error"]["code"], "invalid_request", "{reply}");
    assert!(!output.exists());
    fs::write(&output, b"occupied").unwrap();
    let reply = request_json(&table_add_request(&source, &sha, &output).to_string());
    assert_eq!(reply["error"]["code"], "output_exists", "{reply}");
    assert_eq!(fs::read(output).unwrap(), b"occupied");
    assert_eq!(fs::read(source).unwrap(), original);
}

fn cell_text_fixture(directory: &Path) -> (PathBuf, u64) {
    let source = directory.join("before-table.pptx");
    let table = directory.join("with-table.pptx");
    let input = text_box_fixture(false, false);
    fs::write(&source, &input).unwrap();
    let reply = request_json(&table_add_request(&source, &hash(&input), &table).to_string());
    let id = reply["shapeId"]
        .as_u64()
        .unwrap_or_else(|| panic!("{reply}"));
    (table, id)
}

fn inspect_cell_text(source: &Path, sha: &str, slide: Option<usize>) -> Value {
    let mut request = json!({
        "op":"pptx_table_cell_text_inspect","sourcePath":source,"sourceSha256":sha,
    });
    if let Some(slide) = slide {
        request["slideIndex"] = json!(slide);
    }
    request_json(&request.to_string())
}

fn cell_text_request(source: &Path, sha: &str, output: &Path, id: u64) -> Value {
    json!({
        "op":"pptx_table_cell_text_replace","sourcePath":source,"sourceSha256":sha,
        "outputPath":output,"slideIndex":1,"shapeId":id,"row":1,"column":2,
        "changes":[{"paragraphIndex":0,"runIndex":0,"text":"한글 🧪 & <글자>"}],
    })
}

#[test]
fn table_cell_text_writes_only_the_selected_a132_cell() {
    let directory = tempfile::tempdir().unwrap();
    let (source, id) = cell_text_fixture(directory.path());
    let output = directory.path().join("edited.pptx");
    let original = fs::read(&source).unwrap();
    let sha = hash(&original);
    let slides = inspect_cell_text(&source, &sha, None);
    assert_eq!(slides["sourceSha256"], sha, "{slides}");
    assert_eq!(slides["slideCount"], 2);
    assert_eq!(slides["slides"][1], json!({"index":1,"hidden":true}));
    let catalog = inspect_cell_text(&source, &sha, Some(1));
    let table = &catalog["tables"][0];
    assert_eq!(table["shapeId"], id, "{catalog}");
    assert_eq!(table["name"], format!("Table {id}"));
    assert_eq!(table["rows"], 3);
    assert_eq!(table["columns"], 4);
    assert_eq!(table["cells"].as_array().unwrap().len(), 12);
    assert_eq!(
        table["cells"][6],
        json!({"row":1,"column":2,"runs":[
            {"paragraphIndex":0,"runIndex":0,"text":""}
        ]})
    );

    let reply = request_json(&cell_text_request(&source, &sha, &output, id).to_string());
    let changed = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(
        reply,
        json!({"sourceSha256":sha,"outputSha256":hash(&changed),
        "slideCount":2,"slideIndex":1,"shapeId":id,"row":1,"column":2})
    );
    assert_eq!(fs::read(&source).unwrap(), original);
    let part = "ppt/slides/slide2.xml";
    let before = xml_parts(&original);
    let after = xml_parts(&changed);
    let empty = "<a:t xml:space=\"preserve\"/>";
    let (at, _) = before[part].match_indices(empty).nth(6).unwrap();
    let expected = format!(
        "{}<a:t xml:space=\"preserve\">한글 🧪 &amp; &lt;글자&gt;</a:t>{}",
        &before[part][..at],
        &before[part][at + empty.len()..]
    );
    assert_eq!(after[part], expected);
    assert_eq!(after.len(), before.len());
    for (name, content) in before.iter().filter(|(name, _)| **name != part) {
        assert_eq!(after[name], *content, "{name}");
    }
    let reopened = inspect_cell_text(&output, &hash(&changed), Some(1));
    let mut expected_cells = table["cells"].clone();
    expected_cells[6]["runs"][0]["text"] = json!("한글 🧪 & <글자>");
    assert_eq!(reopened["tables"][0]["cells"], expected_cells);
}

#[test]
fn table_cell_text_preserves_runs_and_validates_merged_and_blank_cells() {
    let directory = tempfile::tempdir().unwrap();
    let (authored, id) = cell_text_fixture(directory.path());
    let source = directory.path().join("external.pptx");
    let output = directory.path().join("edited.pptx");
    let original = fs::read(authored).unwrap();
    let part = "ppt/slides/slide2.xml";
    let mut parts = xml_parts(&original);
    let xml = &parts[part];
    let doc = roxmltree::Document::parse(xml).unwrap();
    let cells: Vec<_> = doc
        .descendants()
        .filter(|n| n.has_tag_name((A, "tc")))
        .collect();
    let mut external = xml.to_string();
    let mut cell = xml[cells[6].range()].to_string();
    let paragraph = cells[6]
        .descendants()
        .find(|n| n.has_tag_name((A, "p")))
        .unwrap()
        .range();
    let first = cells[6].range().start;
    let existing = "<a:p><a:r><a:rPr b='1'/><a:t>keep</a:t></a:r><a:r><a:rPr i='1'/><a:t>replace</a:t></a:r></a:p>";
    let blank = "<a:p><a:pPr/><a:endParaRPr sz='2000'/></a:p>";
    let self_closed = format!("<d:p xmlns:d='{A}'/>");
    cell.replace_range(
        paragraph.start - first..paragraph.end - first,
        &format!("{existing}{blank}{self_closed}"),
    );
    external.replace_range(cells[6].range(), &cell);
    external.insert_str(cells[1].range().start + "<a:tc".len(), " hMerge='1'");
    external.insert_str(cells[0].range().start + "<a:tc".len(), " gridSpan='2'");
    parts.insert(part, Cow::Borrowed(&external));
    let bytes = zip(&parts
        .iter()
        .map(|(&name, content)| (name, content.as_ref()))
        .collect::<Vec<_>>());
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let catalog = inspect_cell_text(&source, &sha, Some(1));
    let choices = catalog["tables"][0]["cells"]
        .as_array()
        .unwrap_or_else(|| panic!("{catalog}"));
    assert_eq!(choices.len(), 10);
    assert!(
        !choices
            .iter()
            .any(|cell| cell["row"] == 0 && (cell["column"] == 0 || cell["column"] == 1))
    );
    let selected = choices
        .iter()
        .find(|cell| cell["row"] == 1 && cell["column"] == 2)
        .unwrap();
    assert_eq!(
        selected["runs"],
        json!([
            {"paragraphIndex":0,"runIndex":0,"text":"keep"},
            {"paragraphIndex":0,"runIndex":1,"text":"replace"},
            {"paragraphIndex":1,"runIndex":0,"text":""},
            {"paragraphIndex":2,"runIndex":0,"text":""}
        ])
    );
    for (row, column, code) in [
        (0, 0, "invalid_request"),
        (0, 1, "invalid_request"),
        (2, 4, "invalid_request"),
    ] {
        let mut request = cell_text_request(&source, &sha, &output, id);
        request["row"] = json!(row);
        request["column"] = json!(column);
        let reply = request_json(&request.to_string());
        assert_eq!(reply["error"]["code"], code, "{reply}");
        assert!(!output.exists());
    }
    let mut request = cell_text_request(&source, &sha, &output, id);
    request["changes"] = json!([
        {"paragraphIndex":0,"runIndex":1,"text":"changed"},
        {"paragraphIndex":1,"runIndex":0,"text":"inserted"},
        {"paragraphIndex":2,"runIndex":0,"text":"prefixed"}
    ]);
    let mut stale = request.clone();
    stale["sourceSha256"] = json!("0".repeat(64));
    assert_eq!(
        request_json(&stale.to_string())["error"]["code"],
        "source_changed"
    );
    let mut noop = request.clone();
    noop["changes"] = json!([{"paragraphIndex":0,"runIndex":1,"text":"replace"}]);
    assert_eq!(
        request_json(&noop.to_string())["error"]["code"],
        "invalid_request"
    );
    assert!(!output.exists());
    let reply = request_json(&request.to_string());
    let changed = fs::read(&output).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(reply["outputSha256"], hash(&changed));
    let edited = xml_parts(&changed);
    let expected = external.replace(existing, &existing.replace(">replace<", ">changed<"))
        .replace(blank, "<a:p><a:pPr/><a:r><a:rPr sz='2000'/><a:t xml:space=\"preserve\">inserted</a:t></a:r><a:endParaRPr sz='2000'/></a:p>")
        .replace(&self_closed, &format!("<d:p xmlns:d='{A}'><d:r><d:t xml:space=\"preserve\">prefixed</d:t></d:r></d:p>"));
    assert_eq!(edited[part], expected);
    let occupied = request_json(&request.to_string());
    assert_eq!(occupied["error"]["code"], "output_exists", "{occupied}");
    assert_eq!(fs::read(&output).unwrap(), changed);
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

fn table_structure_slide(heights: &[i64], widths: &[i64]) -> String {
    use std::fmt::Write;

    let width = widths.iter().sum::<i64>() - 360;
    let height = heights.iter().sum::<i64>() + 120;
    let mut slide = format!(
        "<p:sld xmlns:p='{P}' xmlns:d='{A}' show='0'><p:cSld><p:spTree>\n\
         <p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\n\
         <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id='5' name='표 🧪'/><p:cNvGraphicFramePr>\
         <d:graphicFrameLocks noGrp='1'/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>\
         <p:xfrm><d:off y='12000' x='-360'/><d:ext cy='{height}' cx='{width}'/></p:xfrm>\
         <d:graphic><d:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'>\
         <d:tbl><d:tblPr firstRow='0' bandRow='1'/><d:tblGrid>"
    );
    for width in widths {
        write!(slide, "\n<d:gridCol w='{width}'/>").unwrap();
    }
    slide.push_str("\n</d:tblGrid>");
    for (row, height) in heights.iter().enumerate() {
        write!(slide, "\n<d:tr h='{height}'>").unwrap();
        for column in 0..widths.len() {
            write!(slide,
                "\n<d:tc><d:txBody><d:bodyPr/><d:lstStyle/><d:p><d:r><d:rPr b='1'/><d:t>셀 {row}·{column}</d:t>\
                 </d:r></d:p></d:txBody><d:tcPr marL='600'/></d:tc>"
            ).unwrap();
        }
        slide.push_str("\n</d:tr>");
    }
    slide.push_str("\n</d:tbl></d:graphicData></d:graphic></p:graphicFrame>\n\
                    <p:sp><p:nvSpPr><p:cNvPr id='6' name='다른 도형'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>\
                    <p:spPr/></p:sp></p:spTree></p:cSld></p:sld>");
    slide
}

fn inspect_table_structure(source: &Path, sha: &str, index: Option<usize>) -> Value {
    let mut request =
        json!({"op":"pptx_table_structure_inspect","sourcePath":source,"sourceSha256":sha});
    if let Some(index) = index {
        request["slideIndex"] = json!(index);
    }
    request_json(&request.to_string())
}

fn edit_table_structure(
    source: &Path,
    sha: &str,
    output: &Path,
    action: &str,
    index: usize,
) -> Value {
    request_json(
        &json!({"op":"pptx_table_structure_edit","sourcePath":source,"sourceSha256":sha,
        "outputPath":output,"slideIndex":1,"shapeId":5,"action":action,"index":index})
        .to_string(),
    )
}

struct StructureReport<'a> {
    anchor: &'a str,
    frame_width: i64,
    frame_height: i64,
    widths: Vec<i64>,
    heights: Vec<i64>,
    cells: Vec<Vec<&'a str>>,
    siblings: (&'a str, &'a str),
}

fn structure_report(xml: &str) -> StructureReport<'_> {
    let doc = roxmltree::Document::parse(xml).unwrap();
    let descendant = |namespace, name| {
        doc.descendants()
            .find(|node| node.has_tag_name((namespace, name)))
            .unwrap()
    };
    let measure =
        |node: roxmltree::Node, attr| node.attribute(attr).unwrap().parse::<i64>().unwrap();
    let frame = descendant(P, "graphicFrame");
    let rows: Vec<_> = descendant(A, "tbl")
        .children()
        .filter(|node| node.has_tag_name((A, "tr")))
        .collect();
    StructureReport {
        anchor: &xml[descendant(A, "off").range()],
        frame_width: measure(descendant(A, "ext"), "cx"),
        frame_height: measure(descendant(A, "ext"), "cy"),
        widths: descendant(A, "tblGrid")
            .children()
            .filter(|node| node.has_tag_name((A, "gridCol")))
            .map(|node| measure(node, "w"))
            .collect(),
        heights: rows.iter().map(|&node| measure(node, "h")).collect(),
        cells: rows
            .iter()
            .map(|row| {
                row.children()
                    .filter(|node| node.has_tag_name((A, "tc")))
                    .map(|node| &xml[node.range()])
                    .collect()
            })
            .collect(),
        siblings: (&xml[..frame.range().start], &xml[frame.range().end..]),
    }
}

#[test]
fn table_structure_edits_each_axis_preserving_source_styles_and_frame_delta() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("structure.pptx");
    let slide = table_structure_slide(
        &[120_000, 240_000, 360_000],
        &[400_000, 600_000, 900_000, 500_000],
    );
    let original = fixture_with_second(&slide, &[("ppt/media/untouched.bin", "untouched")]);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    assert_eq!(
        inspect_table_structure(&source, &sha, None)["slides"][1],
        json!({"index":1,"hidden":true,"title":"셀 0·0"})
    );
    assert_eq!(
        inspect_table_structure(&source, &sha, Some(0))["tables"],
        json!([])
    );
    assert_eq!(
        inspect_table_structure(&source, &sha, Some(1))["tables"],
        json!([{
            "shapeId":5,"name":"표 🧪","rows":3,"columns":4,"rowInsertGaps":[0,1,2,3],
            "columnInsertGaps":[0,1,2,3,4],"rowDelete":[0,1,2],"columnDelete":[0,1,2,3]
        }])
    );
    let before = structure_report(&slide);
    let original_parts = raw_parts(&original);
    let target = "ppt/slides/slide2.xml";
    for (action, index, row_axis, inserted, at) in [
        ("insertRowBefore", 0, true, true, 0),
        ("insertRowAfter", 2, true, true, 3),
        ("insertColumnBefore", 2, false, true, 2),
        ("insertColumnAfter", 3, false, true, 4),
        ("deleteRow", 1, true, false, 1),
        ("deleteColumn", 1, false, false, 1),
    ] {
        let output = directory.path().join(format!("{action}.pptx"));
        let reply = edit_table_structure(&source, &sha, &output, action, index);
        let updated = fs::read(&output).unwrap_or_else(|_| panic!("{action}: {reply}"));
        let parts = raw_parts(&updated);
        assert_eq!(parts.len(), original_parts.len());
        for (name, bytes) in original_parts.iter().filter(|(name, _)| **name != target) {
            assert_eq!(&parts[name], bytes, "{action}: {name}");
        }
        let actual = structure_report(std::str::from_utf8(&parts[target]).unwrap());
        let mut heights = before.heights.clone();
        let mut widths = before.widths.clone();
        let mut expected_cells: Vec<Vec<_>> = before
            .cells
            .iter()
            .map(|row| row.iter().copied().map(Some).collect())
            .collect();
        let dimensions = if row_axis { &mut heights } else { &mut widths };
        if inserted {
            dimensions.insert(at, dimensions[index]);
        } else {
            dimensions.remove(at);
        }
        match (row_axis, inserted) {
            (true, true) => expected_cells.insert(at, vec![None; widths.len()]),
            (true, false) => {
                expected_cells.remove(at);
            }
            (false, true) => expected_cells
                .iter_mut()
                .for_each(|row| row.insert(at, None)),
            (false, false) => expected_cells.iter_mut().for_each(|row| {
                row.remove(at);
            }),
        }
        assert_eq!(
            reply,
            json!({"sourceSha256":sha,"outputSha256":hash(&updated),"slideCount":2,
            "slideIndex":1,"shapeId":5,"action":action,"index":index,"rows":heights.len(),"columns":widths.len()})
        );
        assert_eq!(actual.anchor, before.anchor);
        assert_eq!(actual.siblings, before.siblings);
        assert_eq!(actual.widths, widths);
        assert_eq!(actual.heights, heights);
        assert_eq!(actual.frame_width, widths.iter().sum::<i64>() - 360);
        assert_eq!(actual.frame_height, heights.iter().sum::<i64>() + 120);
        for (row, expected) in actual.cells.iter().zip(expected_cells) {
            assert_eq!(row.len(), expected.len());
            for (&cell, old) in row.iter().zip(expected) {
                if let Some(old) = old {
                    assert_eq!(cell, old);
                } else {
                    let blank = roxmltree::Document::parse(cell).unwrap();
                    assert!(blank.root_element().has_tag_name((A, "tc")));
                    assert!(!blank.descendants().any(|node| node.has_tag_name((A, "t"))));
                }
            }
        }
        assert_eq!(fs::read(&source).unwrap(), original);
    }
}

#[test]
fn table_structure_rejects_edits_through_merges_and_keeps_unaffected_merges() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("merged.pptx");
    let output = directory.path().join("merged-output.pptx");
    let slide = table_structure_slide(
        &[120_000, 240_000, 360_000],
        &[400_000, 600_000, 900_000, 500_000],
    );
    let positions: Vec<_> = slide
        .match_indices("<d:tc>")
        .map(|(i, _)| i + "<d:tc".len())
        .collect();
    let mut merged = slide.clone();
    for (index, flags) in [
        (5, " hMerge='1' vMerge='1'"),
        (4, " vMerge='1' gridSpan='2'"),
        (1, " hMerge='1' rowSpan='2'"),
        (0, " rowSpan='2' gridSpan='2'"),
    ] {
        merged.insert_str(positions[index], flags);
    }
    let original = fixture_with_second(&merged, &[]);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    let reply = inspect_table_structure(&source, &sha, Some(1));
    let table = &reply["tables"][0];
    assert_eq!(table["rowInsertGaps"], json!([0, 2, 3]));
    assert_eq!(table["columnInsertGaps"], json!([0, 2, 3, 4]));
    assert_eq!(table["rowDelete"], json!([2]));
    assert_eq!(table["columnDelete"], json!([2, 3]));
    for (action, index) in [
        ("insertRowAfter", 0),
        ("insertRowBefore", 1),
        ("insertColumnAfter", 0),
        ("insertColumnBefore", 1),
        ("deleteRow", 0),
        ("deleteRow", 1),
        ("deleteColumn", 0),
        ("deleteColumn", 1),
    ] {
        assert_eq!(
            edit_table_structure(&source, &sha, &output, action, index)["error"]["code"],
            "invalid_request"
        );
        assert!(!output.exists());
    }
    for (action, index, shift) in [("insertRowBefore", 0, 1), ("deleteColumn", 3, 0)] {
        let result = directory.path().join(format!("{action}.pptx"));
        let reply = edit_table_structure(&source, &sha, &result, action, index);
        let bytes = fs::read(&result).unwrap_or_else(|_| panic!("{reply}"));
        let parts = xml_parts(&bytes);
        let actual = structure_report(&parts["ppt/slides/slide2.xml"]);
        let before = structure_report(&merged);
        assert_eq!(&actual.cells[shift][..2], &before.cells[0][..2]);
        assert_eq!(&actual.cells[shift + 1][..2], &before.cells[1][..2]);
    }

    let mut horizontal = slide;
    horizontal.insert_str(positions[1], " hMerge='1'");
    horizontal.insert_str(positions[0], " gridSpan='2'");
    let bytes = fixture_with_second(&horizontal, &[]);
    fs::write(&source, &bytes).unwrap();
    let reply = edit_table_structure(&source, &hash(&bytes), &output, "deleteRow", 0);
    assert_eq!(reply["rows"], 2, "{reply}");
}

#[test]
fn table_structure_rejects_last_bands_locks_and_stale_output_without_writing() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("single.pptx");
    let output = directory.path().join("blocked.pptx");
    let slide = table_structure_slide(&[120_000], &[400_000]);
    let original = fixture_with_second(&slide, &[]);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    let catalog = inspect_table_structure(&source, &sha, Some(1));
    assert_eq!(catalog["tables"][0]["rowDelete"], json!([]));
    assert_eq!(catalog["tables"][0]["columnDelete"], json!([]));
    for (action, index) in [
        ("deleteRow", 0),
        ("deleteColumn", 0),
        ("insertRowBefore", 1),
        ("deleteTable", 0),
    ] {
        assert_eq!(
            edit_table_structure(&source, &sha, &output, action, index)["error"]["code"],
            "invalid_request"
        );
        assert!(!output.exists());
    }
    let stale = edit_table_structure(&source, &"0".repeat(64), &output, "insertRowBefore", 0);
    assert_eq!(stale["error"]["code"], "source_changed");
    assert!(!output.exists());
    for blocked in [
        slide.replace("noGrp='1'", "noGrp='1' noResize='1'"),
        slide.replace("<d:tr h='120000'>", "<d:tr h='0'>"),
        slide.replace("</d:tr>", "<d:extLst/></d:tr>"),
        slide.replace("<p:xfrm>", "<p:xfrm rot='60000'>"),
    ] {
        let original = fixture_with_second(&blocked, &[]);
        let sha = hash(&original);
        fs::write(&source, &original).unwrap();
        assert_eq!(
            inspect_table_structure(&source, &sha, Some(1))["tables"],
            json!([])
        );
        assert_eq!(
            edit_table_structure(&source, &sha, &output, "insertColumnAfter", 0)["error"]["code"],
            "invalid_request"
        );
        assert!(!output.exists());
        assert_eq!(fs::read(&source).unwrap(), original);
    }
    fs::write(&source, &original).unwrap();
    fs::write(&output, b"existing").unwrap();
    let occupied = edit_table_structure(&source, &sha, &output, "insertColumnAfter", 0);
    assert_eq!(occupied["error"]["code"], "output_exists");
    assert_eq!(fs::read(&output).unwrap(), b"existing");
}

fn inspect_geometry(source: &Path, sha: &str, index: Option<usize>) -> Value {
    let mut request = json!({
        "op":"pptx_shape_geometry_inspect","sourcePath":source,"sourceSha256":sha
    });
    if let Some(index) = index {
        request["slideIndex"] = json!(index);
    }
    request_json(&request.to_string())
}

fn replace_geometry(
    source: &Path,
    sha: &str,
    output: &Path,
    shape_id: u32,
    [x, y, width, height]: [i64; 4],
) -> Value {
    request_json(
        &json!({
            "op":"pptx_shape_geometry_replace","sourcePath":source,"sourceSha256":sha,
            "outputPath":output,"slideIndex":1,"shapeId":shape_id,
            "xEmu":x,"yEmu":y,"widthEmu":width,"heightEmu":height,
        })
        .to_string(),
    )
}

fn geometry_fixture() -> String {
    let geometry = "<d:xfrm rot='5400000' flipH='1'><d:off y=\"20\" x='+00010'/><d:ext cy='360000' cx='720000'/></d:xfrm>";
    format!(
        "<p:sld xmlns:p='{P}' xmlns:d='{A}' xmlns:r='{R}' show='0'><p:cSld><p:spTree>
         <p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
         <p:sp><p:nvSpPr><p:cNvPr id='7' name='기존 상자'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
         <p:spPr>{geometry}<d:prstGeom prst='rect'><d:avLst/></d:prstGeom></p:spPr>
         <p:txBody><d:bodyPr/><d:lstStyle/><d:p><d:r><d:rPr b='1'/><d:t>제목 😀</d:t></d:r></d:p></p:txBody></p:sp>
         <p:pic><p:nvPicPr><p:cNvPr id='8' name='사진'/><p:cNvPicPr><d:picLocks noChangeAspect='1'/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
         <p:blipFill><d:srcRect l='140'/></p:blipFill><p:spPr>{geometry}</p:spPr></p:pic>
         <p:sp><p:nvSpPr><p:cNvPr id='9' name='Locked'/><p:cNvSpPr><d:spLocks noMove='true' noResize='1'/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
         <p:spPr>{geometry}</p:spPr></p:sp>
         <p:sp><p:nvSpPr><p:cNvPr id='10' name='Inherited'/><p:cNvSpPr/><p:nvPr><p:ph/></p:nvPr></p:nvSpPr>
         <p:spPr>{geometry}</p:spPr></p:sp>
         <p:grpSp><p:nvGrpSpPr><p:cNvPr id='11' name='Group'/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
         <p:sp><p:nvSpPr><p:cNvPr id='12' name='Nested'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
         <p:spPr>{geometry}</p:spPr></p:sp></p:grpSp>
         <p:sp><p:nvSpPr><p:cNvPr id='13' name='Resize only'/><p:cNvSpPr><d:spLocks noMove='1'/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
         <p:spPr>{geometry}</p:spPr></p:sp>
         <p:sp><p:nvSpPr><p:cNvPr id='14' name='Move only'/><p:cNvSpPr><d:spLocks noResize='1'/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
         <p:spPr>{geometry}</p:spPr></p:sp></p:spTree></p:cSld></p:sld>"
    )
}

#[test]
fn shape_geometry_reopens_moved_shape_and_resized_picture_with_other_parts_unchanged() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let moved = directory.path().join("moved.pptx");
    let resized = directory.path().join("resized.pptx");
    let slide = geometry_fixture();
    let bytes = fixture_with_second(&slide, &[("ppt/media/untouched.bin", "untouched")]);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let plan = inspect_geometry(&source, &sha, None);
    assert_eq!(plan["slideCount"], 2, "{plan}");
    assert_eq!(plan["slides"][1]["hidden"], true);
    assert_eq!(plan["slides"][1]["title"], "제목 😀");
    let inspected = inspect_geometry(&source, &sha, Some(1));
    let shapes = inspected["shapes"].as_array().unwrap();
    assert_eq!(shapes.len(), 4);
    for (shape, id, name, kind, aspect, can_move, can_resize) in [
        (&shapes[0], 7, "기존 상자", "shape", false, true, true),
        (&shapes[1], 8, "사진", "picture", true, true, true),
        (&shapes[2], 13, "Resize only", "shape", false, false, true),
        (&shapes[3], 14, "Move only", "shape", false, true, false),
    ] {
        assert_eq!(shape["shapeId"], id);
        assert_eq!(shape["name"], name);
        assert_eq!(shape["kind"], kind);
        assert_eq!(shape["xEmu"], 10);
        assert_eq!(shape["widthEmu"], 720000);
        assert_eq!(shape["aspectRatioLocked"], aspect);
        assert_eq!(shape["canMove"], can_move);
        assert_eq!(shape["canResize"], can_resize);
    }
    let moved_result = replace_geometry(&source, &sha, &moved, 7, [-43200, 20, 720000, 360000]);
    let moved_bytes = fs::read(&moved).unwrap_or_else(|_| panic!("{moved_result}"));
    let moved_sha = hash(&moved_bytes);
    assert_eq!(
        moved_result,
        json!({"sourceSha256":sha,"outputSha256":moved_sha,"slideCount":2,"slideIndex":1,"shapeId":7,
               "xEmu":-43200,"yEmu":20,"widthEmu":720000,"heightEmu":360000})
    );
    let moved_slide = slide.replacen("x='+00010'", "x='-43200'", 1);
    let mut parts = xml_parts(&bytes);
    parts.insert("ppt/slides/slide2.xml", Cow::Borrowed(&moved_slide));
    assert_eq!(xml_parts(&moved_bytes), parts);

    let resized_result =
        replace_geometry(&moved, &moved_sha, &resized, 8, [10, -30, 1440000, 720000]);
    let resized_bytes = fs::read(&resized).unwrap_or_else(|_| panic!("{resized_result}"));
    let resized_sha = hash(&resized_bytes);
    assert_eq!(resized_result["outputSha256"], resized_sha);
    let resized_slide = moved_slide.replacen(
        "<d:off y=\"20\" x='+00010'/><d:ext cy='360000' cx='720000'/></d:xfrm></p:spPr></p:pic>",
        "<d:off y=\"-30\" x='+00010'/><d:ext cy='720000' cx='1440000'/></d:xfrm></p:spPr></p:pic>",
        1,
    );
    parts.insert("ppt/slides/slide2.xml", Cow::Borrowed(&resized_slide));
    assert_eq!(xml_parts(&resized_bytes), parts);
    assert_eq!(fs::read(&source).unwrap(), bytes);
    let reopened = inspect_geometry(&resized, &resized_sha, Some(1));
    assert_eq!(reopened["shapes"][0]["xEmu"], -43200);
    assert_eq!(reopened["shapes"][1]["yEmu"], -30);
    assert_eq!(reopened["shapes"][1]["heightEmu"], 720000);
}

#[test]
fn shape_geometry_rejects_stale_locked_noop_ambiguous_and_out_of_range_edits() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("rejected.pptx");
    let slide = geometry_fixture();
    let bytes = fixture_with_second(&slide, &[]);
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    for (id, coordinates) in [
        (7, [10, 20, 720000, 360000]),
        (7, [1, 2, 0, 360000]),
        (7, [1, 2, 720000, -1]),
        (7, [-2_147_483_649, 20, 720000, 360000]),
        (7, [2_147_483_648, 20, 720000, 360000]),
        (7, [10, 20, 2_147_483_648, 360000]),
        (8, [10, 20, 720000, 720000]),
        (9, [1, 2, 720000, 360000]),
        (10, [1, 2, 720000, 360000]),
        (12, [1, 2, 720000, 360000]),
        (13, [1, 20, 720000, 360000]),
        (14, [10, 20, 900000, 360000]),
    ] {
        assert!(replace_geometry(&source, &sha, &output, id, coordinates)["error"].is_object());
        assert!(!output.exists());
    }
    let change = [1, 2, 720000, 360000];
    assert_eq!(
        replace_geometry(&source, &"0".repeat(64), &output, 7, change)["error"]["code"],
        "source_changed"
    );
    fs::write(&output, b"keep").unwrap();
    assert_eq!(
        replace_geometry(&source, &sha, &output, 7, change)["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), b"keep");
    assert_eq!(fs::read(&source).unwrap(), bytes);

    for bad in [
        slide.replace("id='8'", "id='7'"),
        slide.replacen(
            "<d:off y=\"20\" x='+00010'/>",
            "<d:off y='1' x='2'/><d:off y='3' x='4'/>",
            1,
        ),
    ] {
        let bytes = fixture_with_second(&bad, &[]);
        fs::write(&source, &bytes).unwrap();
        assert_eq!(
            inspect_geometry(&source, &hash(&bytes), Some(1))["error"]["code"],
            "invalid_pptx"
        );
    }
    for (protected, signed) in [(true, false), (false, true)] {
        let bytes = text_box_fixture(protected, signed);
        fs::write(&source, &bytes).unwrap();
        assert_eq!(
            inspect_geometry(&source, &hash(&bytes), None)["error"]["code"],
            "invalid_pptx"
        );
    }
}

#[test]
fn shape_geometry_refuses_oversized_catalog_without_returning_partial_results() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let shapes: String = (2..=402)
        .map(|id| {
            format!(
                "<p:sp><p:nvSpPr><p:cNvPr id='{id}' name='Shape'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
             <p:spPr><a:xfrm><a:off x='0' y='0'/><a:ext cx='1' cy='1'/></a:xfrm></p:spPr></p:sp>"
            )
        })
        .collect();
    let slide = format!(
        "<p:sld xmlns:p='{P}' xmlns:a='{A}'><p:cSld><p:spTree>{shapes}</p:spTree></p:cSld></p:sld>"
    );
    let bytes = fixture_with_second(&slide, &[]);
    fs::write(&source, &bytes).unwrap();
    let actual = inspect_geometry(&source, &hash(&bytes), Some(1));
    assert_eq!(actual["error"]["code"], "invalid_pptx", "{actual}");
    assert!(actual.get("shapes").is_none());
}

fn shape_delete_target() -> &'static str {
    "<p:sp><p:nvSpPr><p:cNvPr id='7' name='Arrow &amp; text'><a:hlinkClick r:id='link'/></p:cNvPr><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:prstGeom prst='rightArrow'><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:p><a:r><a:t>Keep source intact</a:t></a:r></a:p></p:txBody></p:sp>"
}

fn shape_delete_fixture(extra_tree: &str, extra_root: &str) -> (String, String) {
    let slide = format!(
        "<p:sld xmlns:p='{P}' xmlns:a='{A}' xmlns:r='{R}' xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:p14='{P14}' show='0'><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>{}
        <p:sp><p:nvSpPr><p:cNvPr id='8' name='글 상자'/><p:cNvSpPr txBox='1'/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp>
        <p:sp><p:nvSpPr><p:cNvPr id='9' name='Freeform'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:custGeom/></p:spPr></p:sp>
        {extra_tree}</p:spTree></p:cSld><mc:AlternateContent><mc:Choice Requires='p14'><p:transition p14:dur='2000'/></mc:Choice><mc:Fallback><p:transition/></mc:Fallback></mc:AlternateContent>{extra_root}</p:sld>",
        shape_delete_target(),
    );
    let rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='link' Type='{R}/hyperlink' Target='https://example.org/fixture' TargetMode='External'/></Relationships>"
    );
    (slide, rels)
}

fn inspect_shape_delete(source: &Path, sha: &str, index: Option<usize>) -> Value {
    let mut request =
        json!({"op":"pptx_shape_delete_inspect","sourcePath":source,"sourceSha256":sha});
    if let Some(index) = index {
        request["slideIndex"] = json!(index);
    }
    request_json(&request.to_string())
}

fn delete_shape(source: &Path, sha: &str, output: &Path, id: u32) -> Value {
    request_json(&json!({"op":"pptx_shape_delete","sourcePath":source,"sourceSha256":sha,"outputPath":output,"slideIndex":1,"shapeId":id}).to_string())
}

#[test]
fn shape_delete_reopens_removing_only_one_xml_element_and_retaining_relationships() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source.pptx");
    let output = temp.path().join("edited.pptx");
    let (slide, relationships) = shape_delete_fixture("", "");
    let bytes = fixture_with_second(
        &slide,
        &[
            ("ppt/slides/_rels/slide2.xml.rels", &relationships),
            ("ppt/media/unchanged.bin", "asset"),
        ],
    );
    let sha = hash(&bytes);
    fs::write(&source, &bytes).unwrap();
    let catalog = inspect_shape_delete(&source, &sha, None);
    assert_eq!(catalog["slideCount"], 2, "{catalog}");
    assert_eq!(
        catalog["slides"][1],
        json!({"index":1,"hidden":true,"title":"Keep source intact"})
    );
    let targets = inspect_shape_delete(&source, &sha, Some(1));
    assert_eq!(
        targets["shapes"],
        json!([
            {"shapeId":7,"name":"Arrow & text","kind":"shape"},
            {"shapeId":8,"name":"글 상자","kind":"textBox"},
            {"shapeId":9,"name":"Freeform","kind":"freeform"},
        ]),
        "{targets}"
    );
    let result = delete_shape(&source, &sha, &output, 7);
    let edited = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    let edited_hash = hash(&edited);
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":edited_hash,"slideCount":2,"slideIndex":1,"shapeId":7})
    );
    let mut parts = xml_parts(&bytes);
    let expected = slide.replace(shape_delete_target(), "");
    parts.insert("ppt/slides/slide2.xml", Cow::Borrowed(&expected));
    assert_eq!(xml_parts(&edited), parts);
    assert_eq!(fs::read(&source).unwrap(), bytes);
    let after = inspect_shape_delete(&output, &edited_hash, Some(1));
    assert_eq!(
        after["shapes"],
        json!(targets["shapes"].as_array().unwrap()[1..])
    );
}

#[test]
fn shape_delete_rejects_referenced_locked_ambiguous_and_stale_targets() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source.pptx");
    let output = temp.path().join("rejected.pptx");
    let connector = "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id='10' name='Connector'/><p:cNvCxnSpPr><a:stCxn id='7' idx='0'/></p:cNvCxnSpPr><p:nvPr/></p:nvCxnSpPr><p:spPr/></p:cxnSp>";
    let timing = "<p:timing><p:tnLst><p:set><p:cBhvr><p:tgtEl><p:spTgt spid='7'/></p:tgtEl></p:cBhvr></p:set></p:tnLst></p:timing>";
    let (base, rels) = shape_delete_fixture("", "");
    let (connected, _) = shape_delete_fixture(connector, "");
    let (animated, _) = shape_delete_fixture("", timing);
    let target = shape_delete_target();
    for slide in [
        connected,
        animated,
        base.replace(target, &target.replace("<p:cNvSpPr/>", "<p:cNvSpPr><a:spLocks noSelect='true'/></p:cNvSpPr>")),
        base.replace(target, &target.replace("<p:cNvSpPr/>", "<p:cNvSpPr><a:spLocks noDelete='1'/></p:cNvSpPr>")),
        base.replace(target, &target.replace("<p:nvPr/>", "<p:nvPr><p:ph/></p:nvPr>")),
        base.replace(target, &format!("<p:grpSp>{target}</p:grpSp>")),
        base.replace(target, &format!("<mc:AlternateContent><mc:Choice Requires='p14'>{target}</mc:Choice><mc:Fallback/></mc:AlternateContent>")),
        base.replace(target, &target.replace("</p:txBody>", "<p:sp><p:nvSpPr><p:cNvPr id='71' name='Nested'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp></p:txBody>")),
        base.replace("id='8'", "id='7'"),
    ] {
        let bytes = fixture_with_second(&slide, &[("ppt/slides/_rels/slide2.xml.rels", &rels)]);
        let sha = hash(&bytes);
        fs::write(&source, &bytes).unwrap();
        let inspected = inspect_shape_delete(&source, &sha, Some(1));
        assert!(inspected["shapes"].as_array().is_none_or(|shapes| shapes.iter().all(|shape| shape["shapeId"] != 7)), "{inspected}");
        assert!(delete_shape(&source, &sha, &output, 7)["error"].is_object());
        assert!(!output.exists());
    }
    let bytes = fixture_with_second(&base, &[("ppt/slides/_rels/slide2.xml.rels", &rels)]);
    fs::write(&source, &bytes).unwrap();
    assert_eq!(
        delete_shape(&source, &"0".repeat(64), &output, 7)["error"]["code"],
        "source_changed"
    );
    assert!(!output.exists());
    fs::write(&output, b"keep").unwrap();
    assert_eq!(
        delete_shape(&source, &hash(&bytes), &output, 7)["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), b"keep");
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

fn png_chunk(bytes: &mut Vec<u8>, tag: &[u8; 4], data: &[u8]) {
    bytes.extend((data.len() as u32).to_be_bytes());
    let start = bytes.len();
    bytes.extend(tag);
    bytes.extend(data);
    bytes.extend(crc32fast::hash(&bytes[start..]).to_be_bytes());
}

fn landscape_png() -> Vec<u8> {
    use std::io::Write as _;
    let mut pixels = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::fast());
    pixels.write_all(&[0, 255, 0, 0, 0, 0, 255]).unwrap();
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    png_chunk(
        &mut bytes,
        b"IHDR",
        &[0, 0, 0, 2, 0, 0, 0, 1, 8, 2, 0, 0, 0],
    );
    png_chunk(&mut bytes, b"IDAT", &pixels.finish().unwrap());
    png_chunk(&mut bytes, b"IEND", &[]);
    bytes
}

fn inspect_photo_add(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"pptx_photo_add_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn add_photo(source: &Path, sha: &str, output: &Path, asset: &Path, asset_sha: &str) -> Value {
    request_json(
        &json!({
            "op":"pptx_photo_add","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "slideIndex":1,"assetPath":asset,"assetSha256":asset_sha,
        })
        .to_string(),
    )
}

#[test]
fn photo_add_reopens_with_exact_media_and_retains_other_parts() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("with-photo.pptx");
    let asset = directory.path().join("photo.image");
    let input = text_box_fixture(false, false);
    let sha = hash(&input);
    let image = landscape_png();
    fs::write(&source, &input).unwrap();
    fs::write(&asset, &image).unwrap();
    let inspected = inspect_photo_add(&source, &sha);
    assert_eq!(inspected["sourceSha256"], sha, "{inspected}");
    assert_eq!(inspected["slideCount"], 2, "{inspected}");
    assert_eq!(
        inspected["slides"][1],
        json!({"index":1,"hidden":true,"canAdd":true})
    );
    let added = add_photo(&source, &sha, &output, &asset, &hash(&image));
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{added}"));
    assert_eq!(
        added,
        json!({"sourceSha256":sha,"outputSha256":hash(&written),"slideCount":2,
               "slideIndex":1,"shapeId":4})
    );
    let previous = raw_parts(&input);
    let updated = raw_parts(&written);
    assert_eq!(updated.len(), previous.len() + 2);
    for (name, bytes) in &previous {
        if !matches!(*name, "[Content_Types].xml" | "ppt/slides/slide2.xml") {
            assert_eq!(updated[name], *bytes, "{name}");
        }
    }
    let slide = std::str::from_utf8(&updated["ppt/slides/slide2.xml"]).unwrap();
    let doc = roxmltree::Document::parse(slide).unwrap();
    assert_eq!(doc.root_element().attribute("show"), Some("0"));
    let tree = doc
        .descendants()
        .find(|node| node.has_tag_name((P, "spTree")))
        .unwrap();
    let extension = tree.last_element_child().unwrap();
    assert!(extension.has_tag_name((P, "extLst")));
    let picture = extension.prev_sibling_element().unwrap();
    assert!(picture.has_tag_name((P, "pic")));
    let find = |namespace, name| {
        picture
            .descendants()
            .find(|node| node.has_tag_name((namespace, name)))
            .unwrap()
    };
    assert_eq!(find(P, "cNvPr").attribute("id"), Some("4"));
    let offset = find(A, "off");
    let size = find(A, "ext");
    assert_eq!(
        (offset.attribute("x"), offset.attribute("y")),
        (Some("1219200"), Some("990600"))
    );
    assert_eq!(
        (size.attribute("cx"), size.attribute("cy")),
        (Some("9753600"), Some("4876800"))
    );
    let relationship_id = find(A, "blip").attribute((R, "embed")).unwrap();
    let relationships = roxmltree::Document::parse(
        std::str::from_utf8(&updated["ppt/slides/_rels/slide2.xml.rels"]).unwrap(),
    )
    .unwrap();
    let link = relationships
        .root_element()
        .children()
        .find(|node| node.attribute("Id") == Some(relationship_id))
        .unwrap();
    assert_eq!(link.attribute("Type"), Some(&format!("{R}/image")[..]));
    let media = format!(
        "ppt/{}",
        link.attribute("Target")
            .unwrap()
            .strip_prefix("../")
            .unwrap()
    );
    assert_eq!(updated[media.as_str()].as_ref(), &image);
    let types =
        roxmltree::Document::parse(std::str::from_utf8(&updated["[Content_Types].xml"]).unwrap())
            .unwrap();
    assert!(
        types
            .root_element()
            .children()
            .any(|node| node.attribute("ContentType") == Some("image/png")
                && (node.attribute("Extension") == Some("png")
                    || node.attribute("PartName") == Some(&format!("/{media}")[..])))
    );
    let range = picture.range();
    assert_eq!(
        format!("{}{}", &slide[..range.start], &slide[range.end..]).as_bytes(),
        previous["ppt/slides/slide2.xml"].as_ref()
    );
    assert_eq!(fs::read(&source).unwrap(), input);
}

#[test]
fn photo_add_rejects_stale_hash_invalid_asset_and_output_collision() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("with-photo.pptx");
    let asset = directory.path().join("photo.png");
    let input = text_box_fixture(false, false);
    let sha = hash(&input);
    let image = landscape_png();
    fs::write(&source, &input).unwrap();
    fs::write(&asset, &image).unwrap();
    assert_eq!(
        add_photo(&source, &"0".repeat(64), &output, &asset, &hash(&image))["error"]["code"],
        "source_changed"
    );
    assert_eq!(
        add_photo(&source, &sha, &output, &asset, &"0".repeat(64))["error"]["code"],
        "asset_changed"
    );
    fs::write(&asset, b"not a PNG").unwrap();
    assert!(
        add_photo(&source, &sha, &output, &asset, &hash(b"not a PNG"))
            .get("error")
            .is_some()
    );
    assert!(!output.exists());
    fs::write(&asset, &image).unwrap();
    fs::write(&output, b"do not replace").unwrap();
    assert_eq!(
        add_photo(&source, &sha, &output, &asset, &hash(&image))["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), b"do not replace");
    assert_eq!(fs::read(&source).unwrap(), input);
}

#[test]
fn photo_add_keeps_existing_mime_and_accepts_media_larger_than_the_xml_limit() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("with-photo.pptx");
    let asset = directory.path().join("photo.image");
    let mut image = landscape_png();
    let after_header = image.split_off(33);
    let mut annotation = vec![b'x'; 9 * 1024 * 1024];
    annotation[..5].copy_from_slice(b"data\0");
    png_chunk(&mut image, b"tEXt", &annotation);
    image.extend_from_slice(&after_header);
    let image_sha = hash(&image);
    fs::write(&asset, &image).unwrap();

    let original = text_box_fixture(false, false);
    let mut parts = stored_parts(&original);
    let types = parts["[Content_Types].xml"].replace(
        "</Types>",
        "<Default Extension='png' ContentType='image/png'/></Types>",
    );
    parts.insert("[Content_Types].xml", &types);
    let rels = format!("<?xml version='1.0'?><z:Relationships xmlns:z='{REL}' />");
    parts.insert("ppt/slides/_rels/slide2.xml.rels", &rels);
    let collision = format!("PPT/MEDIA/PIV-{}-1.PNG", image_sha[..16].to_uppercase());
    parts.insert(&collision, "unchanged prior media");
    let input = zip(&parts.into_iter().collect::<Vec<_>>());
    fs::write(&source, &input).unwrap();

    let result = add_photo(&source, &hash(&input), &output, &asset, &image_sha);
    let saved = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    let parts = raw_parts(&saved);
    assert_eq!(parts["[Content_Types].xml"].as_ref(), types.as_bytes());
    assert_eq!(parts[collision.as_str()].as_ref(), b"unchanged prior media");
    let path = format!("ppt/media/piv-{}-2.png", &image_sha[..16]);
    assert_eq!(parts[path.as_str()].as_ref(), image);
    let rels = std::str::from_utf8(&parts["ppt/slides/_rels/slide2.xml.rels"]).unwrap();
    assert!(rels.starts_with(&format!(
        "<?xml version='1.0'?><z:Relationships xmlns:z='{REL}' >"
    )));
    assert!(rels.ends_with("</z:Relationships>"));
    assert_eq!(fs::read(&source).unwrap(), input);
}

fn shape_order_objects() -> [&'static str; 6] {
    [
        "<p:sp><p:nvSpPr><p:cNvPr id='7' name='뒤 도형'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp>",
        "<p:pic><p:nvPicPr><p:cNvPr id='8' name='사진'><a:hlinkClick r:id='link'/></p:cNvPr><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill/><p:spPr/></p:pic>",
        "<p:sp><p:nvSpPr><p:cNvPr id='9' name='텍스트 상자'/><p:cNvSpPr txBox='true'/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>겹치는 글자 😀</a:t></a:r></a:p></p:txBody></p:sp>",
        "<p:grpSp><p:nvGrpSpPr><p:cNvPr id='10' name='그룹'/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id='40' name='그룹 안 도형'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp></p:grpSp>",
        "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id='11' name='연결선'/><p:cNvCxnSpPr><a:stCxn id='7' idx='0'/><a:endCxn id='9' idx='1'/></p:cNvCxnSpPr><p:nvPr/></p:nvCxnSpPr><p:spPr/></p:cxnSp>",
        "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id='12' name='표'/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm/><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'/></a:graphic></p:graphicFrame>",
    ]
}

fn shape_order_slide(objects: &[&str]) -> String {
    let mut slide = format!(
        "<p:sld xmlns:p='{P}' xmlns:a='{A}' xmlns:r='{R}' show='0'><p:cSld><p:spTree>\n\
         <p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
    );
    for (slot, object) in objects.iter().enumerate() {
        slide.push_str(&format!("\n <!--slot {slot}--> \t{object}"));
    }
    slide.push_str(
        "\n <p:extLst><p:ext uri='urn:opaque-metadata'><x:payload xmlns:x='urn:fixture'/></p:ext></p:extLst></p:spTree></p:cSld><p:timing><p:tnLst/></p:timing></p:sld>",
    );
    slide
}

fn shape_order_fixture(slide: &str) -> Vec<u8> {
    let rels = format!(
        "<Relationships xmlns='{REL}'><Relationship Id='link' Type='{R}/hyperlink' TargetMode='External' Target='https://example.com/'/></Relationships>"
    );
    fixture_with_second(slide, &[("ppt/slides/_rels/slide2.xml.rels", &rels)])
}

fn inspect_shape_order(source: &Path, sha: &str, index: Option<usize>) -> Value {
    let mut request = json!({
        "op":"pptx_shape_order_inspect","sourcePath":source,"sourceSha256":sha
    });
    if let Some(index) = index {
        request["slideIndex"] = json!(index);
    }
    request_json(&request.to_string())
}

fn apply_shape_order(source: &Path, sha: &str, output: &Path, id: u32, direction: &str) -> Value {
    request_json(
        &json!({
            "op":"pptx_shape_order_apply","sourcePath":source,"sourceSha256":sha,
            "outputPath":output,"slideIndex":1,"shapeId":id,"direction":direction
        })
        .to_string(),
    )
}

#[test]
fn shape_order_moves_one_direct_layer_and_preserves_every_object_and_other_part() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let objects = shape_order_objects();
    let original = shape_order_fixture(&shape_order_slide(&objects));
    let original_parts = raw_parts(&original);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();

    let catalog = inspect_shape_order(&source, &sha, None);
    assert_eq!(catalog["sourceSha256"], sha, "{catalog}");
    assert_eq!(catalog["slideCount"], 2);
    assert_eq!(catalog["slides"][1]["hidden"], true);
    let inspected = inspect_shape_order(&source, &sha, Some(1));
    let shapes = inspected["shapes"]
        .as_array()
        .unwrap_or_else(|| panic!("{inspected}"));
    let ids = [7, 8, 9, 10, 11, 12];
    let kinds = [
        "shape",
        "picture",
        "textBox",
        "group",
        "connector",
        "graphicFrame",
    ];
    assert_eq!(shapes.len(), ids.len());
    for (index, shape) in shapes.iter().enumerate() {
        assert_eq!(shape["shapeId"], ids[index]);
        assert_eq!(shape["kind"], kinds[index]);
    }
    assert_eq!(shapes[2]["name"], "텍스트 상자");

    for (direction, from, to) in [
        ("front", 2, 5),
        ("forward", 3, 4),
        ("backward", 2, 1),
        ("back", 3, 0),
    ] {
        let output = directory.path().join(format!("{direction}.pptx"));
        let result = apply_shape_order(&source, &sha, &output, ids[from], direction);
        let saved = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
        let output_sha = hash(&saved);
        assert_eq!(result["sourceSha256"], sha);
        assert_eq!(result["outputSha256"], output_sha);
        assert_eq!(result["shapeId"], ids[from]);
        assert_eq!(result["slideIndex"], 1);
        assert_eq!(result["slideCount"], 2);
        assert_eq!(result["fromIndex"], from);
        assert_eq!(result["toIndex"], to);
        let after = raw_parts(&saved);
        assert_eq!(after.len(), original_parts.len());
        let mut expected = objects.to_vec();
        expected.remove(from);
        expected.insert(to, objects[from]);
        for (part, before) in &original_parts {
            if *part == "ppt/slides/slide2.xml" {
                assert_eq!(
                    after[part].as_ref(),
                    shape_order_slide(&expected).as_bytes()
                );
            } else {
                assert_eq!(&after[part], before, "{part}");
            }
        }
        let reopened = inspect_shape_order(&output, &output_sha, Some(1));
        let mut expected_shapes = shapes.clone();
        expected_shapes.remove(from);
        expected_shapes.insert(to, shapes[from].clone());
        assert_eq!(reopened["shapes"], json!(expected_shapes));
        assert_eq!(fs::read(&source).unwrap(), original);
    }
}

#[test]
fn shape_order_rejects_stale_noop_nested_and_ambiguous_edits_without_writing() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.pptx");
    let output = directory.path().join("output.pptx");
    let slide = shape_order_slide(&shape_order_objects());
    let original = shape_order_fixture(&slide);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    for (id, direction) in [(7, "back"), (12, "forward"), (40, "front"), (9, "outside")] {
        assert_eq!(
            apply_shape_order(&source, &sha, &output, id, direction)["error"]["code"],
            "invalid_request"
        );
        assert!(!output.exists());
    }
    assert_eq!(
        apply_shape_order(&source, &"0".repeat(64), &output, 9, "front")["error"]["code"],
        "source_changed"
    );
    assert!(!output.exists());
    for unsafe_slide in [
        slide.replace("id='40'", "id='7'"),
        slide.replace("<p:graphicFrame>", "<p:contentPart/><p:graphicFrame>"),
        slide.replace("<p:cxnSp>", "<mc:AlternateContent xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006'/><p:cxnSp>"),
        slide.replace("r:id='link'", "r:id='missing'"),
    ] {
        let bytes = shape_order_fixture(&unsafe_slide);
        let sha = hash(&bytes);
        fs::write(&source, &bytes).unwrap();
        let inspected = inspect_shape_order(&source, &sha, Some(1));
        assert!(inspected["shapes"] == json!([]) || inspected.get("error").is_some(), "{inspected}");
        let result = apply_shape_order(&source, &sha, &output, 9, "front");
        assert!(result.get("error").is_some(), "{result}");
        assert!(!output.exists());
        assert_eq!(fs::read(&source).unwrap(), bytes);
    }

    fs::write(&source, &original).unwrap();
    fs::write(&output, b"keep").unwrap();
    assert_eq!(
        apply_shape_order(&source, &sha, &output, 9, "front")["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(&output).unwrap(), b"keep");
    assert_eq!(fs::read(&source).unwrap(), original);
}
