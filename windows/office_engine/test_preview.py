"""Export initial previews of the synthetic original fixtures without saving them."""
import argparse
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker


def run(runtime, fixtures, output):
    worker.initialize(runtime)
    output.mkdir(parents=True, exist_ok=False)
    report = {}
    for extension, pages, expected_text in (("docx", 1, "Original heading"), ("pptx", 2, "Original slide 0")):
        source = fixtures / ("original." + extension)
        original_hash = worker.digest(source)
        original_stat = source.stat()
        working_directory = output / ("inspect-" + extension)
        result = worker.run_request(runtime, {"mode": "inspect", "sourcePath": str(source), "preview": True}, working_directory)
        snapshot = result["snapshot"]
        pdf = Path(snapshot["previewPdfPath"])
        assert snapshot["sourceSha256"] == original_hash == worker.digest(source)
        assert snapshot["previewPageCount"] == pages
        assert source.stat().st_mtime_ns == original_stat.st_mtime_ns
        assert source.stat().st_size == original_stat.st_size
        assert not working_directory.exists()
        assert pdf.parent == output and pdf.is_file()
        assert expected_text in worker.PdfReader(str(pdf)).pages[0].extract_text()
        report[extension] = {"sourceSha256": original_hash, "sourceMtimeUnchanged": True,
            "workingCopyRemoved": True, "previewSha256": worker.digest(pdf), "snapshot": snapshot}
    hidden = output / "hidden-first-slide.pptx"
    with zipfile.ZipFile(fixtures / "original.pptx") as source, zipfile.ZipFile(hidden, "w", zipfile.ZIP_DEFLATED) as destination:
        for info in source.infolist():
            data = source.read(info.filename)
            if info.filename == "ppt/slides/slide1.xml":
                slide = ET.fromstring(data)
                slide.set("show", "0")
                data = ET.tostring(slide, encoding="utf-8", xml_declaration=True)
            destination.writestr(info, data)
    hidden_hash = worker.digest(hidden)
    hidden_stat = hidden.stat()
    hidden_snapshot = worker.run_request(runtime, {"mode": "inspect", "sourcePath": str(hidden), "preview": True}, output / "inspect-hidden")["snapshot"]
    assert len(hidden_snapshot["slides"]) == hidden_snapshot["previewPageCount"] == 2
    assert "Original slide 0" in worker.PdfReader(hidden_snapshot["previewPdfPath"]).pages[0].extract_text()
    assert worker.digest(hidden) == hidden_hash and hidden.stat().st_mtime_ns == hidden_stat.st_mtime_ns
    assert not (output / "inspect-hidden").exists()
    report["hiddenFirstSlide"] = {"sourceSha256": hidden_hash, "sourceMtimeUnchanged": True,
        "workingCopyRemoved": True, "snapshot": hidden_snapshot}
    (output / "result.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.runtime.resolve(), args.fixtures.resolve(), args.output.resolve())
