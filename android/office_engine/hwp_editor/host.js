// Host page of the Android HWP editor (HwpEditorActivity). It embeds the bundled rhwp-studio through the
// official @rhwp/editor client, loads the working copy the Activity serves at /__piv/document, and hands the
// saved bytes back through the PivHwpHost JavaScript interface.
import { createEditor } from './rhwp-editor/index.js';

const host = window.PivHwpHost;
let editor = null;
let info = null;

function report(state, detail) {
  host.state(state, detail === undefined ? '' : String(detail));
}

function message(error) {
  return String((error && error.message) || error);
}

function base64(bytes) {
  let text = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(text);
}

async function open() {
  try {
    info = JSON.parse(host.documentInfo());
    // chrome=embed: the studio's embedding mode. No startup blank document, no draft-recovery prompt, and no
    // studio file menu (new/open/save/print) or Ctrl+S/Ctrl+P; the app's "저장하고 닫기" is the only save.
    editor = await createEditor('#editor', {
      studioUrl: new URL('/?chrome=embed', location.href).href,
      requestTimeoutMs: 120000,
    });
    const response = await fetch('/__piv/document', { cache: 'no-store' });
    if (!response.ok) throw new Error(`document ${response.status}`);
    const result = await editor.loadFile(await response.arrayBuffer(), info.name, { suppressDialogs: true });
    report('opened', result.pageCount);
  } catch (error) {
    report('openFailed', message(error));
  }
}

// Called by the Activity's "저장하고 닫기" button.
window.pivSave = async function () {
  try {
    if (!editor) throw new Error('editor not ready');
    const bytes = info.format === 'hwpx' ? await editor.exportHwpx() : await editor.exportHwp();
    if (!bytes || bytes.length === 0) throw new Error('empty export');
    host.saved(base64(bytes));
  } catch (error) {
    report('saveFailed', message(error));
  }
};

// Called after the Activity has written the bytes, so the studio stops warning about unsaved changes.
window.pivSavedOk = async function () {
  try {
    await editor.notifySaved(info.name);
  } catch (error) {
    report('notifyFailed', message(error));
  }
};

// Called before closing without saving.
window.pivDirty = async function () {
  try {
    const state = await editor.getDocumentState();
    host.dirty(Boolean(state.dirty));
  } catch (error) {
    host.dirty(true);
  }
};

open();
