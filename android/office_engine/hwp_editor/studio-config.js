// Loaded by the bundled rhwp-studio page before its own scripts. The app editor must never reach a CDN:
// fonts come from the bundled /fonts/ folder (the WebView also blocks every non-local request).
window.__RHWP_DISABLE_EXTERNAL_WEBFONTS__ = true;

// The app keeps its own edit session and recovery, so the studio's draft autosave (IndexedDB copies of the
// document, offered back through a "문서 복구" prompt) is turned off, and drafts left by builds 213/214 are removed.
// A block keeps these names out of the page's shared global scope.
{
  let settings = {};
  try {
    settings = JSON.parse(localStorage.getItem('rhwp-settings') || '{}') || {};
  } catch (error) {
    settings = {};
  }
  settings.autosave = { ...settings.autosave, recoveryEnabled: false, idleSaveEnabled: false };
  localStorage.setItem('rhwp-settings', JSON.stringify(settings));
  indexedDB.deleteDatabase('rhwpStudioAutosave');
}

// Diagnostics for the app log: when the browser finishes loading fonts, the studio refreshes the page view. A
// refresh that lands while a document is still loading used to leave a blank page (fixed in the staged bundle).
document.fonts.addEventListener('loadingdone', (event) => {
  console.info(`[PIV] fonts loadingdone at ${Math.round(performance.now())} ms, faces ${event.fontfaces?.length ?? 0}`);
});
