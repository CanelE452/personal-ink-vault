import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:saber/data/office/hwpx_template_parts.dart';

enum OfficeTemplateKind { document, presentation, hwpx }

final class OfficeStarterFile {
  new({required this.fileName, required Uint8List bytes})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final String fileName;
  final Uint8List bytes;
}

abstract final class OfficeTemplates {
  static OfficeStarterFile create(
    OfficeTemplateKind kind, {
    required String title,
  }) {
    for (final rune in title.runes) {
      if (rune != 0x9 &&
          rune != 0xa &&
          rune != 0xd &&
          !(rune >= 0x20 && rune <= 0xd7ff) &&
          !(rune >= 0xe000 && rune <= 0xfffd) &&
          !(rune >= 0x10000 && rune <= 0x10ffff)) {
        throw const FormatException('Title contains an invalid XML character');
      }
    }
    if (kind == OfficeTemplateKind.hwpx) return _hwpx(title);
    final document = kind == OfficeTemplateKind.document;
    final fallback = document ? 'Document' : 'Presentation';
    final contentTitle = title.trim().isEmpty ? fallback : title;
    final escapedTitle = _escape(contentTitle);
    final mainPath = document ? 'word/document.xml' : 'ppt/presentation.xml';
    final parts = document
        ? _document(escapedTitle)
        : _presentation(escapedTitle);
    parts.addAll({
      '_rels/.rels': _relationships({
        'rId1': ('$_officeRelationships/officeDocument', mainPath),
        'rId2': (
          'http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties',
          'docProps/core.xml',
        ),
        'rId3': (
          '$_officeRelationships/extended-properties',
          'docProps/app.xml',
        ),
      }),
      'docProps/core.xml':
          '''
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
 xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>$escapedTitle</dc:title>
  <dc:creator>Personal Ink Vault</dc:creator>
  <cp:lastModifiedBy>Personal Ink Vault</cp:lastModifiedBy>
  <cp:revision>1</cp:revision>
</cp:coreProperties>''',
      'docProps/app.xml':
          '''
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
  <Application>Personal Ink Vault</Application>
  <AppVersion>1.0</AppVersion>
  ${document ? '<Pages>1</Pages>' : '<PresentationFormat>Widescreen</PresentationFormat><Slides>1</Slides>'}
</Properties>''',
    });
    final types = {
      'docProps/core.xml':
          'application/vnd.openxmlformats-package.core-properties+xml',
      'docProps/app.xml': 'application/vnd.openxmlformats-officedocument.extended-properties+xml',
      if (document) ...{
        'word/document.xml': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml',
        'word/styles.xml': 'application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml',
      } else ...{
        'ppt/presentation.xml': 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml',
        'ppt/presProps.xml': 'application/vnd.openxmlformats-officedocument.presentationml.presProps+xml',
        'ppt/slides/slide1.xml': 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml',
        'ppt/slideMasters/slideMaster1.xml': 'application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml',
        'ppt/slideLayouts/slideLayout1.xml': 'application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml',
        'ppt/theme/theme1.xml':
            'application/vnd.openxmlformats-officedocument.theme+xml',
      },
    };
    parts['[Content_Types].xml'] =
        '''
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  ${types.entries.map((entry) => '<Override PartName="/${entry.key}" ContentType="${entry.value}"/>').join()}
</Types>''';
    final archive = Archive();
    try {
      for (final part in parts.entries) {
        archive.addFile(
          ArchiveFile.string(
            part.key,
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n${part.value}',
          ),
        );
      }
      return OfficeStarterFile(
        fileName:
            '${_fileName(contentTitle, fallback)}.${document ? 'docx' : 'pptx'}',
        bytes: Uint8List.fromList(ZipEncoder().encode(archive)),
      );
    } finally {
      archive.clearSync();
    }
  }

  static OfficeStarterFile _hwpx(String title) {
    final contentTitle = title.trim().isEmpty ? 'Document' : title;
    final body =
        _escape(contentTitle.replaceAll('\r\n', '\n').replaceAll('\r', '\n'))
            .replaceAll('\t', '<hp:tab width="4000" leader="0" type="1"/>')
            .replaceAll('\n', '<hp:lineBreak/>');
    final archive = Archive();
    try {
      for (final part in hwpxTemplateParts.entries) {
        final replacement = switch (part.key) {
          'Contents/section0.xml' => body,
          'Preview/PrvText.txt' => contentTitle,
          _ => _escape(contentTitle),
        };
        final file = ArchiveFile.string(
          part.key,
          part.value.replaceAll(hwpxTemplateMarker, replacement),
        )..lastModTime = 946684800;
        if (part.key == 'mimetype') file.compression = CompressionType.none;
        archive.addFile(file);
      }
      return OfficeStarterFile(
        fileName: '${_fileName(contentTitle, 'Document')}.hwpx',
        bytes: Uint8List.fromList(ZipEncoder().encode(archive)),
      );
    } finally {
      archive.clearSync();
    }
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;')
      .replaceAll('\r', '&#13;');

  static String _fileName(String title, String fallback) {
    var name = title
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    name = String.fromCharCodes(name.runes.take(100));
    name = name.replaceAll(RegExp(r'[. ]+$'), '');
    if (name.isEmpty) return fallback;
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)',
      caseSensitive: false,
    ).hasMatch(name)) {
      name = '_$name';
    }
    return name;
  }

  static const _officeRelationships =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const _word =
      'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  static const _drawing =
      'http://schemas.openxmlformats.org/drawingml/2006/main';
  static const _slides =
      'http://schemas.openxmlformats.org/presentationml/2006/main';

  static String _relationships(Map<String, (String, String)> relationships) =>
      '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  ${relationships.entries.map((entry) => '<Relationship Id="${entry.key}" Type="${entry.value.$1}" Target="${entry.value.$2}"/>').join()}
</Relationships>''';

  static Map<String, String> _document(String title) => {
    'word/document.xml':
        '''
<w:document xmlns:w="$_word">
  <w:body>
    <w:p><w:r><w:t xml:space="preserve">$title</w:t></w:r></w:p>
    <w:sectPr>
      <w:pgSz w:w="11906" w:h="16838"/>
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
    </w:sectPr>
  </w:body>
</w:document>''',
    'word/_rels/document.xml.rels': _relationships({
      'rId1': ('$_officeRelationships/styles', 'styles.xml'),
    }),
    'word/styles.xml':
        '''
<w:styles xmlns:w="$_word">
  <w:docDefaults>
    <w:rPrDefault><w:rPr>
      <w:rFonts w:ascii="Noto Sans CJK KR" w:hAnsi="Noto Sans CJK KR" w:eastAsia="Noto Sans CJK KR" w:cs="Noto Sans CJK KR"/>
      <w:sz w:val="24"/><w:szCs w:val="24"/>
    </w:rPr></w:rPrDefault>
    <w:pPrDefault/>
  </w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
</w:styles>''',
  };

  static const _shapeTree = '''
<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>''';

  static Map<String, String> _presentation(String title) => {
    'ppt/presentation.xml':
        '''
<p:presentation xmlns:p="$_slides" xmlns:a="$_drawing" xmlns:r="$_officeRelationships">
  <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
  <p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>
  <p:sldSz cx="12192000" cy="6858000" type="screen16x9"/>
  <p:notesSz cx="6858000" cy="9144000"/>
  <p:defaultTextStyle><a:defPPr><a:defRPr lang="ko-KR"/></a:defPPr></p:defaultTextStyle>
</p:presentation>''',
    'ppt/_rels/presentation.xml.rels': _relationships({
      'rId1': (
        '$_officeRelationships/slideMaster',
        'slideMasters/slideMaster1.xml',
      ),
      'rId2': ('$_officeRelationships/slide', 'slides/slide1.xml'),
      'rId3': ('$_officeRelationships/presProps', 'presProps.xml'),
      'rId4': ('$_officeRelationships/theme', 'theme/theme1.xml'),
    }),
    'ppt/presProps.xml': '<p:presentationPr xmlns:p="$_slides"/>',
    'ppt/slides/slide1.xml':
        '''
<p:sld xmlns:p="$_slides" xmlns:a="$_drawing">
  <p:cSld><p:spTree>$_shapeTree
    <p:sp>
      <p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr>
        <a:xfrm><a:off x="914400" y="685800"/><a:ext cx="10363200" cy="1828800"/></a:xfrm>
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln>
      </p:spPr>
      <p:txBody><a:bodyPr wrap="square" anchor="ctr"/><a:lstStyle/>
        <a:p><a:r><a:rPr lang="ko-KR" sz="3600">
          <a:solidFill><a:srgbClr val="202124"/></a:solidFill>
          <a:latin typeface="Noto Sans CJK KR"/><a:ea typeface="Noto Sans CJK KR"/><a:cs typeface="Noto Sans CJK KR"/>
        </a:rPr><a:t>$title</a:t></a:r><a:endParaRPr lang="ko-KR" sz="3600"/></a:p>
      </p:txBody>
    </p:sp>
  </p:spTree></p:cSld>
  <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>''',
    'ppt/slides/_rels/slide1.xml.rels': _relationships({
      'rId1': (
        '$_officeRelationships/slideLayout',
        '../slideLayouts/slideLayout1.xml',
      ),
    }),
    'ppt/slideLayouts/slideLayout1.xml':
        '''
<p:sldLayout xmlns:p="$_slides" xmlns:a="$_drawing" type="blank" preserve="1">
  <p:cSld name="Blank"><p:spTree>$_shapeTree</p:spTree></p:cSld>
  <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sldLayout>''',
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels': _relationships({
      'rId1': (
        '$_officeRelationships/slideMaster',
        '../slideMasters/slideMaster1.xml',
      ),
    }),
    'ppt/slideMasters/slideMaster1.xml':
        '''
<p:sldMaster xmlns:p="$_slides" xmlns:a="$_drawing" xmlns:r="$_officeRelationships">
  <p:cSld name="Ink Vault"><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>$_shapeTree</p:spTree></p:cSld>
  <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
  <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
  <p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles>
</p:sldMaster>''',
    'ppt/slideMasters/_rels/slideMaster1.xml.rels': _relationships({
      'rId1': (
        '$_officeRelationships/slideLayout',
        '../slideLayouts/slideLayout1.xml',
      ),
      'rId2': ('$_officeRelationships/theme', '../theme/theme1.xml'),
    }),
    'ppt/theme/theme1.xml': _theme,
  };

  static const _theme =
      '''
<a:theme xmlns:a="$_drawing" name="Ink Vault">
  <a:themeElements>
    <a:clrScheme name="Ink Vault">
      <a:dk1><a:srgbClr val="202124"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
      <a:dk2><a:srgbClr val="42474E"/></a:dk2><a:lt2><a:srgbClr val="F1F3F4"/></a:lt2>
      <a:accent1><a:srgbClr val="1A73E8"/></a:accent1><a:accent2><a:srgbClr val="D93025"/></a:accent2>
      <a:accent3><a:srgbClr val="188038"/></a:accent3><a:accent4><a:srgbClr val="A142F4"/></a:accent4>
      <a:accent5><a:srgbClr val="007B83"/></a:accent5><a:accent6><a:srgbClr val="E37400"/></a:accent6>
      <a:hlink><a:srgbClr val="1A73E8"/></a:hlink><a:folHlink><a:srgbClr val="A142F4"/></a:folHlink>
    </a:clrScheme>
    <a:fontScheme name="Ink Vault">
      <a:majorFont><a:latin typeface="Noto Sans CJK KR"/><a:ea typeface="Noto Sans CJK KR"/><a:cs typeface="Noto Sans CJK KR"/></a:majorFont>
      <a:minorFont><a:latin typeface="Noto Sans CJK KR"/><a:ea typeface="Noto Sans CJK KR"/><a:cs typeface="Noto Sans CJK KR"/></a:minorFont>
    </a:fontScheme>
    <a:fmtScheme name="Ink Vault">
      <a:fillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      </a:fillStyleLst>
      <a:lnStyleLst>
        <a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
      </a:lnStyleLst>
      <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
      <a:bgFillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      </a:bgFillStyleLst>
    </a:fmtScheme>
  </a:themeElements>
</a:theme>''';
}
