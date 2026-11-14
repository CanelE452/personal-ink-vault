"""HOST ONLY: strict Java validation of the Rust text-style-map reply."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_cell_reply import JAVA, JSON_JAR, JSON_SHA256
import hashlib

CODEC = JAVA / 'OfficeTextStylePlan.java'

HARNESS = r'''
import io.github.canele452.personalinkvault.office.OfficeTextStylePlan;
import org.json.*;
import java.io.*;import java.nio.charset.StandardCharsets;import java.security.MessageDigest;import java.util.*;
public final class TextStylePlanHarness {
 static int checks; interface Checked{void run()throws Exception;}
 static void require(boolean b,String m){checks++;if(!b)throw new AssertionError(m);}
 static void reject(Checked a,String m)throws Exception{checks++;try{a.run();}catch(IOException e){return;}throw new AssertionError(m);}
 static String hash(String s)throws Exception{StringBuilder r=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8)))r.append(String.format(Locale.ROOT,"%02x",b&255));return r.toString();}
 static JSONObject seg(String k,int ns,int ne,int os,int oe){return new JSONObject().put("kind",k).put("newStart",ns).put("newEnd",ne).put("oldStart",os).put("oldEnd",oe);}
 static JSONObject para(int source,JSONObject... ss){JSONArray a=new JSONArray();for(JSONObject s:ss)a.put(s);return new JSONObject().put("sourceParagraph",source).put("segments",a);}
 static JSONObject plan(String old,String text,JSONObject... ps)throws Exception{JSONArray a=new JSONArray();for(JSONObject p:ps)a.put(p);return new JSONObject().put("protocol","piv-text-style-map-1").put("oldUtf16Length",old.length()).put("newUtf16Length",text.length()).put("oldSha256",hash(old)).put("newSha256",hash(text)).put("paragraphs",a);}
 static byte[] bytes(JSONObject p){return p.toString().getBytes(StandardCharsets.UTF_8);}
 static JSONObject copy(JSONObject p){return new JSONObject(p.toString());}
 static void decode(JSONObject p,String o,String n)throws Exception{OfficeTextStylePlan.decode(bytes(p),o,n);}
 static void good()throws Exception{
  String old="한😀e\u0301\n끝",text="한😀Xe\u0301\n끝";
  JSONObject p=plan(old,text,para(0,seg("retain",0,3,0,3),seg("inherit",3,4,3,5),seg("retain",4,6,3,5)),para(1,seg("retain",0,1,0,1)));
  require(OfficeTextStylePlan.decode(bytes(p),old,text).similar(p),"valid UTF16 mapping survives exact strings, hashes and ranges");
  decode(plan("","",para(0,seg("inherit",0,0,0,0))),"","");
  decode(plan("abc","\n",para(0,seg("inherit",0,0,0,1)),para(0,seg("inherit",0,0,0,1))),"abc","\n");
  decode(plan("x\ny","y",para(1,seg("retain",0,1,0,1))),"x\ny","y");
  String large="a".repeat(200000),newMax="z".repeat(8192);
  decode(plan(large,newMax,para(0,seg("inherit",0,8192,0,1))),large,newMax);
  String lines="\n".repeat(511);JSONObject[] ps=new JSONObject[512];for(int i=0;i<512;i++)ps[i]=para(i,seg("inherit",0,0,0,0));decode(plan(lines,lines,ps),lines,lines);
 }
 static void schemas()throws Exception{
  JSONObject p=plan("abc","abc",para(0,seg("retain",0,3,0,3)));
  for(Object[] c:new Object[][]{{"protocol","bad"},{"oldUtf16Length","3"},{"newUtf16Length",3.5},{"oldUtf16Length",2147483648L},{"oldSha256","A".repeat(64)},{"newSha256","0".repeat(64)},{"paragraphs",new JSONObject()},{"extra",true}}){JSONObject q=copy(p).put((String)c[0],c[1]);reject(()->decode(q,"abc","abc"),"closed strongly typed schema: "+c[0]);}
  for(String missing:new String[]{"protocol","oldUtf16Length","newUtf16Length","oldSha256","newSha256","paragraphs"}){JSONObject q=copy(p);q.remove(missing);reject(()->decode(q,"abc","abc"),"missing field "+missing);}
  for(Object[] c:new Object[][]{{"sourceParagraph",-1},{"sourceParagraph",1},{"sourceParagraph","0"},{"segments",new JSONArray()},{"extra",1}}){JSONObject q=copy(p);q.getJSONArray("paragraphs").getJSONObject(0).put((String)c[0],c[1]);reject(()->decode(q,"abc","abc"),"paragraph bounds and closed schema");}
  for(Object[] c:new Object[][]{{"kind","copy"},{"newStart",-1},{"newEnd",4},{"newStart",1},{"oldEnd",2},{"oldStart",1},{"oldEnd",4},{"oldStart",0.5},{"oldStart","0"},{"extra",1}}){JSONObject q=copy(p);q.getJSONArray("paragraphs").getJSONObject(0).getJSONArray("segments").getJSONObject(0).put((String)c[0],c[1]);reject(()->decode(q,"abc","abc"),"range and segment schema");}
  reject(()->decode(plan("abc","abc",para(0,seg("retain",0,2,0,2))),"abc","abc"),"coverage cannot stop early");
  reject(()->decode(plan("abc","abc",para(0,seg("retain",0,2,0,2),seg("retain",1,3,1,3))),"abc","abc"),"overlap rejected");
  reject(()->decode(plan("abc","abd",para(0,seg("retain",0,3,0,3))),"abc","abd"),"retained strings must be equal");
  reject(()->decode(plan("a","",para(0,seg("retain",0,0,0,0))),"a",""),"empty target requires inherit anchor");
  reject(()->decode(plan("a","",para(0,seg("inherit",0,0,0,0))),"a",""),"zero source anchor only belongs to empty source");
  reject(()->decode(plan("","a",para(0,seg("retain",0,1,0,0))),"","a"),"empty source cannot retain new text");
  reject(()->decode(plan("a","a",para(0,seg("inherit",0,0,0,1),seg("retain",0,1,0,1))),"a","a"),"nonempty target forbids zero length segment");
  reject(()->decode(plan("a","a",para(0,seg("retain",0,1,0,1)),para(0,seg("retain",0,1,0,1))),"a","a"),"paragraph count is exact");
 }
 static void unicodeAndBounds()throws Exception{
  reject(()->decode(plan("😀","😀",para(0,seg("retain",0,1,0,1),seg("retain",1,2,1,2))),"😀","😀"),"surrogate scalar cannot be split");
  reject(()->decode(plan("😀","a",para(0,seg("inherit",0,1,0,1))),"😀","a"),"inherit source boundaries cannot split scalar");
  reject(()->decode(plan("a","😀",para(0,seg("inherit",0,1,0,1),seg("inherit",1,2,0,1))),"a","😀"),"new boundaries cannot split scalar");
  JSONObject p=plan("a","a",para(0,seg("retain",0,1,0,1)));
  reject(()->OfficeTextStylePlan.decode(bytes(p),"b","a"),"old hash binds full original");
  reject(()->OfficeTextStylePlan.decode(bytes(p),"a","b"),"new hash binds full draft");
  reject(()->OfficeTextStylePlan.decode(bytes(p),"\ud800","a"),"unpaired original rejected");
  reject(()->OfficeTextStylePlan.decode(bytes(p),"a","\udc00"),"unpaired target rejected");
  reject(()->OfficeTextStylePlan.decode(null,"a","a"),"null native result rejected");
  reject(()->OfficeTextStylePlan.decode(new byte[1024*1024+1],"a","a"),"raw reply budget before parse");
  reject(()->OfficeTextStylePlan.decode(new byte[]{(byte)0xc0,(byte)0x80},"a","a"),"invalid UTF8 never replacement decoded");
  reject(()->decode(p,"a".repeat(200001),"a"),"old UTF16 bound");
  reject(()->decode(p,"a","a".repeat(8193)),"new UTF16 bound");
  reject(()->decode(p,"\n".repeat(512),"a"),"old paragraph bound");
  reject(()->decode(p,"a","\n".repeat(512)),"new paragraph bound");
  String raw=p.toString();for(String bad:new String[]{raw+" x",raw.substring(0,raw.length()-1)+",\"protocol\":\"piv-text-style-map-1\"}",raw.replace("\"oldUtf16Length\":1","\"oldUtf16Length\":01"),"{'protocol':'piv-text-style-map-1'}","{x:1}","[".repeat(33)+"0"+"]".repeat(33)})reject(()->OfficeTextStylePlan.decode(bad.getBytes(StandardCharsets.UTF_8),"a","a"),"strict JSON lexer before permissive Android parser");
 }
 public static void main(String[] args)throws Exception{good();schemas();unicodeAndBounds();System.out.println("HOST ONLY: "+checks+" style-plan validation checks passed; no JNI/UNO runtime proof.");}
}
'''


class TextStylePlanTests(unittest.TestCase):
    def test_actual_java_style_plan_validator(self):
        self.assertTrue(CODEC.is_file(), 'OfficeTextStylePlan strict planner reply codec is missing')
        self.assertTrue(JSON_JAR.is_file())
        self.assertEqual(hashlib.sha256(JSON_JAR.read_bytes()).hexdigest(), JSON_SHA256)
        suffix = '.exe' if os.name == 'nt' else ''
        java_home = os.environ.get('JAVA_HOME')
        javac = str(Path(java_home) / f'bin/javac{suffix}') if java_home else shutil.which('javac')
        java = str(Path(java_home) / f'bin/java{suffix}') if java_home else shutil.which('java')
        self.assertTrue(javac and java)
        with tempfile.TemporaryDirectory(prefix='office-style-plan-') as folder:
            harness = Path(folder) / 'TextStylePlanHarness.java'
            harness.write_text(HARNESS, encoding='utf-8')
            result = subprocess.run([javac, '-encoding', 'UTF-8', '-cp', str(JSON_JAR), '-d', folder,
                str(harness), str(CODEC), str(JAVA/'OfficeCellReply.java'), str(JAVA/'OfficeScriptSession.java')],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            result = subprocess.run([java, '-cp', folder+os.pathsep+str(JSON_JAR), 'TextStylePlanHarness'],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main(verbosity=2)
