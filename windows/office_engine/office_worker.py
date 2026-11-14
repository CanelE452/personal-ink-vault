import argparse
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from process_ownership import OwnedOfficeProcess
import office_text
import office_images
import office_word
import office_word_layout
import office_word_inline
import office_word_export
import office_presentation

FILTERS = {"docx": "Office Open XML Text", "doc": "MS Word 97",
           "odt": "writer8", "pptx": "Impress MS PowerPoint 2007 XML",
           "ppt": "MS PowerPoint 97", "odp": "impress8"}
PRESET_SHAPES = {"roundedRectangle": "round-rectangle", "rightArrow": "right-arrow"}
LEGACY_COPY_LIMIT = 128 * 1024 * 1024
LEGACY_COPY_FORMATS = {'doc': ('docx', 'word/document.xml'),
                       'ppt': ('pptx', 'ppt/presentation.xml')}
COMPOUND_FILE_MAGIC = bytes.fromhex('d0cf11e0a1b11ae1')


class DocumentFamilyMismatch(ValueError):
    def __init__(self):
        super().__init__("Office 파일의 확장자가 실제 문서 종류와 일치하지 않습니다.")


def require_document_kind(document, extension):
    if extension in ("ppt", "pptx", "odp"):
        kind, service = "presentation", "com.sun.star.presentation.PresentationDocument"
    elif extension in ("doc", "docx", "odt"):
        kind, service = "word", "com.sun.star.text.TextDocument"
    else:
        raise ValueError("Unsupported Office source")
    if not document.supportsService(service):
        raise DocumentFamilyMismatch()
    return kind


def initialize(runtime):
    global uno, PdfReader, AbortInteraction
    sys.path.insert(0, str(runtime / "program"))
    sys.path.insert(0, str(runtime / "python-deps"))
    import uno
    import unohelper
    from pypdf import PdfReader
    from com.sun.star.task import XInteractionHandler

    class AbortInteraction(unohelper.Base, XInteractionHandler):
        def handle(self, request):
            for continuation in request.getContinuations():
                abort = continuation.queryInterface(uno.getTypeByName("com.sun.star.task.XInteractionAbort"))
                if abort is not None:
                    abort.select()
                    return


def prop(name, value):
    result = uno.createUnoStruct("com.sun.star.beans.PropertyValue")
    result.Name, result.Value = name, value
    return result


class OfficeServer:
    def __init__(self, runtime, directory, *, interactive=False):
        if type(interactive) is not bool:
            raise TypeError("interactive must be a boolean")
        self.runtime, self.directory = runtime, directory
        self.interactive = interactive
        self.desktop, self.process = None, None

    def __enter__(self):
        pipe = "piv_office_" + uuid.uuid4().hex
        self.profile = Path(tempfile.mkdtemp(prefix="piv-lo-"))
        profile = self.profile
        try:
            headless = [] if self.interactive else ["--headless"]
            self.process = OwnedOfficeProcess(self.runtime / "program/soffice.com", headless + [
                "--nologo", "--nodefault", "--norestore",
                "-env:UserInstallation=" + profile.as_uri(),
                "--pidfile=" + str(self.directory / "office.pid"),
                "--accept=pipe,name=" + pipe + ";urp;StarOffice.ComponentContext"],
                self.runtime / "program", **({'show_window': True} if self.interactive else {}))
            local = uno.getComponentContext()
            resolver = local.ServiceManager.createInstanceWithContext("com.sun.star.bridge.UnoUrlResolver", local)
            deadline = time.monotonic() + 60
            while True:
                try:
                    self.context = resolver.resolve("uno:pipe,name=" + pipe + ";urp;StarOffice.ComponentContext")
                    break
                except Exception:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Office engine did not start; loader exit=" + str(self.process.exit_code()))
                    time.sleep(.1)
            self.desktop = self.context.ServiceManager.createInstanceWithContext("com.sun.star.frame.Desktop", self.context)
            return self
        except BaseException:
            if self.process is not None:
                self.process.close()
            self.cleanup_profile()
            raise

    def load(self, path, read_only=False):
        document = self.desktop.loadComponentFromURL(path.as_uri(), "_blank", 0, (
            prop("Hidden", not self.interactive), prop("ReadOnly", read_only), prop("MacroExecutionMode", 0),
            prop("UpdateDocMode", 0), prop("InteractionHandler", AbortInteraction())))
        if document is None:
            raise ValueError("Office document could not be opened")
        return document

    def __exit__(self, *_):
        if self.desktop is not None:
            try:
                self.desktop.terminate()
            except Exception:
                pass
        if self.process is not None:
            self.process.close()
        self.cleanup_profile()

    def cleanup_profile(self):
        if getattr(self, "profile", None):
            target = self.profile.resolve()
            if target.parent == Path(tempfile.gettempdir()).resolve() and target.name.startswith("piv-lo-"):
                for attempt in range(20):
                    try:
                        shutil.rmtree(target)
                        return
                    except OSError as error:
                        if getattr(error, 'winerror', None) not in (32, 33, 5) or attempt == 19:
                            return
                        time.sleep(.05)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def export_pdf(document, pdf, kind, *, max_bytes=None):
    options = [prop("FilterName", "writer_pdf_Export" if kind == "word" else "impress_pdf_Export")]
    if kind == "presentation":
        data = (prop("ExportHiddenSlides", True), prop("ExportNotesPages", False), prop("ExportOnlyNotesPages", False))
        options.append(prop("FilterData", uno.Any("[]com.sun.star.beans.PropertyValue", data)))
    document.storeToURL(pdf.as_uri(), tuple(options))
    if max_bytes is not None and not 0 < pdf.stat().st_size <= max_bytes:
        raise ValueError('Office conversion PDF exceeds the file limit')
    return len(PdfReader(str(pdf), strict=True).pages)


def text_cursor(value, paragraph=False):
    if paragraph:
        cursor = value.getText().createTextCursorByRange(value.Start)
        cursor.gotoRange(value.End, True)
    else:
        cursor = value.Text.createTextCursor()
        cursor.gotoEnd(True)
    return cursor


def style(value):
    def number(name):
        result = getattr(value, name, None)
        return float(result) if isinstance(result, (int, float)) else None
    weight = number("CharWeight")
    color = value.CharColor
    return {"fontSize": number("CharHeight"), "bold": None if weight is None else weight >= 150,
            "color": int(color) if color is not None and color >= 0 else None}


def objects(document):
    if document.supportsService("com.sun.star.presentation.PresentationDocument"):
        pages = {"slide-" + str(i): document.DrawPages.getByIndex(i) for i in range(document.DrawPages.Count)}
        shapes = {page_id + "/shape-" + str(i): page.getByIndex(i)
                  for page_id, page in pages.items() for i in range(page.Count)}
        return "presentation", pages, shapes
    if document.supportsService("com.sun.star.text.TextDocument"):
        paragraphs, enumeration = {}, document.Text.createEnumeration()
        while enumeration.hasMoreElements():
            element = enumeration.nextElement()
            if element.supportsService("com.sun.star.text.Paragraph"):
                paragraphs["paragraph-" + str(len(paragraphs))] = element
        tables = {name: document.TextTables.getByName(name) for name in document.TextTables.ElementNames}
        return "word", paragraphs, tables
    raise ValueError("Unsupported Office document type")


def optional_property(value, name):
    if value is None or not value.getPropertySetInfo().hasPropertyByName(name):
        return None
    return value.getPropertyValue(name)


def writable_properties(value, *names):
    if value is None:
        return False
    properties = value.getPropertySetInfo()
    return all(properties.hasPropertyByName(name) and
               not properties.getPropertyByName(name).Attributes & 16 for name in names)


def shape_kind(shape):
    simple = {"TextShape": "text", "TitleTextShape": "text", "SubtitleShape": "text",
              "RectangleShape": "rectangle", "EllipseShape": "ellipse", "LineShape": "line",
              "GraphicObjectShape": "image"}
    native = shape.ShapeType.rsplit(".", 1)[-1]
    if native in simple:
        return simple[native]
    if native == "CustomShape":
        geometry = optional_property(shape, "CustomShapeGeometry") or ()
        kind = next((entry.Value for entry in geometry if entry.Name == "Type"), None)
        return {"rect": "rectangle", "ooxml-rect": "rectangle", "rectangle": "rectangle",
                "ellipse": "ellipse", "ooxml-ellipse": "ellipse",
                "round-rectangle": "roundedRectangle", "ooxml-roundRect": "roundedRectangle",
                "right-arrow": "rightArrow", "ooxml-rightArrow": "rightArrow"}.get(kind)
    return None


def appearance(value, prefix):
    fill = optional_property(value, prefix + "Style")
    color = optional_property(value, prefix + "Color")
    return {prefix.lower() + "Style": None if fill is None else fill.value.lower(),
            prefix.lower() + "Color": color if isinstance(color, int) and color >= 0 else None}


def photo_rotation(shape):
    # UNO uses counterclockwise hundredths of a degree; PPTX uses clockwise.
    native = optional_property(shape, 'RotateAngle')
    return (-native) % 36000 if type(native) is int else None


def can_rotate_photo(shape, metadata, rotation):
    return (rotation is not None and metadata['ownerKind'] == 'slide' and
            metadata['presentationObject'] is False and metadata['canEditGeometry'] and
            shape_kind(shape) == 'image' and optional_property(shape, 'Graphic') is not None and
            writable_properties(shape, 'RotateAngle'))


def presentation_shape(identifier, shape, presentation, context, thumbnail_budget):
    if shape.ShapeType == 'com.sun.star.drawing.TableShape':
        metadata = presentation.shape_metadata(identifier)
        return {'id': identifier, 'type': shape.ShapeType, 'text': '',
            'editableText': False, 'shapeKind': None, 'textDetails': None, 'image': None,
            'x': shape.Position.X / 100, 'y': shape.Position.Y / 100,
            'width': shape.Size.Width / 100, 'height': shape.Size.Height / 100,
            'fillStyle': None, 'fillColor': None, 'lineStyle': None, 'lineColor': None,
            'lineWidth': None, 'canEditFill': False, 'canEditLine': False, **metadata}
    try:
        text, text_style, editable = shape.String, style(text_cursor(shape)), True
        details = office_text.text_details(shape)
    except Exception:
        text, text_style, editable, details = '', {}, False, None
    metadata = presentation.shape_metadata(identifier)
    mutable = metadata['canDelete']
    if details is not None and not mutable:
        details['canReplace'], details['canStyle'] = False, False
    shape_type = shape_kind(shape)
    image = office_images.image_details(context, shape, prop, uno, thumbnail_budget) if shape_type == 'image' else None
    if image is not None:
        image['canReplace'] = mutable and writable_properties(shape, 'Graphic')
        rotation = photo_rotation(shape)
        image['rotationHundredths'] = rotation
        image['canRotate'] = can_rotate_photo(shape, metadata, rotation)
    line_width = optional_property(shape, 'LineWidth')
    return {'id': identifier, 'type': shape.ShapeType, 'text': text,
        'editableText': editable and mutable and shape_type not in ('line', 'image'), 'shapeKind': shape_type,
        'textDetails': None if shape_type == 'image' else details, 'image': image,
        'x': shape.Position.X / 100, 'y': shape.Position.Y / 100,
        'width': shape.Size.Width / 100, 'height': shape.Size.Height / 100,
        **text_style, **appearance(shape, 'Fill'), **appearance(shape, 'Line'),
        'lineWidth': None if line_width is None else line_width / 100,
        'canEditFill': mutable and shape_type != 'line' and writable_properties(shape, 'FillStyle', 'FillColor'),
        'canEditLine': mutable and writable_properties(shape, 'LineStyle', 'LineColor', 'LineWidth'), **metadata}


def snapshot(document, source_hash, context=None, presentation=None, word=None, source_path=None):
    kind, first, second = (('word', word.body.paragraphs, word.tables) if word is not None else
        objects(document) if presentation is None else ('presentation', presentation.slides, presentation.shapes))
    result = {"kind": kind, "sourceSha256": source_hash, "paragraphs": [], "tables": [], "slides": []}
    if kind == "word":
        word = word or office_word_layout.WordDocument(document, first, second, uno, prop, context=context)
        word.refresh_page_metadata()
        def render_paragraphs(scope):
            return [{"id": key, "text": value.String, 'ownerId': scope.owner_id, **style(text_cursor(value, True)),
                "textDetails": office_text.text_details(value, True),
                'paragraphFormat': office_word.paragraph_format(value, document),
                'structure': scope.structure(key)} for key, value in scope.paragraphs.items()]
        result['blocks'] = word.body.order
        result['paragraphStyles'] = office_word.paragraph_styles(document)
        result['bodyOwnerId'] = 'body'
        result['pageStyles'] = word.page_styles
        result['wordOwners'] = word.owner_snapshot(render_paragraphs)
        catalog = word.image_catalog()
        try:
            result['wordImages'] = catalog.snapshot([office_images.THUMBNAIL_BUDGET]) if catalog is not None else None
        except Exception:
            result['wordImages'] = None
        try:
            result['wordImageTargets'] = catalog.snapshot_targets() if catalog is not None else None
        except Exception:
            result['wordImageTargets'] = None
        result["paragraphs"] = render_paragraphs(word.body)
        result["tables"] = [{"id": key, "cells": {name: value.getCellByName(name).String for name in value.CellNames},
                             'ownerId': word.table_owners[key],
                             "cellTextDetails": {name: office_text.text_details(value.getCellByName(name)) for name in value.CellNames}}
                            for key, value in second.items()]
    else:
        presentation = presentation or office_presentation.Presentation(document, first, second, source_path)
        catalog = presentation.table_catalog
        if source_path is not None and (catalog.source_path != Path(source_path).resolve(strict=True) or
                catalog.source_sha256 != source_hash):
            raise ValueError('Presentation table catalog does not match the inspected source')
        table_snapshots = catalog.snapshot_all()
        duplicable = set()
        if (source_path is not None and Path(source_path).suffix.lower() == '.pptx' and
                presentation.logical == [f'slide-{index}' for index in range(len(first))]):
            from office_presentation_duplicate import duplicable_slides

            try:
                duplicable = {f'slide-{index}' for index in duplicable_slides(Path(source_path), source_hash)}
            except (ValueError, OSError, zipfile.BadZipFile):
                pass
        result['layoutOptions'] = list(office_presentation.LAYOUT_OPTIONS)
        result['masters'] = []
        thumbnail_budget = [office_images.THUMBNAIL_BUDGET]
        for page_id in presentation.logical:
            page = first[page_id]
            shapes = [presentation_shape(identifier, shape, presentation, context, thumbnail_budget)
                for identifier, shape in presentation.shape_items(page_id)]
            background = appearance(optional_property(page, "Background"), "Fill")
            result["slides"].append({"id": page_id, "width": page.Width / 100,
                                     "height": page.Height / 100, "shapes": shapes,
                                     "backgroundStyle": background["fillStyle"],
                                     "backgroundColor": background["fillColor"], **presentation.slide_metadata(page_id),
                                      'presentationTables': table_snapshots[page_id], **catalog.metadata(page_id)})
            if page_id in duplicable:
                result['slides'][-1]['canDuplicate'] = True
        for master_id, master in presentation.masters.items():
            background = appearance(optional_property(master, 'Background'), 'Fill')
            result['masters'].append({'id': master_id, 'name': master.getName(),
                'width': master.Width / 100, 'height': master.Height / 100,
                'backgroundStyle': background['fillStyle'], 'backgroundColor': background['fillColor'],
                'shapes': [presentation_shape(identifier, shape, presentation, context, thumbnail_budget)
                    for identifier, shape in presentation.shape_items(master_id)],
                'presentationTables': table_snapshots[master_id], **catalog.metadata(master_id)})
    return result


def require_keys(operation, allowed):
    if not isinstance(operation, dict) or set(operation) - set(allowed):
        raise ValueError("Invalid Office operation fields")


def number(operation, key, minimum=-100000, maximum=100000):
    value = operation[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not minimum <= value <= maximum:
        raise ValueError("Invalid Office numeric value")
    return value


def text(operation):
    value = operation["text"]
    if not isinstance(value, str) or len(value) > 10000000:
        raise ValueError("Invalid Office text")
    return value


def apply_style(cursor, operation):
    office_text.apply_style(cursor, operation)


def object_id(operation, key, existing):
    identifier = operation.get(key)
    if not isinstance(identifier, str) or not identifier or identifier not in existing:
        raise ValueError("Unknown Office object identity")
    return identifier


def new_id(operation, used):
    identifier = operation.get("id")
    if not isinstance(identifier, str) or not identifier or identifier in used:
        raise ValueError("Invalid or reused Office object identity")
    return identifier


def color_value(operation, key):
    value = operation[key]
    if type(value) is not int or not 0 <= value <= 0xffffff:
        raise ValueError("Invalid Office RGB color")
    return value


def explicit_fill_color(value, color):
    for name, assigned in (("FillColorTheme", -1), ("FillColorLumMod", 10000), ("FillColorLumOff", 0)):
        if writable_properties(value, name):
            value.setPropertyValue(name, assigned)
    value.FillColor = color


def apply_fill(value, operation):
    if any(name in operation for name in ("fillStyle", "fillColor")) and not writable_properties(value, "FillStyle", "FillColor"):
        raise ValueError("This Office object does not support fill edits")
    if "fillStyle" in operation:
        if operation["fillStyle"] not in ("none", "solid"):
            raise ValueError("Unsupported Office fill style")
        value.FillStyle = uno.Enum("com.sun.star.drawing.FillStyle", operation["fillStyle"].upper())
    if "fillColor" in operation:
        explicit_fill_color(value, color_value(operation, "fillColor"))


def apply_appearance(document, shape, operation):
    if shape_kind(shape) == "line" and any(name in operation for name in ("fillStyle", "fillColor")):
        raise ValueError("Line shapes do not support fill edits")
    apply_fill(shape, operation)
    if any(name in operation for name in ("lineStyle", "lineColor", "lineWidth")) and not writable_properties(shape, "LineStyle", "LineColor", "LineWidth"):
        raise ValueError("This Office object does not support line edits")
    if "lineStyle" in operation:
        if operation["lineStyle"] not in ("none", "solid"):
            raise ValueError("Unsupported Office line style")
        shape.LineStyle = uno.Enum("com.sun.star.drawing.LineStyle", operation["lineStyle"].upper())
    if "lineColor" in operation:
        color = color_value(operation, "lineColor")
        donor = document.createInstance("com.sun.star.drawing.Background")
        explicit_fill_color(donor, color)
        shape.LineComplexColor = donor.FillComplexColor
        shape.LineColor = color
    if "lineWidth" in operation:
        shape.LineWidth = round(number(operation, "lineWidth", 0, 100) * 100)


def apply_geometry(shape, operation):
    line = shape_kind(shape) == "line"
    width = round(number(operation, "width", 0 if line else .01) * 100)
    height = round(number(operation, "height", 0 if line else .01) * 100)
    if width == 0 and height == 0:
        raise ValueError("Office shapes must have a visible dimension")
    for name in ("TextAutoGrowHeight", "TextAutoGrowWidth"):
        if writable_properties(shape, name):
            shape.setPropertyValue(name, False)
    shape.Position = uno.createUnoStruct("com.sun.star.awt.Point", round(number(operation, "x") * 100), round(number(operation, "y") * 100))
    shape.Size = uno.createUnoStruct("com.sun.star.awt.Size", width, height)


def add_shape(document, page, operation):
    native = {"text": "TextShape", "rectangle": "RectangleShape", "ellipse": "EllipseShape", "line": "LineShape"}
    kind = operation.get("shapeKind")
    if not isinstance(kind, str) or (kind not in native and kind not in PRESET_SHAPES):
        raise ValueError("Unsupported new Office shape kind")
    content = text({"text": operation.get("text", "")})
    if kind == "line" and content:
        raise ValueError("New line shapes cannot contain text")
    shape = document.createInstance("com.sun.star.drawing." + native.get(kind, "CustomShape"))
    page.add(shape)
    if kind in PRESET_SHAPES:
        shape.createCustomShapeDefaults(PRESET_SHAPES[kind])
        if shape_kind(shape) != kind:
            raise ValueError("Office engine could not initialize the requested preset shape")
    if kind == "line":
        shape.FillStyle = uno.Enum("com.sun.star.drawing.FillStyle", "NONE")
        apply_appearance(document, shape, {"lineStyle": "solid", "lineColor": 0, "lineWidth": .5})
    else:
        shape.String = content
        apply_style(text_cursor(shape), {"fontSize": 18, "bold": False, "color": 0})
        apply_appearance(document, shape, {"fillStyle": "none" if kind == "text" else "solid",
            "fillColor": 0xffffff if kind == "text" else 0x16828a,
            "lineStyle": "none" if kind == "text" else "solid", "lineColor": 0, "lineWidth": .5})
    apply_geometry(shape, operation)
    return shape


def preset_reopen_locations(presentation, operations):
    pending = {operation['id']: operation['shapeKind'] for operation in operations
               if operation['op'] == 'shapeAdd' and operation['shapeKind'] in PRESET_SHAPES
               and operation['id'] in presentation.shapes}
    owners = {presentation.owners[identifier] for identifier in pending}
    locations = []
    for slide_index, owner in enumerate(presentation.logical):
        if owner not in owners:
            continue
        for shape_index, (identifier, shape) in enumerate(presentation.shape_items(owner)):
            kind = pending.pop(identifier, None)
            if kind is not None:
                if shape_kind(shape) != kind:
                    raise ValueError("Office edit changed the requested preset shape")
                locations.append((slide_index, shape_index, kind))
    if pending:
        raise ValueError("Could not locate the requested preset shape before saving")
    return locations


def range_target(kind, first, second, operation, presentation=None, word=None):
    target = operation.get('targetKind')
    if target == 'paragraph' and kind == 'word' and 'cell' not in operation:
        return (word.paragraph(operation.get('id')) if word is not None else first[object_id(operation, 'id', first)]), True
    if target == 'shape' and kind == 'presentation' and 'cell' not in operation:
        identifier = object_id(operation, 'id', second)
        if presentation is not None:
            presentation.require_edit(identifier, 'textStyle' if operation['op'] == 'textStyle' else 'text')
        shape = second[identifier]
        if shape_kind(shape) in ('line', 'image'):
            raise ValueError('This shape does not support text edits')
        return shape, False
    if target == 'cell' and kind == 'word':
        table = second[object_id(operation, 'id', second)]
        cell = operation.get('cell')
        if not isinstance(cell, str) or cell not in table.CellNames:
            raise ValueError('Unknown Office table cell')
        return table.getCellByName(cell), False
    raise ValueError('Unsupported Office text target')


def apply_operations(document, operations, image_assets=None, context=None, presentation_state=None, source_path=None,
        slide_sections=None):
    kind, first, second = objects(document)
    word = office_word_layout.WordDocument(document, first, second, uno, prop, context=context) if kind == 'word' else None
    if word is not None:
        word.image_catalog()
    presentation = office_presentation.Presentation(document, first, second, source_path) if kind == 'presentation' else None
    physical, logical = (presentation.physical, presentation.logical) if presentation is not None else (list(first), list(first))
    used_slides, used_shapes = (presentation.used, presentation.used) if presentation is not None else (set(first), set(second))
    owners = presentation.owners if presentation is not None else {}
    if presentation_state is not None:
        presentation_state['presentation'] = presentation
        presentation_state['word'] = word
    graphics = {}
    def asset_graphic(operation):
        identifier = operation.get('assetId')
        if not isinstance(identifier, str) or image_assets is None or identifier not in image_assets:
            raise ValueError('Unknown Office image asset identity')
        if identifier not in graphics:
            graphics[identifier] = office_images.load_graphic(context, image_assets[identifier], prop, uno)
        return graphics[identifier]
    if not isinstance(operations, list) or len(operations) > 10000:
        raise ValueError("Invalid Office operation list")
    for operation in operations:
        op = operation.get("op") if isinstance(operation, dict) else None
        if kind == 'word' and op == 'pageGeometry':
            word.geometry(operation)
        elif kind == 'word' and op in office_word.STRUCTURE_OPERATIONS:
            word.apply(operation)
        elif kind == 'presentation' and op == 'slideDesign':
            presentation.design(operation)
        elif kind == 'presentation' and op == 'slideDisplay':
            presentation.display(operation)
        elif op in ('textReplace', 'textStyle'):
            fields = ['op', 'targetKind', 'id', 'cell', 'startUtf16', 'endUtf16', 'expectedTextSha256']
            fields += ['text'] if op == 'textReplace' else ['fontSize', 'bold', 'italic', 'underline', 'color', 'fontFamily']
            require_keys(operation, fields)
            value, paragraph = range_target(kind, first, second, operation, presentation, word)
            if op == 'textReplace':
                office_text.replace_text(value, operation, paragraph, kind == 'word')
            else:
                office_text.style_text(value, operation, paragraph, kind == 'word')
        elif kind == "word" and op in ("paragraphText", "paragraphStyle"):
            require_keys(operation, ["op", "id", "text"] if op == "paragraphText" else ["op", "id", "fontSize", "bold", "color"])
            paragraph = word.paragraph(operation.get('id'))
            if op == "paragraphText":
                office_text.replace_legacy(paragraph, text(operation), True)
            else:
                apply_style(text_cursor(paragraph, True), operation)
        elif kind == "word" and op == "tableCellText":
            require_keys(operation, ["op", "tableId", "cell", "text"])
            office_text.replace_legacy(second[operation["tableId"]].getCellByName(operation["cell"]), text(operation))
        elif kind == 'presentation' and op == 'imageAdd':
            require_keys(operation, ['op', 'id', 'slideId', 'assetId', 'x', 'y', 'width', 'height'])
            identifier = new_id(operation, used_shapes)
            presentation.assert_fresh(identifier)
            owner = operation.get('slideId')
            page = presentation.owner(owner)
            shape = document.createInstance('com.sun.star.drawing.GraphicObjectShape')
            page.add(shape)
            shape.Graphic = asset_graphic(operation)
            apply_geometry(shape, operation)
            presentation.register_shape(identifier, shape, owner)
        elif kind == 'word' and op == 'imageReplace':
            require_keys(operation, ['op', 'id', 'assetId'])
            catalog = word.image_catalog()
            if catalog is None:
                raise ValueError('This Word document has no verified image catalog')
            identifier = object_id(operation, 'id', catalog.images)
            asset_id = operation.get('assetId')
            if not isinstance(asset_id, str) or asset_id not in (image_assets or {}):
                raise ValueError('Unknown verified Word image asset')
            catalog.replace(identifier, image_assets[asset_id])
        elif kind == 'word' and op in ('wordImageAdd', 'wordImageMove', 'wordImageDelete'):
            fields = ['op', 'id']
            if op != 'wordImageDelete':
                fields += ['ownerId', 'paragraphId', 'offsetUtf16', 'expectedTextSha256']
            if op == 'wordImageAdd':
                fields += ['assetId', 'width', 'height']
            require_keys(operation, fields)
            catalog = word.image_catalog()
            if catalog is None:
                raise ValueError('This Word source has no verified image catalog')
            if op == 'wordImageAdd':
                asset_id = operation.get('assetId')
                if not isinstance(asset_id, str) or asset_id not in (image_assets or {}):
                    raise ValueError('Unknown sealed Word image asset')
                catalog.add(operation, image_assets[asset_id])
            elif op == 'wordImageMove':
                catalog.move(operation)
            else:
                catalog.delete(operation)
        elif kind == 'presentation' and op == 'imageReplace':
            require_keys(operation, ['op', 'id', 'assetId'])
            identifier = object_id(operation, 'id', second)
            presentation.require_edit(identifier, 'image')
            shape = second[identifier]
            if shape_kind(shape) != 'image' or not writable_properties(shape, 'Graphic'):
                raise ValueError('This Office object is not a replaceable photo')
            office_images.replace_graphic(shape, asset_graphic(operation))
        elif kind == 'presentation' and op == 'imageRotate':
            require_keys(operation, ['op', 'id', 'expectedRotationHundredths', 'rotationHundredths'])
            identifier = object_id(operation, 'id', second)
            shape = second[identifier]
            current = photo_rotation(shape)
            expected = operation.get('expectedRotationHundredths')
            rotation = operation.get('rotationHundredths')
            if (any(type(value) is not int or not 0 <= value < 36000 for value in (expected, rotation)) or
                    rotation == expected or (rotation - expected) % 9000 != 0):
                raise ValueError('Office photo rotation requires a nonzero quarter turn')
            if not can_rotate_photo(shape, presentation.shape_metadata(identifier), current):
                raise ValueError('This Office photo cannot be rotated')
            if current != expected:
                raise ValueError('The Office photo rotation changed since inspection')
            # UNO changes the reported Position as the picture turns about its center.
            before = (shape.Size.Width, shape.Size.Height, shape.ZOrder, shape.GraphicCrop)
            shape.RotateAngle = (-rotation) % 36000
            after = (shape.Size.Width, shape.Size.Height, shape.ZOrder, shape.GraphicCrop)
            if photo_rotation(shape) != rotation or after != before:
                raise ValueError('Native rotation did not preserve the Office photo geometry or crop')
        elif kind == "presentation" and op in ("shapeText", "shapeStyle", "shapeGeometry", "shapeAppearance"):
            allowed = {"shapeText": ["op", "id", "text"], "shapeStyle": ["op", "id", "fontSize", "bold", "color"],
                       "shapeGeometry": ["op", "id", "x", "y", "width", "height"],
                       "shapeAppearance": ["op", "id", "fillStyle", "fillColor", "lineStyle", "lineColor", "lineWidth"]}[op]
            require_keys(operation, allowed)
            identifier = object_id(operation, 'id', second)
            presentation.require_edit(identifier, {'shapeStyle': 'textStyle', 'shapeGeometry': 'geometry'}.get(op, 'content'))
            shape = second[identifier]
            if op == "shapeText":
                if shape_kind(shape) in ('line', 'image'):
                    raise ValueError("This shape does not support text edits")
                office_text.replace_legacy(shape, text(operation), scalar_cursor=False)
            elif op == "shapeStyle":
                apply_style(text_cursor(shape), operation)
            elif op == "shapeGeometry":
                apply_geometry(shape, operation)
            else:
                apply_appearance(document, shape, operation)
        elif kind == "presentation" and op == "shapeAdd":
            require_keys(operation, ["op", "id", "slideId", "shapeKind", "x", "y", "width", "height", "text"])
            identifier = new_id(operation, used_shapes)
            presentation.assert_fresh(identifier)
            owner = operation.get('slideId')
            page = presentation.owner(owner)
            if (isinstance(operation.get('shapeKind'), str) and operation['shapeKind'] in PRESET_SHAPES
                    and presentation.owner_kind(owner) != 'slide'):
                raise ValueError("Preset shapes can only be added to a slide")
            presentation.register_shape(identifier, add_shape(document, page, operation), owner)
        elif kind == "presentation" and op == "shapeDelete":
            require_keys(operation, ["op", "id"])
            identifier = object_id(operation, "id", second)
            presentation.require_edit(identifier, 'delete')
            presentation.owner(owners.pop(identifier)).remove(second.pop(identifier))
        elif kind == "presentation" and op == "slideBackground":
            require_keys(operation, ["op", "id", "fillStyle", "fillColor"])
            page = presentation.owner(operation.get('id'))
            if "fillStyle" not in operation and "fillColor" not in operation:
                continue
            background = optional_property(page, "Background")
            live_master_style = (operation.get('id') in presentation.masters and background is not None and
                background.supportsService('com.sun.star.style.Style'))
            if background is None:
                if "fillStyle" not in operation:
                    raise ValueError("An inherited background requires an explicit fill style")
                background = document.createInstance("com.sun.star.drawing.Background")
            apply_fill(background, operation)
            if not live_master_style:
                page.Background = background
            applied = optional_property(page, 'Background')
            if ('fillColor' in operation and optional_property(applied, 'FillColor') != operation['fillColor'] or
                    'fillStyle' in operation and optional_property(applied, 'FillStyle') !=
                    uno.Enum('com.sun.star.drawing.FillStyle', operation['fillStyle'].upper())):
                raise ValueError('The requested Office background was not applied')
        elif kind == "presentation" and op == "slideAdd":
            require_keys(operation, ["op", "id", "index", "text"])
            identifier = new_id(operation, used_slides)
            presentation.assert_fresh(identifier)
            index = operation["index"]
            if identifier + "/shape-0" in used_shapes or type(index) is not int or not 0 <= index <= len(logical):
                raise ValueError("Invalid new slide identity or position")
            if slide_sections is not None:
                slide_sections.assign(identifier, logical[min(index, len(logical) - 1)])
            page = document.DrawPages.insertNewByIndex(len(physical))
            page.Width, page.Height = next(iter(first.values())).Width, next(iter(first.values())).Height
            first[identifier] = page
            physical.append(identifier)
            logical.insert(index, identifier)
            presentation.table_catalog.register_empty_owner(identifier, page)
            shape = document.createInstance("com.sun.star.drawing.TextShape")
            page.add(shape)
            shape.Position = uno.createUnoStruct("com.sun.star.awt.Point", 1000, 1000)
            shape.Size = uno.createUnoStruct("com.sun.star.awt.Size", max(1000, page.Width - 2000), 3000)
            shape.String = text(operation)
            used_slides.add(identifier)
            presentation.register_shape(identifier + '/shape-0', shape, identifier)
        elif kind == "presentation" and op == "slideDelete":
            require_keys(operation, ["op", "id"])
            identifier = object_id(operation, "id", first)
            if len(logical) <= 1:
                raise ValueError("A presentation must retain a slide")
            if slide_sections is not None:
                slide_sections.remove(identifier)
            document.DrawPages.remove(first.pop(identifier))
            physical.remove(identifier)
            logical.remove(identifier)
            for key in [key for key, owner in owners.items() if owner == identifier]:
                second.pop(key)
                owners.pop(key)
        elif kind == "presentation" and op == "slideMove":
            require_keys(operation, ["op", "id", "index"])
            identifier, index = object_id(operation, "id", first), operation["index"]
            if type(index) is not int or not 0 <= index < len(logical):
                raise ValueError("Invalid slide destination")
            if logical[index] == identifier:
                continue
            if slide_sections is not None:
                slide_sections.assign(identifier, logical[index])
            logical.remove(identifier)
            logical.insert(index, identifier)
        else:
            raise ValueError("Unsupported Office operation")
    return kind, physical, logical


def reordered_pptx(source, destination, physical, logical):
    with zipfile.ZipFile(source) as archive:
        root = ET.fromstring(archive.read("ppt/presentation.xml"))
        slides = root.find("{http://schemas.openxmlformats.org/presentationml/2006/main}sldIdLst")
        if slides is None or len(slides) != len(physical):
            raise ValueError("Presentation order could not be verified")
        elements = dict(zip(physical, list(slides)))
        slides[:] = [elements[identifier] for identifier in logical]
        with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as output:
            for info in archive.infolist():
                output.writestr(info, ET.tostring(root, encoding="utf-8", xml_declaration=True)
                                if info.filename == "ppt/presentation.xml" else archive.read(info.filename))


def apply_slide_duplicate(runtime, source, source_hash, request, directory, server_factory):
    operations = request['operations']
    if len(operations) != 1:
        raise ValueError('Slide duplication requires a separate edit')
    operation = operations[0]
    slide_id = operation.get('id')
    session_id = request.get('sessionId')
    if (set(operation) != {'op', 'id'} or
            type(slide_id) is not str or re.fullmatch(r'slide-(0|[1-9][0-9]{0,5})', slide_id) is None or
            source.suffix.lower() != '.pptx' or request.get('expectedSourceSha256') != source_hash or
            request.get('imageAssets', []) != [] or request.get('includeDraftSnapshot', False) or
            type(session_id) is not str or not session_id.strip()):
        raise ValueError('Slide duplication requires one saved PPTX slide and its exact source hash')

    from office_presentation_duplicate import duplicate_pptx

    directory.mkdir(parents=True, exist_ok=False)
    edited, pdf = directory / 'edited.pptx', directory / 'preview.pdf'
    slide_index = int(slide_id[6:])
    try:
        duplicate_pptx(source, edited, slide_index, source_hash)
        edited_hash = digest(edited)
        with server_factory(runtime, directory) as server:
            original = server.load(source, read_only=True)
            try:
                kind, slides, _ = objects(original)
                if kind != 'presentation' or slide_index >= len(slides):
                    raise ValueError('Slide duplication original verification failed')
                expected_pages = len(slides) + 1
            finally:
                original.close(True)
            duplicate = server.load(edited, read_only=True)
            try:
                reopened = snapshot(duplicate, edited_hash, server.context, source_path=edited)
                if (reopened['kind'] != 'presentation' or
                        len(reopened['slides']) != expected_pages):
                    raise ValueError('Slide duplication reopen verification failed')
                page_count = export_pdf(duplicate, pdf, 'presentation')
            finally:
                duplicate.close(True)
        if page_count != expected_pages or digest(source) != source_hash or digest(edited) != edited_hash:
            raise ValueError('Slide duplication PDF verification failed')
        return {'status': 'saved', 'sessionId': session_id, 'sourcePath': str(edited),
                'pdfPath': str(pdf), 'sourceSha256': edited_hash, 'pdfSha256': digest(pdf),
                'pdfPageCount': page_count, 'engineVersion': 'LibreOffice26.8.2.2', 'snapshot': reopened}
    except BaseException as error:
        for output in (edited, pdf):
            try:
                output.unlink(missing_ok=True)
            except OSError as cleanup_error:
                error.add_note('Removing private failed slide duplicate output: ' + str(cleanup_error))
        raise


def _legacy_copy_digest(path):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= LEGACY_COPY_LIMIT:
        raise ValueError('Invalid or oversized Office conversion file')
    return digest(path)


def convert_legacy(runtime, request, directory, server_factory):
    if set(request) != {'mode', 'sourcePath', 'sessionId', 'expectedSourceSha256'}:
        raise ValueError('Invalid Office conversion request fields')
    source_path = request['sourcePath']
    session_id, source_hash = request['sessionId'], request['expectedSourceSha256']
    if (type(source_path) is not str or not Path(source_path).is_absolute() or
            type(session_id) is not str or not session_id.strip() or len(session_id) > 128 or
            type(source_hash) is not str or re.fullmatch(r'[0-9a-f]{64}', source_hash) is None):
        raise ValueError('Invalid Office conversion source binding')
    source = Path(source_path).resolve(strict=True)
    extension = source.suffix[1:].lower()
    if extension not in LEGACY_COPY_FORMATS or _legacy_copy_digest(source) != source_hash:
        raise ValueError('Office conversion requires the exact original DOC or PPT')
    target, main_part = LEGACY_COPY_FORMATS[extension]
    directory = directory.parent.resolve(strict=True) / directory.name
    directory.mkdir(exist_ok=False)
    working = directory / ('working.' + extension)
    converted, pdf = directory / ('converted.' + target), directory / 'preview.pdf'
    try:
        with source.open('rb') as stream:
            magic = stream.read(len(COMPOUND_FILE_MAGIC))
            if magic != COMPOUND_FILE_MAGIC:
                raise ValueError('Office conversion requires a legacy compound document')
            with working.open('xb') as output:
                output.write(magic)
                size = len(magic)
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    size += len(block)
                    if size > LEGACY_COPY_LIMIT:
                        raise ValueError('Office conversion source exceeds the file limit')
                    output.write(block)
        if _legacy_copy_digest(working) != source_hash:
            raise ValueError('Office conversion source changed during copying')

        with server_factory(runtime, directory) as server:
            original = server.load(working, read_only=True)
            try:
                kind = require_document_kind(original, extension)
                if not original.isReadonly():
                    raise ValueError('Office conversion source must be read-only')
                slide_count = original.DrawPages.Count if kind == 'presentation' else None
                original.storeToURL(converted.as_uri(), (
                    prop('FilterName', FILTERS[target]), prop('Overwrite', False)))
            finally:
                original.close(True)

            converted_hash = _legacy_copy_digest(converted)
            with zipfile.ZipFile(converted) as archive:
                members = archive.infolist()
                names = {member.filename for member in members}
                if (len(names) != len(members) or
                        not {'[Content_Types].xml', main_part} <= names or
                        any(archive.getinfo(name).file_size < 1 for name in ('[Content_Types].xml', main_part)) or
                        sum(member.file_size for member in members) > LEGACY_COPY_LIMIT):
                    raise ValueError('Office conversion did not produce a bounded OOXML package')
            reopened = server.load(converted, read_only=True)
            try:
                require_document_kind(reopened, target)
                if not reopened.isReadonly():
                    raise ValueError('Reopened Office conversion must be read-only')
                if slide_count is not None and reopened.DrawPages.Count != slide_count:
                    raise ValueError('Office conversion changed the slide count')
                page_count = export_pdf(reopened, pdf, kind, max_bytes=LEGACY_COPY_LIMIT)
            finally:
                reopened.close(True)

        if (page_count < 1 or slide_count is not None and page_count != slide_count or
                _legacy_copy_digest(source) != source_hash or _legacy_copy_digest(working) != source_hash or
                _legacy_copy_digest(converted) != converted_hash):
            raise ValueError('Office conversion source or PDF verification failed')
        return {'sessionId': session_id, 'inputSourceSha256': source_hash, 'targetExtension': target,
                'sourcePath': str(converted), 'sourceSha256': converted_hash, 'pdfPath': str(pdf),
                'pdfSha256': _legacy_copy_digest(pdf), 'pdfPageCount': page_count,
                'engineVersion': 'LibreOffice26.8.2.2'}
    except BaseException as error:
        try:
            if directory.resolve(strict=True) == directory:
                shutil.rmtree(directory)
        except OSError as cleanup_error:
            error.add_note('Removing private failed Office conversion: ' + str(cleanup_error))
        raise


def run_request(runtime, request, directory, asset_root=None, *, native_stages=None, server_factory=None):
    if request.get('mode') == 'convertLegacy':
        return convert_legacy(runtime, request, directory, OfficeServer if server_factory is None else server_factory)
    if set(request) - {"mode", "sourcePath", "sessionId", "operations", "expectedSourceSha256", "preview", 'imageAssets', 'includeDraftSnapshot'}:
        raise ValueError("Unsupported Office request fields")
    mode = request["mode"]
    if mode not in ("inspect", "apply"):
        raise ValueError("Unsupported Office request")
    if 'imageAssets' in request and mode != 'apply':
        raise ValueError('Image assets require an Office edit operation')
    include_draft = request.get('includeDraftSnapshot', False)
    if type(include_draft) is not bool or 'includeDraftSnapshot' in request and mode != 'apply':
        raise ValueError('Draft snapshot requires a boolean Office apply request')
    preview = request.get("preview", False)
    if not isinstance(preview, bool) or preview and mode != "inspect":
        raise ValueError("Invalid Office preview request")
    source = Path(request["sourcePath"]).resolve(strict=True)
    extension = source.suffix[1:].lower()
    if not source.is_file() or extension not in FILTERS:
        raise ValueError("Unsupported Office source")
    source_hash = digest(source)
    has_geometry = mode == 'apply' and isinstance(request.get('operations'), list) and any(
        isinstance(operation, dict) and operation.get('op') == 'pageGeometry' for operation in request['operations'])
    has_word_images = mode == 'apply' and extension in ('docx', 'doc', 'odt') and isinstance(request.get('operations'), list) and any(
        isinstance(operation, dict) and operation.get('op') == 'imageReplace' for operation in request['operations'])
    has_word_mutations = mode == 'apply' and isinstance(request.get('operations'), list) and any(
        isinstance(operation, dict) and operation.get('op') in ('wordImageAdd', 'wordImageMove', 'wordImageDelete')
        for operation in request['operations'])
    if has_word_mutations:
        has_word_images = True
    if has_word_images and (extension != 'docx' or request.get('expectedSourceSha256') != source_hash):
        raise ValueError('Word image replacement requires a DOCX source and its inspected source hash')
    if has_geometry and (extension != 'docx' or request.get('expectedSourceSha256') != source_hash):
        raise ValueError('Word page geometry requires a DOCX source and its inspected source hash')
    if request.get("expectedSourceSha256") not in (None, source_hash):
        raise ValueError("Office source changed since inspection")
    server_factory = OfficeServer if server_factory is None else server_factory
    operations = request.get('operations')
    has_pptx_slide_edits = mode == 'apply' and extension == 'pptx' and isinstance(operations, list) and any(
        isinstance(operation, dict) and operation.get('op') in ('slideAdd', 'slideDelete', 'slideMove')
        for operation in operations)
    moves_only = has_pptx_slide_edits and all(
        isinstance(operation, dict) and operation.get('op') == 'slideMove' for operation in operations)
    if mode == 'apply' and isinstance(operations, list) and any(
            isinstance(operation, dict) and operation.get('op') == 'slideDuplicate' for operation in operations):
        return apply_slide_duplicate(runtime, source, source_hash, request, directory, server_factory)
    has_source_structure = mode == 'apply' and isinstance(operations, list) and any(
        isinstance(operation, dict) and operation.get('op') == 'presentationSourceTableAdd' for operation in operations)
    if has_source_structure:
        import office_presentation_structure_edit

        if any(not isinstance(operation, dict) or operation.get('op') != 'presentationSourceTableAdd' for operation in operations):
            raise ValueError('Mixed native, source text and source structure batches are unsupported')
        if extension != 'pptx' or request.get('expectedSourceSha256') != source_hash or request.get('imageAssets'):
            raise ValueError('Source table creation requires the pinned PPTX source and no native/image batch')
        office_presentation_structure_edit.validate_batch(operations, source_hash)
        return office_presentation_structure_edit.apply_source_structure_edit(runtime, source, source_hash, operations, directory,
            request['sessionId'], include_draft, server_factory=server_factory, objects=objects,
            snapshot=snapshot, export_pdf=export_pdf, native_stages=native_stages)
    has_source_text = mode == 'apply' and isinstance(operations, list) and any(
        isinstance(operation, dict) and operation.get('op') == 'presentationCellTextPatch' for operation in operations)
    if has_source_text:
        import office_presentation_source_edit

        if any(not isinstance(operation, dict) or operation.get('op') != 'presentationCellTextPatch' for operation in operations):
            raise ValueError('Mixed native and source text patch batches are unsupported')
        if extension != 'pptx' or request.get('expectedSourceSha256') != source_hash or request.get('imageAssets'):
            raise ValueError('Source text patch requires the pinned PPTX source and no native/image batch')
        office_presentation_source_edit.validate_batch(operations, source_hash)
        return office_presentation_source_edit.apply_source_text_edit(runtime, source, source_hash, operations, directory,
            request['sessionId'], include_draft, server_factory=server_factory, objects=objects,
            snapshot=snapshot, export_pdf=export_pdf, native_stages=native_stages)
    if native_stages is not None and mode == 'inspect' and extension == 'pptx':
        return native_stages.inspect(runtime, source, source_hash, request, directory)
    slide_sections = None
    if has_pptx_slide_edits:
        from office_presentation_package_patch import read_slide_sections

        slide_sections = read_slide_sections(source, source_hash)
    source_directory_ready = False
    if mode == 'apply' and extension == 'pptx' and include_draft and operations == [] and not request.get('imageAssets'):
        import office_presentation_source_edit

        empty_preview = office_presentation_source_edit.apply_source_text_edit(runtime, source, source_hash, [], directory,
            request['sessionId'], include_draft, server_factory=server_factory, objects=objects,
            snapshot=snapshot, export_pdf=export_pdf, allow_empty_fallback=True, native_stages=native_stages)
        if empty_preview is not None:
            return empty_preview
        source_directory_ready = True
    image_assets = office_images.read_assets(request.get('imageAssets', []), asset_root or directory.parent)
    if not source_directory_ready:
        directory.mkdir(parents=True, exist_ok=False)
    working = directory / ("working." + extension)
    if source_directory_ready and working.exists():
        raise ValueError('Preserve an existing legacy no-op working copy')
    shutil.copyfile(source, working)
    if source_directory_ready and (digest(source) != source_hash or digest(working) != source_hash):
        raise ValueError('The source or working copy changed before legacy no-op preview')
    with ExitStack() as cleanup:
        if mode == "inspect":
            cleanup.callback(shutil.rmtree, directory)
        server = cleanup.enter_context(server_factory(runtime, directory))
        prepared = None
        if mode == 'inspect' and extension == 'pptx':
            import office_presentation_binding

            try:
                prepared = cleanup.enter_context(office_presentation_binding.prepare_pptx_binding(
                    source, directory, source_hash))
            except ValueError as error:
                if digest(source) != source_hash or digest(working) != source_hash:
                    raise ValueError('The source or working copy changed before legacy inspection') from error
        document = (prepared.load(lambda path: server.load(path, read_only=True))
            if prepared is not None else server.load(working))
        verify_word_save = False
        source_ordered = False
        preset_locations = []
        processing_error = None
        try:
            require_document_kind(document, extension)
            if mode == "inspect":
                if prepared is not None:
                    kind, slides, shapes = objects(document)
                    if kind != 'presentation':
                        raise ValueError('A bound PPTX must load as an actual presentation')
                    presentation = office_presentation.Presentation(document, slides, shapes, source_path=source)
                    presentation.table_catalog.attach_source(prepared)
                    inspected = snapshot(document, source_hash, server.context, presentation=presentation,
                        source_path=source)
                else:
                    inspected = snapshot(document, source_hash, server.context, source_path=source)
                if preview:
                    pdf = directory.parent / ("preview-" + uuid.uuid4().hex + ".pdf")
                    pages = export_pdf(document, pdf, inspected["kind"])
                    if (pages < 1 or digest(source) != source_hash or
                            inspected["kind"] == "presentation" and pages != len(inspected["slides"])):
                        raise ValueError("Office preview verification failed")
                    inspected.update({"previewPdfPath": str(pdf), "previewPageCount": pages})
                return {"snapshot": inspected, "engineVersion": "LibreOffice26.8.2.2"}
            state = {}
            source_binding = {'source_path': source} if extension in ('pptx', 'ppt', 'odp') else {}
            kind, physical, logical = apply_operations(document, request["operations"], image_assets, server.context, state,
                slide_sections=slide_sections, **source_binding)
            if include_draft and kind not in ('presentation', 'word'):
                raise ValueError('Live snapshots require a supported Office document')
            presentation = state['presentation']
            word = state['word']
            if presentation is not None:
                preset_locations = preset_reopen_locations(presentation, operations)
            source_ordered = has_pptx_slide_edits and (moves_only or physical != logical or slide_sections is not None)
            serialization_count = 1 + int(extension != 'pptx' and kind == 'presentation' and physical != logical)
            verify_design = presentation is not None and presentation.requires_reopen_verification()
            live = snapshot(document, source_hash, server.context, presentation, word,
                source_path=source) if include_draft or verify_design else None
            verify_word_save = word is not None and word.requires_reopen_verification()
            word_verification = word.reopen_verification_state() if verify_word_save else None
            if verify_design:
                presentation.prepare_reopen(live, server.context, uno, prop)
            edited, pdf = directory / ("edited." + extension), directory / "preview.pdf"
            if source_ordered:
                from office_presentation_package_patch import write_reordered_pptx

                staging, staging_hash = working, source_hash
                if not moves_only:
                    staging = directory / 'staging.pptx'
                    document.storeToURL(staging.as_uri(), (prop('FilterName', FILTERS['pptx']), prop('Overwrite', True)))
                    staging_hash = digest(staging)
                document.close(True)
                document = None
                edited_hash = write_reordered_pptx(staging, edited, staging_hash, physical, logical, slide_sections)
            else:
                if kind == "presentation" and physical != logical:
                    staging = directory / "staging.pptx"
                    ordered = directory / "ordered.pptx"
                    document.storeToURL(staging.as_uri(), (prop("FilterName", FILTERS["pptx"]), prop("Overwrite", True)))
                    document.close(True)
                    document = None
                    reordered_pptx(staging, ordered, physical, logical)
                    document = server.load(ordered)
                    require_document_kind(document, extension)
                inline_spacing = office_word_inline.prepare_inline_spacing(
                    document, word.export_bindings, server.context, uno, prop) if word_verification is not None else {}
                document.storeToURL(edited.as_uri(), (prop("FilterName", FILTERS[extension]), prop("Overwrite", True)))
                document.close(True)
                document = None
                if inline_spacing:
                    office_word_export.restore_inline_spacing(edited, inline_spacing)
                edited_hash = digest(edited)
            document = server.load(edited, read_only=True) if source_ordered else server.load(edited)
            require_document_kind(document, extension)
            canonical_word = None
            if word_verification is not None:
                _, paragraphs, tables = objects(document)
                canonical_word = office_word_layout.WordDocument(document, paragraphs, tables, uno, prop, context=server.context)
                canonical_word.verify_reopened(word_verification)
            reopened = snapshot(document, edited_hash, server.context, word=canonical_word, source_path=edited)
            for slide_index, shape_index, expected_kind in preset_locations:
                slides = reopened['slides']
                if (slide_index >= len(slides) or shape_index >= len(slides[slide_index]['shapes'])
                        or slides[slide_index]['shapes'][shape_index]['shapeKind'] != expected_kind):
                    raise ValueError("Saved presentation did not retain the requested preset shape")
            if verify_design:
                presentation.verify_reopened(live, reopened, document, server.context, uno, prop,
                    serialization_count=serialization_count)
            page_count = export_pdf(document, pdf, kind)
            if (page_count < 1 or digest(source) != source_hash or
                    source_ordered and (digest(edited) != edited_hash or len(reopened['slides']) != len(logical)) or
                    kind == "presentation" and page_count != len(reopened["slides"])):
                raise ValueError("Office save verification failed")
            result = {"status": "saved", "sessionId": request["sessionId"], "sourcePath": str(edited),
                    "pdfPath": str(pdf), "sourceSha256": digest(edited), "pdfSha256": digest(pdf),
                    "pdfPageCount": page_count, "engineVersion": "LibreOffice26.8.2.2", "snapshot": reopened,
                    **({'draftSnapshot': live} if include_draft else {})}
            closing, document = document, None
            # The verified read-only candidate closes with its owned Office server.
            if not source_ordered:
                closing.close(True)
            return result
        except BaseException as error:
            processing_error = error
            if (has_geometry or has_word_images or verify_word_save or preset_locations or source_ordered
                    or isinstance(error, DocumentFamilyMismatch)):
                if document is not None:
                    try:
                        document.close(True)
                    except Exception as cleanup_error:
                        error.add_note('Closing failed verified Office document: ' + str(cleanup_error))
                    document = None
                for name in ('edited.' + extension, 'preview.pdf'):
                    try:
                        (directory / name).unlink(missing_ok=True)
                    except OSError as cleanup_error:
                        error.add_note('Removing private failed Office output: ' + str(cleanup_error))
            raise
        finally:
            if document is not None:
                try:
                    document.close(True)
                except Exception as cleanup_error:
                    if processing_error is None:
                        raise
                    processing_error.add_note('Closing failed Office document: ' + str(cleanup_error))


def error_diagnostics(error):
    def summary(current):
        frames = []
        truncated = False
        traceback = current.__traceback__
        while traceback is not None:
            line = traceback.tb_lineno
            if type(line) is not int or line <= 0:
                truncated = True
                traceback = traceback.tb_next
                continue
            code = traceback.tb_frame.f_code
            frames.append({
                'file': (code.co_filename.replace('\\', '/').rsplit('/', 1)[-1] or '<unknown>')[:128],
                'function': (code.co_name or '<unknown>')[:128],
                'line': line,
            })
            if len(frames) > 16:
                del frames[0]
                truncated = True
            traceback = traceback.tb_next
        return {'type': type(current).__name__[:128], 'frames': frames,
            'framesTruncated': truncated}

    def cause(current):
        if current.__cause__ is not None:
            return current.__cause__
        return None if current.__suppress_context__ else current.__context__

    diagnostics = summary(error)
    causes = []
    seen = {id(error)}
    current = cause(error)
    truncated = False
    while current is not None:
        if id(current) in seen or len(causes) == 2:
            truncated = True
            break
        seen.add(id(current))
        causes.append(summary(current))
        current = cause(current)
    diagnostics.update({'causes': causes, 'causesTruncated': truncated})
    return diagnostics


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--response", type=Path, required=True)
    args = parser.parse_args()
    try:
        runtime = args.runtime.resolve()
        initialize(runtime)
        request = json.loads(args.request.read_text(encoding="utf-8"))
        from office_embedded_stages import EmbeddedPresentationStages

        # LibreOffice appends deeply nested registry paths inside the job profile.
        # The caller already creates a private request directory, and each phase
        # still validates its full job and phase tokens.
        directory = args.response.parent.resolve() / ("job-" + uuid.uuid4().hex[:10])
        if directory.exists():
            raise FileExistsError("Office job directory already exists")
        with EmbeddedPresentationStages(runtime, request, directory,
                helpers=Path(__file__).resolve().parent) as stages:
            result = run_request(runtime, request, directory, native_stages=stages)
        response = {"ok": True, "result": result}
    except Exception as error:
        code = "office_format_mismatch" if isinstance(error, DocumentFamilyMismatch) else "office_operation_failed"
        response = {"ok": False, "error": {"code": code, "message": str(error),
            "diagnostics": error_diagnostics(error)}}
    args.response.write_text(json.dumps(response, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
