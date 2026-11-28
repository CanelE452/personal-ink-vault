/// The fixed list of action ids. An id is lowerCamel and never changes: saved
/// right-side layouts read them. "Published by" says who fills the registry.
abstract final class AppActionIds {
  // 229 shortcuts published by the editor (document registry).
  static const insertPage = 'insertPage';
  static const pageMode = 'pageMode';
  static const finger = 'finger';
  static const fullscreen = 'fullscreen';
  static const export = 'export';
  static const linkAdd = 'linkAdd';

  // 229 shortcuts published by the workspace in the document registry (again
  // for each open document). An editor without a host publishes only `save`.
  static const prev = 'prev';
  static const next = 'next';
  static const save = 'save';
  static const pdfSearch = 'pdfSearch';
  static const documentExport = 'documentExport';
  static const viewToggle = 'viewToggle';
  static const pdfRemake = 'pdfRemake';
  static const quickSwitch = 'quickSwitch';
  static const bookmarks = 'bookmarks';
  static const knowledge = 'knowledge';
  static const copyPageLink = 'copyPageLink';

  // 229 shortcuts published by the workspace in the app registry. The document
  // registry finds them through its parent.
  static const mcp = 'mcp';
  static const openNoteLink = 'openNoteLink';
  static const vaultExport = 'vaultExport';

  // Editor input, published by the editor.
  static const undo = 'undo';
  static const redo = 'redo';
  static const pickPhoto = 'pickPhoto';
  static const paste = 'paste';
  static const duplicateSelection = 'duplicateSelection';
  static const deleteSelection = 'deleteSelection';
  static const recolorSelection = 'recolorSelection';
  static const linkSelection = 'linkSelection';
  static const pageList = 'pageList';

  // Tools, published by the editor. `checked` is whether it is the current tool.
  static const toolLasso = 'toolLasso';
  static const toolPen = 'toolPen';
  static const toolEraser = 'toolEraser';
  static const toolText = 'toolText';
  static const toolShapes = 'toolShapes';
  static const toolHighlighter = 'toolHighlighter';
  static const toolPencil = 'toolPencil';
  static const toolLaser = 'toolLaser';

  // The editor's ⋯ menu, published by the editor. `saveNow` ("지금 저장")
  // saves at once even when auto save is on; it is not the 229 shortcut
  // `save`. (확대 비율 is no action: the menu reads the editor's zoom.)
  static const saveNow = 'saveNow';
  static const readOnly = 'readOnly';
  static const pageDuplicate = 'pageDuplicate';
  static const templateChange = 'templateChange';
  static const goToPage = 'goToPage';
  static const clearPage = 'clearPage';
  static const toolbarCustomize = 'toolbarCustomize';

  // The ⋯ menu rows published by the workspace in the document registry,
  // but `docInfo`, published by the editor (it knows the pages).
  static const rename = 'rename';
  static const moveToTrash = 'moveToTrash';
  static const docInfo = 'docInfo';
  static const tabBarHide = 'tabBarHide';

  // App level, published by the workspace in the app registry. `openDataDir`
  // only on desktop.
  static const openSettings = 'openSettings';
  static const localVaults = 'localVaults';
  static const backup = 'backup';
  static const restore = 'restore';
  static const viewLogs = 'viewLogs';
  static const openDataDir = 'openDataDir';

  // Infinite note, published by the infinite note page. `toolMove` is its
  // move tool (the editor has none); `checked` as for the tools above.
  static const canvasOrigin = 'canvasOrigin';
  static const canvasSave = 'canvasSave';
  static const toolMove = 'toolMove';

  // Later stages: nobody publishes these in stage 1, so their menu rows hide.
  // The editor publishes pageBookmark (supplement Task 9) and outlineAdd
  // (Task 10) where the note's vault holds page marks.
  static const pageBookmark = 'pageBookmark';
  static const pageCopy = 'pageCopy';
  static const pageRotate = 'pageRotate';
  static const outlineAdd = 'outlineAdd';
  static const selectiveErase = 'selectiveErase';
  static const alignObjects = 'alignObjects';
  static const showDoneMemos = 'showDoneMemos';

  // Decided to be made (user, 2026-11-19). Published by the editor (document
  // registry).
  static const eyedropper = 'eyedropper';

  // Supplement Task 12: the toolbar's record button, published by the editor
  // on Android where the note's vault holds recordings (format 2).
  static const record = 'record';

  // Supplement Task 13: the quick note window (the toolbar's 노트 창),
  // published by the editor where the note's vault holds attachments
  // (format 2).
  static const quickNote = 'quickNote';

  // Supplement Task 14: the toolbar's 노트 추가 window (where to put a page and
  // in which pattern), published by the editor. `insertPage` puts one in at
  // once, where and as the window last did.
  static const insertPageMenu = 'insertPageMenu';

  // Stage 2 Task 4: what the toolbar's mode button, the ⋯ menu's 확대 잠금
  // and the old toolbar keys did, published by the editor and by the infinite
  // note (each screen has its own floating bar). None of them is `checked`:
  // the state is in `stows.editorGestureMode` and `stows.lastZoomLock`, and the
  // bar's open flag belongs to its screen. `eraserBar` writes again out of
  // gesture mode, takes the eraser (the eraser in hand goes back to the tool
  // before it, as the eraser button) and opens the floating bar.
  static const gestureMode = 'gestureMode';
  static const floatingBar = 'floatingBar';
  static const zoomLock = 'zoomLock';
  static const eraserBar = 'eraserBar';

  /// The tool actions in toolbar order.
  static const List<String> tools = [
    toolLasso,
    toolPen,
    toolEraser,
    toolText,
    toolShapes,
    toolHighlighter,
    toolPencil,
    toolLaser,
  ];

  /// The 229 "⋯" menu order of the note function row (Task 14 reads it).
  static const List<String> more229 = [
    export,
    pdfRemake,
    quickSwitch,
    bookmarks,
    knowledge,
    mcp,
    copyPageLink,
    openNoteLink,
    vaultExport,
    linkAdd,
  ];

  /// Every id.
  static const List<String> all = [
    insertPage,
    pageMode,
    finger,
    fullscreen,
    export,
    linkAdd,
    prev,
    next,
    save,
    pdfSearch,
    documentExport,
    viewToggle,
    pdfRemake,
    quickSwitch,
    bookmarks,
    knowledge,
    copyPageLink,
    mcp,
    openNoteLink,
    vaultExport,
    undo,
    redo,
    pickPhoto,
    paste,
    duplicateSelection,
    deleteSelection,
    recolorSelection,
    linkSelection,
    pageList,
    toolLasso,
    toolPen,
    toolEraser,
    toolText,
    toolShapes,
    toolHighlighter,
    toolPencil,
    toolLaser,
    saveNow,
    readOnly,
    pageDuplicate,
    templateChange,
    goToPage,
    clearPage,
    toolbarCustomize,
    rename,
    moveToTrash,
    docInfo,
    tabBarHide,
    openSettings,
    localVaults,
    backup,
    restore,
    viewLogs,
    openDataDir,
    canvasOrigin,
    canvasSave,
    toolMove,
    pageBookmark,
    pageCopy,
    pageRotate,
    outlineAdd,
    selectiveErase,
    alignObjects,
    showDoneMemos,
    eyedropper,
    record,
    quickNote,
    insertPageMenu,
    gestureMode,
    floatingBar,
    zoomLock,
    eraserBar,
  ];
}
