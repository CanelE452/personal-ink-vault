use super::*;
use std::io::Write;
use std::path::PathBuf;

const SECTION: &str = "Contents/section0.xml";

fn structure_fixture(dir: &Path) -> PathBuf {
    let path = dir.join("grid.hwpx");
    let document = hwp_convert::from_markdown(
        "INTRO_MARKER\n\n| **강조** | Beta | Gamma |\n| --- | --- | --- |\n| Delta | Epsilon | Zeta |\n\nAFTER_MARKER\n",
    );
    hwpx::write_document(&document, &path).unwrap();
    path
}

fn table(path: &Path) -> Value {
    let result = inspect(path);
    let value = &result["snapshot"]["tables"][0];
    assert!(value.is_object(), "{result}");
    value.clone()
}

fn operation(id: &Value, action: &str, index: usize) -> Value {
    json!({"op":"tableStructure","id":id,"action":action,"index":index})
}

fn edit(path: &Path, action: &str, index: usize) -> PathBuf {
    let result = apply(
        path,
        &[operation(&table(path)["id"], action, index)],
        &sha(&fs::read(path).unwrap()),
    );
    assert_eq!(result["status"], "saved", "{result}");
    assert!(
        fs::read(result["pdfPath"].as_str().unwrap())
            .unwrap()
            .starts_with(b"%PDF-")
    );
    PathBuf::from(result["sourcePath"].as_str().unwrap())
}

fn geometry(path: &Path) -> (i32, i32, Vec<(i32, i32)>) {
    let document = hwpx::read_document(path).unwrap().document;
    let table = document.sections[0]
        .paragraphs
        .iter()
        .flat_map(|p| &p.controls)
        .find_map(|control| match control {
            hwp_model::Control::Table(table) => Some(table),
            _ => None,
        })
        .unwrap();
    let placement = table.placement.as_ref().unwrap();
    (
        placement.width,
        placement.height,
        table
            .cells
            .iter()
            .map(|cell| (cell.width.0, cell.height.0))
            .collect(),
    )
}

#[test]
fn hwp_table_structure_roundtrips_each_axis_and_preserves_other_package_data() {
    let dir = tempfile::tempdir().unwrap();
    let source = structure_fixture(dir.path());
    let original_bytes = fs::read(&source).unwrap();
    let original = table(&source);
    assert_eq!(
        original["structure"],
        json!({"rows":2,"columns":3,"canInsertRow":true,"canDeleteRow":true,"canInsertColumn":true,"canDeleteColumn":true}),
        "{original}"
    );
    let original_geometry = geometry(&source);

    let row = edit(&source, "insertRow", 0);
    let observed = table(&row);
    assert_eq!(observed["structure"]["rows"], 3);
    assert_eq!(observed["cells"]["0,0"], "");
    assert_eq!(observed["cells"]["1,0"], "강조");
    assert_eq!(
        observed["cellTextDetails"]["1,0"],
        original["cellTextDetails"]["0,0"]
    );
    assert_eq!(
        geometry(&row).1,
        original_geometry.1 + original_geometry.2[0].1
    );
    let rows_restored = edit(&row, "deleteRow", 0);
    assert_eq!(table(&rows_restored), original);
    assert_eq!(geometry(&rows_restored), original_geometry);

    let column = edit(&source, "insertColumn", 1);
    let observed = table(&column);
    assert_eq!(observed["structure"]["columns"], 4);
    assert_eq!(observed["cells"]["0,1"], "");
    assert_eq!(observed["cells"]["0,2"], "Beta");
    let wider = geometry(&column);
    assert_eq!(
        (wider.0, wider.1),
        (original_geometry.0, original_geometry.1)
    );
    assert_eq!(wider.2[1].0 + wider.2[2].0, original_geometry.2[1].0);
    let columns_restored = edit(&column, "deleteColumn", 1);
    assert_eq!(table(&columns_restored), original);
    assert_eq!(geometry(&columns_restored), original_geometry);

    let before = entries(&source);
    let after = entries(&column);
    for (name, bytes) in before.iter().filter(|(name, _)| name.as_str() != SECTION) {
        assert_eq!(after[name], *bytes, "changed untouched entry {name}");
    }
    let before = std::str::from_utf8(&before[SECTION]).unwrap();
    let after = std::str::from_utf8(&after[SECTION]).unwrap();
    let first = before.find("<hp:tbl ").unwrap();
    let end = before.find("</hp:tbl>").unwrap() + "</hp:tbl>".len();
    assert!(after.starts_with(&before[..first]));
    assert!(after.ends_with(&before[end..]));
    assert_eq!(fs::read(&source).unwrap(), original_bytes);
}

#[test]
fn hwp_table_structure_refuses_unsafe_tables_indices_and_stale_requests() {
    let dir = tempfile::tempdir().unwrap();
    let source = structure_fixture(dir.path());
    let original = fs::read(&source).unwrap();
    let id = table(&source)["id"].clone();
    let digest = sha(&original);
    let valid = operation(&id, "insertRow", 2);
    assert_eq!(
        apply(&source, &[valid.clone()], &"0".repeat(64))["error"]["code"],
        "source_changed"
    );
    for invalid in [
        operation(&id, "insertRow", 3),
        operation(&id, "deleteColumn", 3),
        operation(&id, "mergeCells", 0),
    ] {
        assert_eq!(
            apply(&source, &[invalid], &digest)["error"]["code"],
            "invalid_request"
        );
    }
    assert_eq!(
        apply(&source, &[valid.clone(), valid.clone()], &digest)["error"]["code"],
        "invalid_request"
    );

    let one = edit(&source, "deleteRow", 1);
    assert_eq!(table(&one)["structure"]["canDeleteRow"], false);
    assert!(
        apply(
            &one,
            &[operation(&id, "deleteRow", 0)],
            &sha(&fs::read(&one).unwrap())
        )["error"]
            .is_object()
    );
    let mut altered = entries(&source);
    let section = std::str::from_utf8(&altered[SECTION]).unwrap().replacen(
        "colSpan=\"1\"",
        "colSpan=\"2\"",
        1,
    );
    altered.insert(SECTION.into(), section.into_bytes());
    let unsafe_source = dir.path().join("merged.hwpx");
    let mut archive = zip::ZipWriter::new(fs::File::create(&unsafe_source).unwrap());
    for (name, bytes) in altered {
        archive
            .start_file(name, zip::write::SimpleFileOptions::default())
            .unwrap();
        archive.write_all(&bytes).unwrap();
    }
    archive.finish().unwrap();
    assert!(table(&unsafe_source)["structure"].is_null());
    assert!(
        apply(
            &unsafe_source,
            &[valid],
            &sha(&fs::read(&unsafe_source).unwrap())
        )["error"]
            .is_object()
    );
    assert_eq!(fs::read(&source).unwrap(), original);
}

#[test]
fn hwp_table_structure_refuses_to_narrow_cells_that_cannot_keep_their_line_layout() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("narrow.hwpx");
    let mut document = hwp_convert::from_markdown(
        "| ABC | MMM MMM MMM MMM MMM | DEF |\n| --- | --- | --- |\n| One | Two | Three |\n",
    );
    let hwp_model::Control::Table(grid) = document.sections[0]
        .paragraphs
        .iter_mut()
        .flat_map(|p| &mut p.controls)
        .find(|c| matches!(c, hwp_model::Control::Table(_)))
        .unwrap()
    else {
        unreachable!()
    };
    for cell in &mut grid.cells {
        cell.width.0 = 12_000;
    }
    hwpx::write_document(&document, &source).unwrap();
    let original = fs::read(&source).unwrap();
    let target = table(&source);
    assert_eq!(target["structure"]["canInsertColumn"], true, "{target}");
    let result = apply(
        &source,
        &[operation(&target["id"], "insertColumn", 1)],
        &sha(&original),
    );
    assert_eq!(result["error"]["code"], "incomplete_layout", "{result}");
    assert_eq!(fs::read(&source).unwrap(), original);
}
