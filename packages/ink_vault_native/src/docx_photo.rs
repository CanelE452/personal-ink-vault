//! Edits inline pictures in the DOCX body.
use crate::pptx_clone::{
    A, CT, MAX_PART, MimeMap, PKG, R, ROOT_RELATIONSHIPS, Relationship, Relationships, TYPES,
    append_element, content_types, document, edit, escape, expected_hash, hash_file,
    normalized_title, parse_relationships, relationships_path, relative_part, require,
    single_child,
};
use crate::pptx_zip::{Layout, MAX_PACKAGE, PackageEdits, invalid_zip, io_error};
use crate::{ApiError, ApiResult, error, invalid, string};
use roxmltree::{Attribute, Node};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{File, Metadata, OpenOptions, symlink_metadata};
use std::io::{ErrorKind, Read, Write};
use std::ops::Range;
use std::path::{Component, Path, PathBuf};

pub(crate) mod image;
use image::{Format, MAX_IMAGE, image_format, image_info};

#[path = "docx_table.rs"]
pub(super) mod table;

#[path = "docx_body_text.rs"]
pub(super) mod body_text;

#[path = "docx_table_structure.rs"]
pub(super) mod table_structure;

#[path = "docx_photo_insert.rs"]
pub(super) mod insert;

const W: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const WP: &str = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing";
const PIC: &str = "http://schemas.openxmlformats.org/drawingml/2006/picture";
const MC: &str = "http://schemas.openxmlformats.org/markup-compatibility/2006";
const MAIN_MIME: &str =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml";
const SETTINGS_MIME: &str =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml";
const RELS_MIME: &str = "application/vnd.openxmlformats-package.relationships+xml";
const MAX_PHOTOS: usize = 1024;
const QUARTER_TURN: i32 = 5_400_000;
const FULL_TURN: i32 = 4 * QUARTER_TURN;

pub(super) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let path = requested_path(request.get("sourcePath"), true)?;
    let source_sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(&path, source_sha)?;
    let package = Package::read(&mut source)?;
    verify_source(&mut source, &path, source_sha)?;
    let photos = package
        .photos
        .iter()
        .enumerate()
        .map(|(index, photo)| {
            let mut item = json!({
                "index": index,
                "mediaPart": photo.media_part,
                "mediaSha256": photo.media_sha,
                "format": photo.format.name(),
            });
            if let Some(title) = &photo.title {
                item["title"] = json!(title);
            }
            item
        })
        .collect::<Vec<_>>();
    Ok(json!({"sourceSha256":source_sha,"photos":photos}))
}

pub(super) fn replace(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = requested_path(request.get("sourcePath"), true)?;
    let output_path = requested_path(request.get("outputPath"), true)?;
    let asset_path = requested_path(request.get("assetPath"), false)?;
    let parent = source_path.parent().ok_or_else(invalid)?;
    if output_path.parent() != Some(parent) || asset_path.parent() != Some(parent) {
        return Err(invalid());
    }
    let source_sha = expected_hash(request.get("sourceSha256"))?;
    let asset_sha = expected_hash(request.get("assetSha256"))?;
    let index = photo_index(request)?;
    let mut source = open_source(&source_path, source_sha)?;
    require_fresh_output(&output_path)?;
    let package = Package::read(&mut source)?;
    let selected = package.photos.get(index).ok_or_else(invalid)?;
    if selected.media_sha == asset_sha {
        return Err(invalid());
    }
    let (bytes, format, _, _) = read_asset(&asset_path, asset_sha)?;
    let (id, media_part, mut edits) = package.plan_media(bytes, format)?;
    edits.changed.insert(
        package.main_part.clone(),
        edit(&package.main_xml, vec![(selected.embed_range.clone(), id)])?,
    );
    let output_sha = package.write_candidate(
        source,
        (&source_path, &output_path),
        source_sha,
        &edits,
        |written| {
            require(written.photos.len() == package.photos.len())?;
            for (position, (before, after)) in
                package.photos.iter().zip(&written.photos).enumerate()
            {
                if position == index {
                    require(
                        after.id == before.id
                            && after.title == before.title
                            && after.media_part == media_part
                            && after.media_sha == asset_sha
                            && after.format == format,
                    )?;
                } else {
                    require(after.same_picture(before))?;
                }
            }
            Ok(())
        },
    )?;
    Ok(json!({
        "sourceSha256":source_sha,"outputSha256":output_sha,"photoIndex":index,"mediaSha256":asset_sha,
    }))
}

pub(super) fn delete(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 5 {
        return Err(invalid());
    }
    let source_path = requested_path(request.get("sourcePath"), true)?;
    let output_path = requested_path(request.get("outputPath"), true)?;
    if source_path.parent() != output_path.parent() {
        return Err(invalid());
    }
    let source_sha = expected_hash(request.get("sourceSha256"))?;
    let index = photo_index(request)?;
    let mut source = open_source(&source_path, source_sha)?;
    require_fresh_output(&output_path)?;
    let package = Package::read(&mut source)?;
    let selected = package.photos.get(index).ok_or_else(invalid)?;
    let remaining = package.photos.len() - 1;
    let mut edits = PackageEdits::default();
    edits.changed.insert(
        package.main_part.clone(),
        edit(
            &package.main_xml,
            vec![(selected.drawing_range.clone(), String::new())],
        )?,
    );
    let output_sha = package.write_candidate(
        source,
        (&source_path, &output_path),
        source_sha,
        &edits,
        |written| {
            let surviving = package.photos[..index]
                .iter()
                .chain(&package.photos[index + 1..]);
            require(
                written.photos.len() == remaining
                    && surviving
                        .zip(&written.photos)
                        .all(|(before, after)| after.same_picture(before)),
            )
        },
    )?;
    Ok(json!({
        "sourceSha256":source_sha,"outputSha256":output_sha,"photoIndex":index,
        "mediaSha256":selected.media_sha,"remainingPhotoCount":remaining,
    }))
}

pub(super) fn rotate(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 5 {
        return Err(invalid());
    }
    let source_path = requested_path(request.get("sourcePath"), true)?;
    let output_path = requested_path(request.get("outputPath"), true)?;
    if source_path.parent() != output_path.parent() {
        return Err(invalid());
    }
    let source_sha = expected_hash(request.get("sourceSha256"))?;
    let index = photo_index(request)?;
    let mut source = open_source(&source_path, source_sha)?;
    require_fresh_output(&output_path)?;
    let package = Package::read(&mut source)?;
    let selected = package.photos.get(index).ok_or_else(invalid)?;
    let rotation = selected
        .rotation
        .as_ref()
        .ok_or_else(unsupported_document)?;
    let angle = (rotation.angle.rem_euclid(FULL_TURN) + QUARTER_TURN) % FULL_TURN;
    let value = if rotation.span.is_empty() {
        format!(" rot=\"{angle}\"")
    } else {
        angle.to_string()
    };
    let mut edits = PackageEdits::default();
    edits.changed.insert(
        package.main_part.clone(),
        edit(&package.main_xml, vec![(rotation.span.clone(), value)])?,
    );
    let output_sha = package.write_candidate(
        source,
        (&source_path, &output_path),
        source_sha,
        &edits,
        |written| {
            require(
                written.photos.len() == package.photos.len()
                    && written
                        .photos
                        .iter()
                        .zip(&package.photos)
                        .all(|(after, before)| after.same_picture(before))
                    && written.photos[index]
                        .rotation
                        .as_ref()
                        .is_some_and(|rotation| rotation.angle == angle),
            )
        },
    )?;
    Ok(json!({
        "sourceSha256":source_sha,"outputSha256":output_sha,"photoIndex":index,
        "mediaSha256":selected.media_sha,
    }))
}

fn photo_index(request: &Map<String, Value>) -> ApiResult<usize> {
    request
        .get("photoIndex")
        .and_then(Value::as_u64)
        .and_then(|n| usize::try_from(n).ok())
        .filter(|n| *n < MAX_PHOTOS)
        .ok_or_else(invalid)
}

struct Photo {
    id: u32,
    title: Option<String>,
    drawing_range: Range<usize>,
    embed_range: Range<usize>,
    media_part: String,
    media_sha: String,
    format: Format,
    rotation: Option<PhotoRotation>,
}

struct PhotoRotation {
    angle: i32,
    span: Range<usize>,
}

impl Photo {
    fn same_picture(&self, other: &Self) -> bool {
        self.id == other.id
            && self.title == other.title
            && self.media_part == other.media_part
            && self.media_sha == other.media_sha
            && self.format == other.format
    }
}

struct Package {
    layout: Layout,
    main_part: String,
    main_rels_part: String,
    main_xml: String,
    rels_xml: String,
    types_xml: String,
    defaults: MimeMap,
    relation_ids: BTreeSet<String>,
    photos: Vec<Photo>,
    track_revisions: bool,
}

impl Package {
    fn read(file: &mut File) -> ApiResult<Self> {
        let layout = Layout::parse(file)?;
        if layout.entries.iter().any(|entry| {
            entry.name.eq_ignore_ascii_case("_xmlsignatures")
                || entry
                    .name
                    .to_ascii_lowercase()
                    .starts_with("_xmlsignatures/")
        }) {
            return Err(unsupported_document());
        }
        let types_xml = read_xml(&layout, file, TYPES)?;
        let (defaults, overrides) = content_types(&types_xml, &layout)?;
        let root_rels = read_xml(&layout, file, ROOT_RELATIONSHIPS)?;
        let root_rels = parse_relationships(&root_rels, "", &layout)?;
        let main_part = relationship(&root_rels, "officeDocument")?
            .filter(|rel| mime_for(&rel.target, &defaults, &overrides) == Some(MAIN_MIME))
            .ok_or_else(unsupported_document)?
            .target
            .clone();
        let main_rels_part = relationships_path(&main_part);
        let (rels_xml, rels) = if layout.entry(&main_rels_part).is_some() {
            let xml = read_xml(&layout, file, &main_rels_part)?;
            let rels = parse_relationships(&xml, &main_part, &layout)?;
            (xml, rels)
        } else {
            (String::new(), BTreeMap::new())
        };
        let mut track_revisions = false;
        if let Some(settings) = relationship(&rels, "settings")? {
            require(mime_for(&settings.target, &defaults, &overrides) == Some(SETTINGS_MIME))?;
            let xml = read_xml(&layout, file, &settings.target)?;
            let xml = document(&xml)?;
            require(xml.root_element().has_tag_name((W, "settings")))?;
            if xml.root_element().descendants().any(|node| {
                node.has_tag_name((W, "writeProtection"))
                    || (node.has_tag_name((W, "documentProtection"))
                        && !matches!(
                            node.attribute((W, "enforcement")),
                            Some("0" | "false" | "off")
                        ))
            }) {
                return Err(unsupported_document());
            }
            track_revisions = children(xml.root_element(), W, "trackRevisions")
                .any(|node| !matches!(node.attribute((W, "val")), Some("0" | "false" | "off")));
        }
        let main_xml = read_xml(&layout, file, &main_part)?;
        let xml = document(&main_xml)?;
        let root = xml.root_element();
        if !root.has_tag_name((W, "document")) {
            return Err(unsupported_document());
        }
        let body = single_child(root, W, "body")?;
        let mut relation_ids = rels.keys().cloned().collect::<BTreeSet<_>>();
        let mut drawing_ids = BTreeMap::new();
        for node in root.descendants().filter(Node::is_element) {
            for attr in node.attributes().filter(|attr| attr.namespace() == Some(R)) {
                relation_ids.insert(attr.value().to_owned());
            }
            if let Some(id) = drawing_id(node) {
                *drawing_ids.entry(id).or_insert(0) += 1;
            }
        }
        let mut photos = Vec::new();
        let mut media_cache = BTreeMap::new();
        for drawing in children(body, W, "p")
            .flat_map(|p| children(p, W, "r"))
            .flat_map(|r| children(r, W, "drawing"))
            .filter(|drawing| drawing.children().filter(Node::is_element).count() == 1)
        {
            let Some(inline) = children(drawing, WP, "inline").next() else {
                continue;
            };
            let Some((id, title, embed, picture)) = inline_photo(inline, &drawing_ids) else {
                continue;
            };
            let Some(rel) = rels
                .get(embed.value())
                .filter(|rel| !rel.external && is_relationship_type(rel, "image"))
            else {
                continue;
            };
            let media = match media_cache.entry(rel.target.as_str()) {
                std::collections::btree_map::Entry::Occupied(entry) => entry.into_mut(),
                std::collections::btree_map::Entry::Vacant(entry) => entry.insert(read_media(
                    &layout,
                    file,
                    &rel.target,
                    mime_for(&rel.target, &defaults, &overrides),
                )?),
            };
            if let Some((format, sha)) = media {
                require(photos.len() < MAX_PHOTOS)?;
                photos.push(Photo {
                    id,
                    title,
                    drawing_range: drawing.range(),
                    embed_range: embed.range_value(),
                    media_part: rel.target.clone(),
                    media_sha: sha.clone(),
                    format: *format,
                    rotation: photo_rotation(picture, &main_xml),
                });
            }
        }
        Ok(Self {
            layout,
            main_part,
            main_rels_part,
            main_xml,
            rels_xml,
            types_xml,
            defaults,
            relation_ids,
            photos,
            track_revisions,
        })
    }

    fn plan_media(
        &self,
        asset: Vec<u8>,
        format: Format,
    ) -> ApiResult<(String, String, PackageEdits)> {
        let extension = format.extension();
        let (id, part) = (1..=self.relation_ids.len() + self.layout.entries.len() + 1)
            .map(|n| {
                (
                    format!("PivPhoto{n}"),
                    format!("word/media/piv-photo-{n}.{extension}"),
                )
            })
            .find(|(id, part)| {
                !self.relation_ids.contains(id) && !self.layout.contains_casefold(part)
            })
            .ok_or_else(invalid_zip)?;
        let mut edits = PackageEdits::default();
        let target = escape(&relative_part(&self.main_part, &part));
        let link = format!(
            "<Relationship xmlns=\"{PKG}\" Id=\"{id}\" Type=\"{R}/image\" Target=\"{target}\"/>"
        );
        let mut overrides = String::new();
        if self.rels_xml.is_empty() {
            edits.added.insert(
                self.main_rels_part.clone(),
                format!("<Relationships xmlns=\"{PKG}\">{link}</Relationships>").into_bytes(),
            );
            if self.defaults.get("rels").map(String::as_str) != Some(RELS_MIME) {
                let part_name = escape(&self.main_rels_part);
                overrides.push_str(&format!(
                    "<Override xmlns=\"{CT}\" PartName=\"/{part_name}\" ContentType=\"{RELS_MIME}\"/>"
                ));
            }
        } else {
            edits.changed.insert(
                self.main_rels_part.clone(),
                append_element(&self.rels_xml, link)?,
            );
        }
        let mime = format.mime();
        if self.defaults.get(extension).map(String::as_str) != Some(mime) {
            let part_name = escape(&part);
            overrides.push_str(&format!(
                "<Override xmlns=\"{CT}\" PartName=\"/{part_name}\" ContentType=\"{mime}\"/>"
            ));
        }
        if !overrides.is_empty() {
            edits.changed.insert(
                TYPES.to_owned(),
                append_element(&self.types_xml, overrides)?,
            );
        }
        edits.added.insert(part.clone(), asset);
        Ok((id, part, edits))
    }

    fn write_candidate(
        &self,
        mut source: File,
        (source_path, output_path): (&Path, &Path),
        source_sha: &str,
        edits: &PackageEdits,
        verify: impl FnOnce(&Self) -> ApiResult<()>,
    ) -> ApiResult<String> {
        let parent = output_path.parent().ok_or_else(invalid)?;
        let mut candidate = tempfile::NamedTempFile::new_in(parent).map_err(io_error)?;
        self.layout.rewrite(&mut source, &mut candidate, edits)?;
        candidate.flush().map_err(io_error)?;
        candidate.as_file().sync_all().map_err(io_error)?;
        let written = Self::read(candidate.as_file_mut())?;
        self.layout.verify_unchanged(&written.layout, edits)?;
        written.layout.verify_payloads(candidate.as_file_mut())?;
        for (part, bytes) in edits.changed.iter().chain(&edits.added) {
            require(
                written
                    .layout
                    .read(candidate.as_file_mut(), part, bytes.len())?
                    == *bytes,
            )?;
        }
        verify(&written)?;
        let output_sha = hash_file(candidate.as_file_mut())?;
        verify_source(&mut source, source_path, source_sha)?;
        candidate
            .persist_noclobber(output_path)
            .map_err(|failure| {
                if failure.error.kind() == ErrorKind::AlreadyExists {
                    output_exists()
                } else {
                    io_error(failure.error)
                }
            })?;
        Ok(output_sha)
    }
}

fn children<'a, 'input>(
    node: Node<'a, 'input>,
    namespace: &'static str,
    local: &'static str,
) -> impl Iterator<Item = Node<'a, 'input>> {
    node.children()
        .filter(move |child| child.has_tag_name((namespace, local)))
}

fn drawing_id(node: Node<'_, '_>) -> Option<u32> {
    if !node.has_tag_name((WP, "docPr")) {
        return None;
    }
    node.attribute("id")
        .filter(|value| value.bytes().all(|byte| byte.is_ascii_digit()))?
        .parse()
        .ok()
}

fn inline_photo<'a, 'input>(
    inline: Node<'a, 'input>,
    drawing_ids: &BTreeMap<u32, usize>,
) -> Option<(u32, Option<String>, Attribute<'a, 'input>, Node<'a, 'input>)> {
    let doc_pr = single_child(inline, WP, "docPr").ok()?;
    let id = drawing_id(doc_pr)?;
    if drawing_ids.get(&id) != Some(&1) {
        return None;
    }
    let graphic = single_child(inline, A, "graphic").ok()?;
    let data = single_child(graphic, A, "graphicData").ok()?;
    if data.attribute("uri") != Some(PIC) {
        return None;
    }
    let picture = single_child(data, PIC, "pic").ok()?;
    let fill = single_child(picture, PIC, "blipFill").ok()?;
    let blip = single_child(fill, A, "blip").ok()?;
    let embed = blip.attribute_node((R, "embed"))?;
    if inline.descendants().filter(Node::is_element).any(|node| {
        node.has_tag_name((MC, "AlternateContent"))
            || node.tag_name().name() == "svgBlip"
            || node.attributes().any(|attr| {
                attr.namespace() == Some(R)
                    && !(attr.name() == "embed" && node == blip)
                    && !(attr.name() == "id"
                        && (node.has_tag_name((A, "hlinkClick"))
                            || node.has_tag_name((A, "hlinkHover"))))
            })
    }) {
        return None;
    }
    let title = ["descr", "title", "name"]
        .into_iter()
        .filter_map(|name| doc_pr.attribute(name))
        .find_map(normalized_title);
    Some((id, title, embed, picture))
}

fn photo_rotation(picture: Node<'_, '_>, xml: &str) -> Option<PhotoRotation> {
    let properties = single_child(picture, PIC, "spPr").ok()?;
    let transform = single_child(properties, A, "xfrm").ok()?;
    if let Some(attribute) = transform.attribute_node("rot") {
        let span = attribute.range_value();
        let raw = xml.get(span.clone())?;
        let digits = raw.trim_ascii();
        let angle = digits.parse::<i32>().ok()?;
        if angle != attribute.value().trim_ascii().parse::<i32>().ok()? {
            return None;
        }
        let start = span.start + raw.len() - raw.trim_ascii_start().len();
        return Some(PhotoRotation {
            angle,
            span: start..start + digits.len(),
        });
    }
    let range = transform.range();
    let name_start = range.start + 1;
    let name_end = name_start
        + xml
            .get(name_start..range.end)?
            .find([' ', '\t', '\r', '\n', '/', '>'])?;
    Some(PhotoRotation {
        angle: 0,
        span: name_end..name_end,
    })
}

fn relationship<'a>(rels: &'a Relationships, kind: &str) -> ApiResult<Option<&'a Relationship>> {
    let mut matches = rels.values().filter(|rel| is_relationship_type(rel, kind));
    let found = matches.next();
    require(matches.next().is_none() && found.is_none_or(|rel| !rel.external))?;
    Ok(found)
}

fn is_relationship_type(rel: &Relationship, kind: &str) -> bool {
    rel.kind.rsplit_once('/') == Some((R, kind))
}

fn mime_for<'a>(part: &str, defaults: &'a MimeMap, overrides: &'a MimeMap) -> Option<&'a str> {
    overrides
        .get(part)
        .or_else(|| {
            let name = part.rsplit('/').next()?;
            let (_, extension) = name.rsplit_once('.')?;
            defaults.get(&extension.to_ascii_lowercase())
        })
        .map(String::as_str)
}

fn read_xml(layout: &Layout, file: &mut File, part: &str) -> ApiResult<String> {
    String::from_utf8(layout.read(file, part, MAX_PART)?).map_err(|_| invalid_zip())
}

fn read_media(
    layout: &Layout,
    file: &mut File,
    part: &str,
    mime: Option<&str>,
) -> ApiResult<Option<(Format, String)>> {
    if !part.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'[' | b']' | b'/' | b'-')
    }) || !matches!(mime, Some("image/png" | "image/jpeg"))
        || layout
            .entry(part)
            .is_none_or(|entry| entry.size > MAX_IMAGE)
    {
        return Ok(None);
    }
    let bytes = layout.read(file, part, MAX_IMAGE)?;
    Ok(image_format(&bytes)
        .filter(|format| Some(format.mime()) == mime)
        .map(|format| (format, hash_bytes(&bytes))))
}

pub(crate) fn read_asset(path: &Path, expected: &str) -> ApiResult<(Vec<u8>, Format, u32, u32)> {
    let file = open_regular(path, MAX_IMAGE)?;
    let mut bytes = Vec::new();
    file.take(MAX_IMAGE as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(io_error)?;
    if hash_bytes(&bytes) != expected {
        return Err(error("asset_changed", "The image asset hash changed"));
    }
    let (format, width, height) = image_info(&bytes).ok_or_else(invalid)?;
    Ok((bytes, format, width, height))
}

fn hash_bytes(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn requested_path(value: Option<&Value>, docx: bool) -> ApiResult<PathBuf> {
    let path = Path::new(string(value)?);
    if !path.is_absolute()
        || path.components().any(|part| {
            matches!(part, Component::ParentDir | Component::CurDir)
                || matches!(part, Component::Normal(name) if name.to_str().is_none_or(|name|
                    name.ends_with(['.', ' ']) || name.chars().any(|c| c.is_control() || c == ':')))
        })
        || (docx
            && !path
                .extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case("docx")))
    {
        return Err(invalid());
    }
    let name = path.file_name().ok_or_else(invalid)?;
    let parent = path.parent().ok_or_else(invalid)?;
    for directory in parent.ancestors() {
        let metadata = symlink_metadata(directory).map_err(io_error)?;
        if !metadata.is_dir() || is_reparse_point(&metadata) {
            return Err(invalid());
        }
    }
    Ok(parent.canonicalize().map_err(io_error)?.join(name))
}

fn is_reparse_point(metadata: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

fn open_regular(path: &Path, limit: usize) -> ApiResult<File> {
    let metadata = symlink_metadata(path).map_err(io_error)?;
    if !metadata.is_file() || is_reparse_point(&metadata) || metadata.len() > limit as u64 {
        return Err(invalid());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options.open(path).map_err(io_error)?;
    let opened = file.metadata().map_err(io_error)?;
    if !opened.is_file() || is_reparse_point(&opened) || opened.len() > limit as u64 {
        return Err(invalid());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if opened.dev() != metadata.dev() || opened.ino() != metadata.ino() {
            return Err(invalid());
        }
    }
    Ok(file)
}

fn open_source(path: &Path, expected: &str) -> ApiResult<File> {
    let mut file = open_regular(path, MAX_PACKAGE)?;
    if hash_file(&mut file)? != expected {
        return Err(source_changed());
    }
    Ok(file)
}

fn verify_source(source: &mut File, path: &Path, expected: &str) -> ApiResult<()> {
    if hash_file(source)? != expected {
        return Err(source_changed());
    }
    open_source(path, expected)?;
    Ok(())
}

fn require_fresh_output(path: &Path) -> ApiResult<()> {
    match symlink_metadata(path) {
        Ok(_) => Err(output_exists()),
        Err(failure) if failure.kind() == ErrorKind::NotFound => Ok(()),
        Err(failure) => Err(io_error(failure)),
    }
}

fn output_exists() -> ApiError {
    error(
        "output_exists",
        "The private DOCX destination already exists",
    )
}

fn source_changed() -> ApiError {
    error("source_changed", "The DOCX source hash changed")
}

fn unsupported_document() -> ApiError {
    error("unsupported_document", "This DOCX cannot be safely edited")
}
