use std::{env, fs, path::PathBuf};
fn main() {
    let output = PathBuf::from(env::args().nth(1).expect("output directory"));
    fs::create_dir_all(&output).unwrap();
    let doc = hwp_convert::from_markdown(
        "ORIGINAL_PARAGRAPH\n\n| COL_A | COL_B |\n| --- | --- |\n| ORIGINAL_CELL | OTHER_CELL |\n",
    );
    hwp5::write_document_with_report(
        &doc,
        &output.join("original.hwp"),
        &hwp5::WriteOptions::default(),
    )
    .unwrap();
    hwpx::write_document(&doc, &output.join("original.hwpx")).unwrap();
    println!("Prepared two original-format synthetic fixtures");
}
