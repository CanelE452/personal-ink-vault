"""Test private native-observation files with the actual pure Java helper.

This is a JDK/ownership/UTF8 boundary test, not Android COKit/JNI execution.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parent
HELPER = MODULE / 'src/main/java/io/github/canele452/personalinkvault/office/OfficeNativeObservation.java'

HARNESS = r'''
import io.github.canele452.personalinkvault.office.OfficeNativeObservation;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;

public final class NativeObservationHarness {
  static final String ID="70bf425f-c413-457a-82cc-119c3f6cc8ae";
  static final String HASH="a".repeat(64), VERSION="26.04.6.0-962";
  interface Checked { void run() throws Exception; }
  static void require(boolean condition,String message) {
    if (!condition) throw new AssertionError(message);
  }
  static void rejected(Checked action,String message) throws Exception {
    try { action.run(); } catch (IOException expected) { return; }
    throw new AssertionError(message);
  }
  static File dir(File root,String name) throws IOException {
    return Files.createDirectory(new File(root,name).toPath()).toFile();
  }
  static Map<String,Object> write(File directory,byte[] bytes) throws IOException {
    return OfficeNativeObservation.write(directory,ID,HASH,"pptx",VERSION,2,bytes);
  }
  static Map<String,Object> read(File directory) throws IOException {
    return OfficeNativeObservation.read(directory,ID,HASH,"pptx",VERSION);
  }
  static void metadata(File directory,String key,String value) throws Exception {
    File marker=new File(directory,"native-observation.properties");
    Properties p=new Properties();
    try(InputStream in=new FileInputStream(marker)) {p.load(in);}
    p.setProperty(key,value);
    try(OutputStream out=new FileOutputStream(marker)) {p.store(out,null);}
  }
  static byte[] nativeJson() {
    return "{\"slides\":[{\"name\":\"한글 😀\"}],\"sourceTableEditingSupported\":true}".getBytes(StandardCharsets.UTF_8);
  }
  public static void main(String[] args) throws Exception {
    File root=new File(args[0]);
    File directory=dir(root,"owned");
    byte[] original=nativeJson();
    byte[] input=original.clone();
    Map<String,Object> result=write(directory,input);
    Arrays.fill(input,(byte)0);
    File payload=new File(directory,"native-observation.json");
    require(payload.isFile() && Arrays.equals(original,Files.readAllBytes(payload.toPath())),"copies original UTF8 bytes before callers can mutate them");
    require(result.get("sourceSha256").equals(HASH) && result.get("sessionId").equals(ID),"same input/session binding");
    require(result.get("format").equals("pptx") && result.get("engineVersion").equals(VERSION),"same format and engine binding");
    require(result.get("partCount").equals(2),"actual part count retained");
    require(result.get("observationByteLength").equals(original.length),"byte count is UTF8, not UTF16");
    require(result.get("nativeJson").equals(new String(original,StandardCharsets.UTF_8)),"Unicode including emoji is exact");
    require(!result.containsKey("sourceTableEditingSupported") && !result.containsKey("cellTextEditingSupported"),"raw native JSON never grants edit authority");
    require(read(directory).equals(result),"reopening checks exact private payload and marker");
    rejected(()->write(directory,original),"second write must not overwrite prior observation");
    require(Arrays.equals(original,Files.readAllBytes(payload.toPath())),"duplicate write leaves old bytes exact");
    rejected(()->OfficeNativeObservation.read(directory,ID,"b".repeat(64),"pptx",VERSION),"other source rejected");
    rejected(()->OfficeNativeObservation.read(directory,"4cc6fb56-5965-4613-8a01-6a074d30120d",HASH,"pptx",VERSION),"other session rejected");
    rejected(()->OfficeNativeObservation.read(directory,ID,HASH,"odp",VERSION),"other format rejected");
    rejected(()->OfficeNativeObservation.read(directory,ID,HASH,"pptx","other-engine"),"other engine rejected");

    File invalidUtf8=dir(root,"invalid-utf8");
    rejected(()->write(invalidUtf8,new byte[]{(byte)0xc0,(byte)0xaf}),"overlong invalid UTF8 rejected");
    require(invalidUtf8.list().length==0,"invalid UTF8 creates no output");
    File large=dir(root,"large");
    rejected(()->write(large,new byte[128*1024+1]),"raw byte budget is enforced");
    require(large.list().length==0,"oversized result creates no output");
    File empty=dir(root,"empty");
    rejected(()->write(empty,new byte[0]),"empty result rejected");
    rejected(()->OfficeNativeObservation.write(empty,ID,HASH,"pptx",VERSION,0,original),"zero native parts rejected");
    rejected(()->OfficeNativeObservation.write(empty,ID,HASH,"pptx",VERSION,257,original),"too many native parts rejected");
    rejected(()->OfficeNativeObservation.write(empty,ID,HASH,"docx",VERSION,2,original),"non presentation format rejected");
    require(empty.list().length==0,"preflight rejections preserve the empty owned directory");

    File preexisting=dir(root,"preexisting");
    File foreign=new File(preexisting,"native-observation.json");
    Files.writeString(foreign.toPath(),"foreign retained bytes");
    rejected(()->write(preexisting,original),"preexisting payload is never overwritten");
    require(Files.readString(foreign.toPath()).equals("foreign retained bytes"),"foreign file preserved");
    File preexistingMarker=dir(root,"preexisting-marker");
    File foreignMarker=new File(preexistingMarker,"native-observation.properties");
    Files.writeString(foreignMarker.toPath(),"foreign=retained");
    rejected(()->write(preexistingMarker,original),"preexisting marker is never overwritten");
    require(Files.readString(foreignMarker.toPath()).equals("foreign=retained"),"foreign marker preserved");

    File changed=dir(root,"changed");
    write(changed,original);
    Files.writeString(new File(changed,"native-observation.json").toPath(),"changed payload");
    rejected(()->read(changed),"changed payload fails digest/byte count");
    for(String key:List.of("sessionId","inputSourceSha256","format","engineVersion","partCount","byteLength","sha256","version")) {
      File altered=dir(root,"marker-"+key);
      write(altered,original);
      metadata(altered,key,"invalid");
      rejected(()->read(altered),"tampered marker rejected: "+key);
    }
    File extra=dir(root,"extra-marker");
    write(extra,original);
    metadata(extra,"foreignCapability","true");
    rejected(()->read(extra),"unknown marker fields cannot become trusted");
    File linked=dir(root,"linked");
    File link=new File(linked,"native-observation.json");
    boolean symlinks=false;
    try {Files.createSymbolicLink(link.toPath(),payload.toPath());symlinks=true;}
    catch(UnsupportedOperationException|FileSystemException|SecurityException unavailable) {
      System.out.println("symlink fixture unavailable: "+unavailable.getClass().getSimpleName());
    }
    if(symlinks) {
      rejected(()->write(linked,original),"symlink payload never overwritten");
      require(Arrays.equals(original,Files.readAllBytes(payload.toPath())),"foreign link target preserved");
    }
    System.out.println("native observation UTF8, immutable input, binding, limits, tamper and foreign-output boundaries passed");
  }
}
'''

def java_tool(name):
    home = os.environ.get('JAVA_HOME')
    candidate = Path(home, 'bin', name + '.exe') if home else None
    result = str(candidate) if candidate and candidate.is_file() else shutil.which(name)
    if not result:
        raise RuntimeError(f'{name} is required for this actual helper test')
    return result


class NativeObservationTests(unittest.TestCase):
    def test_actual_helper_binds_only_owned_read_only_native_bytes(self):
        self.assertTrue(HELPER.is_file(), 'actual OfficeNativeObservation helper is missing')
        with tempfile.TemporaryDirectory(prefix='office-native-observation-') as temporary:
            directory = Path(temporary)
            harness = directory / 'NativeObservationHarness.java'
            harness.write_text(HARNESS, encoding='utf-8')
            subprocess.run(
                [java_tool('javac'), '-encoding', 'UTF-8', '-d', str(directory), str(HELPER), str(harness)],
                check=True,
            )
            fixture = directory / 'fixture'
            fixture.mkdir()
            subprocess.run(
                [java_tool('java'), '-cp', str(directory), 'NativeObservationHarness', str(fixture)],
                check=True,
            )


if __name__ == '__main__':
    unittest.main(verbosity=2)
