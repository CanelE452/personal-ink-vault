use flate2::{Compression, read::DeflateDecoder, write::ZlibEncoder};
use ink_vault_native::request_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::path::Path;

const W: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const WP: &str = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing";
const A: &str = "http://schemas.openxmlformats.org/drawingml/2006/main";
const PIC: &str = "http://schemas.openxmlformats.org/drawingml/2006/picture";
const R: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const REL: &str = "http://schemas.openxmlformats.org/package/2006/relationships";
const CT: &str = "http://schemas.openxmlformats.org/package/2006/content-types";
const MIME: &str = "application/vnd.openxmlformats-officedocument.wordprocessingml.";
const MAIN: &str = "word/document.xml";
const MAIN_RELS: &str = "word/_rels/document.xml.rels";
const TYPES: &str = "[Content_Types].xml";

fn png(pixel: [u8; 3]) -> Vec<u8> {
    fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend((data.len() as u32).to_be_bytes());
        out.extend(kind);
        out.extend(data);
        out.extend(crc32fast::hash(&[kind.as_slice(), data].concat()).to_be_bytes());
    }
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    chunk(&mut out, b"IHDR", &[0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]);
    let mut data = ZlibEncoder::new(Vec::new(), Compression::fast());
    data.write_all(&[&[0], pixel.as_slice()].concat()).unwrap();
    chunk(&mut out, b"IDAT", &data.finish().unwrap());
    chunk(&mut out, b"IEND", &[]);
    out
}

fn grayscale_jpeg() -> Vec<u8> {
    fn segment(out: &mut Vec<u8>, marker: u8, bytes: &[u8]) {
        out.extend([0xff, marker]);
        out.extend((bytes.len() as u16 + 2).to_be_bytes());
        out.extend(bytes);
    }
    let mut output = vec![0xff, 0xd8];
    let mut quantization = [1; 65];
    quantization[0] = 0;
    segment(&mut output, 0xdb, &quantization);
    segment(&mut output, 0xc0, &[8, 0, 1, 0, 1, 1, 1, 0x11, 0]);
    let mut huffman = [0; 36];
    huffman[1] = 1;
    huffman[18] = 0x10;
    huffman[19] = 1;
    segment(&mut output, 0xc4, &huffman);
    segment(&mut output, 0xda, &[1, 1, 0, 0, 63, 0]);
    output.extend([0x3f, 0xff, 0xd9]);
    output
}

fn zip(members: &BTreeMap<&str, Vec<u8>>) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut central = Vec::new();
    for (name, data) in members {
        let offset = bytes.len() as u32;
        let size = data.len() as u32;
        let crc = crc32fast::hash(data);
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
        bytes.extend(data);

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

fn parts(bytes: &[u8]) -> BTreeMap<&str, (Vec<u8>, &[u8])> {
    let word = |at| u16::from_le_bytes(bytes[at..at + 2].try_into().unwrap()) as usize;
    let long = |at| u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
    let mut at = 0;
    let mut result = BTreeMap::new();
    while long(at) == 0x0403_4b50 {
        let size = long(at + 18);
        let name_size = word(at + 26);
        let extra = word(at + 28);
        let name = std::str::from_utf8(&bytes[at + 30..at + 30 + name_size]).unwrap();
        let start = at + 30 + name_size + extra;
        let stop = start + size;
        let data = match word(at + 8) {
            0 => bytes[start..stop].to_vec(),
            8 => {
                let mut data = Vec::new();
                DeflateDecoder::new(&bytes[start..stop])
                    .read_to_end(&mut data)
                    .unwrap();
                data
            }
            method => panic!("Unexpected compression method {method}"),
        };
        assert_eq!(crc32fast::hash(&data), long(at + 14) as u32);
        assert!(result.insert(name, (data, &bytes[at..stop])).is_none());
        at = stop;
    }
    assert_eq!(long(at), 0x0201_4b50);
    result
}

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn drawing(id: u32, title: &str, blip: &str) -> String {
    format!(
        "<w:drawing><wp:inline><wp:extent cx='1000' cy='2000'/><wp:docPr id='{id}' name='{title}'/><a:graphic><a:graphicData uri='{PIC}'><pic:pic><pic:blipFill>{blip}<a:srcRect l='1100'/><a:stretch><a:fillRect/></a:stretch></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>"
    )
}

fn fixture<'a>() -> BTreeMap<&'a str, Vec<u8>> {
    let namespaces =
        format!("xmlns:w='{W}' xmlns:wp='{WP}' xmlns:a='{A}' xmlns:pic='{PIC}' xmlns:r='{R}'");
    let embed = "<a:blip r:embed='shared'/>";
    let first = drawing(1, "첫 사진", embed);
    let second = drawing(2, "둘째 사진", embed);
    let header = drawing(3, "머리글", embed);
    [
        (TYPES, format!("<Types xmlns='{CT}'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='png' ContentType='image/png'/><Override PartName='/{MAIN}' ContentType='{MIME}document.main+xml'/><Override PartName='/word/header1.xml' ContentType='{MIME}header+xml'/><Override PartName='/word/settings.xml' ContentType='{MIME}settings+xml'/></Types>").into_bytes()),
        ("_rels/.rels", format!("<Relationships xmlns='{REL}'><Relationship Id='root' Type='{R}/officeDocument' Target='{MAIN}'/></Relationships>").into_bytes()),
        (MAIN, format!("<w:document {namespaces}><w:body><w:p><w:r>{first}</w:r><w:r>{second}</w:r><w:r><w:t>본문 보존</w:t></w:r></w:p><w:sectPr><w:headerReference r:id='header' w:type='default'/></w:sectPr></w:body></w:document>").into_bytes()),
        (MAIN_RELS, format!("<Relationships xmlns='{REL}'><Relationship Id='shared' Type='{R}/image' Target='media/original.png'/><Relationship Id='header' Type='{R}/header' Target='header1.xml'/><Relationship Id='settings' Type='{R}/settings' Target='settings.xml'/></Relationships>").into_bytes()),
        ("word/header1.xml", format!("<w:hdr {namespaces}><w:p><w:r>{header}</w:r></w:p></w:hdr>").into_bytes()),
        ("word/_rels/header1.xml.rels", format!("<Relationships xmlns='{REL}'><Relationship Id='shared' Type='{R}/image' Target='media/original.png'/></Relationships>").into_bytes()),
        ("word/settings.xml", format!("<w:settings xmlns:w='{W}'/>").into_bytes()),
        ("word/media/original.png", png([240, 10, 0])),
    ]
    .into_iter()
    .collect()
}

fn inspect(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"docx_photo_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn replace(
    source: &Path,
    sha: &str,
    output: &Path,
    asset: &Path,
    asset_sha: &str,
    index: usize,
) -> Value {
    request_json(
        &json!({
            "op":"docx_photo_replace","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "photoIndex":index,"assetPath":asset,"assetSha256":asset_sha,
        })
        .to_string(),
    )
}

fn delete(source: &Path, sha: &str, output: &Path, index: usize) -> Value {
    request_json(
        &json!({
            "op":"docx_photo_delete","sourcePath":source,"sourceSha256":sha,
            "outputPath":output,"photoIndex":index,
        })
        .to_string(),
    )
}

fn rotate(source: &Path, sha: &str, output: &Path, index: usize) -> Value {
    request_json(
        &json!({
            "op":"docx_photo_rotate","sourcePath":source,"sourceSha256":sha,
            "outputPath":output,"photoIndex":index,
        })
        .to_string(),
    )
}

fn insert_photo(
    source: &Path,
    sha: &str,
    output: &Path,
    anchor: (usize, &str),
    asset: &Path,
    asset_sha: &str,
) -> Value {
    request_json(
        &json!({
            "op":"docx_photo_insert","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "anchorParagraphIndex":anchor.0,"position":anchor.1,"assetPath":asset,"assetSha256":asset_sha,
        })
        .to_string(),
    )
}

#[test]
fn inserts_first_photo_before_the_blank_paragraph_without_a_main_relationship_part() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let asset = directory.path().join("asset.jpg");
    let main = "custom/word/main.xml";
    let rels = "custom/word/_rels/main.xml.rels";
    let original = zip(&BTreeMap::from([
        (TYPES, format!("<Types xmlns='{CT}'><Override PartName='/_rels/.rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Override PartName='/{main}' ContentType='{MIME}document.main+xml'/></Types>").into_bytes()),
        ("_rels/.rels", format!("<Relationships xmlns='{REL}'><Relationship Id='root' Type='{R}/officeDocument' Target='{main}'/></Relationships>").into_bytes()),
        (main, format!("<w:document xmlns:w='{W}'><w:body><w:p/><w:sectPr/></w:body></w:document>").into_bytes()),
    ]));
    let jpeg = grayscale_jpeg();
    let source_sha = hash(&original);
    let image_sha = hash(&jpeg);
    fs::write(&source, &original).unwrap();
    fs::write(&asset, &jpeg).unwrap();
    assert_eq!(inspect(&source, &source_sha)["photos"], json!([]));

    let result = insert_photo(
        &source,
        &source_sha,
        &output,
        (0, "before"),
        &asset,
        &image_sha,
    );
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    let output_sha = hash(&bytes);
    assert_eq!(
        result,
        json!({"sourceSha256":source_sha,"outputSha256":output_sha,"paragraphIndex":0})
    );
    assert_eq!(fs::read(&source).unwrap(), original);
    let photo = &inspect(&output, &output_sha)["photos"][0];
    assert_eq!(photo["mediaSha256"], image_sha);
    assert_eq!(photo["format"], "jpeg");
    let media = photo["mediaPart"].as_str().unwrap();
    let before = parts(&original);
    let after = parts(&bytes);
    assert_eq!(after[media].0, jpeg);
    assert_eq!(after["_rels/.rels"], before["_rels/.rels"]);
    assert!(after.contains_key(rels));
    let types = roxmltree::Document::parse(std::str::from_utf8(&after[TYPES].0).unwrap()).unwrap();
    for (part, mime) in [
        (media, "image/jpeg"),
        (
            rels,
            "application/vnd.openxmlformats-package.relationships+xml",
        ),
    ] {
        let part_name = format!("/{part}");
        assert!(
            types
                .root_element()
                .children()
                .any(|node| node.attribute("PartName") == Some(&part_name)
                    && node.attribute("ContentType") == Some(mime))
        );
    }
    let xml = roxmltree::Document::parse(std::str::from_utf8(&after[main].0).unwrap()).unwrap();
    let body = xml.root_element().first_element_child().unwrap();
    let blocks = body
        .children()
        .filter(roxmltree::Node::is_element)
        .collect::<Vec<_>>();
    assert_eq!(
        blocks
            .iter()
            .map(|node| node.tag_name().name())
            .collect::<Vec<_>>(),
        ["p", "p", "sectPr"]
    );
    assert!(
        blocks[0]
            .descendants()
            .any(|node| node.has_tag_name((WP, "inline")))
    );
    assert!(blocks[1].first_element_child().is_none());
}

#[test]
fn inserts_after_body_paragraph_and_preserves_existing_pictures_and_header() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let asset = directory.path().join("asset.png");
    let original = zip(&fixture());
    let image = png([0, 40, 240]);
    let source_sha = hash(&original);
    let image_sha = hash(&image);
    fs::write(&source, &original).unwrap();
    fs::write(&asset, &image).unwrap();
    let old = inspect(&source, &source_sha);

    let result = insert_photo(
        &source,
        &source_sha,
        &output,
        (0, "after"),
        &asset,
        &image_sha,
    );
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    let output_sha = hash(&bytes);
    assert_eq!(
        result,
        json!({"sourceSha256":source_sha,"outputSha256":output_sha,"paragraphIndex":1})
    );
    let photos = inspect(&output, &output_sha)["photos"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(photos.len(), 3);
    assert_eq!(&photos[..2], old["photos"].as_array().unwrap());
    assert_eq!(photos[2]["mediaSha256"], image_sha);
    let before = parts(&original);
    let after = parts(&bytes);
    assert_eq!(after[photos[2]["mediaPart"].as_str().unwrap()].0, image);
    for (name, part) in before {
        if !matches!(name, MAIN | MAIN_RELS) {
            assert_eq!(after[name], part, "Part changed: {name}");
        }
    }
    let xml = roxmltree::Document::parse(std::str::from_utf8(&after[MAIN].0).unwrap()).unwrap();
    let body = xml.root_element().first_element_child().unwrap();
    let inserted = body
        .first_element_child()
        .unwrap()
        .next_sibling_element()
        .unwrap();
    let id = inserted
        .descendants()
        .find(|node| node.has_tag_name((WP, "docPr")))
        .unwrap()
        .attribute("id")
        .unwrap();
    assert!(!["1", "2", "3"].contains(&id));
    assert!(
        inserted
            .next_sibling_element()
            .unwrap()
            .has_tag_name((W, "sectPr"))
    );
}

#[test]
fn photo_insertion_refuses_crossed_bookmark_stale_hashes_and_existing_output() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let asset = directory.path().join("asset.png");
    let mut input = fixture();
    let main = std::str::from_utf8(&input[MAIN]).unwrap().replace(
        "</w:p><w:sectPr>",
        "<w:bookmarkStart w:id='4' w:name='Crossed'/></w:p><w:p><w:bookmarkEnd w:id='4'/></w:p><w:sectPr>",
    );
    input.insert(MAIN, main.into_bytes());
    let original = zip(&input);
    let image = png([0, 40, 240]);
    let source_sha = hash(&original);
    let image_sha = hash(&image);
    let stale = "0".repeat(64);
    fs::write(&source, &original).unwrap();
    fs::write(&asset, &image).unwrap();
    for (sha, anchor, asset_sha, code) in [
        (&stale, (0, "before"), &image_sha, "source_changed"),
        (&source_sha, (0, "before"), &stale, "asset_changed"),
        (&source_sha, (0, "after"), &image_sha, "invalid_request"),
        (&source_sha, (1, "before"), &image_sha, "invalid_request"),
    ] {
        assert_eq!(
            insert_photo(&source, sha, &output, anchor, &asset, asset_sha)["error"]["code"],
            code,
        );
        assert!(!output.exists());
    }
    fs::write(&output, b"existing destination").unwrap();
    assert_eq!(
        insert_photo(
            &source,
            &source_sha,
            &output,
            (0, "before"),
            &asset,
            &image_sha
        )["error"]["code"],
        "output_exists",
    );
    assert_eq!(fs::read(&source).unwrap(), original);
    assert_eq!(fs::read(&output).unwrap(), b"existing destination");
}

const PHOTO_TRANSFORM: &str = "<a:xfrm><a:off x='0' y='0'/><a:ext cx='1000' cy='2000'/></a:xfrm>";

fn with_photo_transform(drawing: &str, transform: &str) -> String {
    drawing.replace(
        "</pic:pic>",
        &format!("<pic:spPr>{transform}</pic:spPr></pic:pic>"),
    )
}

#[test]
fn rotates_only_the_selected_inline_photo_without_touching_shared_media() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let mut input = fixture();
    let embed = "<a:blip r:embed='shared'/>";
    let first = drawing(1, "첫 사진", embed);
    let second = drawing(2, "둘째 사진", embed);
    let main = std::str::from_utf8(&input[MAIN])
        .unwrap()
        .replace(&first, &with_photo_transform(&first, PHOTO_TRANSFORM))
        .replace(&second, &with_photo_transform(&second, PHOTO_TRANSFORM));
    input.insert(MAIN, main.as_bytes().to_vec());
    let original = zip(&input);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();

    let result = rotate(&source, &sha, &output, 1);
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    let output_sha = hash(&bytes);
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":output_sha,"photoIndex":1,
               "mediaSha256":hash(&input["word/media/original.png"])})
    );
    let before = parts(&original);
    let after = parts(&bytes);
    assert_eq!(after.len(), before.len());
    for (name, part) in &before {
        if *name != MAIN {
            assert_eq!(after[name], *part, "Part changed: {name}");
        }
    }
    let expected_transform = PHOTO_TRANSFORM.replace("<a:xfrm>", "<a:xfrm rot=\"5400000\">");
    let expected = main.replace(
        &with_photo_transform(&second, PHOTO_TRANSFORM),
        &with_photo_transform(&second, &expected_transform),
    );
    assert_eq!(after[MAIN].0, expected.as_bytes());
    assert_eq!(
        inspect(&output, &output_sha)["photos"],
        inspect(&source, &sha)["photos"]
    );
    assert_eq!(fs::read(source).unwrap(), original);
}

#[test]
fn adds_to_an_existing_rotation_and_wraps_after_a_full_turn() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let mut input = fixture();
    let selected = drawing(1, "첫 사진", "<a:blip r:embed='shared'/>");
    let transform = PHOTO_TRANSFORM.replace("<a:xfrm>", "<a:xfrm flipH='1' rot = '18000000'>");
    let main = std::str::from_utf8(&input[MAIN])
        .unwrap()
        .replace(&selected, &with_photo_transform(&selected, &transform));
    input.insert(MAIN, main.as_bytes().to_vec());
    let original = zip(&input);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();

    let result = rotate(&source, &sha, &output, 0);
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    assert_eq!(
        parts(&bytes)[MAIN].0,
        main.replace("rot = '18000000'", "rot = '1800000'")
            .as_bytes()
    );
    assert_eq!(fs::read(source).unwrap(), original);
}

#[test]
fn rejects_unsupported_rotation_without_hiding_photos_or_writing_a_candidate() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let mut input = fixture();
    let selected = drawing(1, "첫 사진", "<a:blip r:embed='shared'/>");
    let transform = PHOTO_TRANSFORM.replace("<a:xfrm>", "<a:xfrm rot='invalid'>");
    let main = std::str::from_utf8(&input[MAIN])
        .unwrap()
        .replace(&selected, &with_photo_transform(&selected, &transform));
    input.insert(MAIN, main.into_bytes());
    let original = zip(&input);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    assert_eq!(
        inspect(&source, &sha)["photos"].as_array().unwrap().len(),
        2
    );
    for index in [0, 1] {
        assert_eq!(
            rotate(&source, &sha, &output, index)["error"]["code"],
            "unsupported_document"
        );
        assert!(!output.exists());
    }
    assert_eq!(
        rotate(&source, &"0".repeat(64), &output, 0)["error"]["code"],
        "source_changed"
    );
    fs::write(&output, b"sentinel").unwrap();
    assert_eq!(
        rotate(&source, &sha, &output, 0)["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(output).unwrap(), b"sentinel");
    assert_eq!(fs::read(source).unwrap(), original);
}

#[test]
fn deletes_only_one_drawing_in_a_styled_run_with_shared_body_and_header_media() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let empty = directory.path().join("empty.docx");
    let mut input = fixture();
    let embed = "<a:blip r:embed='shared'/>";
    let first = drawing(1, "첫 사진", embed);
    let second = drawing(2, "둘째 사진", embed);
    let main = std::str::from_utf8(&input[MAIN]).unwrap().replace(
        &format!("<w:r>{first}</w:r><w:r>{second}</w:r><w:r>"),
        &format!("<w:r><w:rPr><w:b/></w:rPr><w:t>앞 글자</w:t>{first}<w:tab/>{second}"),
    );
    assert!(main.contains(&format!("{first}<w:tab/>{second}<w:t>본문 보존")));
    input.insert(MAIN, main.as_bytes().to_vec());
    let original = zip(&input);
    let sha = hash(&original);
    let media_sha = hash(&input["word/media/original.png"]);
    fs::write(&source, &original).unwrap();

    let result = delete(&source, &sha, &output, 0);
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    let output_sha = hash(&bytes);
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":output_sha,"photoIndex":0,
               "mediaSha256":media_sha,"remainingPhotoCount":1})
    );
    let before = parts(&original);
    let after = parts(&bytes);
    assert_eq!(after.len(), before.len());
    for (name, part) in &before {
        if *name != MAIN {
            assert_eq!(after[name], *part, "Part changed: {name}");
        }
    }
    let without_first = main.replacen(&first, "", 1);
    assert_eq!(after[MAIN].0, without_first.as_bytes());
    assert_eq!(
        inspect(&output, &output_sha)["photos"],
        json!([{"index":0,"title":"둘째 사진","mediaPart":"word/media/original.png",
                "mediaSha256":media_sha,"format":"png"}]),
    );

    let result = delete(&output, &output_sha, &empty, 0);
    let empty_bytes = fs::read(&empty).unwrap_or_else(|_| panic!("{result}"));
    let empty_sha = hash(&empty_bytes);
    assert_eq!(
        result,
        json!({"sourceSha256":output_sha,"outputSha256":empty_sha,"photoIndex":0,
               "mediaSha256":media_sha,"remainingPhotoCount":0})
    );
    let without_photos = parts(&empty_bytes);
    assert_eq!(
        without_photos[MAIN].0,
        without_first.replacen(&second, "", 1).as_bytes()
    );
    for (name, part) in &before {
        if *name != MAIN {
            assert_eq!(without_photos[name], *part, "Part changed: {name}");
        }
    }
    assert_eq!(inspect(&empty, &empty_sha)["photos"], json!([]));
    assert_eq!(fs::read(source).unwrap(), original);
    assert_eq!(fs::read(output).unwrap(), bytes);
}

#[test]
fn photo_deletion_rejects_stale_index_protected_and_existing_destination() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let mut input = fixture();
    let original = zip(&input);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    assert_eq!(
        delete(&source, &"0".repeat(64), &output, 0)["error"]["code"],
        "source_changed",
    );
    assert_eq!(
        delete(&source, &sha, &output, 2)["error"]["code"],
        "invalid_request",
    );
    assert!(!output.exists());
    fs::write(&output, b"sentinel").unwrap();
    assert_eq!(
        delete(&source, &sha, &output, 0)["error"]["code"],
        "output_exists",
    );
    assert_eq!(fs::read(&output).unwrap(), b"sentinel");
    assert_eq!(fs::read(&source).unwrap(), original);

    let protected = directory.path().join("protected.docx");
    let protected_output = directory.path().join("protected-result.docx");
    input.insert(
        "word/settings.xml",
        format!("<w:settings xmlns:w='{W}'><w:documentProtection w:enforcement='1'/></w:settings>")
            .into_bytes(),
    );
    let protected_bytes = zip(&input);
    fs::write(&protected, &protected_bytes).unwrap();
    assert_eq!(
        delete(&protected, &hash(&protected_bytes), &protected_output, 0)["error"]["code"],
        "unsupported_document",
    );
    assert!(!protected_output.exists());
}

#[test]
fn replaces_one_of_two_body_photos_sharing_the_same_header_media() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let asset = directory.path().join("asset.png");
    let original = zip(&fixture());
    let new_image = png([0, 40, 240]);
    let sha = hash(&original);
    let image_sha = hash(&new_image);
    fs::write(&source, &original).unwrap();
    fs::write(&asset, &new_image).unwrap();
    let old = inspect(&source, &sha);
    let old_image_sha = hash(&fixture()["word/media/original.png"]);
    assert_eq!(
        old,
        json!({"sourceSha256":sha,"photos":[
            {"index":0,"title":"첫 사진","mediaPart":"word/media/original.png","mediaSha256":old_image_sha,"format":"png"},
            {"index":1,"title":"둘째 사진","mediaPart":"word/media/original.png","mediaSha256":old_image_sha,"format":"png"}
        ]}),
        "{old}"
    );
    let result = replace(&source, &sha, &output, &asset, &image_sha, 1);
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    assert_eq!(
        result,
        json!({"sourceSha256":sha,"outputSha256":hash(&bytes),"photoIndex":1,"mediaSha256":image_sha})
    );
    let before = parts(&original);
    let after = parts(&bytes);
    assert_eq!(after.len(), before.len() + 1);
    for (name, part) in &before {
        if !matches!(*name, MAIN | MAIN_RELS) {
            assert_eq!(after[name], *part, "Part changed: {name}");
        }
    }
    let inspected = inspect(&output, &hash(&bytes));
    assert_eq!(inspected["photos"][0], old["photos"][0]);
    assert_eq!(inspected["photos"][1]["title"], "둘째 사진");
    let new_part = inspected["photos"][1]["mediaPart"].as_str().unwrap();
    assert_ne!(new_part, "word/media/original.png");
    assert_eq!(after[new_part].0, new_image);
    let rels = std::str::from_utf8(&after[MAIN_RELS].0).unwrap();
    let rels = roxmltree::Document::parse(rels).unwrap();
    let new_target = new_part.strip_prefix("word/").unwrap();
    let new_id = rels
        .root_element()
        .children()
        .find(|n| n.attribute("Target") == Some(new_target))
        .unwrap()
        .attribute("Id")
        .unwrap();
    let main_before = std::str::from_utf8(&before[MAIN].0).unwrap();
    let second = main_before.rfind("r:embed='shared'").unwrap();
    let value = second + "r:embed='".len();
    let mut expected = main_before.to_owned();
    expected.replace_range(value..value + "shared".len(), new_id);
    assert_eq!(after[MAIN].0, expected.into_bytes());
    assert_eq!(fs::read(&source).unwrap(), original);
}

#[test]
fn adds_jpeg_content_type_without_reusing_dangling_relationship_id() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let asset = directory.path().join("image-without-extension");
    let mut input = fixture();
    let main = std::str::from_utf8(&input[MAIN])
        .unwrap()
        .replace("</w:p>", "<w:hyperlink r:id='PivPhoto1'/></w:p>");
    input.insert(MAIN, main.into_bytes());
    let original = zip(&input);
    let jpeg = grayscale_jpeg();
    let source_sha = hash(&original);
    let jpeg_sha = hash(&jpeg);
    fs::write(&source, &original).unwrap();
    fs::write(&asset, &jpeg).unwrap();
    let replaced = replace(&source, &source_sha, &output, &asset, &jpeg_sha, 0);
    let bytes = fs::read(&output).unwrap_or_else(|_| panic!("{replaced}"));
    let entries = parts(&bytes);
    let photo = &inspect(&output, &hash(&bytes))["photos"][0];
    assert_eq!(photo["format"], "jpeg");
    assert_eq!(photo["mediaSha256"], jpeg_sha);
    let part = photo["mediaPart"].as_str().unwrap();
    assert_eq!(entries[part].0, jpeg);
    let types = std::str::from_utf8(&entries[TYPES].0).unwrap();
    let types = roxmltree::Document::parse(types).unwrap();
    let path = format!("/{part}");
    assert!(types.root_element().children().any(|node| {
        node.attribute("PartName") == Some(path.as_str())
            && node.attribute("ContentType") == Some("image/jpeg")
    }));
    let rels = std::str::from_utf8(&entries[MAIN_RELS].0).unwrap();
    assert!(!rels.contains("PivPhoto1"));
    assert_eq!(fs::read(source).unwrap(), original);
}

#[test]
fn skips_linked_or_alternate_pictures_and_rejects_enforced_protection() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let mut input = fixture();
    let main = std::str::from_utf8(&input[MAIN]).unwrap().replacen(
        "<a:blip r:embed='shared'/>",
        "<a:blip r:embed='shared' r:link='shared'/>",
        1,
    );
    input.insert(MAIN, main.into_bytes());
    let content = zip(&input);
    fs::write(&source, &content).unwrap();
    let inspected = inspect(&source, &hash(&content));
    assert_eq!(
        inspected["photos"]
            .as_array()
            .unwrap_or_else(|| panic!("{inspected}"))
            .len(),
        1
    );
    assert_eq!(inspected["photos"][0]["title"], "둘째 사진");
    input.insert(
        "word/settings.xml",
        format!("<w:settings xmlns:w='{W}'><w:documentProtection w:edit='readOnly'/></w:settings>")
            .into_bytes(),
    );
    let protected = zip(&input);
    fs::write(&source, &protected).unwrap();
    assert_eq!(
        inspect(&source, &hash(&protected))["error"]["code"],
        "unsupported_document"
    );
}

#[test]
fn refuses_signed_documents_and_only_lists_embedded_png_or_jpeg() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let mut input = fixture();
    let main = std::str::from_utf8(&input[MAIN]).unwrap().replacen(
        "<a:blip r:embed='shared'/>",
        "<a:blip r:embed='shared'><a:extLst><a:ext uri='svg'><s:svgBlip xmlns:s='http://schemas.microsoft.com/office/drawing/2016/SVG/main' r:embed='shared'/></a:ext></a:extLst></a:blip>",
        1,
    );
    input.insert(MAIN, main.into_bytes());
    let alternate = zip(&input);
    fs::write(&source, &alternate).unwrap();
    let inspected = inspect(&source, &hash(&alternate));
    assert_eq!(
        inspected["photos"]
            .as_array()
            .unwrap_or_else(|| panic!("{inspected}"))
            .len(),
        1,
    );
    assert_eq!(inspected["photos"][0]["title"], "둘째 사진");
    let wrong_mime = std::str::from_utf8(&input[TYPES])
        .unwrap()
        .replace("image/png", "image/jpeg");
    input.insert(TYPES, wrong_mime.into_bytes());
    let wrong_mime = zip(&input);
    fs::write(&source, &wrong_mime).unwrap();
    assert_eq!(inspect(&source, &hash(&wrong_mime))["photos"], json!([]));
    input.insert("_xmlsignatures/sig1.xml", b"<Signature/>".to_vec());
    let signed = zip(&input);
    fs::write(&source, &signed).unwrap();
    assert_eq!(
        inspect(&source, &hash(&signed))["error"]["code"],
        "unsupported_document",
    );
}

#[test]
fn rejects_wrong_asset_hash_and_oversize_image_before_writing() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let asset = directory.path().join("asset.png");
    let original = zip(&fixture());
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    let mut image = png([3, 2, 1]);
    image[16..20].copy_from_slice(&40_000_001u32.to_be_bytes());
    let checksum = crc32fast::hash(&image[12..29]).to_be_bytes();
    image[29..33].copy_from_slice(&checksum);
    fs::write(&asset, &image).unwrap();
    assert_eq!(
        replace(&source, &sha, &output, &asset, &"0".repeat(64), 0)["error"]["code"],
        "asset_changed",
    );
    assert_eq!(
        replace(&source, &sha, &output, &asset, &hash(&image), 0)["error"]["code"],
        "invalid_request",
    );
    let foreign = tempfile::tempdir().unwrap();
    let other_output = foreign.path().join("result.docx");
    assert_eq!(
        replace(&source, &sha, &other_output, &asset, &hash(&image), 0)["error"]["code"],
        "invalid_request",
    );
    assert!(!output.exists() && !other_output.exists());
    assert_eq!(fs::read(source).unwrap(), original);
}

#[test]
fn prevents_stale_source_unchanged_image_and_destination_clobber() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let asset = directory.path().join("asset.png");
    let input = fixture();
    let original = zip(&input);
    fs::write(&source, &original).unwrap();
    let image = &input["word/media/original.png"];
    fs::write(&asset, image).unwrap();
    assert_eq!(
        replace(&source, &"0".repeat(64), &output, &asset, &hash(image), 0)["error"]["code"],
        "source_changed"
    );
    assert_eq!(
        replace(&source, &hash(&original), &output, &asset, &hash(image), 0)["error"]["code"],
        "invalid_request"
    );
    assert!(!output.exists());
    fs::write(&output, b"sentinel").unwrap();
    assert_eq!(
        replace(&source, &hash(&original), &output, &asset, &hash(image), 0)["error"]["code"],
        "output_exists"
    );
    assert_eq!(fs::read(output).unwrap(), b"sentinel");
    assert_eq!(fs::read(source).unwrap(), original);
}

fn inspect_table_anchors(source: &Path, sha: &str) -> Value {
    request_json(
        &json!({"op":"docx_table_inspect","sourcePath":source,"sourceSha256":sha}).to_string(),
    )
}

fn insert_table(source: &Path, sha: &str, output: &Path, anchor: Value, cells: Value) -> Value {
    request_json(
        &json!({
            "op":"docx_table_insert","sourcePath":source,"sourceSha256":sha,"outputPath":output,
            "afterParagraphIndex":anchor,"cells":cells,
        })
        .to_string(),
    )
}

#[test]
fn table_insert_reopens_unicode_grid_at_the_selected_body_paragraph() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let mut input = fixture();
    let body = String::from_utf8(input[MAIN].clone()).unwrap().replace(
        "<w:body>",
        "<w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Nested</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
    );
    input.insert(MAIN, body.as_bytes().to_vec());
    let original = zip(&input);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    assert_eq!(
        inspect_table_anchors(&source, &sha),
        json!({"sourceSha256":sha,"paragraphs":[{"index":0,"text":"본문 보존"}]}),
    );

    let cells = json!([["  줄 & <표>  ", ""], ["보존", "별 🌟"]]);
    let result = insert_table(&source, &sha, &output, json!(0), cells);
    let written = fs::read(&output).unwrap_or_else(|_| panic!("{result}"));
    let written_sha = hash(&written);
    assert_eq!(
        result,
        json!({
            "sourceSha256":sha,"outputSha256":written_sha,"afterParagraphIndex":0,
            "rows":2,"columns":2,"tableIndex":1,
        }),
    );
    assert_eq!(fs::read(&source).unwrap(), original);
    let old = parts(&original);
    let updated = parts(&written);
    assert!(old.keys().eq(updated.keys()));
    for name in old.keys().filter(|name| **name != MAIN) {
        assert_eq!(updated[name], old[name], "{name}");
    }
    let main = std::str::from_utf8(&updated[MAIN].0).unwrap();
    let xml = roxmltree::Document::parse(main).unwrap();
    let body_node = xml.root_element().first_element_child().unwrap();
    let blocks = body_node
        .children()
        .filter(|node| node.is_element())
        .collect::<Vec<_>>();
    assert_eq!(
        blocks
            .iter()
            .map(|node| node.tag_name().name())
            .collect::<Vec<_>>(),
        ["tbl", "p", "tbl", "sectPr"],
    );
    let inserted = blocks[2].range();
    assert_eq!(
        format!("{}{}", &main[..inserted.start], &main[inserted.end..]),
        body
    );
    let grid = blocks[2]
        .children()
        .find(|node| node.has_tag_name((W, "tblGrid")))
        .unwrap();
    assert_eq!(
        grid.children()
            .filter(|node| node.has_tag_name((W, "gridCol")))
            .count(),
        2
    );
    let cell_text = blocks[2]
        .children()
        .filter(|node| node.has_tag_name((W, "tr")))
        .map(|row| {
            row.children()
                .filter(|node| node.has_tag_name((W, "tc")))
                .map(|cell| {
                    cell.descendants()
                        .find(|node| node.has_tag_name((W, "t")))
                        .and_then(|node| node.text())
                        .unwrap_or_default()
                })
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    assert_eq!(
        cell_text,
        vec![vec!["  줄 & <표>  ", ""], vec!["보존", "별 🌟"]]
    );
    assert_eq!(
        inspect_table_anchors(&output, &written_sha)["paragraphs"],
        json!([{"index":0,"text":"본문 보존"}]),
    );
}

#[test]
fn table_insert_handles_a_body_without_top_level_paragraphs() {
    let directory = tempfile::tempdir().unwrap();
    for (index, body) in [
        "<alt:body/>",
        "<alt:body><alt:sectPr/></alt:body>",
        "<alt:body><alt:tbl><alt:tr><alt:tc><alt:p/></alt:tc></alt:tr></alt:tbl></alt:body>",
    ]
    .into_iter()
    .enumerate()
    {
        let mut input = fixture();
        input.insert(
            MAIN,
            format!("<alt:document xmlns:alt='{W}'>{body}</alt:document>").into_bytes(),
        );
        let original = zip(&input);
        let sha = hash(&original);
        let source = directory.path().join(format!("original-{index}.docx"));
        let output = directory.path().join(format!("result-{index}.docx"));
        fs::write(&source, &original).unwrap();
        assert_eq!(
            inspect_table_anchors(&source, &sha)["paragraphs"],
            json!([])
        );
        let result = insert_table(&source, &sha, &output, Value::Null, json!([[""]]));
        assert_eq!(result["tableIndex"], 0, "{result}");
        assert!(result["afterParagraphIndex"].is_null());
        let written = fs::read(&output).unwrap();
        let updated = parts(&written);
        let xml =
            roxmltree::Document::parse(std::str::from_utf8(&updated[MAIN].0).unwrap()).unwrap();
        let first = xml
            .root_element()
            .first_element_child()
            .unwrap()
            .first_element_child()
            .unwrap();
        assert!(first.has_tag_name((W, "tbl")));
        assert_eq!(fs::read(&source).unwrap(), original);
    }
}

#[test]
fn table_insert_rejects_stale_protected_invalid_and_existing_outputs() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("original.docx");
    let output = directory.path().join("result.docx");
    let mut input = fixture();
    let original = zip(&input);
    let sha = hash(&original);
    fs::write(&source, &original).unwrap();
    assert_eq!(
        insert_table(&source, &"0".repeat(64), &output, json!(0), json!([[""]]))["error"]["code"],
        "source_changed",
    );
    assert_eq!(
        insert_table(&source, &sha, &output, json!(1), json!([[""]]))["error"]["code"],
        "invalid_request",
    );
    for cells in [
        json!([]),
        json!([[]]),
        json!([[""], ["", ""]]),
        json!([["a\nb"]]),
        json!([["\u{2028}"]]),
        json!([["\u{ffff}"]]),
        json!([["🌟".repeat(201)]]),
    ] {
        assert_eq!(
            insert_table(&source, &sha, &output, json!(0), cells)["error"]["code"],
            "invalid_request",
        );
    }
    assert!(!output.exists());
    fs::write(&output, b"sentinel").unwrap();
    assert_eq!(
        insert_table(&source, &sha, &output, json!(0), json!([[""]]))["error"]["code"],
        "output_exists",
    );
    assert_eq!(fs::read(&output).unwrap(), b"sentinel");
    assert_eq!(fs::read(&source).unwrap(), original);

    for (index, settings) in [
        "<w:trackRevisions/>",
        "<w:documentProtection w:enforcement='1'/>",
    ]
    .into_iter()
    .enumerate()
    {
        input.insert(
            "word/settings.xml",
            format!("<w:settings xmlns:w='{W}'>{settings}</w:settings>").into_bytes(),
        );
        let locked = zip(&input);
        let source = directory.path().join(format!("protected-{index}.docx"));
        let output = directory.path().join(format!("result-{index}.docx"));
        fs::write(&source, &locked).unwrap();
        let sha = hash(&locked);
        assert_eq!(
            inspect_table_anchors(&source, &sha)["error"]["code"],
            "unsupported_document"
        );
        assert_eq!(
            insert_table(&source, &sha, &output, json!(0), json!([[""]]))["error"]["code"],
            "unsupported_document",
        );
        assert!(!output.exists());
    }
}
