"""Exercise Office recovery with real files and JDK Activity/Intent stubs.

PIV_OFFICE_TEST_JNI_DIR and PIV_OFFICE_TEST_LEGACY_FIXTURES select the Rust
classifier and actual valid.doc/valid.ppt fixtures instead of the host double.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_lifecycle import method


MODULE = Path(__file__).parent
JAVA = MODULE / "src/main/java/io/github/canele452/personalinkvault/office"
APP = MODULE.parent / "app/src/main/kotlin/com/adilhanney/saber/MainActivity.kt"

HARNESS = r'''
import io.github.canele452.personalinkvault.office.*;
import android.app.Activity;
import android.content.Intent;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.FileTime;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.zip.*;

public class RecoveryHarness {
  static final String VERSION = "26.04.6.0-962";
  static final String ID = "01234567-89ab-4cde-8fab-0123456789ab";
  static final String OTHER = "01234567-89ab-4cde-8fab-0123456789ac";
  static final String WRONG = "0".repeat(64);
  static void require(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }
  interface Checked { void run() throws Exception; }
  static void rejects(Checked action, String message) throws Exception {
    try { action.run(); }
    catch (IOException | IllegalArgumentException expected) { return; }
    throw new AssertionError(message);
  }
  static String hash(File file) throws Exception {
    byte[] digest = MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(file.toPath()));
    StringBuilder result = new StringBuilder();
    for (byte value : digest) result.append(String.format("%02x", value & 255));
    return result.toString();
  }
  static void docx(File file, String content) throws Exception {
    writePackage(file, packageParts("docx",content), false);
  }
  static LinkedHashMap<String,byte[]> packageParts(String format,String content) {
    LinkedHashMap<String,byte[]> entries=new LinkedHashMap<>();
    String types="<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
      +"<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
      +"<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
      +"<Override PartName=\"/"+(format.equals("docx")?"word/document.xml":"ppt/presentation.xml")
      +"\" ContentType=\"application/vnd.openxmlformats-officedocument."
      +(format.equals("docx")?"wordprocessingml.document.main+xml":"presentationml.presentation.main+xml")+"\"/></Types>";
    if (format.equals("docx") || format.equals("pptx")) {
      entries.put("[Content_Types].xml",types.getBytes(StandardCharsets.UTF_8));
      entries.put("_rels/.rels",("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        +"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\""
        +(format.equals("docx")?"word/document.xml":"ppt/presentation.xml")+"\"/></Relationships>").getBytes(StandardCharsets.UTF_8));
      String escaped=content.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;");
      if (format.equals("docx")) entries.put("word/document.xml",("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        +"<w:body><w:p><w:r><w:t>"+escaped+"</w:t></w:r></w:p></w:body></w:document>").getBytes(StandardCharsets.UTF_8));
      else entries.put("ppt/presentation.xml",("<p:presentation xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">"
        +"<!--"+escaped+"--><p:sldIdLst/></p:presentation>").getBytes(StandardCharsets.UTF_8));
    } else {
      String mime="application/vnd.oasis.opendocument."+(format.equals("odt")?"text":"presentation");
      String escaped=content.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;");
      entries.put("mimetype",mime.getBytes(StandardCharsets.US_ASCII));
      entries.put("content.xml",("<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" office:version=\"1.2\">"
        +"<!--"+escaped+"--><office:body><office:"+(format.equals("odt")?"text":"presentation")+"/></office:body></office:document-content>").getBytes(StandardCharsets.UTF_8));
      entries.put("META-INF/manifest.xml",("<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\">"
        +"<manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\""+mime+"\"/>"
        +"<manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>").getBytes(StandardCharsets.UTF_8));
    }
    return entries;
  }
  static void writePackage(File file,Map<String,byte[]> entries,boolean stored) throws Exception {
    writePackage(file,entries,stored,null);
  }
  static void writePackage(File file,Map<String,byte[]> entries,boolean stored,String commentedEntry) throws Exception {
    try (ZipOutputStream zip = new ZipOutputStream(new FileOutputStream(file))) {
      for (Map.Entry<String,byte[]> item:entries.entrySet()) {
        ZipEntry entry=new ZipEntry(item.getKey());
        if (item.getKey().equals(commentedEntry)) entry.setComment("safe-central");
        if (stored || item.getKey().equals("mimetype")) {
          CRC32 crc=new CRC32(); crc.update(item.getValue());
          entry.setMethod(ZipEntry.STORED); entry.setSize(item.getValue().length); entry.setCompressedSize(item.getValue().length); entry.setCrc(crc.getValue());
        }
        zip.putNextEntry(entry); zip.write(item.getValue()); zip.closeEntry();
      }
    }
  }
  static void office(File file,String format,String content) throws Exception {
    if (format.equals("doc") || format.equals("ppt")) {
      String fixtures = System.getProperty("piv.test.legacy-fixtures");
      if (fixtures != null) {
        Files.copy(Path.of(fixtures,"valid."+format),file.toPath(),StandardCopyOption.REPLACE_EXISTING);
        return;
      }
      ByteArrayOutputStream bytes=new ByteArrayOutputStream();
      // A family-tagged fixture for the host classifier double.
      bytes.write(new byte[]{(byte)0xd0,(byte)0xcf,0x11,(byte)0xe0,(byte)0xa1,(byte)0xb1,0x1a,(byte)0xe1});
      bytes.write(format.equals("doc")?1:2);
      bytes.write(content.getBytes(StandardCharsets.UTF_8));
      Files.write(file.toPath(),bytes.toByteArray());
    } else writePackage(file,packageParts(format,content),false);
  }
  static void pdf(File file, String content) throws Exception {
    // Only the journal's byte identity is exercised. Android validates real PDF pages.
    Files.writeString(file.toPath(), "%PDF-1.4\n" + content + "\n%%EOF\n");
  }
  static void changeSameLength(File file) throws Exception {
    byte[] bytes=Files.readAllBytes(file.toPath());
    bytes[bytes.length/2]^=1;
    Files.write(file.toPath(),bytes);
  }
  static int unsigned16(byte[] bytes,int offset) {
    return (bytes[offset]&255)|((bytes[offset+1]&255)<<8);
  }
  static long unsigned32(byte[] bytes,int offset) {
    return (unsigned16(bytes,offset)&65535L)|((unsigned16(bytes,offset+2)&65535L)<<16);
  }
  static void littleEndian(OutputStream output,long value,int count) throws Exception {
    for (int index=0;index<count;index++) output.write((int)(value>>>(8*index))&255);
  }
  static void zip64Directory(File file) throws Exception {
    byte[] original=Files.readAllBytes(file.toPath());
    int end=original.length-22;
    require(unsigned32(original,end)==0x06054b50L,"ZIP64 fixture starts with an ordinary un-commented EOCD");
    long count=unsigned16(original,end+10), size=unsigned32(original,end+12), offset=unsigned32(original,end+16);
    ByteArrayOutputStream bytes=new ByteArrayOutputStream(); bytes.write(original,0,end);
    littleEndian(bytes,0x06064b50L,4); littleEndian(bytes,44,8);
    littleEndian(bytes,45,2); littleEndian(bytes,45,2);
    littleEndian(bytes,0,4); littleEndian(bytes,0,4);
    littleEndian(bytes,count,8); littleEndian(bytes,count,8);
    littleEndian(bytes,size,8); littleEndian(bytes,offset,8);
    littleEndian(bytes,0x07064b50L,4); littleEndian(bytes,0,4);
    littleEndian(bytes,end,8); littleEndian(bytes,1,4);
    byte[] eocd=Arrays.copyOfRange(original,end,original.length);
    Arrays.fill(eocd,8,20,(byte)0xff);
    bytes.write(eocd); Files.write(file.toPath(),bytes.toByteArray());
  }
  static void zipComment(File file) throws Exception {
    byte[] bytes=Files.readAllBytes(file.toPath());
    ByteArrayOutputStream text=new ByteArrayOutputStream();
    text.write("retained Office comment ".getBytes(StandardCharsets.UTF_8));
    text.write(new byte[]{0x50,0x4b,0x05,0x06});
    text.write(new byte[24]);
    text.write(" comment suffix".getBytes(StandardCharsets.UTF_8));
    byte[] comment=text.toByteArray();
    int end=bytes.length-22;
    require(unsigned32(bytes,end)==0x06054b50L,"ZIP comment fixture EOCD");
    bytes[end+20]=(byte)comment.length; bytes[end+21]=0;
    ByteArrayOutputStream output=new ByteArrayOutputStream(); output.write(bytes); output.write(comment);
    Files.write(file.toPath(),output.toByteArray());
  }
  static int centralEntry(byte[] bytes,String name) {
    for (int offset=0;offset+46<=bytes.length;offset++) {
      if (bytes[offset]!=0x50 || bytes[offset+1]!=0x4b || bytes[offset+2]!=0x01 || bytes[offset+3]!=0x02) continue;
      int length=unsigned16(bytes,offset+28);
      if (offset+46+length<=bytes.length && name.equals(new String(bytes,offset+46,length,StandardCharsets.UTF_8))) return offset;
    }
    throw new AssertionError("fixture central-directory entry missing: "+name);
  }
  static void corruptCrc(File file,String name,byte[] payload) throws Exception {
    byte[] bytes=Files.readAllBytes(file.toPath());
    int entry=centralEntry(bytes,name);
    bytes[entry+16]^=0x5a;
    Files.write(file.toPath(),bytes);
    CRC32 crc=new CRC32(); crc.update(payload);
    try (ZipFile zip=new ZipFile(file)) {
      require(zip.getEntry(name).getCrc()!=crc.getValue(),"fixture explicitly mismatches the declared CRC without relying on ZipFile stream checks");
    }
  }
  static void duplicateEntryName(File file,String from,String to) throws Exception {
    byte[] bytes=Files.readAllBytes(file.toPath());
    int entry=centralEntry(bytes,from);
    byte[] oldName=from.getBytes(StandardCharsets.UTF_8), newName=to.getBytes(StandardCharsets.UTF_8);
    require(oldName.length==newName.length,"duplicate-name fixture preserves ZIP offsets");
    int local=(bytes[entry+42]&255)|((bytes[entry+43]&255)<<8)|((bytes[entry+44]&255)<<16)|((bytes[entry+45]&255)<<24);
    System.arraycopy(newName,0,bytes,entry+46,newName.length);
    System.arraycopy(newName,0,bytes,local+30,newName.length);
    Files.write(file.toPath(),bytes);
    try (ZipFile zip=new ZipFile(file)) {
      long count=zip.stream().filter(item->item.getName().equals(to)).count();
      require(count==2,"fixture contains two separate entries with the same required name");
    }
  }
  static void markUnixSymlink(File file,String name) throws Exception {
    byte[] bytes=Files.readAllBytes(file.toPath());
    int entry=centralEntry(bytes,name);
    bytes[entry+4]=20;
    bytes[entry+5]=3; // Unix version-made-by host.
    bytes[entry+38]=0; bytes[entry+39]=0;
    bytes[entry+40]=(byte)0xff; bytes[entry+41]=(byte)0xa1; // 0120777 << 16.
    Files.write(file.toPath(),bytes);
    try (ZipFile zip=new ZipFile(file)) {
      ZipEntry item=zip.getEntry(name);
      CRC32 crc=new CRC32();
      try (InputStream input=zip.getInputStream(item)) {
        byte[] buffer=new byte[1024]; int count;
        while ((count=input.read(buffer))!=-1) crc.update(buffer,0,count);
      }
      require(!item.isDirectory() && crc.getValue()==item.getCrc(),"symlink fixture changes only Unix type attributes, with safe name and valid payload CRC");
    }
  }
  static void concatenatedSymlinkPackage(File file) throws Exception {
    String body="word/document.xml";
    writePackage(file,packageParts("docx","same valid package payload"),true,body);
    byte[] safe=Files.readAllBytes(file.toPath());
    markUnixSymlink(file,body);
    byte[] linked=Files.readAllBytes(file.toPath());
    int entry=centralEntry(linked,body);
    int comment=entry+46+unsigned16(linked,entry+28)+unsigned16(linked,entry+30);
    byte[] label="link-central".getBytes(StandardCharsets.UTF_8);
    require(unsigned16(linked,entry+32)==label.length,"decoy fixture keeps both central-directory lengths equal");
    System.arraycopy(label,0,linked,comment,label.length);
    ByteArrayOutputStream bytes=new ByteArrayOutputStream(); bytes.write(safe); bytes.write(linked);
    Files.write(file.toPath(),bytes.toByteArray());
    try (ZipFile zip=new ZipFile(file)) {
      require(zip.size()==packageParts("docx","unused").size(),"concatenated ZIP keeps the approved entry count");
      require("link-central".equals(zip.getEntry(body).getComment()),"actual ZipFile uses the second, symlink-marked central directory instead of the safe declared-offset decoy");
      CRC32 crc=new CRC32();
      try (InputStream input=zip.getInputStream(zip.getEntry(body))) {
        byte[] buffer=new byte[1024]; int count;
        while ((count=input.read(buffer))!=-1) crc.update(buffer,0,count);
      }
      require(crc.getValue()==zip.getEntry(body).getCrc(),"actual ZipFile can read the selected second package with matching payload CRC");
    }
  }
  static void expandedPackage(File file,boolean forgeSize) throws Exception {
    try (ZipOutputStream zip=new ZipOutputStream(new FileOutputStream(file))) {
      for (Map.Entry<String,byte[]> part:packageParts("docx","bounded body").entrySet()) {
        zip.putNextEntry(new ZipEntry(part.getKey())); zip.write(part.getValue()); zip.closeEntry();
      }
      zip.putNextEntry(new ZipEntry("assets/expanded.bin"));
      byte[] block=new byte[65536];
      for (int count=0;count<129*16;count++) zip.write(block);
      zip.closeEntry();
    }
    require(file.length()<3*1024*1024,"expanded-size fixture is small on disk");
    if (forgeSize) {
      byte[] bytes=Files.readAllBytes(file.toPath());
      int entry=centralEntry(bytes,"assets/expanded.bin");
      bytes[entry+24]=1; bytes[entry+25]=0; bytes[entry+26]=0; bytes[entry+27]=0;
      Files.write(file.toPath(),bytes);
      try (ZipFile zip=new ZipFile(file)) {
        require(zip.getEntry("assets/expanded.bin").getSize()==1,"fixture advertises one byte, so bounded reads cannot rely only on metadata");
      }
    }
  }
  static void containerScenario(File root,String scenario) throws Exception {
    if (scenario.equals("valid")) {
      for (String format:List.of("doc","ppt","docx","pptx","odt","odp")) {
        Fixture f=new Fixture(new File(root,"valid-"+format),format);
        Map<String,Object> saved=f.saved();
        binding(saved,"saved",f.inputHash);
        require(f.reopened().recover(ID,f.inputHash).equals(saved),"valid container remains recoverable: "+format);
      }
      for (String variant:List.of("comment","zip64")) {
        Fixture f=new Fixture(new File(root,"valid-"+variant));
        File edited=new File(f.directory,"edited.docx");
        docx(edited,"valid central-directory variant");
        if (variant.equals("zip64")) zip64Directory(edited);
        zipComment(edited);
        pdf(new File(f.directory,"preview.pdf"),"valid directory preview");
        Map<String,Object> saved=f.journal.recordSaved(ID,f.inputHash,1);
        require(f.reopened().recover(ID,f.inputHash).equals(saved),"regular ZIP/ZIP64 comments preserve saved recovery");
      }
      System.out.println("native valid-container scenarios passed");
      return;
    }
    String format=scenario.substring(0,scenario.indexOf('-'));
    Fixture f=new Fixture(new File(root,scenario),format);
    File edited=new File(f.directory,"edited."+format);
    File preview=new File(f.directory,"preview.pdf");
    pdf(preview,"validated native PDF result");
    LinkedHashMap<String,byte[]> entries=packageParts(format,"invalid export candidate");
    String body=format.equals("docx")?"word/document.xml":format.equals("pptx")?"ppt/presentation.xml":"content.xml";
    if (scenario.endsWith("invalid-ole")) {
      Files.writeString(edited.toPath(),"nonempty bytes are not an OLE document");
    } else if (scenario.endsWith("truncated-ole")) {
      Files.write(edited.toPath(),new byte[]{(byte)0xd0,(byte)0xcf,0x11,(byte)0xe0,(byte)0xa1,(byte)0xb1,0x1a});
    } else if (scenario.endsWith("expanded") || scenario.endsWith("forged-size")) {
      expandedPackage(edited,scenario.endsWith("forged-size"));
    } else if (scenario.endsWith("decoy-central")) {
      concatenatedSymlinkPackage(edited);
    } else {
      if (scenario.endsWith("missing-types")) entries.remove("[Content_Types].xml");
      if (scenario.endsWith("missing-body") || scenario.endsWith("missing-content")) entries.remove(body);
      if (scenario.endsWith("missing-mimetype")) entries.remove("mimetype");
      if (scenario.endsWith("empty-types")) entries.put("[Content_Types].xml",new byte[0]);
      if (scenario.endsWith("empty-body")) entries.put(body,new byte[0]);
      if (scenario.endsWith("empty-mimetype")) entries.put("mimetype",new byte[0]);
      if (scenario.endsWith("wrong-mimetype")) entries.put("mimetype",("application/vnd.oasis.opendocument."+(format.equals("odt")?"presentation":"text")).getBytes(StandardCharsets.US_ASCII));
      if (scenario.endsWith("duplicate-body")) entries.put("word/duplicat.xml",entries.get(body));
      if (scenario.endsWith("unsafe-name")) entries.put("../escape.bin",new byte[]{1,2,3});
      if (scenario.endsWith("symlink-extra")) entries.put("assets/link.bin","../../outside.docx".getBytes(StandardCharsets.UTF_8));
      if (scenario.endsWith("crc-extra")) entries.put("assets/extra.bin","unrelated entry CRC must also be checked".getBytes(StandardCharsets.UTF_8));
      writePackage(edited,entries,scenario.contains("crc-"));
      if (scenario.endsWith("crc-body")) corruptCrc(edited,body,entries.get(body));
      if (scenario.endsWith("crc-extra")) corruptCrc(edited,"assets/extra.bin",entries.get("assets/extra.bin"));
      if (scenario.endsWith("duplicate-body")) duplicateEntryName(edited,"word/duplicat.xml",body);
      if (scenario.endsWith("symlink-body")) markUnixSymlink(edited,body);
      if (scenario.endsWith("symlink-extra")) markUnixSymlink(edited,"assets/link.bin");
    }
    String inputBefore=hash(f.input), workingBefore=hash(f.working);
    String editedBefore=hash(edited), pdfBefore=hash(preview);
    rejects(() -> f.journal.recordSaved(ID,f.inputHash,1),"invalid exported container must not lock the native session as saved: "+scenario);
    require(!f.savedMarker().exists(),"invalid export must not publish a saved marker: "+scenario);
    require(inputBefore.equals(hash(f.input)) && workingBefore.equals(hash(f.working)),"invalid export preserves original and working copies");
    require(editedBefore.equals(hash(edited)) && pdfBefore.equals(hash(preview)),"invalid export files are retained without rewriting");
    binding(f.reopened().recover(ID,f.inputHash),"working",f.inputHash);
    office(edited,format,"corrected export");
    binding(f.journal.recordSaved(ID,f.inputHash,1),"saved",f.inputHash);
    System.out.println("native rejected-container "+scenario+" scenarios passed");
  }
  static class Fixture {
    final File root;
    final File input;
    final OfficeSessionJournal journal;
    final Map<String,Object> created;
    final File directory;
    final File working;
    final String inputHash;
    final String format;
    Fixture(File root) throws Exception {
      this(root,"docx");
    }
    Fixture(File root,String format) throws Exception {
      this.root = root;
      this.format = format;
      require(root.mkdirs() || root.isDirectory(), "fixture root");
      input = new File(root, "original."+format);
      office(input,format,"original");
      inputHash = hash(input);
      journal = new OfficeSessionJournal(new File(root, "office-sessions"), VERSION);
      created = journal.create(input, ID, format);
      working = new File((String)created.get("workingPath"));
      directory = working.getParentFile();
    }
    OfficeSessionJournal reopened() throws Exception {
      return new OfficeSessionJournal(new File(root, "office-sessions"), VERSION);
    }
    Map<String,Object> saved() throws Exception {
      office(new File(directory, "edited."+format),format,"edited");
      pdf(new File(directory, "preview.pdf"), "matching preview");
      return journal.recordSaved(ID, inputHash, 2);
    }
    File marker() { return new File(directory, "session.properties"); }
    File savedMarker() { return new File(directory, "saved.properties"); }
  }
  static Fixture fixture(File root, String name) throws Exception {
    return new Fixture(new File(root, name));
  }
  static void binding(Map<String,Object> result, String state, String inputHash) {
    require(state.equals(result.get("status")), "state: " + result);
    require(ID.equals(result.get("sessionId")), "session binding: " + result);
    require(inputHash.equals(result.get("inputSourceSha256")), "input hash binding: " + result);
    require(VERSION.equals(result.get("engineVersion")), "engine binding: " + result);
  }
  static void copyDirectory(File from, File to) throws Exception {
    try (var paths = Files.walk(from.toPath())) {
      for (Path source : paths.toList()) {
        Path target = to.toPath().resolve(from.toPath().relativize(source));
        if (Files.isDirectory(source)) Files.createDirectories(target);
        else Files.copy(source, target);
      }
    }
  }
  static void replaceProperty(File file, String key, String value) throws Exception {
    Properties properties = new Properties();
    try (InputStream input = new FileInputStream(file)) { properties.load(input); }
    require(properties.containsKey(key), "fixture property " + key);
    properties.setProperty(key, value);
    try (OutputStream output = new FileOutputStream(file)) { properties.store(output, null); }
  }
  static void journalScenarios(File root) throws Exception {
    Fixture f = fixture(root, "roundtrip");
    binding(f.created, "working", f.inputHash);
    require(f.marker().isFile(), "session binding must exist before create returns to launch");
    require(f.working.getName().equals("working.docx"), "fixed working basename");
    require(f.directory.getParentFile().getCanonicalFile().equals(new File(f.root,"office-sessions").getCanonicalFile()), "private immediate directory");
    require(hash(f.working).equals(f.inputHash), "initial copy matches input");
    require(f.input.renameTo(new File(f.root,"moved-original.docx")), "move original after preparation");
    Map<String,Object> found = f.reopened().recover(ID, f.inputHash);
    binding(found, "working", f.inputHash);
    require(found.get("workingPath").equals(f.created.get("workingPath")), "restart reuses the private working file without the input path");
    docx(f.working, "autosaved later input");
    found = f.reopened().recover(ID, f.inputHash);
    binding(found, "working", f.inputHash);
    require(hash(f.working).equals(found.get("workingSha256")), "current working hash is independently read");
    require(!f.inputHash.equals(found.get("workingSha256")), "autosaved working bytes do not replace input binding");
    binding(f.reopened().recover(OTHER, WRONG), "missing", WRONG, OTHER);
    rejects(() -> f.reopened().recover(ID, WRONG), "wrong input SHA must not be missing or usable");
    rejects(() -> f.journal.create(new File(f.root,"moved-original.docx"), ID, "docx"), "duplicate edit must not create an ambiguous second session");

    Fixture partial = fixture(root, "partial");
    docx(new File(partial.directory,"edited.docx"), "source export finished");
    pdf(new File(partial.directory,"preview.pdf"), "unacknowledged PDF export");
    Files.writeString(new File(partial.directory,"saved.properties.interrupted.tmp").toPath(), "status=saved\n");
    binding(partial.reopened().recover(ID, partial.inputHash), "working", partial.inputHash);
    require(!partial.savedMarker().exists(), "unmarked outputs must not be promoted to saved");

    Fixture complete = fixture(root, "complete");
    Map<String,Object> saved = complete.saved();
    binding(saved, "saved", complete.inputHash);
    require(complete.savedMarker().isFile(), "verified saved marker is durable before returning the result");
    require(new File((String)saved.get("sourcePath")).getName().equals("edited.docx"), "fixed edited basename");
    require(new File((String)saved.get("pdfPath")).getName().equals("preview.pdf"), "fixed PDF basename");
    require(hash(new File((String)saved.get("sourcePath"))).equals(saved.get("sourceSha256")), "edited source hash remains separate");
    require(hash(new File((String)saved.get("pdfPath"))).equals(saved.get("pdfSha256")), "exact PDF hash");
    require(Integer.valueOf(2).equals(saved.get("pdfPageCount")), "validated page count is retained");
    require(complete.reopened().recover(ID, complete.inputHash).equals(saved), "result loss recovers the exact saved result in a fresh instance");
    byte[] markerBefore = Files.readAllBytes(complete.savedMarker().toPath());
    FileTime old = FileTime.fromMillis(946684800000L);
    Files.setLastModifiedTime(complete.savedMarker().toPath(), old);
    require(complete.journal.recordSaved(ID, complete.inputHash, 2).equals(saved), "identical saved retry returns the first snapshot");
    require(Arrays.equals(markerBefore, Files.readAllBytes(complete.savedMarker().toPath())), "saved retry preserves marker bytes");
    require(Files.getLastModifiedTime(complete.savedMarker().toPath()).equals(old), "saved retry never rewrites its receipt");
    rejects(() -> complete.journal.recordSaved(ID, complete.inputHash, 3), "different saved retry must not change the committed result");

    for (String damage : List.of("malformed marker","missing source","changed source","missing PDF","changed PDF","missing binding")) {
      Fixture damaged = fixture(root, damage.replace(' ','-'));
      damaged.saved();
      switch (damage) {
        case "malformed marker": Files.writeString(damaged.savedMarker().toPath(), "bad saved marker"); break;
        case "missing source": Files.delete(new File(damaged.directory,"edited.docx").toPath()); break;
        case "changed source": changeSameLength(new File(damaged.directory,"edited.docx")); break;
        case "missing PDF": Files.delete(new File(damaged.directory,"preview.pdf").toPath()); break;
        case "changed PDF": changeSameLength(new File(damaged.directory,"preview.pdf")); break;
        case "missing binding": Files.delete(damaged.marker().toPath()); break;
      }
      rejects(() -> damaged.reopened().recover(ID, damaged.inputHash), "corrupt saved state cannot fall back to working: " + damage);
    }
    for (String property : List.of("sessionId","inputSourceSha256","format","workingName")) {
      Fixture damaged = fixture(root,"binding-"+property);
      replaceProperty(damaged.marker(), property, property.equals("sessionId") ? "../escape" : property.equals("inputSourceSha256") ? WRONG : property.equals("format") ? "exe" : "../original.docx");
      rejects(() -> damaged.reopened().recover(ID, damaged.inputHash), "changed binding must fail closed: " + property);
    }
    Fixture extra = fixture(root,"extra-field");
    Files.writeString(extra.marker().toPath(), "unexpected=value\n", StandardOpenOption.APPEND);
    rejects(() -> extra.reopened().recover(ID, extra.inputHash), "unknown marker field");
    Fixture duplicateProperty = fixture(root,"duplicate-property");
    Files.writeString(duplicateProperty.marker().toPath(), "sessionId="+ID+"\n", StandardOpenOption.APPEND);
    rejects(() -> duplicateProperty.reopened().recover(ID, duplicateProperty.inputHash), "duplicate property must not be silently overwritten");
    Fixture oversized = fixture(root,"oversized-marker");
    Files.writeString(oversized.marker().toPath(), "padding="+"x".repeat(16384)+"\n", StandardOpenOption.APPEND);
    rejects(() -> oversized.reopened().recover(ID, oversized.inputHash), "marker parsing must be bounded");
    Fixture duplicate = fixture(root,"duplicate-directory");
    copyDirectory(duplicate.directory, new File(duplicate.directory.getParentFile(), OTHER));
    rejects(() -> duplicate.reopened().recover(ID, duplicate.inputHash), "duplicate matching session directory must be ambiguous");
    for (String bad : List.of("../escape", "/absolute", "s1", ID+"/child")) {
      rejects(() -> duplicate.reopened().recover(bad, WRONG), "new recovery UUID validation");
    }
    rejects(() -> complete.reopened().recover(ID,"not-a-hash"), "input SHA syntax");

    Fixture blocked = fixture(root,"publish-failure");
    docx(new File(blocked.directory,"edited.docx"), "preserve source");
    pdf(new File(blocked.directory,"preview.pdf"), "preserve PDF");
    byte[] inputBefore = Files.readAllBytes(blocked.input.toPath());
    byte[] workingBefore = Files.readAllBytes(blocked.working.toPath());
    require(blocked.savedMarker().mkdir(), "block the destination marker with a directory");
    Files.writeString(new File(blocked.savedMarker(),"keep").toPath(), "do not replace");
    rejects(() -> blocked.journal.recordSaved(ID, blocked.inputHash, 1), "failed marker publication must not report saved");
    require(Arrays.equals(inputBefore,Files.readAllBytes(blocked.input.toPath())), "publish failure preserves input");
    require(Arrays.equals(workingBefore,Files.readAllBytes(blocked.working.toPath())), "publish failure preserves working");
    require(new File(blocked.savedMarker(),"keep").isFile(), "a foreign directory must never be replaced");
    symlinkScenarios(root);
    System.out.println("native journal real-file scenarios passed");
  }

  static void legacySourceReadyScenarios(File root) throws Exception {
    Fixture f = new Fixture(new File(root, "source-ready"), "ppt");
    File edited = new File(f.directory, "edited.ppt");
    office(edited, "ppt", "serialized user edits");
    String sourceHash = hash(edited);
    Files.writeString(new File(f.directory, "source-ready.properties").toPath(),
        "version=1\nsessionId=" + ID + "\ninputSourceSha256=" + f.inputHash
        + "\nformat=ppt\nengineVersion=" + VERSION + "\nsourceName=edited.ppt"
        + "\nsourceSha256=" + sourceHash + "\nsourceLength=" + edited.length()
        + "\nworkingSha256=" + hash(f.working) + "\n");
    pdf(new File(f.directory, "preview.pdf"), "older unacknowledged PDF");
    Map<String,Object> recovered = f.reopened().recover(ID, f.inputHash);
    binding(recovered, "source_ready", f.inputHash);
    require(edited.getPath().equals(recovered.get("sourcePath")), "retry must reopen the serialized edit");
    require(sourceHash.equals(recovered.get("sourceSha256")), "retry uses the committed edit hash");
    require(!f.savedMarker().exists(), "an older PDF does not promote the source-ready marker");
    System.out.println("native legacy source checkpoint scenarios passed");
  }

  static void previewPromotionScenarios(File root, List<String> formats) throws Exception {
    for (String format : formats) {
      Fixture f = new Fixture(new File(root, "preview-" + format), format);
      File edited = new File(f.directory, "edited." + format);
      if (!format.equals("doc") && !format.equals("ppt")) {
        String foreign = Map.of("docx", "pptx", "pptx", "docx", "odt", "odp", "odp", "odt").get(format);
        office(edited, foreign, "different document family");
        rejects(() -> f.journal.recordSourceReady(ID, f.inputHash), "the saved package must match its registered format");
        binding(f.reopened().recover(ID, f.inputHash), "working", f.inputHash);
      }
      office(edited, format, "serialized user edits");
      String sourceHash = hash(edited), workingHash = hash(f.working);
      File oldPreview = new File(f.directory, "preview.pdf");
      File attempt = new File(f.root, "attempt.pdf");
      pdf(oldPreview, "old PDF without committed provenance");
      pdf(attempt, "new PDF from reopened edit");
      String oldPdfHash = hash(oldPreview), pdfHash = hash(attempt);
      rejects(() -> f.journal.recordReopenedPreview(ID, f.inputHash, sourceHash, attempt, pdfHash, 2),
          "a PDF cannot be promoted without the serialized source checkpoint");

      Map<String,Object> ready = f.journal.recordSourceReady(ID, f.inputHash);
      binding(ready, "source_ready", f.inputHash);
      require(ready.get("sourcePath").equals(edited.getPath()) && ready.get("sourceSha256").equals(sourceHash),
          "the saved source belongs to this edit");
      require(ready.get("workingPath").equals(f.working.getPath()) && ready.get("workingSha256").equals(workingHash),
          "the recovery binding preserves working metadata");
      Files.delete(f.working.toPath());
      OfficeSessionJournal restarted = f.reopened();
      require(restarted.recover(ID, f.inputHash).equals(ready), "the serialized edit survives the loss of the earlier working file");
      require(restarted.recordSourceReady(ID, f.inputHash).equals(ready), "source-ready retry cannot overwrite the source receipt");
      rejects(() -> restarted.recordSaved(ID, f.inputHash, 2), "the same-memory saved path cannot publish a checkpointed edit");
      rejects(() -> restarted.recordReopenedPreview(ID, f.inputHash, sourceHash, oldPreview, oldPdfHash, 2),
          "the session's own stale PDF cannot stand in for a new reopen attempt");
      rejects(() -> restarted.recordReopenedPreview(OTHER, f.inputHash, sourceHash, attempt, pdfHash, 2),
          "different session cannot promote this PDF");
      rejects(() -> restarted.recordReopenedPreview(ID, WRONG, sourceHash, attempt, pdfHash, 2),
          "different original cannot promote this PDF");
      rejects(() -> restarted.recordReopenedPreview(ID, f.inputHash, WRONG, attempt, pdfHash, 2),
          "different serialized edit cannot promote this PDF");
      rejects(() -> restarted.recordReopenedPreview(ID, f.inputHash, sourceHash, attempt, WRONG, 2),
          "wrong PDF hash cannot promote this PDF");
      rejects(() -> restarted.recordReopenedPreview(ID, f.inputHash, sourceHash, attempt, pdfHash, 0),
          "invalid page count cannot promote this PDF");
      File invalidPdf = new File(f.root, "invalid.pdf");
      Files.writeString(invalidPdf.toPath(), "%PDF-1.4\ntruncated PDF without trailer");
      String invalidHash = hash(invalidPdf);
      rejects(() -> restarted.recordReopenedPreview(ID, f.inputHash, sourceHash, invalidPdf, invalidHash, 2),
          "valid digest cannot promote an invalid PDF");
      require(hash(oldPreview).equals(oldPdfHash) && !f.savedMarker().exists()
          && restarted.recover(ID, f.inputHash).equals(ready), "failed exports leave the edit ready for another attempt");

      byte[] exactSource = Files.readAllBytes(edited.toPath());
      changeSameLength(edited);
      rejects(() -> restarted.recover(ID, f.inputHash), "a changed checkpoint cannot fall back to the old working path");
      rejects(() -> restarted.recordReopenedPreview(ID, f.inputHash, sourceHash, attempt, pdfHash, 2),
          "a changed source cannot publish an otherwise valid PDF");
      Files.write(edited.toPath(), exactSource);

      Map<String,Object> saved = restarted.recordReopenedPreview(ID, f.inputHash, sourceHash, attempt, pdfHash, 2);
      binding(saved, "saved", f.inputHash);
      require(hash(edited).equals(sourceHash) && saved.get("sourceSha256").equals(sourceHash), "publish retains the exact source");
      require(saved.get("pdfPath").equals(oldPreview.getPath()) && hash(oldPreview).equals(pdfHash)
          && saved.get("pdfSha256").equals(pdfHash), "publish replaces the stale PDF with the exact reopened output");
      require(hash(attempt).equals(pdfHash), "the attempt remains owned by its caller");
      Files.delete(attempt.toPath());
      FileTime originalMarkerTime = Files.getLastModifiedTime(f.savedMarker().toPath());
      require(f.reopened().recordReopenedPreview(ID, f.inputHash, sourceHash, attempt, pdfHash, 2).equals(saved),
          "the exact retry returns the existing snapshot without a live preview lease");
      require(Files.getLastModifiedTime(f.savedMarker().toPath()).equals(originalMarkerTime), "retry does not rewrite the saved marker");
      rejects(() -> restarted.recordReopenedPreview(ID, f.inputHash, sourceHash, attempt, pdfHash, 3),
          "a different retry cannot replace the saved result");
      require(f.reopened().recover(ID, f.inputHash).equals(saved), "a restart recovers the exact final snapshot");

      Fixture historical = new Fixture(new File(root, "historical-" + format), format);
      Map<String,Object> v1 = historical.saved();
      require(historical.reopened().recover(ID, historical.inputHash).equals(v1), "old v1 saved receipts remain readable");
    }
    String firstFormat = formats.get(0);
    Fixture forged = new Fixture(new File(root, "foreign-checkpoint"), firstFormat);
    office(new File(forged.directory, "edited." + firstFormat), firstFormat, "serialized edit");
    forged.journal.recordSourceReady(ID, forged.inputHash);
    replaceProperty(new File(forged.directory, "source-ready.properties"), "sessionId", OTHER);
    rejects(() -> forged.reopened().recover(ID, forged.inputHash), "foreign source checkpoint fails closed");
    System.out.println("native preview promotion " + formats + " scenarios passed");
  }
  static void binding(Map<String,Object> result, String state, String inputHash, String session) {
    require(state.equals(result.get("status")), "missing state");
    require(session.equals(result.get("sessionId")), "missing request session binding");
    require(inputHash.equals(result.get("inputSourceSha256")), "missing request SHA binding");
    require(VERSION.equals(result.get("engineVersion")), "missing engine version");
  }
  static void symlinkScenarios(File root) throws Exception {
    Fixture f = fixture(root,"symlink");
    File outside = new File(root,"outside.docx");
    docx(outside,"outside protected input");
    Path probe = new File(root,"symlink-probe").toPath();
    try { Files.createSymbolicLink(probe, outside.toPath()); }
    catch (UnsupportedOperationException | FileSystemException unavailable) {
      System.out.println("symlink cases unavailable on this host: " + unavailable.getClass().getSimpleName());
      return;
    }
    Files.delete(probe);
    byte[] protectedBytes = Files.readAllBytes(outside.toPath());
    Files.delete(f.working.toPath());
    Files.createSymbolicLink(f.working.toPath(), outside.toPath());
    rejects(() -> f.reopened().recover(ID,f.inputHash), "working symlink must not be followed");
    require(Arrays.equals(protectedBytes,Files.readAllBytes(outside.toPath())), "outside payload stays untouched");
    Fixture saved = fixture(root,"saved-symlink");
    saved.saved();
    File edited = new File(saved.directory,"edited.docx");
    File clone = new File(root,"same-saved-bytes.docx");
    Files.copy(edited.toPath(),clone.toPath());
    Files.delete(edited.toPath());
    Files.createSymbolicLink(edited.toPath(),clone.toPath());
    rejects(() -> saved.reopened().recover(ID,saved.inputHash), "saved symlink must fail even when its bytes/hash match");
    Fixture dir = fixture(root,"directory-symlink");
    File moved = new File(root,"outside-session");
    require(dir.directory.renameTo(moved), "move real private directory");
    Files.createSymbolicLink(dir.directory.toPath(),moved.toPath());
    rejects(() -> dir.reopened().recover(ID,dir.inputHash), "session directory symlink must not escape the private root");
  }
  static class Completion implements OfficeEngineBridge.Completion {
    final CountDownLatch done = new CountDownLatch(1);
    Map<String,Object> result;
    String code;
    public void success(Map<String,Object> result) { this.result=result; done.countDown(); }
    public void error(String code,String message) { this.code=code; done.countDown(); }
    void await() throws Exception { require(done.await(3,TimeUnit.SECONDS), "bounded bridge completion"); }
  }
  static void waitLaunch(Activity activity, int count) throws Exception {
    long until = System.nanoTime()+TimeUnit.SECONDS.toNanos(3);
    while (activity.launches<count && System.nanoTime()<until) Thread.sleep(5);
    require(activity.launches==count,"expected exactly " + count + " native launches, got " + activity.launches);
  }
  static void expectPreflightFailure(Activity activity, Completion completion, String code, String route) throws Exception {
    long until = System.nanoTime()+TimeUnit.SECONDS.toNanos(3);
    while (activity.launches==0 && completion.done.getCount()!=0 && System.nanoTime()<until) Thread.sleep(5);
    require(activity.launches==0, route+" must reject the document before launching Collabora");
    completion.await();
    require(code.equals(completion.code) && completion.result==null,route+" should return "+code+", got "+completion.code);
    require(!OfficeSessionJournal.hasLiveEditor(),route+" must not reserve an editor on failure");
  }
  static void legacyFormatScenarios(File root) throws Exception {
    String mismatch = "office_format_mismatch";
    for (String format : List.of("doc","ppt")) {
      String opposite = format.equals("doc") ? "ppt" : "doc";
      File home = new File(root,"open-"+format);
      Files.createDirectories(home.toPath());
      File wrong = new File(home,"자료-\uD83D\uDCC4."+format);
      office(wrong,opposite,"wrong family");
      String originalHash = hash(wrong);
      Activity activity = new Activity(home);
      OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
      try {
        Completion edit = new Completion();
        bridge.edit(wrong.getPath(),ID,edit);
        expectPreflightFailure(activity,edit,mismatch,"edit "+format);
        File[] sessions = new File(home,"office-sessions").listFiles();
        require(sessions==null || sessions.length==0,"wrong edit must not create a recovery session");
        Completion preview = new Completion();
        bridge.preview(wrong.getPath(),ID,preview);
        expectPreflightFailure(activity,preview,mismatch,"preview "+format);
        if (format.equals("ppt")) {
          Completion inspect = new Completion();
          bridge.inspect(wrong.getAbsolutePath(),ID,originalHash,inspect);
          expectPreflightFailure(activity,inspect,mismatch,"inspect "+format);
        }
        File[] previews = new File(home,"office-previews").listFiles();
        require(previews==null || previews.length==0,"wrong preview copies must be cleaned up");
        require(originalHash.equals(hash(wrong)),"wrong input bytes must be retained");
        Files.writeString(wrong.toPath(),"unrecognized container");
        Completion invalid = new Completion();
        bridge.preview(wrong.getPath(),ID,invalid);
        expectPreflightFailure(activity,invalid,"office_open_failed","malformed preview "+format);

        File correct = new File(home,"올바른-\uD83D\uDCC4."+format);
        office(correct,format,"correct family");
        String correctHash = hash(correct);
        Completion normal = new Completion();
        bridge.edit(correct.getPath(),ID,normal);
        waitLaunch(activity,1);
        require(normal.done.getCount()==1,"matching document reaches the editor");
        bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT,Activity.RESULT_CANCELED,new Intent().putExtra("sessionId",ID));
        normal.await();
        binding(normal.result,"cancelled",correctHash);
        require(correctHash.equals(hash(correct)),"normal launch leaves original bytes intact");
      } finally { bridge.dispose(); }

      Fixture f = new Fixture(new File(root,"recovery-"+format),format);
      Activity recoveryActivity = new Activity(f.root);
      OfficeEngineBridge recovery = new OfficeEngineBridge(recoveryActivity);
      try {
        office(f.working,opposite,"old raw working copy");
        String workingHash = hash(f.working);
        String bindingHash = hash(f.marker());
        Completion recover = new Completion();
        recovery.recover(ID,f.inputHash,recover);
        expectPreflightFailure(recoveryActivity,recover,mismatch,"working recovery "+format);
        Completion resume = new Completion();
        recovery.resume(ID,f.inputHash,resume);
        expectPreflightFailure(recoveryActivity,resume,mismatch,"working resume "+format);
        require(workingHash.equals(hash(f.working)) && bindingHash.equals(hash(f.marker())),"invalid recovery keeps the original binding and working bytes");

        File edited = new File(f.directory,"edited."+format);
        File preview = new File(f.directory,"preview.pdf");
        office(edited,opposite,"wrong family output");
        pdf(preview,"output remains available");
        String editedHash = hash(edited), previewHash = hash(preview);
        rejects(() -> f.journal.recordSaved(ID,f.inputHash,1),"wrong family output cannot be published");
        require(!f.savedMarker().exists(),"wrong family output must not create a saved receipt");
        require(editedHash.equals(hash(edited)) && previewHash.equals(hash(preview)),"failed publication preserves output files");
        f.saved();
        office(edited,opposite,"earlier editor saved under the wrong extension");
        replaceProperty(f.savedMarker(),"sourceSha256",hash(edited));
        replaceProperty(f.savedMarker(),"sourceLength",Long.toString(edited.length()));
        String receiptHash = hash(f.savedMarker());
        editedHash = hash(edited);
        Completion saved = new Completion();
        recovery.resume(ID,f.inputHash,saved);
        expectPreflightFailure(recoveryActivity,saved,mismatch,"saved recovery "+format);
        require(receiptHash.equals(hash(f.savedMarker())) && editedHash.equals(hash(edited)),"saved recovery retains old receipt and output bytes");
      } finally { recovery.dispose(); }
    }
    System.out.println("native legacy family preflight scenarios passed");
  }
  static void historicalRecoveryScenarios(File root) throws Exception {
    File home = new File(root,"android-files");
    Files.createDirectories(home.toPath());
    File owned = new File(root,"external-vault/.workspace/office-recovery/"+OTHER+"/"+ID+"/native/edited.doc");
    Files.createDirectories(owned.getParentFile().toPath());
    office(owned,"doc","historical source");
    String sourceHash = hash(owned);
    Activity activity = new Activity(home);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    try {
      Completion valid = new Completion();
      bridge.validateLegacySource(owned.getAbsolutePath(),"doc",sourceHash,valid);
      valid.await();
      require(valid.code==null && Collections.emptyMap().equals(valid.result),"verified historical recovery succeeds without returning bytes");
      require(activity.launches==0 && !OfficeSessionJournal.hasLiveEditor(),"historical validation is read-only");
      require(sourceHash.equals(hash(owned)),"historical validation does not rewrite the source");
      Completion unbound = new Completion();
      bridge.validateLegacySource(owned.getAbsolutePath(),"doc",WRONG,unbound);
      expectPreflightFailure(activity,unbound,"office_recovery_invalid","historical digest mismatch");
      File outside = new File(root,"edited.doc");
      Files.copy(owned.toPath(),outside.toPath());
      Completion foreign = new Completion();
      bridge.validateLegacySource(outside.getAbsolutePath(),"doc",sourceHash,foreign);
      expectPreflightFailure(activity,foreign,"office_recovery_invalid","historical foreign path");
      office(owned,"ppt","historical wrong family source");
      String wrongHash = hash(owned);
      Completion mismatch = new Completion();
      bridge.validateLegacySource(owned.getAbsolutePath(),"doc",wrongHash,mismatch);
      expectPreflightFailure(activity,mismatch,"office_format_mismatch","historical format mismatch");
      require(wrongHash.equals(hash(owned)),"wrong historical source remains available");
    } finally { bridge.dispose(); }
    System.out.println("historical recovery source validation scenarios passed");
  }
  static void bridgeScenarios(File root) throws Exception {
    Fixture f = fixture(root,"bridge");
    Activity activity = new Activity(f.root);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    try {
      Completion missing = new Completion();
      bridge.recover(OTHER,WRONG,missing); missing.await();
      binding(missing.result,"missing",WRONG,OTHER);
      require(activity.launches==0,"recover is read-only and never launches an editor");
      Completion working = new Completion();
      bridge.recover(ID,f.inputHash,working); working.await();
      binding(working.result,"working",f.inputHash);
      Completion resumed = new Completion();
      bridge.resume(ID,f.inputHash,resumed); waitLaunch(activity,1);
      require(resumed.done.getCount()==1,"resume waits for the actual activity result");
      require(f.working.getPath().equals(activity.lastIntent.getStringExtra("piv.workingPath")),"resume must reuse the same working file");
      require(f.directory.getPath().equals(activity.lastIntent.getStringExtra("piv.sessionDirectory")),"resume must reuse the same private directory");
      Completion concurrent = new Completion();
      bridge.resume(ID,f.inputHash,concurrent); concurrent.await();
      require("office_busy".equals(concurrent.code),"pending resume blocks another native launch");
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT,Activity.RESULT_CANCELED,new Intent().putExtra("sessionId",ID));
      resumed.await(); binding(resumed.result,"cancelled",f.inputHash);
      binding(f.reopened().recover(ID,f.inputHash),"working",f.inputHash);
      Completion mismatch = new Completion();
      bridge.resume(ID,f.inputHash,mismatch); waitLaunch(activity,2);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT,Activity.RESULT_CANCELED,new Intent().putExtra("sessionId",OTHER));
      mismatch.await(); require("invalid_office_result".equals(mismatch.code),"cancelled results must obey session binding");
      Completion normalEdit = new Completion();
      bridge.edit(f.input.getPath(),OTHER,normalEdit); waitLaunch(activity,3);
      String secondHash=hash(f.input);
      File secondDirectory=new File(activity.lastIntent.getStringExtra("piv.sessionDirectory"));
      OfficeSessionJournal secondJournal=f.reopened();
      Map<String,Object> secondWorking=secondJournal.recover(OTHER,secondHash);
      binding(secondWorking,"working",secondHash,OTHER);
      docx(new File(secondDirectory,"edited.docx"),"normal edit output");
      pdf(new File(secondDirectory,"preview.pdf"),"normal edit PDF");
      Map<String,Object> secondSaved=secondJournal.recordSaved(OTHER,secondHash,2);
      Intent data=new Intent();
      for (String key : List.of("sourcePath","pdfPath","sourceSha256","pdfSha256","sessionId","inputSourceSha256"))
        data.putExtra(key,(String)secondSaved.get(key));
      data.putExtra("pdfPageCount",2);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT,Activity.RESULT_OK,data);
      normalEdit.await();
      require(secondSaved.equals(normalEdit.result),"normal saved callback must retain the native input hash binding");
    } finally { bridge.dispose(); }

    Object liveOwner = new Object();
    require(OfficeSessionJournal.reserveEditor(OTHER,liveOwner),"fixture owns another live editor");
    OfficeEngineBridge fresh = new OfficeEngineBridge(activity);
    try {
      Completion busy = new Completion(); fresh.resume(ID,f.inputHash,busy); busy.await();
      require("office_busy".equals(busy.code),"a fresh bridge cannot launch over a live editor belonging to another Activity");
      Completion edit = new Completion(); fresh.edit(f.input.getPath(),OTHER,edit); edit.await();
      require("office_busy".equals(edit.code),"fresh edit observes the live Activity guard");
      Completion preview = new Completion(); fresh.preview(f.input.getPath(),OTHER,preview); preview.await();
      require("office_busy".equals(preview.code),"preview cannot open another native document over a live editor");
      require(activity.launches==3,"live busy rejection happens before launch");
    } finally { OfficeSessionJournal.releaseEditor(liveOwner); fresh.dispose(); }

    Map<String,Object> saved = f.saved();
    OfficeEngineBridge afterRestart = new OfficeEngineBridge(activity);
    try {
      Completion recovered = new Completion(); afterRestart.recover(ID,f.inputHash,recovered); recovered.await();
      require(saved.equals(recovered.result),"fresh pending=null bridge recovers saved files after result loss");
      byte[] markerBefore = Files.readAllBytes(f.savedMarker().toPath());
      FileTime old = FileTime.fromMillis(946684800000L);
      Files.setLastModifiedTime(f.savedMarker().toPath(),old);
      Completion resumed = new Completion(); afterRestart.resume(ID,f.inputHash,resumed); resumed.await();
      require(saved.equals(resumed.result),"saved resume returns the exact result");
      require(activity.launches==3,"saved resume must not reopen or overwrite native output");
      require(Arrays.equals(markerBefore,Files.readAllBytes(f.savedMarker().toPath())),"saved resume preserves marker bytes");
      require(Files.getLastModifiedTime(f.savedMarker().toPath()).equals(old),"saved resume does not rewrite the receipt");
      Completion wrong = new Completion(); afterRestart.recover(ID,WRONG,wrong); wrong.await();
      require(wrong.code!=null && wrong.result==null,"wrong input binding never returns another document's saved result");
    } finally { afterRestart.dispose(); }
    System.out.println("native bridge stub-Activity recovery scenarios passed");
  }

  static void legacyConversionScenarios(File root) throws Exception {
    Activity activity = new Activity(root);
    File ingress = new File(activity.getCacheDir(), "piv-office-legacy-copy-fixture");
    require(ingress.mkdirs(), "private cache fixture created");
    File source = new File(ingress, "source.doc");
    office(source, "doc", "original text");
    String sourceHash = hash(source);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    try {
      require(Boolean.TRUE.equals(bridge.capabilities().get("supportsLegacyConversion")), "bundled engine advertises the conversion");
      File foreign = new File(root, "source.doc");
      Files.copy(source.toPath(), foreign.toPath());
      Completion rejected = new Completion();
      bridge.convertLegacy(foreign.getPath(), ID, sourceHash, rejected); rejected.await();
      require("invalid_office_conversion".equals(rejected.code) && activity.launches == 0,
          "source outside the designated cache cannot launch");

      Completion converted = new Completion();
      bridge.convertLegacy(source.getPath(), ID, sourceHash, converted); waitLaunch(activity, 1);
      Intent launch = activity.lastIntent;
      require(launch.getBooleanExtra("piv.previewOnly", false) && launch.getBooleanExtra("piv.legacyConversion", false),
          "conversion opens the existing read-only Activity route");
      require(sourceHash.equals(launch.getStringExtra("piv.inputSourceSha256")), "working document retains input binding");
      File working = new File(launch.getStringExtra("piv.workingPath"));
      require(hash(working).equals(sourceHash) && !working.equals(source), "the editor receives a distinct working file");
      File candidate = new File(working.getParentFile(), "converted.docx");
      docx(candidate, "converted text");
      String convertedHash = hash(candidate);
      Intent result = new Intent().putExtra("sessionId", ID).putExtra("inputSourceSha256", sourceHash)
          .putExtra("sourcePath", candidate.getPath()).putExtra("sourceSha256", convertedHash).putExtra("targetExtension", "docx");
      Object editor = new Object();
      var editorOpened = OfficeSessionJournal.class.getDeclaredMethod("editorOpened", String.class, Object.class, boolean.class);
      editorOpened.setAccessible(true);
      require(Boolean.TRUE.equals(editorOpened.invoke(null, ID, editor, true)), "actual preview child claims the launch reservation");
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_OK, result);
      try {
        require(!converted.done.await(200, TimeUnit.MILLISECONDS), "successful output must not race the old Activity close");
      } finally { OfficeSessionJournal.releaseEditor(editor); }
      converted.await();
      require(Map.of("engineVersion", VERSION, "status", "converted", "sessionId", ID, "inputSourceSha256", sourceHash,
          "targetExtension", "docx", "sourcePath", candidate.getPath(), "sourceSha256", convertedHash).equals(converted.result),
          "closed converted result has exactly the owned output and digest");
      Completion released = new Completion();
      bridge.releasePreview(ID, released); released.await();
      require(!candidate.exists() && !working.exists() && hash(source).equals(sourceHash), "release removes only the conversion lease");

      Completion changed = new Completion();
      bridge.convertLegacy(source.getPath(), OTHER, sourceHash, changed); waitLaunch(activity, 2);
      File changedDirectory = new File(activity.lastIntent.getStringExtra("piv.sessionDirectory"));
      File changedCandidate = new File(changedDirectory, "converted.docx");
      docx(changedCandidate, "another valid candidate");
      changeSameLength(source);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_OK,
          new Intent().putExtra("sessionId", OTHER).putExtra("inputSourceSha256", sourceHash)
              .putExtra("sourcePath", changedCandidate.getPath()).putExtra("sourceSha256", hash(changedCandidate))
              .putExtra("targetExtension", "docx"));
      changed.await();
      require("invalid_office_conversion".equals(changed.code) && !changedDirectory.exists() && source.isFile(),
          "changed input denies conversion and only discards its own working directory");

      File presentation = new File(ingress, "source.ppt");
      office(presentation, "ppt", "original slide");
      Completion cancelled = new Completion();
      bridge.convertLegacy(presentation.getPath(), ID, hash(presentation), cancelled); waitLaunch(activity, 3);
      File cancelledDirectory = new File(activity.lastIntent.getStringExtra("piv.sessionDirectory"));
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED,
          new Intent().putExtra("sessionId", ID).putExtra("piv.previewCancelled", true));
      cancelled.await();
      require(Map.of("engineVersion", VERSION, "status", "cancelled", "sessionId", ID).equals(cancelled.result)
          && !cancelledDirectory.exists() && presentation.isFile(), "cancellation retains only the original");
    } finally { bridge.dispose(); }
    System.out.println("legacy conversion bridge ownership and close ordering scenarios passed");
  }
  static void previewTimeoutScenario(File root) throws Exception {
    Files.createDirectories(root.toPath());
    File source = new File(root,"slides.pptx");
    office(source,"pptx","preview timeout");
    String original = hash(source);
    Activity activity = new Activity(root);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    try {
      Completion preview = new Completion();
      bridge.preview(source.getPath(),ID,preview);
      waitLaunch(activity,1);
      File working = new File(activity.lastIntent.getStringExtra("piv.workingPath"));
      OfficeEngineHealth.quarantine();
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT,Activity.RESULT_CANCELED,
          new Intent().putExtra("sessionId",ID).putExtra("errorCode",OfficeEngineHealth.ERROR_CODE)
              .putExtra("errorMessage",OfficeEngineHealth.RECOVERY_MESSAGE));
      preview.await();
      require(OfficeEngineHealth.ERROR_CODE.equals(preview.code) && preview.result==null,"timeout must report an error without publishing a PDF");
      require(working.isFile() && original.equals(hash(working)),"a timed-out native worker must retain its working input");
      require(original.equals(hash(source)),"timeout retains the vault source bytes");
    } finally { bridge.dispose(); }
    System.out.println("preview timeout retention scenarios passed");
  }

  static void previewActivityReleaseScenario(File root) throws Exception {
    Files.createDirectories(root.toPath());
    Activity activity = new Activity(root);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    var editorOpened = OfficeSessionJournal.class.getDeclaredMethod("editorOpened", String.class, Object.class, boolean.class);
    editorOpened.setAccessible(true);
    try {
      for (String format : List.of("docx", "pptx")) {
        File source = new File(root, "source." + format);
        office(source, format, "original " + format);
        String sourceHash = hash(source);
        for (String outcome : List.of("saved", "cancelled", "failed")) {
          Completion completion = new Completion();
          int launch = activity.launches + 1;
          bridge.preview(source.getPath(), ID, completion);
          waitLaunch(activity, launch);
          File working = new File(activity.lastIntent.getStringExtra("piv.workingPath"));
          File output = new File(working.getParentFile(), "preview.pdf");
          Intent result = new Intent().putExtra("sessionId", ID);
          if (outcome.equals("saved")) {
            pdf(output, format);
            result.putExtra("pdfPath", output.getPath()).putExtra("pdfSha256", hash(output))
                .putExtra("sourceSha256", sourceHash).putExtra("pdfPageCount", 1)
                .putExtra("piv.previewPdfReady", true);
          } else if (outcome.equals("cancelled")) {
            result.putExtra("piv.previewCancelled", true);
          } else {
            result.putExtra("errorCode", "office_preview_load_failed");
          }

          Object editor = new Object();
          require(Boolean.TRUE.equals(editorOpened.invoke(null, ID, editor, true)), "preview child owns the session");
          try {
            bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT,
                outcome.equals("saved") ? Activity.RESULT_OK : Activity.RESULT_CANCELED, result);
            require(completion.done.await(2, TimeUnit.SECONDS),
                format + " " + outcome + " must reach Flutter before native release");
            if (outcome.equals("saved")) {
              require(completion.code == null && "previewed".equals(completion.result.get("status"))
                  && output.getPath().equals(completion.result.get("pdfPath")), "the Activity returns its validated PDF");
              Completion released = new Completion();
              bridge.releasePreview(ID, released);
              require(released.done.await(2, TimeUnit.SECONDS), "Flutter can relinquish the PDF without waiting for close");
              require(output.isFile(), "the native session may still own the output after Dart releases it");
            } else if (outcome.equals("cancelled")) {
              require(completion.code == null && "cancelled".equals(completion.result.get("status")), "explicit cancellation is returned");
            } else {
              require("office_preview_load_failed".equals(completion.code), "the native load error is preserved");
            }
            require(working.isFile(), "the open Activity retains its working input");
            Completion busy = new Completion();
            bridge.preview(source.getPath(), OTHER, busy);
            busy.await();
            require("office_busy".equals(busy.code) && activity.launches == launch,
                "the previous Activity still owns the native engine");
          } finally {
            OfficeSessionJournal.releaseEditor(editor);
          }

          long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
          while (working.getParentFile().exists() && System.nanoTime() < deadline) Thread.sleep(5);
          require(!working.getParentFile().exists() && sourceHash.equals(hash(source)),
              "native release reclaims the private preview directory and preserves the original");
        }
      }
    } finally { bridge.dispose(); }
    System.out.println("preview Activity release ordering scenarios passed");
  }
  static void previewReadyDuringQuarantineScenario(File root, String outcome) throws Exception {
    Files.createDirectories(root.toPath());
    File source = new File(root, "slides.pptx");
    office(source, "pptx", "presentation with a complete export");
    String original = hash(source);
    Activity activity = new Activity(root);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    try {
      Completion preview = new Completion();
      bridge.preview(source.getPath(), ID, preview);
      waitLaunch(activity, 1);
      File working = new File(activity.lastIntent.getStringExtra("piv.workingPath"));
      File output = new File(working.getParentFile(), "preview.pdf");
      pdf(output, "complete slides");
      Object editor = new Object();
      var editorOpened = OfficeSessionJournal.class.getDeclaredMethod("editorOpened", String.class, Object.class, boolean.class);
      editorOpened.setAccessible(true);
      require(Boolean.TRUE.equals(editorOpened.invoke(null, ID, editor, true)), "preview Activity owns the native session");
      OfficeEngineHealth.quarantine();
      try {
        Intent result = new Intent().putExtra("sessionId", ID);
        if (outcome.equals("cancelled")) {
          result.putExtra("piv.previewCancelled", true);
        } else {
          String sourceHash = outcome.equals("wrong-source") ? hash(output) : original;
          String pdfHash = outcome.equals("wrong-pdf") ? original : hash(output);
          result.putExtra("piv.previewPdfReady", true)
              .putExtra("pdfPath", output.getPath()).putExtra("pdfSha256", pdfHash)
              .putExtra("sourceSha256", sourceHash).putExtra("pdfPageCount", 1);
        }
        bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT,
            outcome.equals("cancelled") ? Activity.RESULT_CANCELED : Activity.RESULT_OK, result);
        preview.await();
        if (outcome.equals("saved")) {
          require(preview.code == null && "previewed".equals(preview.result.get("status")),
              "a verified PDF must be delivered even if only engine teardown stalled");
        } else if (outcome.equals("cancelled")) {
          require(preview.code == null && "cancelled".equals(preview.result.get("status")),
              "explicit cancellation returns to the workspace without publishing a PDF");
        } else {
          require("invalid_office_preview".equals(preview.code) && preview.result == null,
              "stalled teardown does not bypass source or PDF validation");
        }
        require(original.equals(hash(working)) && original.equals(hash(source)), "working and vault originals stay readable");
        Completion release = new Completion();
        bridge.releasePreview(ID, release); release.await();
        require(output.isFile() && working.isFile(), "a stalled native session retains its private files");
        Completion later = new Completion();
        bridge.preview(source.getPath(), OTHER, later); later.await();
        require(OfficeEngineHealth.ERROR_CODE.equals(later.code) && activity.launches == 1,
            "only further native Office requests require a restart");
      } finally { OfficeSessionJournal.releaseEditor(editor); }
    } finally { bridge.dispose(); }
    System.out.println("completed PDF before native close scenarios passed");
  }
  static void previewCloseScenario(File root) throws Exception {
    Files.createDirectories(root.toPath());
    File source = new File(root,"slides.pptx");
    office(source,"pptx","preview close");
    String original = hash(source);
    Activity activity = new Activity(root);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    try {
      for (Intent result : Arrays.asList(null, new Intent().putExtra("sessionId", ID))) {
        Completion interrupted = new Completion();
        int launch = activity.launches + 1;
        bridge.preview(source.getPath(),ID,interrupted); waitLaunch(activity, launch);
        bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED, result);
        interrupted.await();
        require("office_preview_interrupted".equals(interrupted.code) && interrupted.result==null,
            "an unrequested close must report a failure instead of silent cancellation");
      }
      Completion cancelled = new Completion();
      bridge.preview(source.getPath(),ID,cancelled); waitLaunch(activity,3);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED,
          new Intent().putExtra("sessionId", ID).putExtra("piv.previewCancelled", true));
      cancelled.await();
      require(cancelled.code==null && "cancelled".equals(cancelled.result.get("status")),
          "a user cancellation must not report an error");
      require(original.equals(hash(source)), "both exits preserve the original file");
    } finally { bridge.dispose(); }
    System.out.println("preview close result scenarios passed");
  }
  public static void main(String[] args) throws Exception {
    File root = new File(args[1]);
    if (args[0].equals("seed")) {
      Fixture f=fixture(root,"process");
      f.saved();
      Files.writeString(new File(root,"process-input-sha256").toPath(),f.inputHash);
      Files.delete(f.input.toPath());
      System.out.println("native fresh-process seed scenarios passed");
    } else if (args[0].equals("recover")) {
      String inputHash=Files.readString(new File(root,"process-input-sha256").toPath());
      OfficeSessionJournal journal=new OfficeSessionJournal(new File(root,"process/office-sessions"),VERSION);
      Map<String,Object> result=journal.recover(ID,inputHash);
      binding(result,"saved",inputHash);
      require(hash(new File((String)result.get("sourcePath"))).equals(result.get("sourceSha256")),"fresh JVM verifies saved source");
      require(hash(new File((String)result.get("pdfPath"))).equals(result.get("pdfSha256")),"fresh JVM verifies saved PDF");
      System.out.println("native fresh-process recovery scenarios passed");
    } else if (args[0].startsWith("container-")) containerScenario(root,args[0].substring("container-".length()));
    else if (args[0].equals("journal")) journalScenarios(root);
    else if (args[0].equals("legacy-format")) legacyFormatScenarios(root);
    else if (args[0].equals("preview-timeout")) previewTimeoutScenario(root);
    else if (args[0].equals("preview-close")) previewCloseScenario(root);
    else if (args[0].equals("preview-activity-release")) previewActivityReleaseScenario(root);
    else if (args[0].startsWith("preview-quarantined-"))
      previewReadyDuringQuarantineScenario(root, args[0].substring("preview-quarantined-".length()));
    else if (args[0].equals("legacy-source-ready")) legacySourceReadyScenarios(root);
    else if (args[0].equals("legacy-preview-promotion")) previewPromotionScenarios(root,List.of("doc","ppt"));
    else if (args[0].equals("modern-preview-promotion")) previewPromotionScenarios(root,List.of("docx","pptx","odt","odp"));
    else if (args[0].equals("historical-recovery")) historicalRecoveryScenarios(root);
    else if (args[0].equals("legacy-conversion")) legacyConversionScenarios(root);
    else bridgeScenarios(root);
  }
}
'''

STUBS = {
    "android/app/Activity.java": r'''package android.app;
import android.content.Intent;
import android.content.res.AssetManager;
import java.io.File;
public class Activity {
  public static final int RESULT_OK=-1, RESULT_CANCELED=0;
  final File files;
  public volatile int launches;
  public volatile Intent lastIntent;
  public Activity(File files) { this.files=files; }
  public File getFilesDir() { return files; }
  public File getCacheDir() { return new File(files,"cache"); }
  public AssetManager getAssets() { return new AssetManager(); }
  public boolean isFinishing() { return false; }
  public boolean isDestroyed() { return false; }
  public ClassLoader getClassLoader() { return getClass().getClassLoader(); }
  public void runOnUiThread(Runnable action) { action.run(); }
  public void startActivityForResult(Intent intent,int request) { lastIntent=intent; launches++; }
}''',
    "android/content/Intent.java": r'''package android.content;
import java.util.*;
public class Intent {
  public static final String ACTION_VIEW="view", ACTION_EDIT="edit";
  final Map<String,Object> values=new HashMap<>();
  public Intent() {}
  public Intent(android.app.Activity ignored,Class<?> target) {}
  public Intent setAction(String action) { return this; }
  public Intent putExtra(String key,String value) { values.put(key,value); return this; }
  public Intent putExtra(String key,int value) { values.put(key,value); return this; }
  public Intent putExtra(String key,boolean value) { values.put(key,value); return this; }
  public String getStringExtra(String key) { return (String)values.get(key); }
  public int getIntExtra(String key,int fallback) { return values.containsKey(key)?(Integer)values.get(key):fallback; }
  public boolean getBooleanExtra(String key,boolean fallback) { return values.containsKey(key)?(Boolean)values.get(key):fallback; }
  public boolean hasExtra(String key) { return values.containsKey(key); }
}''',
    "android/content/res/AssetManager.java": r'''package android.content.res;
public class AssetManager {
  public java.io.InputStream open(String name) throws java.io.IOException {
    return new java.io.ByteArrayInputStream(new byte[]{1});
  }
}''',
    "android/os/Build.java": r'''package android.os;
public class Build {
  public static final String[] SUPPORTED_ABIS={"arm64-v8a"};
  public static class VERSION { public static final int SDK_INT=26; }
}''',
    "android/util/Log.java": r'''package android.util;
public final class Log {
  public static int i(String tag,String message) { return 0; }
  public static int w(String tag,String message) { return 0; }
}''',
    "io/github/canele452/personalinkvault/office/OfficeEditorActivity.java": r'''package io.github.canele452.personalinkvault.office;
public class OfficeEditorActivity {
  public static volatile boolean live;
  public static boolean hasLiveEditor() { return live; }
}''',
}

CLASSIFIER_DOUBLE = r'''private static int classifyNative(byte[] path) {
        byte[] bytes;
        try {
            bytes = java.nio.file.Files.readAllBytes(java.nio.file.Path.of(new String(path, StandardCharsets.UTF_8)));
        } catch (IOException error) {
            return 0;
        }
        byte[] signature = {(byte)0xd0,(byte)0xcf,0x11,(byte)0xe0,(byte)0xa1,(byte)0xb1,0x1a,(byte)0xe1};
        if (bytes.length <= signature.length) return 0;
        for (int i=0; i<signature.length; i++) if (bytes[i]!=signature[i]) return 0;
        return bytes[signature.length];
    }'''


class SessionJournalTests(unittest.TestCase):
    def run_harness(self, mode, phases=None):
        journal = JAVA / "OfficeSessionJournal.java"
        self.assertTrue(journal.is_file(), "OfficeSessionJournal must persist native session bindings and verified saved results")
        java_home = os.environ.get("JAVA_HOME")
        suffix = ".exe" if os.name == "nt" else ""
        javac = str(Path(java_home) / f"bin/javac{suffix}") if java_home else shutil.which("javac")
        java = str(Path(java_home) / f"bin/java{suffix}") if java_home else shutil.which("java")
        self.assertTrue(javac and java, "A JDK is required for the host bridge tests")
        jni_dir = os.environ.get("PIV_OFFICE_TEST_JNI_DIR")
        fixtures = os.environ.get("PIV_OFFICE_TEST_LEGACY_FIXTURES")
        self.assertEqual(bool(jni_dir), bool(fixtures), "provide both the JNI and fixture directories")
        classifier = JAVA / "OfficeLegacyContainer.java"
        java_args = []
        with tempfile.TemporaryDirectory(prefix="office-recovery-") as folder:
            root = Path(folder)
            harness = root / "RecoveryHarness.java"
            harness.write_text(HARNESS, encoding="utf-8")
            if jni_dir:
                self.assertTrue(Path(jni_dir).is_dir())
                self.assertTrue(all((Path(fixtures) / name).is_file() for name in ("valid.doc", "valid.ppt")))
                java_args = [f"-Djava.library.path={jni_dir}", f"-Dpiv.test.legacy-fixtures={fixtures}"]
            else:
                source = classifier.read_text(encoding="utf-8")
                declaration = "private static native int classifyNative(byte[] path);"
                load = 'static { System.loadLibrary("ink_hwp_native"); }'
                self.assertIn(declaration, source)
                self.assertIn(load, source)
                classifier = root / classifier.name
                classifier.write_text(source.replace(declaration, CLASSIFIER_DOUBLE).replace(load, ""), encoding="utf-8")
            stub_files = []
            for name, content in STUBS.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
                stub_files.append(str(path))
            command = [javac, "-encoding", "UTF-8", "-d", folder, str(harness), str(journal), str(classifier), str(JAVA / "OfficeEngineBridge.java"), str(JAVA / "OfficeEngineHealth.java"), str(JAVA / "OfficePreviewOutputs.java"), str(JAVA / "OfficeNativeObservation.java"), *stub_files]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            for phase in (phases or (["seed", "recover", "journal"] if mode == "journal" else [mode])):
                with self.subTest(phase=phase):
                    try:
                        result = subprocess.run([java, *java_args, "-cp", folder, "RecoveryHarness", phase, str(root / "files")], capture_output=True, text=True, timeout=20)
                    except subprocess.TimeoutExpired as error:
                        self.fail(f"Office bridge harness timed out in {phase}\nstdout: {error.stdout!r}\nstderr: {error.stderr!r}")
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    print(result.stdout.strip())
                    self.assertIn("scenarios passed", result.stdout)

    def test_real_files_survive_restart_and_reject_corrupt_or_foreign_recovery(self):
        self.run_harness("journal")

    def test_actual_bridge_recover_resume_cancel_and_live_busy_contract(self):
        self.run_harness("bridge")

    def test_legacy_family_mismatch_is_blocked_before_launch_or_publication(self):
        self.run_harness("legacy-format")

    def test_timed_out_preview_retains_its_private_working_copy(self):
        self.run_harness("preview-timeout")

    def test_unrequested_preview_close_reports_failure_but_user_cancel_does_not(self):
        self.run_harness("preview-close")

    def test_preview_result_returns_before_native_release_and_cleanup_waits(self):
        self.run_harness("preview-activity-release")

    def test_completed_pdf_survives_a_stalled_native_close(self):
        self.run_harness("preview-quarantine", phases=[
            "preview-quarantined-saved",
            "preview-quarantined-cancelled",
            "preview-quarantined-wrong-source",
            "preview-quarantined-wrong-pdf",
        ])

    def test_legacy_serialized_source_can_resume_without_accepting_an_orphan_pdf(self):
        self.run_harness("legacy-source-ready")

    def test_legacy_preview_promotion_uses_exact_reopened_outputs_and_is_retryable(self):
        self.run_harness("legacy-preview-promotion")

    def test_modern_preview_promotion_uses_exact_reopened_outputs_and_is_retryable(self):
        self.run_harness("modern-preview-promotion")

    def test_historical_legacy_recovery_checks_path_and_receipt_hash_without_launch(self):
        self.run_harness("historical-recovery")

    def test_legacy_conversion_binds_cache_source_and_waits_for_exact_child_close(self):
        self.run_harness("legacy-conversion")

    def test_saved_marker_requires_verified_office_container(self):
        self.run_harness("container", phases=[
            "container-valid",
            "container-doc-invalid-ole",
            "container-ppt-invalid-ole",
            "container-doc-truncated-ole",
            "container-docx-missing-types",
            "container-docx-missing-body",
            "container-pptx-missing-types",
            "container-pptx-missing-body",
            "container-docx-empty-types",
            "container-docx-empty-body",
            "container-odt-missing-mimetype",
            "container-odt-missing-content",
            "container-odp-missing-mimetype",
            "container-odp-missing-content",
            "container-odt-empty-mimetype",
            "container-odt-wrong-mimetype",
            "container-odp-wrong-mimetype",
            "container-docx-duplicate-body",
            "container-docx-unsafe-name",
            "container-docx-crc-body",
            "container-docx-crc-extra",
            "container-docx-expanded",
            "container-docx-forged-size",
        ])

    def test_saved_marker_rejects_unix_symlink_entries(self):
        self.run_harness("container", phases=[
            "container-docx-symlink-body",
            "container-docx-symlink-extra",
        ])

    def test_saved_marker_rejects_decoy_central_directory(self):
        self.run_harness("container", phases=["container-docx-decoy-central"])

    def test_source_checkpoint_precedes_activity_success_result(self):
        source = (JAVA / "OfficeEditorActivity.java").read_text(encoding="utf-8")
        body = method(source, "protected boolean beforeEmbeddedDocumentClose()")
        checkpoint = body.index("recordSourceReady(")
        export = body.index("saveOriginal(")
        self.assertLess(export, checkpoint)
        self.assertNotIn("setResult(Activity.RESULT_OK", body[export:checkpoint])
        success = body.index("setResult(Activity.RESULT_OK", checkpoint)
        self.assertLess(checkpoint, success, "the saved source must be checkpointed before setResult")
        for live_export in ("saveOutputs(", "savePreviewPdf(", "recordSaved("):
            self.assertNotIn(live_export, body)
        self.assertIn("hasLiveEditor()", source, "Activity ownership must outlive a recreated Bridge")

    def test_main_activity_routes_recovery_without_accepting_a_source_path(self):
        source = APP.read_text(encoding="utf-8")
        for name in ("recover", "resume"):
            start = source.index(f'"{name}" ->')
            next_case = source.find("->", start + len(name) + 5)
            branch = source[start:next_case] if next_case >= 0 else source[start:]
            self.assertIn(f"bridge.{name}(", branch)
            self.assertIn('"sessionId"', branch)
            self.assertIn('"inputSourceSha256"', branch)
            self.assertNotIn('"sourcePath"', branch)


if __name__ == "__main__":
    unittest.main()
