"""Exercise owned preview output lifecycle using the actual pure Java helper."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parent
HELPER = MODULE / 'src/main/java/io/github/canele452/personalinkvault/office/OfficePreviewOutputs.java'

HARNESS = r'''
import io.github.canele452.personalinkvault.office.OfficePreviewOutputs;
import java.io.*;
import java.nio.file.*;
import java.util.*;

public final class PreviewOutputsHarness {
  static void require(boolean condition,String message) {
    if (!condition) throw new AssertionError(message);
  }
  interface Checked { void run() throws Exception; }
  static void rejected(Checked action,String message) throws Exception {
    try { action.run(); } catch (IOException expected) { return; }
    throw new AssertionError(message);
  }
  static File write(File directory,String name,String text) throws Exception {
    File file=new File(directory,name);
    Files.writeString(file.toPath(),text);
    return file;
  }
  static void aliasedFilesDirectory(File fixture) throws Exception {
    File files=new File(fixture,"actual-files");
    require(files.mkdir(),"create actual app files directory");
    File alias=new File(fixture,"aliased-files");
    Files.createSymbolicLink(alias.toPath(),files.toPath());
    OfficePreviewOutputs outputs=new OfficePreviewOutputs(new File(alias,"office-previews"));
    File staged=outputs.create("aliased-preview");
    File opened=OfficePreviewOutputs.requireSessionDirectory(alias,staged.getPath(),true);
    require(opened.getParentFile().equals(new File(files,"office-previews").getCanonicalFile()),
        "Activity resolves the private preview root through the alias");
    File pdf=write(opened,"preview.pdf","%PDF preview from the Activity");
    require(outputs.complete("aliased-preview",pdf.getPath()).equals(pdf),
        "bridge accepts the PDF returned from the canonical Activity path");
    outputs.release("aliased-preview");
    require(!opened.exists(),"release removes the accepted preview directory");
    System.out.println("aliased app files directory preview handoff passed");
  }
  public static void main(String[] args) throws Exception {
    File fixture=new File(args[0]);
    File root=new File(fixture,"office-previews");
    File durable=new File(fixture,"office-sessions/durable-edit");
    require(durable.mkdirs(),"create durable fixture");
    File original=write(durable,"working.docx","original retained bytes");
    File saved=write(durable,"preview.pdf","durable retained bytes");
    OfficePreviewOutputs outputs=new OfficePreviewOutputs(root);

    File first=outputs.create("preview-a");
    require(first.getParentFile().equals(root) && first.isDirectory(),"new private direct child");
    require(OfficePreviewOutputs.requireSessionDirectory(fixture,first.getPath(),true).equals(first),"actual preview Activity accepts its separate root");
    require(OfficePreviewOutputs.requireSessionDirectory(fixture,durable.getPath(),false).equals(durable),"durable Activity keeps its existing root");
    rejected(()->OfficePreviewOutputs.requireSessionDirectory(fixture,durable.getPath(),true),"preview Activity rejects durable edit directory");
    rejected(()->OfficePreviewOutputs.requireSessionDirectory(fixture,first.getPath(),false),"durable Activity rejects preview directory");
    require(!first.getName().equals("preview-a"),"caller identity is not a filesystem path");
    write(first,"working.docx","preview copy");
    File pdf=write(first,"preview.pdf","%PDF synthetic output");
    outputs.release("preview-a");
    require(pdf.isFile(),"release cannot remove an active editor's files");
    rejected(()->outputs.create("preview-a"),"duplicate active session rejected");
    rejected(()->outputs.complete("preview-a",saved.getPath()),"foreign result path rejected");
    require(saved.isFile() && pdf.isFile(),"foreign path never confers ownership");
    require(outputs.complete("preview-a",pdf.getPath()).equals(pdf),"complete binds exact owned preview");
    rejected(()->outputs.create("preview-a"),"duplicate ready session rejected before release");
    outputs.release("preview-a");
    outputs.release("preview-a");
    require(!first.exists(),"ready output and working copy removed once");
    outputs.release("durable-edit");
    outputs.discard("unknown");
    require(Files.readString(original.toPath()).equals("original retained bytes"),"durable original retained");
    require(Files.readString(saved.toPath()).equals("durable retained bytes"),"durable PDF retained");

    File cancelled=outputs.create("cancelled");
    write(cancelled,"working.pptx","cancelled copy");
    outputs.discard("cancelled");
    outputs.discard("cancelled");
    require(!cancelled.exists(),"closed cancelled output discarded");

    File nested=outputs.create("nested");
    File nestedPdf=write(nested,"preview.pdf","%PDF retained unsafe tree");
    File subdir=new File(nested,"unexpected-child");
    require(subdir.mkdir(),"nested fixture");
    rejected(()->OfficePreviewOutputs.requireSessionDirectory(fixture,subdir.getPath(),true),"Activity requires immediate root parent");
    outputs.complete("nested",nestedPdf.getPath());
    rejected(()->outputs.release("nested"),"nested tree refused without recursive deletion");
    require(nestedPdf.isFile() && subdir.isDirectory(),"unsafe tree preserved before any file deletion");
    outputs.release("nested");
    require(nestedPdf.isFile(),"failed cleanup is not retried on another release");

    File missing=outputs.create("missing");
    rejected(()->outputs.complete("missing",new File(missing,"preview.pdf").getPath()),"missing result rejected");
    outputs.discard("missing");
    require(!missing.exists(),"missing failed result can discard its own empty directory");

    File linked=outputs.create("linked");
    File link=new File(linked,"preview.pdf");
    boolean linksAvailable=false;
    try {
      Files.createSymbolicLink(link.toPath(),saved.toPath());
      linksAvailable=true;
    } catch (UnsupportedOperationException|FileSystemException|SecurityException unavailable) {
      System.out.println("symbolic-link fixture unavailable: "+unavailable.getClass().getSimpleName());
    }
    if (linksAvailable) {
      rejected(()->outputs.complete("linked",link.getPath()),"symlink PDF cannot be readied");
      rejected(()->outputs.discard("linked"),"symlink child cannot be deleted by preview cleanup");
      require(Files.isSymbolicLink(link.toPath()) && saved.isFile(),"link and foreign target preserved");
      outputs.discard("linked");
      require(Files.isSymbolicLink(link.toPath()),"failed link cleanup is not retried");
      System.out.println("actual symlink complete/discard refusal passed");
      aliasedFilesDirectory(fixture);
    } else outputs.discard("linked");
    rejected(()->outputs.create(""),"empty caller identity rejected");
    require(saved.isFile() && original.isFile(),"all durable source and PDF fixtures survive");
    System.out.println("owned preview active/ready/release/discard/direct-file boundary scenarios passed");
  }
}
'''


def java_tool(name):
    home = os.environ.get('JAVA_HOME')
    candidate = Path(home, 'bin', name + '.exe') if home else None
    found = str(candidate) if candidate and candidate.is_file() else shutil.which(name)
    if not found:
        raise RuntimeError(f'{name} is required for this actual helper test')
    return found


class PreviewOutputTests(unittest.TestCase):
    def test_actual_helper_owns_only_created_ready_preview_files(self):
        self.assertTrue(HELPER.is_file(), 'actual OfficePreviewOutputs product helper is missing')
        with tempfile.TemporaryDirectory(prefix='office-preview-outputs-') as temporary:
            directory = Path(temporary)
            harness = directory / 'PreviewOutputsHarness.java'
            harness.write_text(HARNESS, encoding='utf-8')
            subprocess.run(
                [java_tool('javac'), '-encoding', 'UTF-8', '-d', str(directory), str(HELPER), str(harness)],
                check=True,
            )
            fixture = directory / 'fixture'
            fixture.mkdir()
            subprocess.run(
                [java_tool('java'), '-cp', str(directory), 'PreviewOutputsHarness', str(fixture)],
                check=True,
            )


if __name__ == '__main__':
    unittest.main(verbosity=2)
