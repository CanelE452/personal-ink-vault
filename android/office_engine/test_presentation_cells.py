"""HOST ONLY: execute the shipped cell program against explicit UNO fixtures.

This proves the closed program's validation, DTO and mutation boundaries. It does
not establish that any candidate UNO API is exposed by Android's pinned JSUNO.
"""
import os
from pathlib import Path
import shutil
import subprocess
import unittest


MODULE = Path(__file__).resolve().parent
PROGRAM = MODULE / 'src/main/assets/piv-presentation-cells.js'
NODE = Path('C:/Users/User/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe')


HARNESS = r'''
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const source = fs.readFileSync(process.argv[2], 'utf8').trim();
const ID = '70bf425f-c413-457a-82cc-119c3f6cc8ae';
const URL = 'file:///data/user/0/io.github.canele452.personalinkvault/files/office-sessions/' + ID + '/working.pptx';
let passed = 0;

// These Type and enum objects model the pinned JSUNO boundary: native Type and
// enum values are live objects, while incoming property Any values need their
// declared Type. They are not Android runtime implementations.
class NativeType {
  constructor(name) { this.name = name; }
  toString() { return this.name; }
}
class NativeEnum {
  constructor(name) { this.type = name.slice(0, name.lastIndexOf('.')); this.name = name.slice(name.lastIndexOf('.') + 1); }
  toString() { return this.name; }
  toJSON() { return this.name; }
}
class NativeAny {
  constructor(type, value) { this.type = type; this.val = value; }
}
class NativeComplexColor {
  constructor(payload = {}, retained = {}, missingMethod = null) {
    this.payload = {type: 0, theme: -1, resolved: 0, ...payload};
    this.retained = retained;
    this.missingMethod = missingMethod;
    if (missingMethod) this[missingMethod] = undefined;
  }
  getType() { return this.payload.type; }
  getThemeColorType() { return this.payload.theme; }
  resolveColor(theme) { assert.equal(theme, null); return this.payload.resolved; }
  clone() { return new NativeComplexColor(this.payload, this.retained, this.missingMethod); }
}
const nativeTypes = new Map();
const nativeEnums = new Map();
const nativeCursors = new WeakMap();
function nativeType(name) {
  if (!nativeTypes.has(name)) nativeTypes.set(name, new NativeType(name));
  return nativeTypes.get(name);
}
function nativeEnum(name) {
  if (!nativeEnums.has(name)) nativeEnums.set(name, new NativeEnum(name));
  return nativeEnums.get(name);
}
function property(type, value, state = 'DIRECT_VALUE', defaultValue = value, attributes = 0) {
  return {type: nativeType(type), value, state: nativeEnum('com.sun.star.beans.PropertyState.' + state), defaultValue, attributes};
}
function defaultParagraphStyle() {
  // Actual drawing-text metadata can report ParaAdjust as short, despite the
  // public service IDL's enum declaration. Restore the declared runtime Type.
  return {ParaAdjust: property('short', 0, 'DEFAULT_VALUE'),
    ParaLeftMargin: property('long', 0, 'DEFAULT_VALUE')};
}
function defaultRunStyle() {
  return {CharColor: property('long', 0, 'DEFAULT_VALUE'), CharWeight: property('float', 100, 'DEFAULT_VALUE'),
    CharHeight: property('float', 12, 'DEFAULT_VALUE'),
    CharPosture: property('com.sun.star.awt.FontSlant', nativeEnum('com.sun.star.awt.FontSlant.NONE'), 'DEFAULT_VALUE')};
}
function styledLine(color, weight, posture, adjust = 'LEFT') {
  return {para: {...defaultParagraphStyle(), ParaAdjust: property('short',
    {LEFT: 0, RIGHT: 1, BLOCK: 2, CENTER: 3}[adjust], 'DIRECT_VALUE', 0)},
    run: {...defaultRunStyle(), CharColor: property('long', color, 'DIRECT_VALUE', 0),
      CharWeight: property('float', weight, 'DIRECT_VALUE', 100), CharPosture: property('com.sun.star.awt.FontSlant',
        nativeEnum('com.sun.star.awt.FontSlant.' + posture), 'DIRECT_VALUE', nativeEnum('com.sun.star.awt.FontSlant.NONE'))}};
}
function ordinaryRgbStyles(payload = {}, missingMethod = null) {
  return [styledLine(0x1122ff, 150, 'NONE'), styledLine(0xff2211, 100, 'ITALIC', 'RIGHT')].map((style, index) => {
    Object.assign(style.run, {
      CharTransparence: property('short', 25, 'DIRECT_VALUE', 0),
      CharColorTheme: property('short', -1, 'DIRECT_VALUE', -1),
      CharColorTintOrShade: property('short', 0, 'DIRECT_VALUE', 0),
      CharColorLumMod: property('long', 100000, 'DIRECT_VALUE', 100000),
      CharColorLumOff: property('long', 0, 'DIRECT_VALUE', 0),
      CharComplexColor: property('com.sun.star.util.XComplexColor',
        new NativeComplexColor(payload, {nativePayload: 'retained-native-alpha-' + index}, missingMethod), 'DIRECT_VALUE',
        new NativeComplexColor({}, {nativePayload: 'empty-default-' + index})),
    });
    return style;
  });
}
function resetRecord(record) {
  return Object.fromEntries(Object.entries(record).map(([name, item]) => [name,
    {...item, value: item.defaultValue, state: nativeEnum('com.sun.star.beans.PropertyState.DEFAULT_VALUE')}]));
}
function completeStyleMetadata(styles) {
  for (const scope of ['para', 'run']) {
    const records = scope === 'para' ? styles.map(style => style.para) :
      styles.flatMap(style => style.runs ? style.runs.map(run => run.run) : [style.run]);
    const descriptors = Object.assign({}, ...records);
    for (const record of records) {
      for (const [name, item] of Object.entries(descriptors)) {
        if (!Object.hasOwn(record, name)) record[name] = {...item, value: item.defaultValue,
          state: nativeEnum('com.sun.star.beans.PropertyState.DEFAULT_VALUE')};
      }
    }
  }
  return styles;
}
function copyRecord(record) {
  return Object.fromEntries(Object.entries(record).map(([name, item]) => [name, {...item}]));
}
function mixedLine(parts, adjust = 'LEFT') {
  let end = 0;
  const runs = parts.map(([text, style]) => {
    const start = end;
    end += text.length;
    return {start, end, run: style.run};
  });
  return {para: styledLine(0, 100, 'NONE', adjust).para, run: runs[0].run, runs};
}

function propertyTarget(record, state, options, metadataUnavailable, context = {}) {
  function selected() {
    if (context.cursor) assert.equal(context.selected, true, 'cursor must select the complete native range before property access');
  }
  function changed(kind, name) {
    selected();
    state.formatWrites.push({kind, name, cursor: !!context.cursor,
      cell: context.cellIndex, paragraph: context.paragraphIndex});
    if (options.emptyEopCharacter && context.kind === 'paragraph' && !context.cursor && context.emptyParagraph && /^Char/.test(name)) {
      state.lastRawEmptyCharacterWrite = state.formatWrites.length;
    }
  }
  function companionChanged(name) {
    if (record.CharComplexColor && /^(CharColor|CharTransparence|CharColorTheme|CharColorTintOrShade|CharColorLumMod|CharColorLumOff)$/.test(name)) {
      // Observed Windows native setters can alter the complex value. Even equivalent
      // visible RGB does not preserve its retained native fields by itself.
      record.CharComplexColor.value = new NativeComplexColor({}, {nativePayload: 'changed-by-' + name});
      record.CharComplexColor.state = nativeEnum('com.sun.star.beans.PropertyState.DIRECT_VALUE');
    }
  }
  const target = {
    getPropertySetInfo() {
      selected();
      if (metadataUnavailable) throw Error('property metadata is unavailable');
      return {
        getProperties() { return Object.entries(record).filter(([Name]) =>
          !(context.cellIndex === 0 && context.kind === 'paragraph' && !context.cursor &&
            options.rawParagraphCharacterFailure === 'metadata' && Name === 'CharWeight'))
          .map(([Name, item]) => ({Name,
            Type: context.cellIndex === 0 && context.kind === 'paragraph' && !context.cursor && Name === 'CharWeight' &&
              ['type', 'unsupportedType'].includes(options.rawParagraphCharacterFailure) ?
              nativeType(options.rawParagraphCharacterFailure === 'type' ? 'short' : 'any') : item.type,
            Attributes: item.attributes})); },
        hasPropertyByName(name) { return Object.hasOwn(record, name); },
        getPropertyByName(name) {
          assert.ok(Object.hasOwn(record, name));
          return {Name: name, Type: record[name].type, Attributes: record[name].attributes};
        },
      };
    },
    getPropertyValue(name) {
      selected();
      assert.ok(Object.hasOwn(record, name));
      if (name === 'CharComplexColor') {
        const value = record[name].value.clone();
        state.complexReads.push({value, beforeWrite: state.writes === 0,
          cell: context.cellIndex, paragraph: context.paragraphIndex});
        return value;
      }
      return record[name].value;
    },
    getPropertyState(name) {
      selected();
      assert.ok(Object.hasOwn(record, name));
      if (options.cursorParagraphStateDefaults && context.cursor && name === 'ParaAdjust') {
        return nativeEnum('com.sun.star.beans.PropertyState.DEFAULT_VALUE');
      }
      return record[name].state;
    },
    setPropertyValue(name, any) {
      assert.ok(state.writes > 0, 'format restoration follows actual text mutation');
      assert.ok(Object.hasOwn(record, name));
      assert.ok(any instanceof NativeAny, 'incoming UNO Any must carry its original native Type');
      assert.equal(any.type, record[name].type, 'float/enum/struct property retains declared native Type');
      if (options.restoreException) throw Error('format restoration failed');
      changed('direct', name);
      // The Windows UNO observation found raw paragraph ParaAdjust restoration
      // ineffective; other raw setters are not assumed to fail. The new full
      // range cursor contract is modeled only by this explicit fixture branch.
      if (options.nativeCursorRequired && !context.cursor && name === 'ParaAdjust') return;
      record[name].value = any.val;
      record[name].state = nativeEnum('com.sun.star.beans.PropertyState.' +
        (options.restoreStateMismatch ? 'DEFAULT_VALUE' : 'DIRECT_VALUE'));
      if (options.partialStyleMismatch && context.start > 0 && name === 'CharColor') record[name].value = 0xabcdef;
      if (options.eopStyleMismatch && context.kind === 'paragraph' && !context.cursor && name === 'CharColor') record[name].value = 0xabcdef;
      if (name === 'CharComplexColor') {
        assert.ok(any.val instanceof NativeComplexColor, 'native interface is restored from a live wrapper, not a JSON reconstruction');
        state.complexRestores.push({value: any.val, cell: context.cellIndex, paragraph: context.paragraphIndex, cursor: !!context.cursor});
        // Native MID_COMPLEX_COLOR copies its entire retained value and does
        // not overwrite the ordinary RGB companion.
        record[name].value = any.val.clone();
        if (options.complexSemanticMismatch && context.paragraphIndex === 0) record[name].value.payload.resolved = 77;
        if (options.complexCompanionMutation && context.paragraphIndex === 0) {
          const mutation = options.complexCompanionMutation;
          record[mutation.name][mutation.kind] = mutation.value;
        }
      } else companionChanged(name);
    },
    setPropertyToDefault(name) {
      assert.ok(state.writes > 0);
      assert.ok(Object.hasOwn(record, name));
      if (options.restoreException) throw Error('format default restoration failed');
      if (options.cursorParaAdjustDefaultMaterializes && !context.cursor && context.kind === 'paragraph' && name === 'ParaAdjust') {
        assert.equal(context.createdGeneration, state.generation, 'raw paragraph reset follows text mutation');
      }
      changed('default', name);
      if ((options.rawDefaultClearsParagraph || options.emptyEopCharacter) && context.kind === 'paragraph' && !context.cursor) {
        // Pinned raw-paragraph DEFAULT setters replace the paragraph attribute
        // set. This clears all direct paragraph/EOP attributes, while selected
        // Text portion character attributes remain a separate native state.
        const paragraph = state.styles[context.cellIndex][context.paragraphIndex];
        for (const attributes of [paragraph.para, paragraph.eopRun || {}]) {
          for (const item of Object.values(attributes)) {
            item.value = item.defaultValue;
            item.state = nativeEnum('com.sun.star.beans.PropertyState.DEFAULT_VALUE');
          }
        }
      }
      record[name].value = record[name].defaultValue;
      record[name].state = nativeEnum('com.sun.star.beans.PropertyState.' +
        (options.restoreStateMismatch || (options.nativeInsertionContract && state.usedSetString &&
          context.paragraphIndex === 1 && /^CharUnderline(?:Color|HasColor)?$/.test(name)) ? 'DIRECT_VALUE' : 'DEFAULT_VALUE'));
      // Controlled Windows UNO observation: a fresh cursor's DEFAULT reset
      // materialized ParaAdjust DIRECT/0, while the raw paragraph reset restored
      // DEFAULT/5. This fixture makes no claim about its internal native cause.
      if (options.cursorParaAdjustDefaultMaterializes && context.cursor && name === 'ParaAdjust') {
        record[name].value = 0;
        record[name].state = nativeEnum('com.sun.star.beans.PropertyState.DIRECT_VALUE');
      }
      companionChanged(name);
    },
  };
  if (options.rawParagraphDefaultUnavailable && context.cellIndex === 0 && context.kind === 'paragraph' && !context.cursor) {
    delete target.setPropertyToDefault;
  }
  if (context.cellIndex === 0 && context.kind === 'paragraph' && !context.cursor) {
    if (options.rawParagraphCharacterFailure === 'directSetter') delete target.setPropertyValue;
    if (options.rawParagraphCharacterFailure === 'defaultSetter') delete target.setPropertyToDefault;
  }
  return target;
}

function enumeration(values) {
  let index = 0;
  return {hasMoreElements() { return index < values.length; }, nextElement() {
    assert.ok(index < values.length, 'program must not overrun an enumeration');
    return values[index++];
  }};
}

// HOST ONLY fixture. These are deliberately explicit candidate UNO methods,
// not a mock of a verified Android runtime or a fallback native adapter.
function fixture(options = {}) {
  const state = {
    writes: 0, setStringWrites: 0, insertTextPortionWrites: 0, usedSetString: false,
    readonly: !!options.readonly, url: options.url === undefined ? URL : options.url,
    texts: options.texts || [['한글 😀\n둘째 줄', 'unchanged'], ['', 'last']],
    rows: options.rows || 2, columns: options.columns || 2,
    position: {X: 100, Y: 200}, size: {Width: 3000, Height: 1200},
    supported: options.supported !== false,
    styles: [],
    generation: 0,
    formatWrites: [], cursorSelections: [],
    complexReads: [], complexRestores: [],
  };
  const cells = [];
  for (let row = 0; row < state.rows; row++) {
    for (let column = 0; column < state.columns; column++) {
      const index = row * state.columns + column;
      state.styles[index] = completeStyleMetadata(options.styles && index === 0 ? options.styles :
        ((state.texts[row] || [])[column] || '').split('\n').map(() => ({para: defaultParagraphStyle(), run: defaultRunStyle()})));
      for (const [paragraphIndex, style] of state.styles[index].entries()) {
        const line = ((state.texts[row] || [])[column] || '').split('\n')[paragraphIndex];
        if (!style.runs) style.runs = options.richIndex === index && line.length > 1 ?
          [{start: 0, end: 1, run: style.run}, {start: 1, end: line.length, run: copyRecord(style.run)}] :
          [{start: 0, end: line.length, run: style.run}];
        if (!style.eopRun) style.eopRun = copyRecord(style.run);
      }
      function replaceContents(text, insertion) {
        state.writes++;
        state.generation++;
        if (insertion) state.insertTextPortionWrites++; else state.setStringWrites++;
        state.usedSetString = !insertion;
        if (options.writeException) throw Error('native write failed after entry');
        if (!options.readbackMismatch) {
          if (!state.texts[row]) state.texts[row] = [];
          state.texts[row][column] = text;
          const original = state.styles[index];
          // setString clears styles; the observed insertTextPortion path clears
          // character attributes while leaving paragraph attributes available.
          state.styles[index] = text.split('\n').map((line, lineIndex) => {
            const run = resetRecord(original[0].run);
            return {para: insertion ? Object.fromEntries(Object.entries(original[Math.min(lineIndex, original.length - 1)].para)
              .map(([name, item]) => [name, {...item}])) : resetRecord(original[0].para),
              run, runs: [{start: 0, end: line.length, run}], eopRun: resetRecord(original[0].eopRun)};
          });
        }
        if (options.onWrite) options.onWrite(state);
      }
      const cell = {
        getString() { return (state.texts[row] || [])[column] || ''; },
        setString(text) { replaceContents(text, false); },
        getStart() { return {cellIndex: index, paragraphIndex: null, kind: 'cell', edge: 'start'}; },
        getEnd() { return {cellIndex: index, paragraphIndex: null, kind: 'cell', edge: 'end'}; },
        getRowSpan() { return options.spanIndex === index ? 2 : 1; },
        getColumnSpan() { return 1; },
        isMerged() { return options.mergedIndex === index; },
        getPropertySetInfo() { return {hasPropertyByName(name) {
          assert.equal(name, 'IsProtected');
          return options.protectionProperty === true || options.protectedIndex === index;
        }}; },
        getPropertyValue(name) {
          assert.equal(name, 'IsProtected', 'only known protection property is accessed');
          return options.protectedIndex === index;
        },
        getText() {
          function boundary(paragraphIndex, kind, edge, offset) {
            return {cellIndex: index, paragraphIndex, kind, edge, offset};
          }
          const text = {createTextCursorByRange(start) {
            assert.equal(start.cellIndex, index);
            assert.equal(start.edge, 'start');
            if (start.kind === 'cell') assert.equal(start.paragraphIndex, null);
            else assert.ok(start.paragraphIndex >= 0 && start.paragraphIndex < state.styles[index].length);
            const context = {...start, cursor: true, selected: false, createdGeneration: state.generation,
              createdFormatWrites: state.formatWrites.length,
              start: start.offset || 0, end: start.offset || 0, verified: false};
            const metadataUnavailable = options.metadataUnavailable ===
              (start.kind === 'paragraph' ? 'paragraph' : 'portion') && index === 0;
            function selectedRecords(name, writing) {
              const style = state.styles[index][start.paragraphIndex === null ? 0 : start.paragraphIndex];
              if (Object.hasOwn(style.para, name || 'ParaAdjust')) return [style.para];
              if (writing) {
                const split = [];
                for (const run of style.runs) {
                  const cuts = [run.start, context.start, context.end, run.end]
                    .filter(value => value >= run.start && value <= run.end).sort((a, b) => a - b);
                  const unique = [...new Set(cuts)];
                  if (run.start === run.end) split.push(run);
                  for (let n = 1; n < unique.length; n++) split.push({start: unique[n - 1], end: unique[n], run: copyRecord(run.run)});
                }
                style.runs = split;
                style.run = split[0].run;
              }
              const runs = style.runs.filter(run => context.start === context.end ?
                run.start <= context.start && (run.end > context.start || run.start === run.end) :
                run.start >= context.start && run.end <= context.end);
              return (runs.length ? runs : [style.runs[style.runs.length - 1]]).map(run => run.run);
            }
            function access(method, name, value) {
              const writing = method.startsWith('set');
              if (writing && options.strictFreshCursor) {
                assert.equal(context.createdGeneration, state.generation, 'restoration must obtain a fresh cursor after text mutation');
                assert.equal(context.verified, true, 'restoration must compare the exact selected substring before writes');
                assert.equal(context.usedGoRight, true, 'character offsets use goRight from the raw paragraph start');
              }
              if (method === 'getPropertySetInfo') {
                const style = state.styles[index][start.paragraphIndex === null ? 0 : start.paragraphIndex];
                return propertyTarget({...style.para, ...style.runs[0].run}, state, options, metadataUnavailable, context)[method]();
              }
              const records = selectedRecords(name, writing);
              let result;
              for (const record of (writing ? records : records.slice(0, 1))) {
                result = propertyTarget(record, state, options, metadataUnavailable, context)[method](name, value);
              }
              return result;
            }
            const cursor = {
              getPropertySetInfo() { return access('getPropertySetInfo'); },
              getPropertyValue(name) { return access('getPropertyValue', name); },
              getPropertyState(name) { return access('getPropertyState', name); },
              setPropertyValue(name, value) { return access('setPropertyValue', name, value); },
              setPropertyToDefault(name) { return access('setPropertyToDefault', name); },
              goRight(amount, expand) {
                assert.ok(Number.isInteger(amount) && amount >= 0 && amount <= 32767, 'native cursor count is a signed short');
                assert.equal(typeof expand, 'boolean');
                const line = cell.getString().split('\n')[start.paragraphIndex];
                const destination = context.end + amount;
                assert.ok(destination <= line.length, 'cursor stays inside its selected paragraph');
                if (!expand) context.start = destination;
                context.end = destination;
                context.selected = true;
                context.usedGoRight = true;
                context.verified = false;
                state.cursorSelections.push({cell: index, paragraph: start.paragraphIndex, kind: start.kind,
                  start: context.start, end: context.end, afterWrite: state.writes > 0});
                return true;
              },
              getString() {
                context.verified = true;
                const line = cell.getString().split('\n')[start.paragraphIndex];
                return options.cursorStringMismatch && state.writes > 0 ? 'wrong selection' : line.slice(context.start, context.end);
              },
              gotoRange(end, expand) {
                assert.equal(end.cellIndex, start.cellIndex);
                assert.equal(end.paragraphIndex, start.paragraphIndex);
                assert.equal(end.kind, start.kind);
                assert.equal(end.edge, 'end');
                assert.equal(expand, true, 'restore selects the full range, not a collapsed insertion point');
                context.selected = true;
                context.end = end.offset === undefined ? (start.kind === 'cell' ? cell.getString().length :
                  cell.getString().split('\n')[start.paragraphIndex].length) : end.offset;
                state.cursorSelections.push({cell: index, paragraph: start.paragraphIndex,
                  kind: start.kind, afterWrite: state.writes > 0});
              },
            };
            nativeCursors.set(cursor, context);
            return cursor;
          }, createEnumeration() {
            const paragraphs = cell.getString().split('\n').map((line, paragraphIndex) => ({
              ...propertyTarget({...state.styles[index][paragraphIndex].para, ...state.styles[index][paragraphIndex].eopRun}, state, options,
                options.metadataUnavailable === 'paragraph' && index === 0,
                {cellIndex: index, paragraphIndex, kind: 'paragraph', createdGeneration: state.generation,
                  createdFormatWrites: state.formatWrites.length, emptyParagraph: line.length === 0}),
              getStart() { return boundary(paragraphIndex, 'paragraph', 'start'); },
              getEnd() { return boundary(paragraphIndex, 'paragraph', 'end'); },
              createEnumeration() {
                if (options.emptyParagraph && !line) return enumeration([]);
                const kind = options.fieldIndex === index ? 'TextField' : 'Text';
                let portions = state.styles[index][paragraphIndex].runs;
                if (options.nativeSplitIdentical && state.writes > 0) portions = portions.flatMap(run => run.end - run.start > 1 ?
                  [{...run, end: run.start + 1}, {...run, start: run.start + 1}] : [run]);
                return enumeration(portions.map(run => ({
                  ...propertyTarget(run.run, state, options,
                    options.metadataUnavailable === 'portion' && index === 0,
                    {cellIndex: index, paragraphIndex, kind: 'character'}),
                  getStart() { return boundary(paragraphIndex, 'character', 'start', run.start); },
                  getEnd() { return boundary(paragraphIndex, 'character', 'end', run.end); },
                  getString() { return line.slice(run.start, run.end); },
                  getPropertyValue(name) {
                    if (name === 'TextPortionType') return kind;
                    const item = run.run[name];
                    assert.ok(item, 'run property must have real metadata');
                    if (name === 'CharComplexColor') {
                      const value = item.value.clone();
                      state.complexReads.push({value, beforeWrite: state.writes === 0, cell: index, paragraph: paragraphIndex});
                      return value;
                    }
                    return item.value;
                  },
                })));
              },
            }));
            return enumeration(paragraphs);
          }};
          if (!options.missingInsertTextPortion) text.insertTextPortion = (content, properties, range) => {
            assert.ok(Array.isArray(properties) && properties.length === 0, 'insertion carries no guessed property values');
            const context = nativeCursors.get(range);
            assert.ok(context && context.selected, 'insertion uses an actual selected text cursor');
            assert.equal(context.cellIndex, index);
            assert.equal(context.kind, 'cell', 'insertion replaces the complete selected cell range');
            replaceContents(content, true);
            return cell;
          };
          return text;
        },
      };
      cells.push(cell);
    }
  }
  const table = {
    getRows() { return {getCount() { return state.rows; }}; },
    getColumns() { return {getCount() { return state.columns; }}; },
    getCellByPosition(column, row) {
      assert.ok(Number.isInteger(column) && Number.isInteger(row));
      assert.ok(row >= 0 && row < state.rows && column >= 0 && column < state.columns);
      return cells[row * state.columns + column];
    },
  };
  const shape = {
    getShapeType() { return 'com.sun.star.drawing.TableShape'; },
    getPropertyValue(name) {
      if (name === 'Model') return table;
      assert.equal(name, 'Name');
      return '검토 표';
    },
    getPosition() { return state.position; },
    getSize() { return state.size; },
  };
  const unrelated = {getShapeType() { return 'com.sun.star.drawing.RectangleShape'; }};
  const pages = options.pages || [[unrelated, shape]];
  const model = {
    supportsService(name) {
      assert.equal(name, 'com.sun.star.presentation.PresentationDocument');
      return state.supported;
    },
    getURL() { return state.url; },
    isReadonly() { return state.readonly; },
    getDrawPages() { return {
      getCount() { return pages.length; },
      getByIndex(index) {
        assert.ok(index >= 0 && index < pages.length);
        return {getCount() { return pages[index].length; }, getByIndex(i) {
          assert.ok(i >= 0 && i < pages[index].length);
          return pages[index][i];
        }};
      },
    }; },
  };
  const componentContext = {};
  const uno = {componentContext, Any: NativeAny, idl: {com: {sun: {star: {frame: {Desktop: {
    create(context) {
      assert.equal(context, componentContext);
      return {getCurrentFrame() { return {getController() { return {getModel() { return model; }}; }}; }};
    },
  }}}}}}};
  return {state, cells, shape, table, model, uno};
}

function request(extra = {}) {
  return {protocol: 'piv-cell-1', action: 'read', sessionId: ID, documentUrl: URL, ...extra};
}
function run(f, input = request()) {
  const sandbox = {uno: f.uno};
  // Same direct invocation shape as the closed native executescript source.
  const result = vm.runInNewContext(source + '(' + JSON.stringify(input) + ');', sandbox, {timeout: 1500});
  assert.deepEqual(Object.keys(sandbox), ['uno'], 'program must not create global state');
  assert.ok(result && typeof result === 'object' && !(result instanceof Promise), 'synchronous DTO result');
  return JSON.parse(JSON.stringify(result));
}
function rejected(result, code, uncertain = false) {
  assert.equal(result.success, false);
  assert.equal(result.mayHaveMutated, uncertain);
  assert.equal(result.code, code);
}
function test(name, body) {
  try { body(); passed++; console.log('PASS ' + name); }
  catch (error) { console.error('FAIL ' + name); throw error; }
}
function snapshot(f) {
  const result = run(f);
  assert.equal(result.success, true);
  return result.tables[0];
}
function replace(f, extra = {}) {
  return run(f, request({action: 'replace', expected: snapshot(f), row: 0, column: 0, text: '새 내용 😀\n다음 줄', ...extra}));
}
// Hand-authored contract vectors test the JS consumer; they do not establish
// correctness of Rust's grapheme diff or Java's exact-byte hash validation.
function stylePlan(oldText, newText, paragraphs) {
  return {protocol: 'piv-text-style-map-1', oldUtf16Length: oldText.length, newUtf16Length: newText.length,
    oldSha256: crypto.createHash('sha256').update(oldText, 'utf8').digest('hex'),
    newSha256: crypto.createHash('sha256').update(newText, 'utf8').digest('hex'), paragraphs};
}
function retain(newStart, newEnd, oldStart, oldEnd) { return {kind: 'retain', newStart, newEnd, oldStart, oldEnd}; }
function inherit(newStart, newEnd, oldStart, oldEnd) { return {kind: 'inherit', newStart, newEnd, oldStart, oldEnd}; }
function runColors(f, paragraph = 0) {
  const line = f.state.texts[0][0].split('\n')[paragraph];
  return Array.from({length: line.length}, (_, offset) => {
    const run = f.state.styles[0][paragraph].runs.find(run => run.start <= offset && offset < run.end);
    assert.ok(run, 'every target UTF16 position has a native style interval');
    return run.run.CharColor.value;
  });
}

test('loading returns one inert function without contacting UNO', () => {
  const sandbox = {};
  const program = vm.runInNewContext(source, sandbox, {timeout: 1500});
  assert.equal(typeof program, 'function');
  assert.deepEqual(Object.keys(sandbox), []);
});
test('read returns complete selected table and preserves Korean emoji multiline', () => {
  const f = fixture();
  assert.deepEqual(run(f), {
    protocol: 'piv-cell-1', sessionId: ID, documentUrl: URL, action: 'read', success: true,
    mayHaveMutated: false, tables: [{slide: 0, shape: 1, pageCount: 1, shapeCount: 2,
      name: '검토 표', rows: 2, columns: 2, x: 100, y: 200, width: 3000, height: 1200,
      cells: [{row: 0, column: 0, text: '한글 😀\n둘째 줄', editable: true},
        {row: 0, column: 1, text: 'unchanged', editable: true},
        {row: 1, column: 0, text: '', editable: true},
        {row: 1, column: 1, text: 'last', editable: true}]}],
  });
  assert.equal(f.state.writes, 0);
});
test('replace writes one requested cell and returns complete verified snapshot', () => {
  const f = fixture();
  const result = replace(f);
  assert.equal(result.success, true);
  assert.equal(result.mayHaveMutated, true);
  assert.equal(result.table.cells[0].text, '새 내용 😀\n다음 줄');
  assert.deepEqual(f.state.texts, [['새 내용 😀\n다음 줄', 'unchanged'], ['', 'last']]);
  assert.equal(f.state.writes, 1);
  assert.equal(result.table.cells.length, 4);
});
test('expected object property order does not confer stale status', () => {
  const f = fixture();
  const expected = snapshot(f);
  const reordered = Object.fromEntries(Object.entries(expected).reverse());
  reordered.cells = expected.cells.map(cell => Object.fromEntries(Object.entries(cell).reverse()));
  assert.equal(replace(f, {expected: reordered}).success, true);
});
test('only file URL slash count is normalized for actual model binding', () => {
  const f = fixture({url: URL.replace('file:///', 'file:/')});
  assert.equal(run(f).success, true);
});
test('foreign model and foreign file spelling fail before write', () => {
  for (const url of [URL.replace('working.pptx', 'foreign.pptx'), URL.replace('working', '%77orking'),
    'https://example.invalid/working.pptx', URL + '?other']) {
    const f = fixture({url});
    rejected(run(f, request({action: 'replace'})), url.startsWith('file:') && !url.includes('?') ? 'document_mismatch' : 'invalid_document_url');
    assert.equal(f.state.writes, 0);
  }
});
test('unsupported document service fails closed', () => {
  const f = fixture({supported: false});
  rejected(run(f), 'unsupported_document');
  assert.equal(f.state.writes, 0);
});
test('remote authority relative traversal and malformed file URL rejected', () => {
  for (const url of ['file://foreignhost/a.pptx', 'file:working.pptx', 'file:///a/../working.pptx',
    'file:///a\\working.pptx', 'file:///a.pptx#part', 'file:///']) {
    const f = fixture({url});
    rejected(run(f, request({documentUrl: url})), 'invalid_document_url');
    assert.equal(f.state.writes, 0);
  }
});
test('malformed protocol action and UUID reject before UNO access', () => {
  for (const extra of [{protocol: 'other'}, {action: 'eval'}, {sessionId: ID.toUpperCase()}, {sessionId: '../other'}]) {
    const f = fixture();
    f.uno.idl.com.sun.star.frame.Desktop.create = () => { throw Error('must not contact UNO'); };
    rejected(run(f, request(extra)), 'invalid_request');
  }
});
test('unavailable native APIs fail closed rather than assuming support', () => {
  for (const remove of [f => delete f.model.getURL, f => delete f.model.isReadonly,
    f => delete f.model.getDrawPages, f => delete f.shape.getPropertyValue,
    f => delete f.cells[0].isMerged, f => delete f.cells[0].getText,
    f => delete f.cells[0].getPropertySetInfo]) {
    const f = fixture(); remove(f);
    rejected(run(f), 'api_unavailable');
    assert.equal(f.state.writes, 0);
  }
});
test('full expected table context rejects stale topology geometry and every cell', () => {
  for (const mutate of [e => e.cells[1].text = 'stale other cell', e => e.x++, e => e.width++,
    e => e.pageCount++, e => e.shapeCount++, e => e.rows++, e => e.name = 'stale',
    e => e.shape = 0, e => e.cells[0].editable = false, e => e.extra = 'untrusted']) {
    const f = fixture();
    const expected = snapshot(f); mutate(expected);
    rejected(run(f, request({action: 'replace', expected, row: 0, column: 0, text: 'replacement'})), 'stale_snapshot');
    assert.equal(f.state.writes, 0);
  }
});
test('known protected merged spanning and field cells remain observable but not editable', () => {
  for (const option of ['readonly', 'protectedIndex', 'mergedIndex', 'spanIndex', 'fieldIndex']) {
    const f = fixture(option === 'readonly' ? {readonly: true} : {[option]: 0});
    const expected = snapshot(f);
    assert.equal(expected.cells[0].editable, false, option);
    rejected(run(f, request({action: 'replace', expected, row: 0, column: 0, text: 'replacement'})), 'cell_uneditable');
    assert.equal(f.state.writes, 0);
  }
});

test('multiple plain Text portions are editable and require a style plan before replacement', () => {
  const f = fixture({richIndex: 0});
  assert.equal(snapshot(f).cells[0].editable, true);
  rejected(replace(f), 'invalid_request');
  assert.equal(f.state.writes, 0);
});

test('retained and inherited ranges preserve independent original character styles', () => {
  const blue = styledLine(0x1122ff, 150, 'NONE');
  const red = styledLine(0xff2211, 100, 'ITALIC');
  const oldText = 'ABCD', text = 'A!BCD?';
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']], strictFreshCursor: true,
    styles: [mixedLine([['AB', blue], ['CD', red]], 'RIGHT')]});
  const plan = stylePlan(oldText, text, [{sourceParagraph: 0, segments:
    [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 5, 1, 4), inherit(5, 6, 3, 4)]}]);
  const result = replace(f, {text, stylePlan: plan});
  assert.equal(result.success, true);
  assert.deepEqual(runColors(f), [0x1122ff, 0x1122ff, 0x1122ff, 0xff2211, 0xff2211, 0xff2211]);
  assert.equal(f.state.styles[0][0].para.ParaAdjust.value, 1);
  assert.equal(f.state.insertTextPortionWrites, 1);
  assert.equal(f.state.setStringWrites, 0);
});

test('one retained ZWJ grapheme preserves different native style runs within it', () => {
  const blue = styledLine(0x1122ff, 150, 'NONE'), red = styledLine(0xff2211, 100, 'ITALIC');
  const oldText = '👩‍💻Z', text = '!👩‍💻Z';
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']], strictFreshCursor: true,
    styles: [mixedLine([['👩', blue], ['‍💻Z', red]])]});
  const plan = stylePlan(oldText, text, [{sourceParagraph: 0,
    segments: [inherit(0, 1, 0, 5), retain(1, 7, 0, 6)]}]);
  assert.equal(replace(f, {text, stylePlan: plan}).success, true);
  assert.deepEqual(runColors(f), [0x1122ff, 0x1122ff, 0x1122ff, 0xff2211, 0xff2211, 0xff2211, 0xff2211]);
});

test('mapped paragraphs and an empty target preserve their selected source typing styles', () => {
  const oldText = 'ab\nCD', text = 'CD\n\nab';
  const blue = styledLine(0x1122ff, 150, 'NONE'), red = styledLine(0xff2211, 100, 'ITALIC', 'RIGHT');
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']], strictFreshCursor: true,
    styles: [mixedLine([['a', blue], ['b', red]]), red]});
  const plan = stylePlan(oldText, text, [
    {sourceParagraph: 1, segments: [retain(0, 2, 0, 2)]},
    {sourceParagraph: 1, segments: [inherit(0, 0, 0, 1)]},
    {sourceParagraph: 0, segments: [retain(0, 2, 0, 2)]}]);
  assert.equal(replace(f, {text, stylePlan: plan}).success, true);
  assert.deepEqual(runColors(f, 0), [0xff2211, 0xff2211]);
  assert.deepEqual(runColors(f, 2), [0x1122ff, 0xff2211]);
  assert.equal(f.state.styles[0][1].run.CharColor.value, 0xff2211);
  assert.deepEqual(f.state.styles[0].map(line => line.para.ParaAdjust.value), [1, 1, 0]);
});

test('an empty original paragraph supplies its zero length typing-style anchor', () => {
  const oldText = '', text = '😀';
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']], emptyParagraph: true, strictFreshCursor: true,
    styles: [styledLine(0x1122ff, 150, 'ITALIC')]});
  const plan = stylePlan(oldText, text, [{sourceParagraph: 0, segments: [inherit(0, 2, 0, 0)]}]);
  assert.equal(replace(f, {text, stylePlan: plan}).success, true);
  assert.deepEqual(runColors(f), [0x1122ff, 0x1122ff]);
});

test('malformed supplied style plans never fall back to uniform paragraph replacement', () => {
  const oldText = 'AB', text = 'A!B';
  const valid = stylePlan(oldText, text, [{sourceParagraph: 0,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}]);
  const cases = [null, {}, {...valid, protocol: 'other'}, {...valid, extra: true},
    {...valid, oldUtf16Length: 3}, {...valid, newUtf16Length: 2},
    {...valid, oldSha256: 'A'.repeat(64)}, {...valid, newSha256: 'f'.repeat(63)},
    {...valid, paragraphs: []}];
  for (const mutate of [p => p.paragraphs[0].extra = true, p => p.paragraphs[0].sourceParagraph = 1,
    p => p.paragraphs[0].sourceParagraph = 0.5, p => p.paragraphs[0].segments[0].extra = true,
    p => p.paragraphs[0].segments[0].kind = 'copy', p => p.paragraphs[0].segments[0].newStart = 1,
    p => p.paragraphs[0].segments[1].newStart = 0, p => p.paragraphs[0].segments[2].newEnd = 4,
    p => p.paragraphs[0].segments[2].newEnd = 2, p => p.paragraphs[0].segments[1].oldStart = -1,
    p => p.paragraphs[0].segments[1].oldEnd = 3, p => p.paragraphs[0].segments[1].oldEnd = 0,
    p => p.paragraphs[0].segments[0].oldStart = 1, p => p.paragraphs[0].segments[0].newEnd = 0]) {
    const plan = JSON.parse(JSON.stringify(valid)); mutate(plan); cases.push(plan);
  }
  for (const plan of cases) {
    const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']]});
    rejected(replace(f, {text, stylePlan: plan}), 'invalid_request');
    assert.equal(f.state.writes, 0);
    assert.equal(f.state.texts[0][0], oldText);
  }
});

test('style plan ranges may not divide UTF16 surrogate pairs', () => {
  for (const [oldText, text, segments] of [
    ['😀B', '!😀B', [inherit(0, 1, 0, 1), retain(1, 4, 0, 3)]],
    ['😀', '😀', [retain(0, 1, 0, 1), retain(1, 2, 1, 2)]],
  ]) {
    const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']]});
    const plan = stylePlan(oldText, text, [{sourceParagraph: 0, segments}]);
    rejected(replace(f, {text, stylePlan: plan}), 'invalid_request');
    assert.equal(f.state.writes, 0);
  }
});

test('retained string equality and empty-target canonical anchors are validated before writes', () => {
  for (const [oldText, text, segments] of [
    ['AB', 'BA', [retain(0, 2, 0, 2)]],
    ['AB', '', []], ['AB', '', [retain(0, 0, 0, 0)]],
    ['AB', '', [inherit(0, 0, 0, 0)]],
    ['', 'A', [inherit(0, 1, 0, 1)]],
  ]) {
    const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']]});
    rejected(replace(f, {text, stylePlan: stylePlan(oldText, text, [{sourceParagraph: 0, segments}])}), 'invalid_request');
    assert.equal(f.state.writes, 0);
  }
});

test('fresh cursor substring mismatch is quarantined before formatting writes', () => {
  const oldText = 'AB', text = 'A!B';
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']], cursorStringMismatch: true});
  const plan = stylePlan(oldText, text, [{sourceParagraph: 0,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}]);
  rejected(replace(f, {text, stylePlan: plan}), 'verification_failed', true);
  assert.equal(f.state.writes, 1);
  assert.equal(f.state.formatWrites.length, 0, 'exact selection verification precedes every format setter');
});

test('native splitting of equal adjacent styles does not change semantic verification', () => {
  const oldText = 'ABCD', text = 'A!BCD';
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']], nativeSplitIdentical: true,
    styles: [mixedLine([['AB', styledLine(0x1122ff, 150, 'NONE')], ['CD', styledLine(0xff2211, 100, 'ITALIC')]])]});
  const plan = stylePlan(oldText, text, [{sourceParagraph: 0,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 5, 1, 4)]}]);
  assert.equal(replace(f, {text, stylePlan: plan}).success, true);
  assert.deepEqual(runColors(f), [0x1122ff, 0x1122ff, 0x1122ff, 0xff2211, 0xff2211]);
});

test('unsupported direct metadata in a later Text portion keeps the whole cell read-only', () => {
  const blue = styledLine(0x1122ff, 150, 'NONE'), red = styledLine(0xff2211, 100, 'ITALIC');
  red.run.CharInteropGrabBag = property('[]com.sun.star.beans.PropertyValue', [{Name: 'native', Value: {opaque: true}}]);
  const f = fixture({texts: [['AB', 'unchanged'], ['', 'last']], styles: [mixedLine([['A', blue], ['B', red]])]});
  assert.equal(snapshot(f).cells[0].editable, false);
  rejected(replace(f, {text: 'AB', stylePlan: stylePlan('AB', 'AB', [{sourceParagraph: 0,
    segments: [retain(0, 2, 0, 2)]}])}), 'cell_uneditable');
  assert.equal(f.state.writes, 0);
});

test('a style mismatch only in a later restored interval is quarantined', () => {
  const oldText = 'AB', text = 'A!B';
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']], partialStyleMismatch: true,
    styles: [mixedLine([['A', styledLine(0x1122ff, 150, 'NONE')], ['B', styledLine(0xff2211, 100, 'ITALIC')]])]});
  const plan = stylePlan(oldText, text, [{sourceParagraph: 0,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}]);
  rejected(replace(f, {text, stylePlan: plan}), 'verification_failed', true);
  assert.equal(f.state.writes, 1);
});

test('equal visible signatures retain each source run live complex-color payload', () => {
  const oldText = 'AB', text = 'A!B';
  const first = ordinaryRgbStyles()[0];
  first.run.CharComplexColor.value = new NativeComplexColor({}, {nativePayload: 'first'});
  const second = {para: first.para, run: copyRecord(first.run)};
  second.run.CharComplexColor.value = new NativeComplexColor({}, {nativePayload: 'second'});
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']],
    styles: [mixedLine([['A', first], ['B', second]])]});
  const plan = stylePlan(oldText, text, [{sourceParagraph: 0,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}]);
  assert.equal(replace(f, {text, stylePlan: plan}).success, true);
  const payloads = Array.from({length: text.length}, (_, offset) => {
    const run = f.state.styles[0][0].runs.find(run => run.start <= offset && offset < run.end);
    return run.run.CharComplexColor.value.retained.nativePayload;
  });
  assert.deepEqual(payloads, ['first', 'first', 'second'], 'semantic signature coalescing must not discard opaque native state');
  assert.ok(f.state.complexRestores.every(restore => f.state.complexReads.some(read =>
    read.beforeWrite && read.value === restore.value)), 'restore passes the exact original live native wrapper');
});

test('a zero-length source portion does not donate style to a nonempty source anchor', () => {
  const oldText = 'A', text = '!A';
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']], styles: [mixedLine([
    ['', styledLine(0x1122ff, 150, 'NONE')], ['A', styledLine(0xff2211, 100, 'ITALIC')]])]});
  const plan = stylePlan(oldText, text, [{sourceParagraph: 0,
    segments: [inherit(0, 1, 0, 1), retain(1, 2, 0, 1)]}]);
  assert.equal(replace(f, {text, stylePlan: plan}).success, true);
  assert.deepEqual(runColors(f), [0xff2211, 0xff2211], 'nonempty oldStart selects the actual containing source run');
});
test('optional protection property absence and present false are usable', () => {
  for (const options of [{}, {protectionProperty: true}]) {
    const f = fixture(options);
    assert.equal(snapshot(f).cells[0].editable, true);
    assert.equal(replace(f).success, true);
  }
});
test('empty text enumeration is editable only for a truly empty paragraph', () => {
  const f = fixture({emptyParagraph: true});
  assert.equal(snapshot(f).cells[2].editable, true);
  assert.equal(replace(f, {row: 1, column: 0, text: ''}).success, true);
});
test('cell bounds and integer types cannot escape the selected table', () => {
  for (const coordinate of [{row: -1, column: 0}, {row: 0, column: 2}, {row: 1.5, column: 0}, {row: '0', column: 0}]) {
    const f = fixture();
    rejected(replace(f, coordinate), 'cell_out_of_bounds');
    assert.equal(f.state.writes, 0);
  }
});
test('text size and Unicode validity reject before mutation', () => {
  for (const text of ['a'.repeat(8193), '\ud800', '\udc00', 'ok\ud800x', 123, null]) {
    const f = fixture();
    rejected(replace(f, {text}), 'invalid_text');
    assert.equal(f.state.writes, 0);
  }
  const f = fixture();
  assert.equal(replace(f, {text: '😀'.repeat(4096)}).success, true, 'exact UTF16 boundary accepted');
});
test('slide total shape table cell and total cell budgets reject explicitly', () => {
  const emptyPages = Array.from({length: 129}, () => []);
  const tooManyShapes = [Array.from({length: 2049}, () => ({getShapeType() { return 'other'; }}))];
  for (const f of [fixture({pages: emptyPages}), fixture({pages: tooManyShapes}), fixture({rows: 17, columns: 16})]) {
    rejected(run(f), 'observation_limit');
    assert.equal(f.state.writes, 0);
  }
  const f = fixture({rows: 16, columns: 16});
  const pages = [Array.from({length: 5}, () => f.shape)];
  const overflow = fixture({pages});
  rejected(run(overflow), 'observation_limit');
});
test('complete captured JSON UTF16 budget rejects without truncation', () => {
  const f = fixture({texts: [['한'.repeat(199500), 'b'.repeat(1000)], ['', 'last']]});
  rejected(run(f), 'observation_limit');
  assert.equal(f.state.writes, 0);
});
test('replacement that would exceed captured JSON budget fails before any write', () => {
  const f = fixture({texts: [['한'.repeat(193000), 'short'], ['', 'last']]});
  const expected = snapshot(f);
  assert.equal(expected.cells[1].text, 'short', 'original complete observation fits its budget');
  rejected(run(f, request({action: 'replace', expected, row: 0, column: 1, text: '새'.repeat(8192)})), 'observation_limit');
  assert.equal(f.state.writes, 0);
  assert.equal(f.state.texts[0][1], 'short');
});
test('malformed native strings and geometry fail closed', () => {
  const unicode = fixture({texts: [['\ud800', 'unchanged'], ['', 'last']]});
  rejected(run(unicode), 'invalid_native_state');
  const geometry = fixture(); geometry.state.size.Width = NaN;
  rejected(run(geometry), 'invalid_native_state');
});
test('write exception never claims clean preflight failure or retries', () => {
  const f = fixture({writeException: true});
  rejected(replace(f), 'write_failed', true);
  assert.equal(f.state.writes, 1);
});
test('target readback mismatch quarantines uncertain mutation', () => {
  const f = fixture({readbackMismatch: true});
  rejected(replace(f), 'verification_failed', true);
  assert.equal(f.state.writes, 1);
});
test('postwrite unrelated cell geometry and document changes are uncertain', () => {
  for (const onWrite of [s => s.texts[0][1] = 'unexpected', s => s.position.X++,
    s => s.url = URL.replace('working.pptx', 'foreign.pptx'), s => s.rows++]) {
    const f = fixture({onWrite});
    const result = replace(f);
    assert.equal(result.success, false);
    assert.equal(result.mayHaveMutated, true);
    assert.equal(f.state.writes, 1);
  }
});
test('replacement preserves independently styled paragraphs after setString clears formatting', () => {
  const f = fixture({styles: [styledLine(0x1122ff, 150, 'NONE', 'LEFT'), styledLine(0xff2211, 100, 'ITALIC', 'RIGHT')]});
  const result = replace(f);
  assert.equal(result.success, true);
  assert.equal(f.state.styles[0][0].run.CharColor.value, 0x1122ff);
  assert.equal(f.state.styles[0][0].run.CharWeight.value, 150);
  assert.equal(f.state.styles[0][0].para.ParaAdjust.value, 0);
  assert.equal(f.state.styles[0][1].run.CharColor.value, 0xff2211);
  assert.equal(String(f.state.styles[0][1].run.CharPosture.value), 'ITALIC');
  assert.equal(f.state.styles[0][1].para.ParaAdjust.value, 1);
  assert.deepEqual(Object.keys(result.table.cells[0]).sort(), ['column', 'editable', 'row', 'text'], 'private style metadata does not change closed DTO');
});
test('restoration retains typed float value and live native enum identity', () => {
  const style = styledLine(0x112233, 150, 'ITALIC');
  style.run.CharHeight = property('float', 12.75, 'DIRECT_VALUE', 12);
  const originalEnum = style.run.CharPosture.value;
  const f = fixture({styles: [style, styledLine(0x445566, 100, 'NONE')]});
  assert.equal(replace(f).success, true);
  assert.equal(f.state.styles[0][0].run.CharHeight.value, 12.75);
  assert.equal(f.state.styles[0][0].run.CharPosture.value, originalEnum, 'native enum is not JSON-flattened for setters');
});
test('default and direct property states survive even when their values are equal', () => {
  const style = styledLine(0, 100, 'NONE');
  style.run.CharWeight = property('float', 100, 'DEFAULT_VALUE');
  const f = fixture({styles: [style, styledLine(0, 100, 'NONE')]});
  assert.equal(replace(f).success, true);
  const restored = f.state.styles[0][0].run;
  assert.equal(String(restored.CharWeight.state), 'DEFAULT_VALUE');
  assert.equal(String(restored.CharColor.state), 'DIRECT_VALUE');
});
test('inserted and deleted paragraphs retain unchanged line formatting anchors', () => {
  const f = fixture({texts: [['alpha\nbeta\ngamma', 'unchanged'], ['', 'last']],
    styles: [styledLine(0x111111, 150, 'NONE'), styledLine(0x222222, 100, 'ITALIC'), styledLine(0x333333, 100, 'NONE')]});
  assert.equal(replace(f, {text: 'alpha\ninserted\nbeta\ngamma'}).success, true);
  assert.deepEqual(f.state.styles[0].map(line => line.run.CharColor.value), [0x111111, 0x111111, 0x222222, 0x333333]);
  assert.equal(replace(f, {text: 'alpha\ngamma'}).success, true);
  assert.deepEqual(f.state.styles[0].map(line => line.run.CharColor.value), [0x111111, 0x333333]);
});
test('supported Locale LineSpacing and typed TabStop sequences retain native values', () => {
  const style = styledLine(0x112233, 150, 'NONE');
  const locale = {Language: 'ko', Country: 'KR', Variant: ''};
  const spacing = {Mode: 0, Height: 125};
  const tabs = [{Position: 1200, Alignment: nativeEnum('com.sun.star.style.TabAlign.LEFT'), DecimalChar: '.', FillChar: ' '}];
  style.run.CharLocale = property('com.sun.star.lang.Locale', locale, 'DIRECT_VALUE', {Language: '', Country: '', Variant: ''});
  style.para.ParaLineSpacing = property('com.sun.star.style.LineSpacing', spacing, 'DIRECT_VALUE', {Mode: 0, Height: 100});
  style.para.ParaTabStops = property('[]com.sun.star.style.TabStop', tabs, 'DIRECT_VALUE', []);
  const f = fixture({styles: [style, styledLine(0x445566, 100, 'NONE')]});
  assert.equal(replace(f).success, true);
  assert.equal(f.state.styles[0][0].run.CharLocale.value, locale);
  assert.equal(f.state.styles[0][0].para.ParaLineSpacing.value, spacing);
  assert.equal(f.state.styles[0][0].para.ParaTabStops.value, tabs);
});
test('unsupported direct nested Any formatting is read-only before mutation', () => {
  const style = styledLine(0x112233, 150, 'NONE');
  style.para.ParaInteropGrabBag = property('[]com.sun.star.beans.PropertyValue', [{Name: 'native', Value: {opaque: true}}], 'DIRECT_VALUE', []);
  const f = fixture({styles: [style, styledLine(0x445566, 100, 'NONE')]});
  const expected = snapshot(f);
  assert.equal(expected.cells[0].editable, false);
  rejected(run(f, request({action: 'replace', expected, row: 0, column: 0, text: 'replacement'})), 'cell_uneditable');
  assert.equal(f.state.writes, 0);
});
test('unknown default formatting resets and verifies its default state', () => {
  const style = styledLine(0x112233, 150, 'NONE');
  style.para.ParaInteropGrabBag = property('[]com.sun.star.beans.PropertyValue', [], 'DEFAULT_VALUE', []);
  const f = fixture({styles: [style, styledLine(0x445566, 100, 'NONE')]});
  assert.equal(replace(f).success, true);
  assert.equal(String(f.state.styles[0][0].para.ParaInteropGrabBag.state), 'DEFAULT_VALUE');
});
test('ambiguous character state is not flattened by a whole-cell replacement', () => {
  const style = styledLine(0x112233, 150, 'NONE');
  style.run.CharColor.state = nativeEnum('com.sun.star.beans.PropertyState.AMBIGUOUS_VALUE');
  const f = fixture({styles: [style, styledLine(0x445566, 100, 'NONE')]});
  assert.equal(snapshot(f).cells[0].editable, false);
  rejected(replace(f), 'cell_uneditable');
  assert.equal(f.state.writes, 0);
});
test('format metadata unavailability leaves cells visible and read-only', () => {
  for (const metadataUnavailable of ['paragraph', 'portion']) {
    const f = fixture({metadataUnavailable});
    const expected = snapshot(f);
    assert.equal(expected.cells[0].text, '한글 😀\n둘째 줄');
    assert.equal(expected.cells[0].editable, false);
    rejected(run(f, request({action: 'replace', expected, row: 0, column: 0, text: 'replacement'})), 'cell_uneditable');
    assert.equal(f.state.writes, 0);
  }
});
test('format restoration exceptions and state mismatches remain uncertain', () => {
  for (const options of [{restoreException: true}, {restoreStateMismatch: true}]) {
    const f = fixture({...options, styles: [styledLine(0x112233, 150, 'NONE'), styledLine(0x445566, 100, 'ITALIC')]});
    rejected(replace(f), 'verification_failed', true);
    assert.equal(f.state.writes, 1);
  }
});
test('unrelated supported cell formatting mutation is caught after replacement', () => {
  const f = fixture({onWrite(state) {
    state.styles[1][0].run.CharColor.value = 0xabcdef;
    state.styles[1][0].run.CharColor.state = nativeEnum('com.sun.star.beans.PropertyState.DIRECT_VALUE');
  }});
  rejected(replace(f), 'verification_failed', true);
  assert.equal(f.state.writes, 1);
});
test('native paragraph adjustment restores through freshly selected full-range cursors', () => {
  const f = fixture({nativeCursorRequired: true,
    styles: [styledLine(0x1122ff, 150, 'NONE', 'LEFT'), styledLine(0xff2211, 100, 'ITALIC', 'RIGHT')]});
  assert.equal(replace(f).success, true);
  assert.deepEqual(f.state.styles[0].map(line => line.para.ParaAdjust.value), [0, 1]);
  assert.ok(f.state.styles[0].every(line => String(line.para.ParaAdjust.state) === 'DIRECT_VALUE'));
  const paragraphWrites = f.state.formatWrites.filter(item => item.cell === 0 && item.name === 'ParaAdjust');
  assert.equal(paragraphWrites.length, 2);
  assert.ok(paragraphWrites.every(item => item.cursor), 'raw paragraph property setters do not establish correct native selection');
  for (let paragraph = 0; paragraph < 2; paragraph++) {
    assert.ok(f.state.cursorSelections.filter(selection => selection.cell === 0 && selection.paragraph === paragraph &&
      selection.start === 0 && selection.end === f.state.texts[0][0].split('\n')[paragraph].length &&
      selection.afterWrite).length >= 2, 'both formatting scopes select fresh full ranges from the paragraph start');
  }
});
test('default resets finish before direct formatting across shared paragraph and character ranges', () => {
  const f = fixture({styles: [styledLine(0x1122ff, 150, 'NONE', 'LEFT'), styledLine(0xff2211, 100, 'ITALIC', 'RIGHT')]});
  assert.equal(replace(f).success, true);
  const writes = f.state.formatWrites.filter(item => item.cell === 0);
  const firstDirect = writes.findIndex(item => item.kind === 'direct');
  assert.ok(firstDirect > 0, 'fixture has both inherited defaults and direct formatting');
  assert.ok(writes.slice(firstDirect).every(item => item.kind === 'direct'),
    'finish DEFAULT resets on all selected paragraph/character ranges before applying DIRECT values');
  assert.deepEqual(f.state.styles[0].map(line => line.run.CharColor.value), [0x1122ff, 0xff2211]);
});
test('whole-cell text insertion preserves exact inherited underline states', () => {
  const styles = [styledLine(0x1122ff, 150, 'NONE', 'LEFT'), styledLine(0xff2211, 100, 'ITALIC', 'RIGHT')];
  for (const style of styles) Object.assign(style.run, {
    CharUnderline: property('short', 0, 'DEFAULT_VALUE'),
    CharUnderlineColor: property('long', 0, 'DEFAULT_VALUE'),
    CharUnderlineHasColor: property('boolean', false, 'DEFAULT_VALUE'),
  });
  const f = fixture({nativeCursorRequired: true, nativeInsertionContract: true, styles});
  const result = replace(f);
  assert.equal(result.success, true);
  assert.equal(f.state.insertTextPortionWrites, 1);
  assert.equal(f.state.setStringWrites, 0, 'setString leaves observed underline states DIRECT despite individual default resets');
  for (const style of f.state.styles[0]) {
    for (const name of ['CharUnderline', 'CharUnderlineColor', 'CharUnderlineHasColor']) {
      assert.equal(String(style.run[name].state), 'DEFAULT_VALUE');
    }
  }
  assert.deepEqual(f.state.texts, [['새 내용 😀\n다음 줄', 'unchanged'], ['', 'last']]);
});
test('unavailable native text insertion fails before touching the cell', () => {
  const f = fixture({missingInsertTextPortion: true});
  rejected(replace(f), 'api_unavailable');
  assert.equal(f.state.writes, 0);
  assert.equal(f.state.setStringWrites, 0);
  assert.equal(f.state.insertTextPortionWrites, 0);
  assert.equal(f.state.texts[0][0], '한글 😀\n둘째 줄');
});
test('raw paragraph states preserve direct alignment when cursor states report defaults', () => {
  const styles = [styledLine(0x1122ff, 150, 'NONE', 'LEFT'), styledLine(0xff2211, 100, 'ITALIC', 'LEFT')];
  styles[1].para.ParaAdjust = property('short', 2, 'DIRECT_VALUE', 0);
  const f = fixture({nativeCursorRequired: true, cursorParagraphStateDefaults: true, styles});
  const result = replace(f);
  assert.equal(result.success, true);
  assert.deepEqual(f.state.styles[0].map(line => line.para.ParaAdjust.value), [0, 2],
    'metadata capture and verification read raw paragraph values and states, while setters use selected cursors');
  assert.ok(f.state.styles[0].every(line => String(line.para.ParaAdjust.state) === 'DIRECT_VALUE'));
});

test('raw paragraph reset restores DEFAULT ParaAdjust after mixed character formatting', () => {
  const oldText = 'AB\nCD', text = 'A!B\nC?D';
  const blue = styledLine(0x1122ff, 150, 'NONE'), red = styledLine(0xff2211, 100, 'ITALIC');
  const first = mixedLine([['A', blue], ['B', red]], 'RIGHT');
  const second = mixedLine([['C', red], ['D', blue]]);
  second.para.ParaAdjust = property('short', 5, 'DEFAULT_VALUE', 5);
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']],
    styles: [first, second], cursorParaAdjustDefaultMaterializes: true});
  const expected = snapshot(f);
  const plan = stylePlan(oldText, text, [0, 1].map(sourceParagraph => ({sourceParagraph,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]})));
  const result = replace(f, {text, expected, stylePlan: plan});
  assert.equal(result.success, true);
  assert.equal(f.state.styles[0][1].para.ParaAdjust.value, 5);
  assert.equal(String(f.state.styles[0][1].para.ParaAdjust.state), 'DEFAULT_VALUE');
  assert.equal(f.state.styles[0][0].para.ParaAdjust.value, 1);
  assert.equal(String(f.state.styles[0][0].para.ParaAdjust.state), 'DIRECT_VALUE');
  assert.deepEqual(runColors(f, 0), [0x1122ff, 0x1122ff, 0xff2211]);
  assert.deepEqual(runColors(f, 1), [0xff2211, 0xff2211, 0x1122ff]);
  const permitted = JSON.parse(JSON.stringify(expected)); permitted.cells[0].text = text;
  assert.deepEqual(result.table, permitted, 'all unrelated cells and table geometry remain exact');
  assert.ok(f.state.formatWrites.every(write => write.cell === 0));
  assert.ok(f.state.formatWrites.some(write => write.kind === 'default' && write.name === 'ParaAdjust' && !write.cursor &&
    write.cell === 0 && write.paragraph === 1), 'the observed DEFAULT alignment case uses a raw reset');
});

test('unavailable raw paragraph default reset makes DEFAULT ParaAdjust cells read-only before mutation', () => {
  const style = styledLine(0x1122ff, 150, 'NONE');
  style.para.ParaAdjust = property('short', 5, 'DEFAULT_VALUE', 5);
  const f = fixture({texts: [['AB', 'unchanged'], ['', 'last']], styles: [style], rawParagraphDefaultUnavailable: true});
  const expected = snapshot(f);
  assert.equal(expected.cells[0].editable, false);
  rejected(replace(f, {text: 'A!B', expected, stylePlan: stylePlan('AB', 'A!B', [{sourceParagraph: 0,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}])}), 'cell_uneditable');
  assert.equal(f.state.writes, 0);
});
test('ordinary RGB remains editable despite cloned unused complex-color interfaces', () => {
  const f = fixture({styles: ordinaryRgbStyles()});
  const expected = snapshot(f);
  assert.equal(expected.cells[0].editable, true, 'ordinary RGB is not disabled just because CharComplexColor has an interface type');
  const result = replace(f);
  assert.equal(result.success, true);
  assert.equal(f.state.styles[0][0].run.CharColor.value, 0x1122ff);
  const complex = f.state.styles[0][0].run.CharComplexColor.value;
  assert.equal(complex.getType(), 0);
  assert.equal(complex.getThemeColorType(), -1);
  assert.equal(complex.resolveColor(null), 0, 'unused complex resolution is not the ordinary RGB value');
  assert.notEqual(complex.resolveColor(null), f.state.styles[0][0].run.CharColor.value);
  const repeated = f.state.complexReads.filter(read => read.cell === 0 && read.paragraph === 0 && read.beforeWrite);
  assert.ok(repeated.length > 1);
  assert.notEqual(repeated[0].value, repeated[1].value, 'repeated reads of the same property return cloned native interface wrappers');
});
test('retained native complex values restore after all companion setters', () => {
  const styles = ordinaryRgbStyles();
  const retained = styles.map(style => style.run.CharComplexColor.value.retained);
  const f = fixture({styles});
  assert.equal(replace(f).success, true);
  for (let paragraph = 0; paragraph < 2; paragraph++) {
    assert.ok(f.state.complexRestores.some(restore => restore.cell === 0 && restore.paragraph === paragraph && restore.cursor),
      'each selected character range restores its retained native complex object');
  }
  for (const restore of f.state.complexRestores) {
    assert.ok(f.state.complexReads.some(read => read.beforeWrite && read.value === restore.value),
      'typed Any receives the exact live interface wrapper retained before text mutation');
  }
  assert.deepEqual(f.state.styles[0].map(style => style.run.CharComplexColor.value.retained), retained,
    'entire retained native values survive, including fields not exposed by a partial representation');
  for (const cursor of [true, false]) {
    for (let paragraph = 0; paragraph < 2; paragraph++) {
      const writes = f.state.formatWrites.filter(item => item.cell === 0 && item.cursor === cursor && item.paragraph === paragraph && /^Char/.test(item.name));
      if (!writes.length) continue;
      const firstComplex = writes.findIndex(item => item.name === 'CharComplexColor');
      assert.ok(firstComplex > 0);
      assert.ok(writes.slice(firstComplex).every(item => item.name === 'CharComplexColor'),
        'each cursor/raw character target finishes RGB and other companions before retained complex values');
    }
  }
});
test('every ordinary color companion value is verified after complex restoration', () => {
  for (const [name, value] of [['CharColor', 0xabcdef], ['CharTransparence', 74], ['CharColorTheme', 5],
    ['CharColorTintOrShade', 10], ['CharColorLumMod', 75000], ['CharColorLumOff', 25000]]) {
    const f = fixture({styles: ordinaryRgbStyles(), complexCompanionMutation: {name, kind: 'value', value}});
    rejected(replace(f), 'verification_failed', true);
    assert.equal(f.state.writes, 1);
  }
});
test('color companion state and native type changes are uncertain', () => {
  for (const mutation of [{name: 'CharColor', kind: 'state', value: nativeEnum('com.sun.star.beans.PropertyState.DEFAULT_VALUE')},
    {name: 'CharColorLumMod', kind: 'type', value: nativeType('short')}]) {
    const f = fixture({styles: ordinaryRgbStyles(), complexCompanionMutation: mutation});
    rejected(replace(f), 'verification_failed', true);
    assert.equal(f.state.writes, 1);
  }
});
test('unused complex semantic mismatch is uncertain even when RGB remains exact', () => {
  const f = fixture({styles: ordinaryRgbStyles(), complexSemanticMismatch: true});
  rejected(replace(f), 'verification_failed', true);
  assert.equal(f.state.styles[0][0].run.CharColor.value, 0x1122ff);
  assert.equal(f.state.writes, 1);
});
test('active complex colors and unavailable semantic methods remain visible but read-only', () => {
  const styles = [ordinaryRgbStyles({type: 2, theme: 4}), ordinaryRgbStyles({theme: 4}),
    ordinaryRgbStyles({resolved: 0.5}), ...['getType', 'getThemeColorType', 'resolveColor'].map(method => ordinaryRgbStyles({}, method))];
  for (const style of styles) {
    const f = fixture({styles: style});
    const expected = snapshot(f);
    assert.equal(expected.cells[0].text, '한글 😀\n둘째 줄');
    assert.equal(expected.cells[0].editable, false);
    rejected(run(f, request({action: 'replace', expected, row: 0, column: 0, text: 'replacement'})), 'cell_uneditable');
    assert.equal(f.state.writes, 0);
  }
});

test('empty target restores every raw EOP character property and paragraph formatting together', () => {
  const oldText = 'AB\nCD', text = 'AB\n';
  const donor = ordinaryRgbStyles()[0];
  donor.para.ParaAdjust = property('short', 2, 'DIRECT_VALUE', 5);
  donor.para.ParaLeftMargin = property('long', 120, 'DIRECT_VALUE', 0);
  donor.run.CharColor = property('long', 0x008833, 'DIRECT_VALUE', 0xffffff);
  donor.run.CharHeight = property('float', 12.75, 'DIRECT_VALUE', 12);
  donor.run.CharPosture = property('com.sun.star.awt.FontSlant', nativeEnum('com.sun.star.awt.FontSlant.ITALIC'),
    'DIRECT_VALUE', nativeEnum('com.sun.star.awt.FontSlant.NONE'));
  Object.assign(donor.run, {
    CharStyleName: property('string', 'Emphasis', 'DIRECT_VALUE', ''),
    CharFontName: property('string', 'Aptos', 'DIRECT_VALUE', ''),
    CharUnderline: property('short', 1, 'DIRECT_VALUE', 0),
    CharUnderlineColor: property('long', 0, 'DEFAULT_VALUE'),
    CharUnderlineHasColor: property('boolean', false, 'DEFAULT_VALUE'),
    CharEscapement: property('short', 0, 'DEFAULT_VALUE'),
    CharEscapementHeight: property('byte', 100, 'DEFAULT_VALUE'),
    CharKerning: property('short', 0, 'DEFAULT_VALUE'),
    CharLocale: property('com.sun.star.lang.Locale', {Language: 'ko', Country: 'KR', Variant: ''},
      'DIRECT_VALUE', {Language: '', Country: '', Variant: ''}),
    CharCaseMap: property('short', 0, 'DEFAULT_VALUE'),
  });
  const first = ordinaryRgbStyles()[0];
  first.run.CharWeight = property('float', 100, 'DIRECT_VALUE', 100);
  const f = fixture({texts: [[oldText, 'unchanged'], ['', 'last']], emptyEopCharacter: true,
    styles: [first, donor]});
  const expected = snapshot(f);
  const plan = stylePlan(oldText, text, [
    {sourceParagraph: 0, segments: [retain(0, 2, 0, 2)]},
    {sourceParagraph: 1, segments: [inherit(0, 0, 0, 1)]},
  ]);
  const result = replace(f, {text, expected, stylePlan: plan});
  assert.equal(result.success, true);
  const empty = f.state.styles[0][1];
  assert.equal(empty.run.CharColor.value, 0x008833, 'live Text portion typing style remains exact');
  assert.equal(empty.eopRun.CharColor.value, 0x008833, 'raw EOP style is distinct and must also be restored');
  assert.equal(empty.eopRun.CharWeight.value, 150, 'restoring color alone loses the donor bold weight');
  for (const [name, original] of Object.entries(donor.run)) {
    const actual = empty.eopRun[name];
    assert.equal(actual.type, original.type, name + ' preserves native declared Type');
    assert.equal(String(actual.state), String(original.state), name + ' preserves DEFAULT/DIRECT state');
    if (name === 'CharComplexColor') {
      assert.equal(actual.value.getType(), 0);
      assert.equal(actual.value.getThemeColorType(), -1);
      assert.equal(actual.value.resolveColor(null), 0);
      assert.equal(actual.value.retained, original.value.retained);
    } else assert.equal(actual.value, original.value, name + ' restores the full original native value');
  }
  assert.equal(empty.para.ParaAdjust.value, 2);
  assert.equal(String(empty.para.ParaAdjust.state), 'DIRECT_VALUE');
  assert.equal(empty.para.ParaLeftMargin.value, 120);
  const rawCharacters = f.state.formatWrites.filter(write => write.cell === 0 && write.paragraph === 1 && !write.cursor && /^Char/.test(write.name));
  assert.equal(new Set(rawCharacters.map(write => write.name)).size, 20, 'all twenty character properties reach the raw empty paragraph');
  const firstDirect = rawCharacters.findIndex(write => write.kind === 'direct');
  assert.ok(firstDirect > 0 && rawCharacters.slice(firstDirect).every(write => write.kind === 'direct'));
  assert.equal(rawCharacters.at(-1).name, 'CharComplexColor', 'retained native complex object follows companion setters');
  const permitted = JSON.parse(JSON.stringify(expected)); permitted.cells[0].text = text;
  assert.deepEqual(result.table, permitted);
  assert.ok(f.state.formatWrites.every(write => write.cell === 0), 'unrelated cells receive no format writes');
});

test('planned empty raw character failures reject before mutation while nonempty replacements stay usable', () => {
  for (const failure of ['directSetter', 'defaultSetter', 'metadata', 'type']) {
    const options = () => ({texts: [['AB', 'unchanged'], ['', 'last']], emptyEopCharacter: true,
      rawParagraphCharacterFailure: failure, styles: [styledLine(0x008833, 150, 'ITALIC')]});
    const empty = fixture(options());
    assert.equal(snapshot(empty).cells[0].editable, true, failure + ' does not disable ordinary nonempty text');
    rejected(replace(empty, {text: '', stylePlan: stylePlan('AB', '', [{sourceParagraph: 0,
      segments: [inherit(0, 0, 0, 1)]}])}), 'cell_uneditable');
    assert.equal(empty.state.writes, 0, failure + ' is checked before inserting replacement text');
    const nonempty = fixture(options());
    assert.equal(replace(nonempty, {text: 'A!B', stylePlan: stylePlan('AB', 'A!B', [{sourceParagraph: 0,
      segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}])}).success, true,
      failure + ' is not needed by a nonempty target');
  }
});

test('an existing empty source keeps its Text portion typing style as the EOP donor', () => {
  const style = styledLine(0x008833, 150, 'ITALIC');
  style.eopRun = defaultRunStyle();
  style.eopRun.CharColor = property('long', -1, 'DEFAULT_VALUE', -1);
  const f = fixture({texts: [['', 'unchanged'], ['', 'last']], styles: [style], emptyEopCharacter: true});
  const plan = stylePlan('', '', [{sourceParagraph: 0, segments: [inherit(0, 0, 0, 0)]}]);
  assert.equal(replace(f, {text: '', stylePlan: plan}).success, true);
  const empty = f.state.styles[0][0];
  assert.equal(empty.run.CharColor.value, 0x008833);
  assert.equal(empty.run.CharWeight.value, 150);
  assert.equal(empty.eopRun.CharColor.value, 0x008833, 'raw AUTO EOP does not replace the original green Text portion donor');
  assert.equal(empty.eopRun.CharWeight.value, 150, 'original live bold typing style is persisted to EOP');
});

test('raw DEFAULT ParaAdjust clearing preserves all direct paragraph attributes and selected character spans', () => {
  const style = styledLine(0x008833, 150, 'ITALIC');
  style.para.ParaAdjust = property('short', 5, 'DEFAULT_VALUE', 5);
  style.para.ParaLeftMargin = property('long', 120, 'DIRECT_VALUE', 0);
  const f = fixture({texts: [['AB', 'unchanged'], ['', 'last']], styles: [style],
    rawDefaultClearsParagraph: true, cursorParaAdjustDefaultMaterializes: true});
  const text = 'A!B';
  const plan = stylePlan('AB', text, [{sourceParagraph: 0,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}]);
  assert.equal(replace(f, {text, stylePlan: plan}).success, true);
  const paragraph = f.state.styles[0][0];
  assert.equal(paragraph.para.ParaAdjust.value, 5);
  assert.equal(String(paragraph.para.ParaAdjust.state), 'DEFAULT_VALUE');
  assert.equal(paragraph.para.ParaLeftMargin.value, 120, 'raw alignment DEFAULT must not discard an unrelated direct margin');
  assert.equal(String(paragraph.para.ParaLeftMargin.state), 'DIRECT_VALUE');
  assert.deepEqual(runColors(f), [0x008833, 0x008833, 0x008833], 'raw paragraph clearing leaves selected character spans distinct');
});

test('nonempty raw paragraph clearing preserves original EOP attributes separately from body styles', () => {
  const style = styledLine(0x008833, 150, 'ITALIC');
  style.para.ParaAdjust = property('short', 5, 'DEFAULT_VALUE', 5);
  style.para.ParaLeftMargin = property('long', 120, 'DIRECT_VALUE', 0);
  style.eopRun = defaultRunStyle();
  style.eopRun.CharColor = property('long', 0xff2211, 'DIRECT_VALUE', -1);
  style.eopRun.CharWeight = property('float', 100, 'DIRECT_VALUE', 100);
  style.eopRun.CharHeight = property('float', 10, 'DIRECT_VALUE', 12);
  const f = fixture({texts: [['AB', 'unchanged'], ['', 'last']], styles: [style],
    rawDefaultClearsParagraph: true, cursorParaAdjustDefaultMaterializes: true});
  const text = 'A!B';
  const plan = stylePlan('AB', text, [{sourceParagraph: 0,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}]);
  assert.equal(replace(f, {text, stylePlan: plan}).success, true);
  const paragraph = f.state.styles[0][0];
  assert.equal(paragraph.para.ParaAdjust.value, 5);
  assert.equal(String(paragraph.para.ParaAdjust.state), 'DEFAULT_VALUE');
  assert.equal(paragraph.para.ParaLeftMargin.value, 120);
  assert.deepEqual(runColors(f), [0x008833, 0x008833, 0x008833]);
  assert.equal(paragraph.run.CharWeight.value, 150);
  assert.equal(paragraph.eopRun.CharColor.value, 0xff2211, 'nonempty EOP keeps its original red style rather than the green body donor');
  assert.equal(paragraph.eopRun.CharWeight.value, 100);
  assert.equal(String(paragraph.eopRun.CharWeight.state), 'DIRECT_VALUE');
  assert.equal(paragraph.eopRun.CharHeight.value, 10);
});

test('nonempty DEFAULT alignment rejects unavailable raw EOP restoration before mutation', () => {
  for (const failure of ['directSetter', 'metadata', 'unsupportedType']) {
    const style = styledLine(0x008833, 150, 'ITALIC');
    style.para.ParaAdjust = property('short', 5, 'DEFAULT_VALUE', 5);
    const f = fixture({texts: [['AB', 'unchanged'], ['', 'last']], styles: [style], rawDefaultClearsParagraph: true,
      rawParagraphCharacterFailure: failure, cursorParaAdjustDefaultMaterializes: true});
    assert.equal(snapshot(f).cells[0].editable, true, failure + ' is checked for the actual planned raw correction');
    const text = 'A!B';
    const plan = stylePlan('AB', text, [{sourceParagraph: 0,
      segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}]);
    rejected(replace(f, {text, stylePlan: plan}), 'cell_uneditable');
    assert.equal(f.state.writes, 0, failure + ' cannot be discovered after the raw reset has erased EOP state');
  }
});

test('empty target DEFAULT alignment preserves direct margins and EOP character attributes together', () => {
  const style = styledLine(0x008833, 150, 'ITALIC');
  style.para.ParaAdjust = property('short', 5, 'DEFAULT_VALUE', 5);
  style.para.ParaLeftMargin = property('long', 120, 'DIRECT_VALUE', 0);
  const f = fixture({texts: [['AB', 'unchanged'], ['', 'last']], styles: [style], emptyEopCharacter: true,
    cursorParaAdjustDefaultMaterializes: true});
  const plan = stylePlan('AB', '', [{sourceParagraph: 0, segments: [inherit(0, 0, 0, 1)]}]);
  assert.equal(replace(f, {text: '', stylePlan: plan}).success, true);
  const empty = f.state.styles[0][0];
  assert.equal(empty.para.ParaAdjust.value, 5);
  assert.equal(String(empty.para.ParaAdjust.state), 'DEFAULT_VALUE');
  assert.equal(empty.para.ParaLeftMargin.value, 120);
  assert.equal(String(empty.para.ParaLeftMargin.state), 'DIRECT_VALUE');
  assert.equal(empty.run.CharColor.value, 0x008833);
  assert.equal(empty.eopRun.CharColor.value, 0x008833, 'a final raw paragraph default must not erase persisted EOP color');
  assert.equal(empty.eopRun.CharWeight.value, 150);
  assert.equal(String(empty.eopRun.CharPosture.value), 'ITALIC');
});

test('raw EOP-only restoration mismatch is quarantined even when live typing style is exact', () => {
  const style = styledLine(0x008833, 150, 'ITALIC');
  const f = fixture({texts: [['AB', 'unchanged'], ['', 'last']], styles: [style], emptyEopCharacter: true, eopStyleMismatch: true});
  const plan = stylePlan('AB', '', [{sourceParagraph: 0, segments: [inherit(0, 0, 0, 1)]}]);
  rejected(replace(f, {text: '', stylePlan: plan}), 'verification_failed', true);
  assert.equal(f.state.writes, 1);
  assert.equal(f.state.styles[0][0].run.CharColor.value, 0x008833, 'live selected Text portion is insufficient to verify raw EOP');
});

test('observed type4 unknown-theme wrappers preserve explicit RGB and each live native payload', () => {
  const styles = ordinaryRgbStyles({type: 4, theme: -1, resolved: 0});
  for (const [index, style] of styles.entries()) {
    style.run.CharColor = property('long', index ? 0xffffff : 0, 'DIRECT_VALUE', 0);
    style.run.CharTransparence = property('short', 0, 'DIRECT_VALUE', 0);
    style.run.CharColorLumMod = property('short', 10000, 'DIRECT_VALUE', 10000);
  }
  const f = fixture({texts: [['AB', 'unchanged'], ['', 'last']],
    styles: [mixedLine([['A', styles[0]], ['B', styles[1]]])]});
  assert.equal(snapshot(f).cells[0].editable, true, 'observed type4/themeUnknown tuple with explicit RGB is bounded support');
  const text = 'A!B';
  const plan = stylePlan('AB', text, [{sourceParagraph: 0,
    segments: [retain(0, 1, 0, 1), inherit(1, 2, 0, 1), retain(2, 3, 1, 2)]}]);
  assert.equal(replace(f, {text, stylePlan: plan}).success, true);
  assert.deepEqual(runColors(f), [0, 0, 0xffffff]);
  for (const run of f.state.styles[0][0].runs) {
    assert.equal(run.run.CharColorLumMod.type, nativeType('short'));
    assert.equal(run.run.CharColorLumMod.value, 10000);
    const complex = run.run.CharComplexColor.value;
    assert.equal(complex.getType(), 4, 'type4 is retained as observed, without calling or normalizing it to RGB/type0');
    assert.equal(complex.getThemeColorType(), -1);
    assert.equal(complex.resolveColor(null), 0, 'resolution is not substituted with explicit RGB');
  }
  assert.equal(f.state.styles[0][0].runs[0].run.CharComplexColor.value.retained, styles[0].run.CharComplexColor.value.retained);
  assert.equal(f.state.styles[0][0].runs.at(-1).run.CharComplexColor.value.retained, styles[1].run.CharComplexColor.value.retained);
  assert.ok(f.state.complexRestores.every(restore => f.state.complexReads.some(read => read.beforeWrite && read.value === restore.value)));
});

test('type4 support rejects automatic colors valid themes missing companions and unobserved semantic tuples', () => {
  const cases = [
    styles => styles[0].run.CharColor.value = -1,
    styles => styles[0].run.CharColor.value = 0x1000000,
    styles => styles[0].run.CharColorTheme.value = 0,
    ...['CharColor', 'CharTransparence', 'CharColorTheme', 'CharColorTintOrShade', 'CharColorLumMod', 'CharColorLumOff']
      .map(name => styles => { for (const style of styles) delete style.run[name]; }),
    ...[{theme: 0}, {theme: 11}, {resolved: 1}, {resolved: 0.5}, {type: '4'}, {type: 1}, {type: 8}]
      .map(payload => styles => { styles[0].run.CharComplexColor.value = new NativeComplexColor({type: 4, theme: -1, resolved: 0, ...payload}); }),
    ...['getType', 'getThemeColorType', 'resolveColor'].map(method => styles => {
      styles[0].run.CharComplexColor.value = new NativeComplexColor({type: 4, theme: -1, resolved: 0}, {}, method);
    }),
  ];
  for (const mutate of cases) {
    const styles = ordinaryRgbStyles({type: 4, theme: -1, resolved: 0}); mutate(styles);
    const f = fixture({styles});
    assert.equal(snapshot(f).cells[0].editable, false);
    rejected(replace(f), 'cell_uneditable');
    assert.equal(f.state.writes, 0);
  }
});
console.log('HOST ONLY: ' + passed + ' closed program behavior cases passed; Android UNO exposure remains unverified.');
'''


def node_tool():
    configured = os.environ.get('NODE_EXE')
    if configured:
        return configured
    if NODE.is_file():
        return str(NODE)
    result = shutil.which('node')
    if not result:
        raise RuntimeError('Node is required for the actual closed JavaScript program test')
    return result


class PresentationCellProgramTests(unittest.TestCase):
    def test_actual_closed_program_host_behavior(self):
        self.assertTrue(PROGRAM.is_file(), 'closed presentation-cell program is missing')
        subprocess.run(
            [node_tool(), '-', str(PROGRAM)],
            input=HARNESS,
            text=True,
            encoding='utf-8',
            check=True,
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
