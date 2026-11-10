(function (request) {
    "use strict";

    var protocol = "piv-cell-1";
    var mayHaveMutated = false;
    var phase = "preflight";
    var documentUrl = null;
    var sessionId = request && typeof request.sessionId === "string" ? request.sessionId : null;
    var action = request && typeof request.action === "string" ? request.action : null;

    function fail(code) {
        throw {cellProgramCode: code};
    }

    function integer(value) {
        return typeof value === "number" && isFinite(value) && Math.floor(value) === value;
    }

    function unicode(value) {
        if (typeof value !== "string") return false;
        for (var index = 0; index < value.length; index++) {
            var code = value.charCodeAt(index);
            if (code >= 0xD800 && code <= 0xDBFF) {
                index++;
                if (index >= value.length) return false;
                code = value.charCodeAt(index);
                if (code < 0xDC00 || code > 0xDFFF) return false;
            } else if (code >= 0xDC00 && code <= 0xDFFF) {
                return false;
            }
        }
        return true;
    }

    function fileUrl(value) {
        if (typeof value !== "string" || value.length > 8192 || !unicode(value) ||
                /[\\?#\u0000-\u0020\u007f]/.test(value)) fail("invalid_document_url");
        var match = /^file:(\/+)(.+)$/.exec(value);
        if (!match || match[1].length === 2 || /(^|\/)\.{1,2}(\/|$)/.test(match[2])) {
            fail("invalid_document_url");
        }
        return "file:///" + match[2];
    }

    function nativeString(value) {
        if (typeof value !== "string") fail("invalid_native_state");
        if (value.length > 200000) fail("observation_limit");
        if (!unicode(value)) fail("invalid_native_state");
        return value;
    }

    function nativeBoolean(value) {
        if (typeof value !== "boolean") fail("invalid_native_state");
        return value;
    }

    function count(value, maximum, positive) {
        if (!integer(value) || value < (positive ? 1 : 0)) fail("invalid_native_state");
        if (value > maximum) fail("observation_limit");
        return value;
    }

    function same(left, right) {
        if (left === right) return true;
        if (left === null || right === null || typeof left !== "object" || typeof right !== "object") return false;
        if (Array.isArray(left) !== Array.isArray(right)) return false;
        var leftKeys = Object.keys(left).sort();
        var rightKeys = Object.keys(right).sort();
        if (leftKeys.length !== rightKeys.length) return false;
        for (var index = 0; index < leftKeys.length; index++) {
            if (leftKeys[index] !== rightKeys[index] || !same(left[leftKeys[index]], right[rightKeys[index]])) return false;
        }
        return true;
    }

    function base(success) {
        return {protocol: protocol, sessionId: sessionId, documentUrl: documentUrl,
            action: action, success: success, mayHaveMutated: mayHaveMutated};
    }

    function bounded(result) {
        if (JSON.stringify(result).length > 200000) fail("observation_limit");
        return result;
    }

    function assertContext(model) {
        if (!nativeBoolean(model.supportsService("com.sun.star.presentation.PresentationDocument"))) {
            fail("unsupported_document");
        }
        if (fileUrl(model.getURL()) !== documentUrl) fail("document_mismatch");
        return nativeBoolean(model.isReadonly());
    }

    var enumTypes = {
        "com.sun.star.awt.FontSlant": true,
        "com.sun.star.style.ParagraphAdjust": true,
        "com.sun.star.style.BreakType": true,
        "com.sun.star.style.TabAlign": true,
        "com.sun.star.style.VerticalAlignment": true,
        "com.sun.star.table.ShadowLocation": true,
        "com.sun.star.text.WritingMode": true,
        "com.sun.star.text.RubyAdjust": true
    };
    var structTypes = {
        "com.sun.star.lang.Locale": {Language: "string", Country: "string", Variant: "string"},
        "com.sun.star.style.LineSpacing": {Mode: "short", Height: "short"},
        "com.sun.star.style.TabStop": {Position: "long", Alignment: "com.sun.star.style.TabAlign", DecimalChar: "char", FillChar: "char"},
        "com.sun.star.style.DropCapFormat": {Lines: "short", Count: "short", Distance: "short"},
        "com.sun.star.table.BorderLine": {Color: "long", InnerLineWidth: "short", OuterLineWidth: "short", LineDistance: "short"},
        "com.sun.star.table.BorderLine2": {Color: "long", InnerLineWidth: "short", OuterLineWidth: "short", LineDistance: "short", LineStyle: "short", LineWidth: "unsigned long"},
        "com.sun.star.table.ShadowFormat": {Location: "com.sun.star.table.ShadowLocation", ShadowWidth: "short", IsTransparent: "boolean", Color: "long"},
        "com.sun.star.awt.Point": {X: "long", Y: "long"},
        "com.sun.star.awt.Size": {Width: "long", Height: "long"}
    };

    function formatBudget() {
        return {paragraphs: 0, properties: 0, values: 0};
    }

    function supportedType(type, depth) {
        if (depth > 4) return false;
        if (/^(boolean|byte|short|unsigned short|long|unsigned long|hyper|unsigned hyper|float|double|char|string)$/.test(type)) return true;
        if (enumTypes[type] || structTypes[type]) return true;
        return type.slice(0, 2) === "[]" && supportedType(type.slice(2), depth + 1);
    }

    function formatValue(type, value, budget, depth) {
        budget.values++;
        if (budget.values > 131072) fail("observation_limit");
        if (depth > 5) throw new Error("unsupported_format_depth");
        if (type === "boolean") {
            if (typeof value !== "boolean") throw new Error("unsupported_format_value");
            return value;
        }
        if (type === "string" || type === "char") {
            if (!unicode(value) || value.length > 200000 || (type === "char" && value.length !== 1)) throw new Error("unsupported_format_value");
            return value;
        }
        if (type === "hyper" || type === "unsigned hyper") {
            if (typeof value !== "bigint") throw new Error("unsupported_format_value");
            return String(value);
        }
        if (/^(byte|short|unsigned short|long|unsigned long|float|double)$/.test(type)) {
            if (typeof value !== "number" || !isFinite(value) ||
                    (type !== "float" && type !== "double" && !integer(value))) throw new Error("unsupported_format_value");
            return value;
        }
        if (enumTypes[type]) {
            if (value === null || typeof value !== "object" || typeof value.toString !== "function") throw new Error("unsupported_format_enum");
            var label = value.toString();
            if (typeof label !== "string" || !/^[A-Za-z_][A-Za-z_0-9]*$/.test(label)) throw new Error("unsupported_format_enum");
            return label;
        }
        if (type.slice(0, 2) === "[]" && supportedType(type.slice(2), 0)) {
            if (!Array.isArray(value) || value.length > 1024) throw new Error("unsupported_format_sequence");
            var sequence = [];
            for (var item = 0; item < value.length; item++) sequence.push(formatValue(type.slice(2), value[item], budget, depth + 1));
            return sequence;
        }
        var fields = structTypes[type];
        if (!fields || value === null || typeof value !== "object") throw new Error("unsupported_format_struct");
        var result = {};
        var names = Object.keys(fields).sort();
        for (var index = 0; index < names.length; index++) {
            var name = names[index];
            result[name] = formatValue(fields[name], value[name], budget, depth + 1);
        }
        return result;
    }

    function formatProperty(name, scope) {
        if (scope === "character") {
            return /^Char/.test(name) || /^(HyperLinkURL|HyperLinkTarget|HyperLinkName|VisitedCharStyleName|UnvisitedCharStyleName|RubyText|RubyAdjust|RubyCharStyleName|RubyIsAbove)$/.test(name);
        }
        return /^(Para|Numbering)/.test(name) || /^(WritingMode|BreakType|OutlineLevel|PageDescName|PageNumberOffset|DropCapFormat|DropCapWholeWord|DropCapCharStyleName|LeftBorder|RightBorder|TopBorder|BottomBorder|BorderDistance|LeftBorderDistance|RightBorderDistance|TopBorderDistance|BottomBorderDistance|ShadowFormat)$/.test(name);
    }

    function retainedComplexColor(value, budget) {
        budget.values += 4;
        if (budget.values > 131072) fail("observation_limit");
        if (!value || typeof value !== "object" || typeof value.getType !== "function" ||
                typeof value.getThemeColorType !== "function" || typeof value.resolveColor !== "function") {
            throw new Error("unsupported_complex_color");
        }
        var colorType = value.getType();
        var themeType = value.getThemeColorType();
        if ((colorType !== 0 && colorType !== 4) || themeType !== -1) throw new Error("unsupported_complex_color");
        var resolved = value.resolveColor(null);
        if (!integer(resolved) || resolved < -2147483648 || resolved > 2147483647) throw new Error("unsupported_complex_color");
        if (colorType === 4 && resolved !== 0) throw new Error("unsupported_complex_color");
        return {colorType: colorType, themeColorType: themeType, resolvedColor: resolved};
    }

    function colorCompanions(properties, complexColor) {
        var names = ["CharColor", "CharTransparence", "CharColorTheme", "CharColorTintOrShade", "CharColorLumMod", "CharColorLumOff"];
        var values = {};
        for (var index = 0; index < names.length; index++) {
            var found = false;
            for (var item = 0; item < properties.length; item++) {
                var property = properties[item];
                if (property.name === names[index] && supportedType(property.typeName, 0) && integer(property.value)) {
                    values[property.name] = property.value;
                    found = true;
                    break;
                }
            }
            if (!found) throw new Error("unsupported_complex_color_companions");
        }
        // The observed type 4 / unknown-theme tuple is retained unchanged;
        // explicit RGB companions, rather than a valid theme, supply its color.
        if (complexColor.colorType === 4 && (values.CharColor < 0 || values.CharColor > 0xFFFFFF ||
                values.CharColorTheme !== -1)) throw new Error("unsupported_complex_color_companions");
    }

    function captureProperties(target, scope, budget, writeTarget) {
        var result = {supported: true, properties: [], signature: [], target: writeTarget};
        try {
            var descriptors = target.getPropertySetInfo().getProperties();
            if (!Array.isArray(descriptors) || descriptors.length > 512) throw new Error("unsupported_property_metadata");
            var seen = {};
            var complexColor = null;
            for (var index = 0; index < descriptors.length; index++) {
                var descriptor = descriptors[index];
                var name = descriptor.Name;
                if (typeof name !== "string" || name.length > 256 || !unicode(name)) throw new Error("unsupported_property_metadata");
                if (!formatProperty(name, scope)) continue;
                if (!integer(descriptor.Attributes)) throw new Error("unsupported_property_metadata");
                if ((descriptor.Attributes & 16) !== 0) continue;
                if (Object.prototype.hasOwnProperty.call(seen, name)) throw new Error("unsupported_property_metadata");
                seen[name] = true;
                budget.properties++;
                if (budget.properties > 65536) fail("observation_limit");
                if (!descriptor.Type || typeof descriptor.Type.toString !== "function") throw new Error("unsupported_property_type");
                var typeName = descriptor.Type.toString();
                if (typeof typeName !== "string" || typeName.length > 256) throw new Error("unsupported_property_type");
                var stateValue = target.getPropertyState(name);
                if (!stateValue || typeof stateValue.toString !== "function") throw new Error("unsupported_property_state");
                var state = stateValue.toString();
                if (state !== "DEFAULT_VALUE" && state !== "DIRECT_VALUE") throw new Error("unsupported_property_state");
                var property = {name: name, type: descriptor.Type, typeName: typeName, state: state};
                var signature = {name: name, type: typeName, state: state};
                if (name === "CharComplexColor" && typeName === "com.sun.star.util.XComplexColor") {
                    property.value = target.getPropertyValue(name);
                    signature.value = retainedComplexColor(property.value, budget);
                    complexColor = signature.value;
                } else if (supportedType(typeName, 0)) {
                    property.value = target.getPropertyValue(name);
                    signature.value = formatValue(typeName, property.value, budget, 0);
                } else if (state !== "DEFAULT_VALUE") {
                    throw new Error("unsupported_direct_format");
                }
                if (state === "DEFAULT_VALUE" && typeof writeTarget.setPropertyToDefault !== "function") throw new Error("unsupported_format_setter");
                if (scope === "paragraph" && name === "ParaAdjust" && state === "DEFAULT_VALUE" &&
                        typeof target.setPropertyToDefault !== "function") throw new Error("unsupported_format_setter");
                if (state === "DIRECT_VALUE" && (typeof writeTarget.setPropertyValue !== "function" || typeof uno.Any !== "function")) throw new Error("unsupported_format_setter");
                result.properties.push(property);
                result.signature.push(signature);
            }
            if (complexColor) colorCompanions(result.properties, complexColor);
            result.properties.sort(function (left, right) {return left.name < right.name ? -1 : left.name > right.name ? 1 : 0;});
            result.signature.sort(function (left, right) {return left.name < right.name ? -1 : left.name > right.name ? 1 : 0;});
            if (!result.properties.length) result.supported = false;
        } catch (error) {
            if (error && error.cellProgramCode === "observation_limit") throw error;
            result.supported = false;
        }
        return result;
    }

    function selectedCursor(text, range) {
        var cursor = text.createTextCursorByRange(range.getStart());
        cursor.gotoRange(range.getEnd(), true);
        return cursor;
    }

    function appendRun(runs, start, end, formatting) {
        var previous = runs.length ? runs[runs.length - 1] : null;
        if (previous && previous.end === start && previous.format === formatting) {
            previous.end = end;
        } else {
            runs.push({start: start, end: end, format: formatting});
        }
    }

    function formatSignature(paragraph, runs) {
        var character = [];
        for (var index = 0; index < runs.length; index++) {
            var run = runs[index];
            var previous = character.length ? character[character.length - 1] : null;
            if (previous && previous.end === run.start && same(previous.character, run.format.signature)) {
                previous.end = run.end;
            } else {
                character.push({start: run.start, end: run.end, character: run.format.signature});
            }
        }
        return {paragraph: paragraph.signature, runs: character};
    }

    function inspectText(cell, text, budget) {
        var textContainer = cell.getText();
        var paragraphs = textContainer.createEnumeration();
        var lines = [];
        var formats = [];
        var supported = true;
        var mixed = false;
        while (nativeBoolean(paragraphs.hasMoreElements())) {
            if (lines.length > text.length) fail("invalid_native_state");
            budget.paragraphs++;
            if (lines.length >= 512 || budget.paragraphs > 4096) fail("observation_limit");
            var paragraph = paragraphs.nextElement();
            var portions = paragraph.createEnumeration();
            var line = "";
            var portionsSeen = 0;
            var runs = [];
            while (nativeBoolean(portions.hasMoreElements())) {
                portionsSeen++;
                if (portionsSeen > 65536) fail("observation_limit");
                var portion = portions.nextElement();
                if (nativeString(portion.getPropertyValue("TextPortionType")) !== "Text") return {supported: false, lines: [], formats: [], signature: null};
                var value = nativeString(portion.getString());
                var characterFormat = captureProperties(portion, "character", budget, selectedCursor(textContainer, portion));
                supported = supported && characterFormat.supported;
                appendRun(runs, line.length, line.length + value.length, characterFormat);
                line += value;
            }
            mixed = mixed || portionsSeen > 1;
            if (!portionsSeen) {
                var emptyFormat = captureProperties(paragraph, "character", budget, selectedCursor(textContainer, paragraph));
                supported = supported && emptyFormat.supported;
                appendRun(runs, 0, 0, emptyFormat);
            }
            lines.push(line);
            var paragraphFormat = captureProperties(paragraph, "paragraph", budget, selectedCursor(textContainer, paragraph));
            supported = supported && paragraphFormat.supported;
            formats.push({paragraph: paragraphFormat, runs: runs, range: paragraph});
        }
        supported = supported && lines.length > 0 && lines.join("\n") === text;
        var signature = [];
        for (var index = 0; index < formats.length; index++) {
            signature.push(formatSignature(formats[index].paragraph, formats[index].runs));
        }
        return {supported: supported, mixed: mixed, lines: lines, formats: formats, signature: signature};
    }

    function exactKeys(value, names) {
        if (!value || typeof value !== "object" || Array.isArray(value)) return false;
        var keys = Object.keys(value).sort();
        names = names.slice().sort();
        if (keys.length !== names.length) return false;
        for (var index = 0; index < keys.length; index++) if (keys[index] !== names[index]) return false;
        return true;
    }

    function scalarBoundary(value, offset) {
        return offset === 0 || offset === value.length ||
            !(value.charCodeAt(offset - 1) >= 0xD800 && value.charCodeAt(offset - 1) <= 0xDBFF &&
              value.charCodeAt(offset) >= 0xDC00 && value.charCodeAt(offset) <= 0xDFFF);
    }

    function validateStylePlan(plan, saved, oldText, newText) {
        if (!exactKeys(plan, ["protocol", "oldUtf16Length", "newUtf16Length", "oldSha256", "newSha256", "paragraphs"]) ||
                plan.protocol !== "piv-text-style-map-1" || plan.oldUtf16Length !== oldText.length ||
                plan.newUtf16Length !== newText.length || typeof plan.oldSha256 !== "string" ||
                typeof plan.newSha256 !== "string" || !/^[0-9a-f]{64}$/.test(plan.oldSha256) ||
                !/^[0-9a-f]{64}$/.test(plan.newSha256) || !Array.isArray(plan.paragraphs)) fail("invalid_request");
        // Java verifies both SHA-256 values against the exact old/new UTF-8
        // bytes. The synchronous JSUNO API provides no digest primitive here.
        var newLines = newText.split("\n");
        if (newLines.length > 512 || plan.paragraphs.length !== newLines.length ||
                JSON.stringify(plan).length > 1048576) fail("invalid_request");
        var segmentsSeen = 0;
        for (var index = 0; index < newLines.length; index++) {
            var paragraph = plan.paragraphs[index];
            if (!exactKeys(paragraph, ["sourceParagraph", "segments"]) || !integer(paragraph.sourceParagraph) ||
                    paragraph.sourceParagraph < 0 || paragraph.sourceParagraph >= saved.lines.length ||
                    !Array.isArray(paragraph.segments) || paragraph.segments.length === 0) fail("invalid_request");
            var oldLine = saved.lines[paragraph.sourceParagraph];
            var newLine = newLines[index];
            var next = 0;
            if (!newLine.length && paragraph.segments.length !== 1) fail("invalid_request");
            for (var item = 0; item < paragraph.segments.length; item++) {
                var segment = paragraph.segments[item];
                segmentsSeen++;
                if (segmentsSeen > 16384 || !exactKeys(segment, ["kind", "newStart", "newEnd", "oldStart", "oldEnd"]) ||
                        (segment.kind !== "retain" && segment.kind !== "inherit") ||
                        !integer(segment.newStart) || !integer(segment.newEnd) || !integer(segment.oldStart) || !integer(segment.oldEnd) ||
                        segment.newStart !== next || segment.newEnd < segment.newStart || segment.newEnd > newLine.length ||
                        segment.oldStart < 0 || segment.oldEnd < segment.oldStart || segment.oldEnd > oldLine.length ||
                        !scalarBoundary(oldLine, segment.oldStart) || !scalarBoundary(oldLine, segment.oldEnd) ||
                        !scalarBoundary(newLine, segment.newStart) || !scalarBoundary(newLine, segment.newEnd)) fail("invalid_request");
                if (newLine.length ? segment.newStart === segment.newEnd : segment.kind !== "inherit") fail("invalid_request");
                if (oldLine.length ? segment.oldStart === segment.oldEnd : segment.oldStart !== 0 || segment.oldEnd !== 0) fail("invalid_request");
                if (segment.kind === "retain" && (segment.newEnd - segment.newStart !== segment.oldEnd - segment.oldStart ||
                        newLine.slice(segment.newStart, segment.newEnd) !== oldLine.slice(segment.oldStart, segment.oldEnd))) fail("invalid_request");
                next = segment.newEnd;
            }
            if (next !== newLine.length) fail("invalid_request");
        }
        return plan.paragraphs;
    }

    function plannedFormats(saved, newText, plan) {
        var lines = newText.split("\n");
        var mapping = plan ? null : paragraphMap(saved.lines, lines);
        var result = [];
        for (var index = 0; index < lines.length; index++) {
            var original = saved.formats[plan ? plan[index].sourceParagraph : mapping[index]];
            var runs = [];
            if (!plan) {
                appendRun(runs, 0, lines[index].length, original.runs[0].format);
            } else {
                var segments = plan[index].segments;
                for (var item = 0; item < segments.length; item++) {
                    var segment = segments[item];
                    var covered = segment.oldStart;
                    for (var source = 0; source < original.runs.length; source++) {
                        var run = original.runs[source];
                        if (segment.kind === "inherit") {
                            if ((run.start <= segment.oldStart && segment.oldStart < run.end) ||
                                    (run.start === 0 && run.end === 0 && segment.oldStart === 0 && segment.oldEnd === 0)) {
                                appendRun(runs, segment.newStart, segment.newEnd, run.format);
                                break;
                            }
                        } else {
                            var start = Math.max(run.start, segment.oldStart);
                            var end = Math.min(run.end, segment.oldEnd);
                            if (start < end) {
                                if (start !== covered) fail("invalid_request");
                                appendRun(runs, segment.newStart + start - segment.oldStart,
                                    segment.newStart + end - segment.oldStart, run.format);
                                covered = end;
                            }
                        }
                    }
                    if (segment.kind === "retain" && covered !== segment.oldEnd) fail("invalid_request");
                }
            }
            if (!runs.length || runs[0].start !== 0 || runs[runs.length - 1].end !== lines[index].length) fail("invalid_request");
            result.push({paragraph: original.paragraph, runs: runs, source: original, rawCharacter: null});
        }
        return result;
    }

    function paragraphMap(oldLines, newLines) {
        if (newLines.length > 512) fail("observation_limit");
        var mapping = [];
        var index;
        if (oldLines.length === newLines.length) {
            for (index = 0; index < newLines.length; index++) mapping.push(index);
            return mapping;
        }
        var scores = [];
        for (index = 0; index <= oldLines.length; index++) {
            var scoreRow = [];
            for (var column = 0; column <= newLines.length; column++) scoreRow.push(0);
            scores.push(scoreRow);
        }
        for (var oldIndex = oldLines.length - 1; oldIndex >= 0; oldIndex--) {
            for (var newIndex = newLines.length - 1; newIndex >= 0; newIndex--) {
                scores[oldIndex][newIndex] = oldLines[oldIndex] === newLines[newIndex] ?
                    scores[oldIndex + 1][newIndex + 1] + 1 : Math.max(scores[oldIndex + 1][newIndex], scores[oldIndex][newIndex + 1]);
            }
        }
        oldIndex = 0;
        newIndex = 0;
        while (oldIndex < oldLines.length && newIndex < newLines.length) {
            if (oldLines[oldIndex] === newLines[newIndex]) {
                mapping[newIndex++] = oldIndex++;
            } else if (scores[oldIndex + 1][newIndex] >= scores[oldIndex][newIndex + 1]) {
                oldIndex++;
            } else {
                newIndex++;
            }
        }
        for (index = 0; index < newLines.length; index++) {
            if (typeof mapping[index] === "number") continue;
            if (index > 0) {
                mapping[index] = mapping[index - 1];
            } else {
                var following = index + 1;
                while (following < newLines.length && typeof mapping[following] !== "number") following++;
                mapping[index] = following < newLines.length ? mapping[following] : 0;
            }
        }
        return mapping;
    }

    function compatibleProperties(saved, destination) {
        if (!saved.supported || !destination.supported) return false;
        var available = {};
        for (var item = 0; item < destination.properties.length; item++) {
            available[destination.properties[item].name] = destination.properties[item].typeName;
        }
        for (var index = 0; index < saved.properties.length; index++) {
            var property = saved.properties[index];
            if (available[property.name] !== property.typeName ||
                    (property.state === "DEFAULT_VALUE" && typeof destination.target.setPropertyToDefault !== "function") ||
                    (property.state === "DIRECT_VALUE" && (typeof destination.target.setPropertyValue !== "function" ||
                        typeof uno.Any !== "function"))) return false;
        }
        return true;
    }

    function prepareRawFormats(planned, text) {
        var lines = text.split("\n");
        var budget = formatBudget();
        for (var index = 0; index < planned.length; index++) {
            var format = planned[index];
            var needed = lines[index].length === 0;
            for (var item = 0; item < format.paragraph.properties.length; item++) {
                var property = format.paragraph.properties[item];
                if (property.name === "ParaAdjust" && property.state === "DEFAULT_VALUE") needed = true;
            }
            if (!needed) continue;
            var range = format.source.range;
            var paragraph = captureProperties(range, "paragraph", budget, range);
            var character = captureProperties(range, "character", budget, range);
            if (!compatibleProperties(format.paragraph, paragraph)) fail("cell_uneditable");
            for (var run = 0; run < format.source.runs.length; run++) {
                if (!compatibleProperties(format.source.runs[run].format, character)) fail("cell_uneditable");
            }
            var desired = lines[index].length === 0 ? format.runs[0].format : character;
            if (!compatibleProperties(desired, character)) fail("cell_uneditable");
            format.rawCharacter = desired;
        }
    }

    function queueProperties(saved, destination, work) {
        if (!compatibleProperties(saved, destination)) fail("verification_failed");
        for (var index = 0; index < saved.properties.length; index++) {
            var property = saved.properties[index];
            work.push({property: property, target: destination.target});
        }
    }

    function applyProperties(work) {
        work.sort(function (left, right) {
            function priority(property) {
                if (property.state === "DEFAULT_VALUE") return 0;
                if (property.name === "CharComplexColor" && property.typeName === "com.sun.star.util.XComplexColor") return 3;
                if (property.name === "ParaStyleName" || property.name === "CharStyleName" || property.name === "NumberingStyleName") return 1;
                return 2;
            }
            return priority(left.property) - priority(right.property);
        });
        for (var item = 0; item < work.length; item++) {
            var property = work[item].property;
            if (property.state === "DEFAULT_VALUE") {
                work[item].target.setPropertyToDefault(property.name);
            } else {
                work[item].target.setPropertyValue(property.name, new uno.Any(property.type, property.value));
            }
        }
    }

    function freshCursor(container, paragraph, line, start, end) {
        var cursor = container.createTextCursorByRange(paragraph.getStart());
        if (typeof cursor.goRight !== "function" || typeof cursor.getString !== "function" ||
                !nativeBoolean(cursor.goRight(start, false)) || !nativeBoolean(cursor.goRight(end - start, true)) ||
                nativeString(cursor.getString()) !== line.slice(start, end)) fail("verification_failed");
        return cursor;
    }

    function restoreTextFormat(planned, target, text) {
        var current = inspectText(target, text, formatBudget());
        if (!current.supported || current.formats.length !== planned.length) fail("verification_failed");
        var container = target.getText();
        var expected = [];
        var work = [];
        for (var index = 0; index < planned.length; index++) {
            var original = planned[index];
            var destination = current.formats[index];
            var line = current.lines[index];
            queueProperties(original.paragraph, {supported: destination.paragraph.supported,
                properties: destination.paragraph.properties,
                target: freshCursor(container, destination.range, line, 0, line.length)}, work);
            for (var item = 0; item < original.runs.length; item++) {
                var wanted = original.runs[item];
                var covered = wanted.start;
                for (var portion = 0; portion < destination.runs.length; portion++) {
                    var observed = destination.runs[portion];
                    var start = Math.max(wanted.start, observed.start);
                    var end = Math.min(wanted.end, observed.end);
                    if (start < end || (line.length === 0 && start === 0 && end === 0)) {
                        if (start !== covered) fail("verification_failed");
                        queueProperties(wanted.format, {supported: observed.format.supported,
                            properties: observed.format.properties,
                            target: freshCursor(container, destination.range, line, start, end)}, work);
                        covered = end;
                    }
                }
                if (covered !== wanted.end) fail("verification_failed");
            }
            expected.push(formatSignature(original.paragraph, original.runs));
        }
        applyProperties(work);
        // Raw DEFAULT setters clear the paragraph attribute set, including EOP
        // character attributes. Restore both scopes together, defaults first.
        var paragraphs = container.createEnumeration();
        var rawWork = [];
        var rawBudget = formatBudget();
        for (var index = 0; index < planned.length; index++) {
            if (!nativeBoolean(paragraphs.hasMoreElements())) fail("verification_failed");
            var paragraph = paragraphs.nextElement();
            if (planned[index].rawCharacter) {
                var paragraphFormat = captureProperties(paragraph, "paragraph", rawBudget, paragraph);
                var characterFormat = captureProperties(paragraph, "character", rawBudget, paragraph);
                queueProperties(planned[index].paragraph, paragraphFormat, rawWork);
                queueProperties(planned[index].rawCharacter, characterFormat, rawWork);
            }
        }
        if (nativeBoolean(paragraphs.hasMoreElements())) fail("verification_failed");
        applyProperties(rawWork);
        return expected;
    }

    function verifyRawFormats(planned, target) {
        var paragraphs = target.getText().createEnumeration();
        var budget = formatBudget();
        for (var index = 0; index < planned.length; index++) {
            if (!nativeBoolean(paragraphs.hasMoreElements())) fail("verification_failed");
            var paragraph = paragraphs.nextElement();
            if (planned[index].rawCharacter) {
                var paragraphFormat = captureProperties(paragraph, "paragraph", budget, paragraph);
                var characterFormat = captureProperties(paragraph, "character", budget, paragraph);
                if (!paragraphFormat.supported || !characterFormat.supported ||
                        !same(planned[index].paragraph.signature, paragraphFormat.signature) ||
                        !same(planned[index].rawCharacter.signature, characterFormat.signature)) fail("verification_failed");
            }
        }
        if (nativeBoolean(paragraphs.hasMoreElements())) fail("verification_failed");
    }

    function verifyFormats(before, after, tableIndex, cellIndex, expected) {
        if (before.length !== after.length) fail("verification_failed");
        for (var table = 0; table < before.length; table++) {
            if (before[table].length !== after[table].length) fail("verification_failed");
            for (var cell = 0; cell < before[table].length; cell++) {
                if (!before[table][cell].supported) continue;
                var wanted = table === tableIndex && cell === cellIndex ? expected : before[table][cell].signature;
                if (!after[table][cell].supported || !same(wanted, after[table][cell].signature)) fail("verification_failed");
            }
        }
    }

    function protectedCell(cell) {
        var info = cell.getPropertySetInfo();
        if (!nativeBoolean(info.hasPropertyByName("IsProtected"))) return false;
        return nativeBoolean(cell.getPropertyValue("IsProtected"));
    }

    function catalogue() {
        var model = uno.idl.com.sun.star.frame.Desktop.create(uno.componentContext)
            .getCurrentFrame().getController().getModel();
        var readonly = assertContext(model);
        var pages = model.getDrawPages();
        var pageCount = count(pages.getCount(), 128, false);
        var totalShapes = 0;
        var totalCells = 0;
        var tables = [];
        var references = [];
        var formats = [];
        var budget = formatBudget();
        for (var slide = 0; slide < pageCount; slide++) {
            var page = pages.getByIndex(slide);
            var shapeCount = count(page.getCount(), 2048, false);
            totalShapes += shapeCount;
            if (totalShapes > 2048) fail("observation_limit");
            for (var shapeIndex = 0; shapeIndex < shapeCount; shapeIndex++) {
                var shape = page.getByIndex(shapeIndex);
                if (nativeString(shape.getShapeType()) !== "com.sun.star.drawing.TableShape") continue;
                var table = shape.getPropertyValue("Model");
                var rows = count(table.getRows().getCount(), 256, true);
                var columns = count(table.getColumns().getCount(), 256, true);
                var cellCount = rows * columns;
                if (cellCount > 256 || totalCells + cellCount > 1024) fail("observation_limit");
                totalCells += cellCount;
                var position = shape.getPosition();
                var size = shape.getSize();
                if (!integer(position.X) || !integer(position.Y) || !integer(size.Width) ||
                        !integer(size.Height) || size.Width <= 0 || size.Height <= 0) fail("invalid_native_state");
                var snapshot = {slide: slide, shape: shapeIndex, pageCount: pageCount,
                    shapeCount: shapeCount, name: nativeString(shape.getPropertyValue("Name")),
                    rows: rows, columns: columns, x: position.X, y: position.Y,
                    width: size.Width, height: size.Height, cells: []};
                var cells = [];
                var cellFormats = [];
                for (var row = 0; row < rows; row++) {
                    for (var column = 0; column < columns; column++) {
                        var cell = table.getCellByPosition(column, row);
                        var rowSpan = cell.getRowSpan();
                        var columnSpan = cell.getColumnSpan();
                        var merged = nativeBoolean(cell.isMerged());
                        if (!integer(rowSpan) || rowSpan < 1 || !integer(columnSpan) || columnSpan < 1 ||
                                rowSpan > rows || columnSpan > columns) fail("invalid_native_state");
                        var text = nativeString(cell.getString());
                        var protectedValue = protectedCell(cell);
                        var formatting = inspectText(cell, text, budget);
                        snapshot.cells.push({row: row, column: column, text: text,
                            editable: !readonly && !protectedValue && !merged && rowSpan === 1 && columnSpan === 1 && formatting.supported});
                        cells.push(cell);
                        cellFormats.push(formatting);
                    }
                }
                tables.push(snapshot);
                references.push(cells);
                formats.push(cellFormats);
                bounded({tables: tables});
            }
        }
        var currentReadonly = assertContext(model);
        if (currentReadonly !== readonly) fail("invalid_native_state");
        return {tables: tables, references: references, formats: formats, model: model};
    }

    try {
        if (!request || typeof request !== "object" || Array.isArray(request) ||
                request.protocol !== protocol || (action !== "read" && action !== "replace") ||
                typeof sessionId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(sessionId)) {
            fail("invalid_request");
        }
        documentUrl = fileUrl(request.documentUrl);
        var before = catalogue();
        if (action === "read") {
            var readResult = base(true);
            readResult.tables = before.tables;
            return bounded(readResult);
        }
        if (!unicode(request.text) || request.text.length > 8192) fail("invalid_text");
        var expected = request.expected;
        var tableIndex = -1;
        for (var index = 0; index < before.tables.length; index++) {
            if (expected && before.tables[index].slide === expected.slide && before.tables[index].shape === expected.shape) {
                tableIndex = index;
                break;
            }
        }
        if (tableIndex < 0 || !same(before.tables[tableIndex], expected)) fail("stale_snapshot");
        var selected = before.tables[tableIndex];
        if (!integer(request.row) || !integer(request.column) || request.row < 0 || request.column < 0 ||
                request.row >= selected.rows || request.column >= selected.columns) fail("cell_out_of_bounds");
        var cellIndex = request.row * selected.columns + request.column;
        if (!selected.cells[cellIndex].editable || assertContext(before.model)) fail("cell_uneditable");
        var targetFormat = before.formats[tableIndex][cellIndex];
        var suppliedPlan = Object.prototype.hasOwnProperty.call(request, "stylePlan");
        if (!suppliedPlan && targetFormat.mixed) fail("invalid_request");
        var stylePlan = suppliedPlan ? validateStylePlan(request.stylePlan, targetFormat,
            selected.cells[cellIndex].text, request.text) : null;
        var planned = plannedFormats(targetFormat, request.text, stylePlan);
        prepareRawFormats(planned, request.text);
        var target = before.references[tableIndex][cellIndex];
        var targetText = target.getText();
        if (typeof targetText.insertTextPortion !== "function") fail("api_unavailable");
        var insertionRange = selectedCursor(targetText, target);
        var permitted = JSON.parse(JSON.stringify(before.tables));
        permitted[tableIndex].cells[cellIndex].text = request.text;
        var projectedRead = base(true);
        projectedRead.action = "read";
        projectedRead.tables = permitted;
        bounded(projectedRead);
        phase = "write";
        mayHaveMutated = true;
        targetText.insertTextPortion(request.text, [], insertionRange);
        phase = "verification";
        var expectedFormat = restoreTextFormat(planned, target, request.text);
        var after = catalogue();
        if (!same(permitted, after.tables)) fail("verification_failed");
        verifyFormats(before.formats, after.formats, tableIndex, cellIndex, expectedFormat);
        verifyRawFormats(planned, target);
        var replaceResult = base(true);
        replaceResult.table = after.tables[tableIndex];
        return bounded(replaceResult);
    } catch (error) {
        var result = base(false);
        result.code = mayHaveMutated ? (phase === "write" ? "write_failed" : "verification_failed") :
            (error && typeof error.cellProgramCode === "string" ? error.cellProgramCode : "api_unavailable");
        return result;
    }
})
