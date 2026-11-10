use super::text_box::{
    InsertionSite, has_room, insertion_site_with_references, inspect_insertable_slides, shape_tree,
    slide_size,
};
use super::{
    A, Deck, MAX_SLIDES, P, document, edit, expected_hash, open_source, path, require,
    require_fresh_output, single_child,
};
use crate::pptx_zip::{PackageEdits, invalid_zip};
use crate::{ApiResult, invalid};
use roxmltree::Node;
use serde_json::{Map, Value, json};
use std::fmt::Write;

const TABLE_URI: &str = "http://schemas.openxmlformats.org/drawingml/2006/table";
const MAX_DIMENSION: u64 = 10;
const EMU_PER_HUNDREDTH_MM: u64 = 360;
const EMU_PER_POINT: u64 = 12_700;

pub(crate) fn inspect(request: &Map<String, Value>) -> ApiResult<Value> {
    inspect_insertable_slides(request, |deck, xml, size| {
        insertion_site_with_references(xml, true)
            .is_ok_and(|site| has_room(deck, xml, Table::new(size, 1, 1).xml(site.id).len()))
    })
}

pub(crate) fn add(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 7 {
        return Err(invalid());
    }
    let source_path = path(request.get("sourcePath"))?;
    let output_path = path(request.get("outputPath"))?;
    let sha = expected_hash(request.get("sourceSha256"))?;
    let slide_index = request
        .get("slideIndex")
        .and_then(Value::as_u64)
        .filter(|&value| value < MAX_SLIDES as u64)
        .ok_or_else(invalid)? as usize;
    let dimension = |key| {
        request
            .get(key)
            .and_then(Value::as_u64)
            .filter(|value| (1..=MAX_DIMENSION).contains(value))
            .ok_or_else(invalid)
    };
    let rows = dimension("rows")?;
    let columns = dimension("columns")?;

    require_fresh_output(output_path)?;
    let mut source = open_source(source_path, sha)?;
    let deck = Deck::read(&mut source)?;
    let table = Table::new(slide_size(&deck)?, rows, columns);
    let slide = deck.slides.get(slide_index).ok_or_else(invalid)?;
    let source_xml = &deck.xml[&slide.part];
    let site = insertion_site_with_references(source_xml, true)?;
    let frame = table.xml(site.id);
    require(has_room(&deck, source_xml, frame.len()))?;
    let mut edits = PackageEdits::default();
    edits.changed.insert(
        slide.part.clone(),
        edit(source_xml, vec![(site.offset..site.offset, frame)])?,
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
            table.verify(&verified.xml[&slide.part], &site)
        },
    )?;
    Ok(json!({
        "sourceSha256":sha,"outputSha256":output_sha,"slideCount":deck.slides.len(),
        "slideIndex":slide_index,"shapeId":site.id,"rows":rows,"columns":columns,
    }))
}

struct Table {
    x: u64,
    y: u64,
    column_width: u64,
    row_height: u64,
    rows: u64,
    columns: u64,
}

impl Table {
    fn new((slide_width, slide_height): (u64, u64), rows: u64, columns: u64) -> Self {
        // Author on a hundredth-millimetre grid, the unit the desktop engine exposes.
        let round_down = |value| value / EMU_PER_HUNDREDTH_MM * EMU_PER_HUNDREDTH_MM;
        let column_width = round_down(slide_width * 3 / (4 * columns));
        let row_height = round_down((slide_height * 3 / (4 * rows)).min(360_000));
        Self {
            x: round_down((slide_width - column_width * columns) / 2),
            y: round_down((slide_height - row_height * rows) / 2),
            column_width,
            row_height,
            rows,
            columns,
        }
    }

    fn xml(&self, id: u32) -> String {
        let Self {
            x,
            y,
            column_width,
            row_height,
            rows,
            columns,
        } = *self;
        let width = column_width * columns;
        let height = row_height * rows;
        let font_size = (column_width.min(row_height) * 60 / EMU_PER_POINT).clamp(100, 1200);
        let horizontal_margin = (column_width / 20).min(38_100);
        let vertical_margin = (row_height / 20).min(19_050);
        let mut cell = format!(
            "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr sz=\"{font_size}\">\
             <a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill></a:rPr><a:t xml:space=\"preserve\"/>\
             </a:r><a:endParaRPr sz=\"{font_size}\"/></a:p></a:txBody>\
             <a:tcPr marL=\"{horizontal_margin}\" marR=\"{horizontal_margin}\" marT=\"{vertical_margin}\" marB=\"{vertical_margin}\">"
        );
        for side in ["lnL", "lnR", "lnT", "lnB"] {
            write!(cell, "<a:{side} w=\"12700\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill><a:prstDash val=\"solid\"/></a:{side}>")
                .expect("writing XML into String");
        }
        cell.push_str("<a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill></a:tcPr></a:tc>");
        let mut frame = format!(
            "<p:graphicFrame xmlns:p=\"{P}\" xmlns:a=\"{A}\"><p:nvGraphicFramePr>\
             <p:cNvPr id=\"{id}\" name=\"Table {id}\"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\"/>\
             </p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>\
             <p:xfrm><a:off x=\"{x}\" y=\"{y}\"/><a:ext cx=\"{width}\" cy=\"{height}\"/></p:xfrm>\
             <a:graphic><a:graphicData uri=\"{TABLE_URI}\"><a:tbl><a:tblPr firstRow=\"0\" bandRow=\"0\"/><a:tblGrid>"
        );
        let column = format!("<a:gridCol w=\"{column_width}\"/>");
        for _ in 0..columns {
            frame.push_str(&column);
        }
        frame.push_str("</a:tblGrid>");
        let row_start = format!("<a:tr h=\"{row_height}\">");
        for _ in 0..rows {
            frame.push_str(&row_start);
            for _ in 0..columns {
                frame.push_str(&cell);
            }
            frame.push_str("</a:tr>");
        }
        frame.push_str("</a:tbl></a:graphicData></a:graphic></p:graphicFrame>");
        frame
    }

    fn verify(&self, xml: &str, site: &InsertionSite) -> ApiResult<()> {
        let doc = document(xml)?;
        let root = doc.root_element();
        let frame = shape_tree(root)?
            .children()
            .find(|node| {
                node.has_tag_name((P, "graphicFrame")) && node.range().start == site.offset
            })
            .ok_or_else(invalid_zip)?;
        let nv = single_child(frame, P, "nvGraphicFramePr")?;
        let id = single_child(nv, P, "cNvPr")?;
        let transform = single_child(frame, P, "xfrm")?;
        let position = single_child(transform, A, "off")?;
        let size = single_child(transform, A, "ext")?;
        let number = |node: Node, key| node.attribute(key).and_then(|value| value.parse().ok());
        for (node, key, value) in [
            (id, "id", u64::from(site.id)),
            (position, "x", self.x),
            (position, "y", self.y),
            (size, "cx", self.column_width * self.columns),
            (size, "cy", self.row_height * self.rows),
        ] {
            require(number(node, key) == Some(value))?;
        }
        let graphic = single_child(frame, A, "graphic")?;
        let data = single_child(graphic, A, "graphicData")?;
        require(data.attribute("uri") == Some(TABLE_URI))?;
        let table = single_child(data, A, "tbl")?;
        let grid = single_child(table, A, "tblGrid")?;
        let widths = grid
            .children()
            .filter(|node| node.has_tag_name((A, "gridCol")))
            .map(|node| number(node, "w"));
        require(widths.eq(std::iter::repeat_n(
            Some(self.column_width),
            self.columns as usize,
        )))?;
        let rows = table
            .children()
            .filter(|node| node.has_tag_name((A, "tr")))
            .collect::<Vec<_>>();
        require(rows.len() == self.rows as usize)?;
        for row in rows {
            require(number(row, "h") == Some(self.row_height))?;
            let mut count = 0;
            for cell in row.children().filter(|node| node.has_tag_name((A, "tc"))) {
                require(
                    ["rowSpan", "gridSpan", "hMerge", "vMerge"]
                        .iter()
                        .all(|key| cell.attribute(*key).is_none()),
                )?;
                let body = single_child(cell, A, "txBody")?;
                single_child(body, A, "p")?;
                single_child(cell, A, "tcPr")?;
                count += 1;
            }
            require(count == self.columns)?;
        }
        Ok(())
    }
}
