"""Actual, isolated LibreOffice save/reopen regression test; synthetic files only."""
import argparse
import json
from pathlib import Path
import sys
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker


def create_sources(runtime, directory):
    with worker.OfficeServer(runtime, directory) as server:
        owned_pid, profile = server.process.pid, server.profile
        writer = server.desktop.loadComponentFromURL("private:factory/swriter", "_blank", 0,
            (worker.prop("Hidden", True), worker.prop("MacroExecutionMode", 0)))
        try:
            writer.Text.String = "Original heading"
            table = writer.createInstance("com.sun.star.text.TextTable")
            table.initialize(2, 2)
            writer.Text.insertTextContent(writer.Text.End, table, False)
            table.getCellByName("B2").String = "Original cell"
            writer.storeToURL((directory / "original.docx").as_uri(),
                (worker.prop("FilterName", worker.FILTERS["docx"]),))
        finally:
            writer.close(True)
        slides = server.desktop.loadComponentFromURL("private:factory/simpress", "_blank", 0,
            (worker.prop("Hidden", True), worker.prop("MacroExecutionMode", 0)))
        try:
            for index in range(2):
                page = slides.DrawPages.getByIndex(0) if index == 0 else slides.DrawPages.insertNewByIndex(index)
                shape = slides.createInstance("com.sun.star.drawing.TextShape")
                page.add(shape)
                shape.String = "Original slide " + str(index)
                shape.Position = worker.uno.createUnoStruct("com.sun.star.awt.Point", 1000, 2000)
                shape.Size = worker.uno.createUnoStruct("com.sun.star.awt.Size", 8000, 3000)
            slides.storeToURL((directory / "original.pptx").as_uri(),
                (worker.prop("FilterName", worker.FILTERS["pptx"]),))
        finally:
            slides.close(True)
    assert not profile.exists(), "Owned profile leaked after engine shutdown"
    return owned_pid


def run(runtime, output):
    worker.initialize(runtime)
    output.mkdir(parents=True, exist_ok=False)
    report = {"engineVersion": "LibreOffice26.8.2.2", "ownedLoaderPid": create_sources(runtime, output)}
    word_path, ppt_path = output / "original.docx", output / "original.pptx"
    word_hash, ppt_hash = worker.digest(word_path), worker.digest(ppt_path)
    word = worker.run_request(runtime, {"mode": "inspect", "sourcePath": str(word_path)}, output / "inspect-word")["snapshot"]
    assert not (output / "inspect-word").exists(), "Inspect copy was retained"
    table_id = word["tables"][0]["id"]
    word_result = worker.run_request(runtime, {"mode": "apply", "sourcePath": str(word_path),
        "sessionId": "word-proof", "expectedSourceSha256": word_hash, "operations": [
            {"op": "paragraphText", "id": "paragraph-0", "text": "Edited heading"},
            {"op": "paragraphStyle", "id": "paragraph-0", "fontSize": 24, "bold": True, "color": 0x123456},
            {"op": "tableCellText", "tableId": table_id, "cell": "B2", "text": "Edited cell"}]}, output / "edit-word")
    paragraph = word_result["snapshot"]["paragraphs"][0]
    assert (paragraph["text"], paragraph["fontSize"], paragraph["bold"], paragraph["color"]) == ("Edited heading", 24, True, 0x123456)
    assert word_result["snapshot"]["tables"][0]["cells"]["B2"] == "Edited cell"
    assert word_result["pdfPageCount"] == 1
    assert "Edited heading" in worker.PdfReader(word_result["pdfPath"]).pages[0].extract_text()
    ppt = worker.run_request(runtime, {"mode": "inspect", "sourcePath": str(ppt_path)}, output / "inspect-ppt")["snapshot"]
    assert not (output / "inspect-ppt").exists(), "Inspect copy was retained"
    shape_id = next(shape["id"] for shape in ppt["slides"][0]["shapes"] if shape["text"] == "Original slide 0")
    ppt_result = worker.run_request(runtime, {"mode": "apply", "sourcePath": str(ppt_path),
        "sessionId": "ppt-proof", "expectedSourceSha256": ppt_hash, "operations": [
            {"op": "shapeText", "id": shape_id, "text": "Edited slide"},
            {"op": "shapeStyle", "id": shape_id, "fontSize": 30, "bold": True, "color": 0x123456},
            {"op": "shapeGeometry", "id": shape_id, "x": 32, "y": 41, "width": 110, "height": 45},
            {"op": "slideAdd", "id": "new-slide", "index": 1, "text": "New first slide"},
            {"op": "slideDelete", "id": "slide-1"},
            {"op": "slideMove", "id": "new-slide", "index": 0}]}, output / "edit-ppt")
    slides = ppt_result["snapshot"]["slides"]
    assert len(slides) == 2
    assert any(shape["text"] == "New first slide" for shape in slides[0]["shapes"])
    edited_shape = next(shape for shape in slides[1]["shapes"] if shape["text"] == "Edited slide")
    for name, expected in {"x": 32, "y": 41, "width": 110, "height": 45}.items():
        assert abs(edited_shape[name] - expected) < .05, (name, edited_shape[name])
    assert (edited_shape["fontSize"], edited_shape["bold"], edited_shape["color"]) == (30, True, 0x123456)
    assert ppt_result["pdfPageCount"] == 2
    pdf = worker.PdfReader(ppt_result["pdfPath"])
    assert "New first slide" in pdf.pages[0].extract_text()
    assert "Edited slide" in pdf.pages[1].extract_text()
    try:
        worker.run_request(runtime, {"mode": "apply", "sourcePath": str(word_path),
            "sessionId": "rejected-proof", "operations": [{"op": "arbitraryDispatch"}]}, output / "rejected")
        raise AssertionError("An unlisted engine operation was accepted")
    except ValueError as error:
        assert str(error) == "Unsupported Office operation"
    assert (worker.digest(word_path), worker.digest(ppt_path)) == (word_hash, ppt_hash)
    report.update({"word": word_result, "presentation": ppt_result,
        "originalHashesUnchanged": True, "unlistedOperationRejected": True})
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = run(args.runtime.resolve(), args.output.resolve())
    except BaseException:
        Path(str(args.output) + ".error.txt").write_text(traceback.format_exc(), encoding="utf-8")
        raise
    (args.output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"passed": True, "wordPdfPages": report["word"]["pdfPageCount"],
        "presentationPdfPages": report["presentation"]["pdfPageCount"]}))
