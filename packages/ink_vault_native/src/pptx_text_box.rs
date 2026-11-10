use super::{
    A, Deck, MAX_PACKAGE, MAX_PART, MAX_SLIDES, MAX_XML, P, PRESENTATION, document, edit, escape,
    expected_hash, ignorable_or_element, open_source, path, require, require_fresh_output,
    single_child, unsigned,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid, string};
use roxmltree::Node;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::fmt::Write;

const MAX_TEXT_UNITS: usize = 600;
const MAX_TEXT_LINES: usize = 8;
const EMU_PER_POINT: u64 = 12_700;

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    inspect_shapes(request, None)
}

pub(crate) fn inspect_presets(request: &Map<String, Value>) -> ApiResult<Value> {
    inspect_shapes(
        request,
        Some(PresetStyle {
            preset: Preset::RoundedRectangle,
            fill: Some("000000"),
            line: "000000",
        }),
    )
}

fn inspect_shapes(
    request: &Map<String, Value>,
    style: Option<PresetStyle<'_>>,
) -> ApiResult<Value> {
    inspect_insertable_slides(request, |deck, xml, size| {
        insertion_site_with_references(xml, style.is_some()).is_ok_and(|site| {
            let growth = TextBox::new(size, Placement::Top, 12, "x", style)
                .xml(site.id, "x")
                .len();
            has_room(deck, xml, growth)
        })
    })
}

pub(super) fn inspect_insertable_slides(
    request: &Map<String, Value>,
    can_add: impl Fn(&Deck, &str, (u64, u64)) -> bool,
) -> ApiResult<Value> {
    if request.len() != 3 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    let size = slide_size(&deck)?;
    let sections = deck.sections()?;
    let section_names = sections
        .iter()
        .flat_map(|section| std::iter::repeat_n(section.title.as_deref(), section.entries.len()));
    let slides = deck
        .slides
        .iter()
        .zip(section_names.chain(std::iter::repeat(None)))
        .enumerate()
        .map(|(index, (slide, section_name))| {
            let addable = can_add(&deck, &deck.xml[&slide.part], size);
            let mut row = json!({"index":index,"hidden":slide.hidden,"canAdd":addable});
            if let Some(title) = &slide.title {
                row["title"] = json!(title);
            }
            if let Some(name) = section_name {
                row["sectionName"] = json!(name);
            }
            row
        })
        .collect::<Vec<_>>();
    open_source(source_path, sha)?;
    Ok(json!({"sourceSha256":sha,"slideCount":slides.len(),"slides":slides}))
}

pub(crate) fn add(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 8 {
        return Err(invalid());
    }
    add_shape(request, None)
}

pub(crate) fn add_preset(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 11 {
        return Err(invalid());
    }
    let preset = Preset::read(request.get("preset"))?;
    let fill = match request.get("fillColor") {
        Some(Value::Null) => None,
        value => Some(rgb(value)?),
    };
    let line = rgb(request.get("lineColor"))?;
    add_shape(request, Some(PresetStyle { preset, fill, line }))
}

fn add_shape(request: &Map<String, Value>, style: Option<PresetStyle<'_>>) -> ApiResult<Value> {
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let slide_index = request
        .get("slideIndex")
        .and_then(Value::as_u64)
        .filter(|&value| value < MAX_SLIDES as u64)
        .ok_or_else(invalid)? as usize;
    let text = text_content(request.get("text"), style.is_some())?;
    let placement = Placement::read(request.get("placement"))?;
    let font_size = request
        .get("fontSize")
        .and_then(Value::as_u64)
        .filter(|size| (12..=40).contains(size))
        .ok_or_else(invalid)?;

    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    let shape = TextBox::new(slide_size(&deck)?, placement, font_size, text, style);
    let slide = deck.slides.get(slide_index).ok_or_else(invalid)?;
    let source_xml = &deck.xml[&slide.part];
    let site = insertion_site_with_references(source_xml, style.is_some())?;
    let xml = shape.xml(site.id, text);
    require(has_room(&deck, source_xml, xml.len()))?;
    let mut edits = PackageEdits::default();
    edits.changed.insert(
        slide.part.clone(),
        edit(source_xml, vec![(site.offset..site.offset, xml)])?,
    );
    let output_sha = deck.write_candidate(
        source,
        (source_path, output_path),
        sha,
        &edits,
        |verified| {
            require(verified.slides.len() == deck.slides.len())?;
            let selected = &verified.slides[slide_index];
            require(
                selected.part == slide.part
                    && selected.identity == slide.identity
                    && selected.hidden == slide.hidden,
            )?;
            shape.verify(&verified.xml[&slide.part], site.id, text)
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":slide_index,"shapeId":site.id,
    }))
}

fn text_content(value: Option<&Value>, allow_empty: bool) -> ApiResult<&str> {
    let text = string(value)?;
    if (!allow_empty || !text.is_empty()) && text.trim().is_empty()
        || text.encode_utf16().count() > MAX_TEXT_UNITS
        || text.split('\n').count() > MAX_TEXT_LINES
        || text.chars().any(|character| {
            (character.is_control() && character != '\n')
                || matches!(character, '\u{2028}' | '\u{2029}' | '\u{fffe}' | '\u{ffff}')
        })
    {
        return Err(invalid());
    }
    Ok(text)
}

fn rgb(value: Option<&Value>) -> ApiResult<&str> {
    let color = string(value)?;
    if color.len() != 6
        || !color
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte))
    {
        return Err(invalid());
    }
    Ok(color)
}

#[derive(Clone, Copy)]
enum Preset {
    Rectangle,
    RoundedRectangle,
    Ellipse,
    RightArrow,
}

impl Preset {
    fn read(value: Option<&Value>) -> ApiResult<Self> {
        match string(value)? {
            "rectangle" => Ok(Self::Rectangle),
            "roundedRectangle" => Ok(Self::RoundedRectangle),
            "ellipse" => Ok(Self::Ellipse),
            "rightArrow" => Ok(Self::RightArrow),
            _ => Err(invalid()),
        }
    }

    fn drawingml(self) -> (&'static str, &'static str) {
        match self {
            Self::Rectangle => ("Rectangle", "rect"),
            Self::RoundedRectangle => ("Rounded Rectangle", "roundRect"),
            Self::Ellipse => ("Ellipse", "ellipse"),
            Self::RightArrow => ("Right Arrow", "rightArrow"),
        }
    }

    fn text_area(self) -> (u64, u64) {
        match self {
            Self::Rectangle | Self::RoundedRectangle => (90, 85),
            Self::Ellipse => (65, 65),
            Self::RightArrow => (55, 50),
        }
    }
}

#[derive(Clone, Copy)]
struct PresetStyle<'a> {
    preset: Preset,
    fill: Option<&'a str>,
    line: &'a str,
}

impl PresetStyle<'_> {
    fn text_color(self) -> Option<&'static str> {
        self.fill.map(|fill| {
            let channel = |offset| {
                let value = f64::from(
                    u8::from_str_radix(&fill[offset..offset + 2], 16)
                        .expect("validated RGB channel"),
                ) / 255.0;
                if value <= 0.04045 {
                    value / 12.92
                } else {
                    ((value + 0.055) / 1.055).powf(2.4)
                }
            };
            let luminance = 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
            // At this luminance black and white have the same contrast ratio.
            if luminance < 0.17913 {
                "FFFFFF"
            } else {
                "000000"
            }
        })
    }
}

enum Placement {
    Top,
    Middle,
    Bottom,
}

impl Placement {
    fn read(value: Option<&Value>) -> ApiResult<Self> {
        match string(value)? {
            "top" => Ok(Self::Top),
            "middle" => Ok(Self::Middle),
            "bottom" => Ok(Self::Bottom),
            _ => Err(invalid()),
        }
    }
}

pub(super) fn slide_size(deck: &Deck) -> ApiResult<(u64, u64)> {
    let presentation = document(&deck.xml[PRESENTATION])?;
    let root = presentation.root_element();
    require(
        !root
            .children()
            .any(|child| child.has_tag_name((P, "modifyVerifier"))),
    )?;
    let size = single_child(root, P, "sldSz")?;
    let width = unsigned(size.attribute("cx").ok_or_else(invalid_zip)?)?;
    let height = unsigned(size.attribute("cy").ok_or_else(invalid_zip)?)?;
    require(
        [width, height]
            .iter()
            .all(|dimension| (914_400..=51_206_400).contains(dimension)),
    )?;
    Ok((width.into(), height.into()))
}

pub(super) fn has_room(deck: &Deck, slide_xml: &str, growth: usize) -> bool {
    slide_xml.len() + growth <= MAX_PART
        && deck.xml_bytes + growth <= MAX_XML
        && deck.layout.expanded + growth <= MAX_PACKAGE
}

pub(super) struct InsertionSite {
    pub(super) offset: usize,
    pub(super) id: u32,
}

pub(super) fn shape_tree<'a, 'input>(root: Node<'a, 'input>) -> ApiResult<Node<'a, 'input>> {
    single_child(single_child(root, P, "cSld")?, P, "spTree")
}

pub(super) fn insertion_site(xml: &str) -> ApiResult<InsertionSite> {
    insertion_site_with_references(xml, false)
}

pub(super) fn insertion_site_with_references(
    xml: &str,
    reserve_references: bool,
) -> ApiResult<InsertionSite> {
    let doc = document(xml)?;
    let root = doc.root_element();
    let tree = shape_tree(root)?;
    require(tree.children().all(ignorable_or_element))?;
    let mut children = tree.children().filter(Node::is_element);
    require(
        children
            .next()
            .is_some_and(|node| node.has_tag_name((P, "nvGrpSpPr"))),
    )?;
    require(
        children
            .next()
            .is_some_and(|node| node.has_tag_name((P, "grpSpPr"))),
    )?;
    let mut extensions = children.filter(|node| node.has_tag_name((P, "extLst")));
    let offset = if let Some(extension) = extensions.next() {
        require(extensions.next().is_none() && tree.last_element_child() == Some(extension))?;
        extension.range().start
    } else {
        let range = tree.range();
        xml[range.clone()].rfind("</").ok_or_else(invalid_zip)? + range.start
    };
    let mut ids = BTreeSet::new();
    for node in root.descendants().filter(Node::is_element) {
        if node.has_tag_name((P, "cNvPr")) {
            let inserted = ids.insert(unsigned(node.attribute("id").ok_or_else(invalid_zip)?)?);
            if reserve_references {
                require(inserted)?;
            }
        }
    }
    if reserve_references {
        for node in root.descendants().filter(Node::is_element) {
            let connector = node.has_tag_name((A, "stCxn")) || node.has_tag_name((A, "endCxn"));
            for attribute in node.attributes().filter(|attribute| {
                let name = attribute.name();
                name.eq_ignore_ascii_case("spid")
                    || name.eq_ignore_ascii_case("shapeId")
                    || (connector && name == "id")
            }) {
                if let Ok(id) = unsigned(attribute.value().trim()) {
                    ids.insert(id);
                }
            }
        }
    }
    let id = (1..=u32::MAX)
        .find(|id| !ids.contains(id))
        .ok_or_else(invalid_zip)?;
    Ok(InsertionSite { offset, id })
}

struct TextBox<'a> {
    x: u64,
    y: u64,
    width: u64,
    height: u64,
    text_size: u64,
    font_scale: u64,
    style: Option<PresetStyle<'a>>,
}

impl<'a> TextBox<'a> {
    fn new(
        (slide_width, slide_height): (u64, u64),
        placement: Placement,
        font_size: u64,
        text: &str,
        style: Option<PresetStyle<'a>>,
    ) -> Self {
        let margin = slide_height * 6 / 100;
        let available_height = slide_height - 2 * margin;
        let font = font_size * EMU_PER_POINT;
        let estimate_height = |width: u64| {
            let columns = (width / font).max(1) as usize;
            let lines = text
                .split('\n')
                .map(|line| line.chars().count().div_ceil(columns).max(1))
                .sum::<usize>() as u64;
            // Allow one em per character and room for line spacing before native wrapping.
            font * lines * 5 / 4
        };
        let (width, height, text_height, estimated_height) = if let Some(style) = style {
            let width = slide_width * 46 / 100;
            let height = slide_height * 29 / 100;
            let (horizontal, vertical) = style.preset.text_area();
            (
                width,
                height,
                height * vertical / 100,
                estimate_height(width * horizontal / 100),
            )
        } else {
            let width = slide_width - 2 * (slide_width * 7 / 100);
            let estimate = estimate_height(width);
            let height = (estimate + margin / 2).clamp(slide_height / 6, available_height);
            (width, height, available_height, estimate)
        };
        let y = match placement {
            Placement::Top => margin,
            Placement::Middle => (slide_height - height) / 2,
            Placement::Bottom => slide_height - margin - height,
        };
        let font_scale = (text_height * 100_000 / estimated_height).clamp(1, 100_000);
        Self {
            x: (slide_width - width) / 2,
            y,
            width,
            height,
            text_size: font_size * 100,
            font_scale,
            style,
        }
    }

    fn xml(&self, id: u32, text: &str) -> String {
        let Self {
            x,
            y,
            width,
            height,
            text_size,
            font_scale,
            style,
        } = self;
        let (name, geometry, textbox) = match style {
            Some(style) => {
                let (name, geometry) = style.preset.drawingml();
                (name, geometry, "")
            }
            None => ("TextBox", "rect", " txBox=\"1\""),
        };
        let mut xml = format!(
            "<p:sp xmlns:p=\"{P}\" xmlns:a=\"{A}\"><p:nvSpPr><p:cNvPr id=\"{id}\" name=\"{name} {id}\"/><p:cNvSpPr{textbox}/><p:nvPr/></p:nvSpPr>\
             <p:spPr><a:xfrm><a:off x=\"{x}\" y=\"{y}\"/><a:ext cx=\"{width}\" cy=\"{height}\"/></a:xfrm>\
             <a:prstGeom prst=\"{geometry}\"><a:avLst/></a:prstGeom>"
        );
        if let Some(style) = style {
            match style.fill {
                Some(fill) => write!(
                    xml,
                    "<a:solidFill><a:srgbClr val=\"{fill}\"/></a:solidFill>"
                )
                .expect("writing XML into String"),
                None => xml.push_str("<a:noFill/>"),
            }
            write!(xml, "<a:ln w=\"25400\"><a:solidFill><a:srgbClr val=\"{}\"/></a:solidFill><a:prstDash val=\"solid\"/></a:ln>", style.line)
                .expect("writing XML into String");
        } else {
            xml.push_str("<a:noFill/><a:ln><a:noFill/></a:ln>");
        }
        let (anchor, alignment) = if style.is_some() {
            ("ctr", "ctr")
        } else {
            ("t", "l")
        };
        write!(xml, "</p:spPr><p:txBody><a:bodyPr wrap=\"square\" anchor=\"{anchor}\" lIns=\"0\" rIns=\"0\" tIns=\"0\" bIns=\"0\"><a:normAutofit fontScale=\"{font_scale}\"/></a:bodyPr><a:lstStyle/>")
            .expect("writing XML into String");
        let text_color = style.and_then(PresetStyle::text_color);
        for line in text.split('\n') {
            write!(
                xml,
                "<a:p><a:pPr algn=\"{alignment}\" marL=\"0\" indent=\"0\"><a:buNone/></a:pPr>"
            )
            .expect("writing XML into String");
            if !line.is_empty() || style.is_some() {
                write!(xml, "<a:r><a:rPr sz=\"{text_size}\"><a:solidFill>")
                    .expect("writing XML into String");
                if let Some(color) = text_color {
                    write!(xml, "<a:srgbClr val=\"{color}\"/>").expect("writing XML into String");
                } else {
                    xml.push_str("<a:schemeClr val=\"tx1\"/>");
                }
                write!(
                    xml,
                    "</a:solidFill></a:rPr><a:t>{}</a:t></a:r>",
                    escape(line),
                )
                .expect("writing XML into String");
            }
            write!(xml, "<a:endParaRPr sz=\"{text_size}\"/></a:p>")
                .expect("writing XML into String");
        }
        xml.push_str("</p:txBody></p:sp>");
        xml
    }

    fn verify(&self, xml: &str, id: u32, text: &str) -> ApiResult<()> {
        let doc = document(xml)?;
        let root = doc.root_element();
        let tree = shape_tree(root)?;
        let last = tree.last_element_child().ok_or_else(invalid_zip)?;
        let shape = if last.has_tag_name((P, "extLst")) {
            last.prev_sibling_element().ok_or_else(invalid_zip)?
        } else {
            last
        };
        require(shape.has_tag_name((P, "sp")))?;
        let nv = single_child(shape, P, "nvSpPr")?;
        let nv_id = single_child(nv, P, "cNvPr")?;
        let id_matches = |node: Node| {
            node.has_tag_name((P, "cNvPr"))
                && node.attribute("id").and_then(|value| unsigned(value).ok()) == Some(id)
        };
        require(
            id_matches(nv_id) && root.descendants().filter(|&node| id_matches(node)).count() == 1,
        )?;
        let textbox = single_child(nv, P, "cNvSpPr")?.attribute("txBox");
        let properties = single_child(shape, P, "spPr")?;
        if let Some(style) = self.style {
            require(textbox.is_none())?;
            let (_, geometry) = style.preset.drawingml();
            require(single_child(properties, A, "prstGeom")?.attribute("prst") == Some(geometry))?;
            let verify_rgb = |parent, color| {
                let fill = single_child(parent, A, "solidFill")?;
                require(single_child(fill, A, "srgbClr")?.attribute("val") == Some(color))
            };
            if let Some(fill) = style.fill {
                verify_rgb(properties, fill)?;
            } else {
                single_child(properties, A, "noFill")?;
            }
            verify_rgb(single_child(properties, A, "ln")?, style.line)?;
        } else {
            require(textbox == Some("1"))?;
        }
        let transform = single_child(properties, A, "xfrm")?;
        let position = single_child(transform, A, "off")?;
        let size = single_child(transform, A, "ext")?;
        for (node, key, expected) in [
            (position, "x", self.x),
            (position, "y", self.y),
            (size, "cx", self.width),
            (size, "cy", self.height),
        ] {
            require(node.attribute(key).and_then(|value| value.parse().ok()) == Some(expected))?;
        }
        let body = single_child(shape, P, "txBody")?;
        let paragraphs = body.children().filter(|node| node.has_tag_name((A, "p")));
        let lines = paragraphs.map(|paragraph| {
            paragraph
                .descendants()
                .find(|node| node.has_tag_name((A, "t")))
                .and_then(|node| node.text())
                .unwrap_or_default()
        });
        require(lines.eq(text.split('\n')))
    }
}
