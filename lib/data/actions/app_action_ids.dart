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
  ];
}
