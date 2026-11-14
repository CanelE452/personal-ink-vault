"""HOST ONLY: drive the actual native cell controller through small UI stubs.

The stubs schedule callbacks and expose literal Android controls. Request state,
reply validation and controller behavior are production Java, with real org.json.
No Android/UNO API exposure or document mutation is established by this test.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parent
JAVA = MODULE / 'src/main/java/io/github/canele452/personalinkvault/office'
CONTROLLER = JAVA / 'OfficePresentationCells.java'
PROGRAM = MODULE / 'src/main/assets/piv-presentation-cells.js'
JSON_JAR = Path('C:/Users/User/.gradle/caches/modules-2/files-2.1/org.json/json/20180813/8566b2b0391d9d4479ea225645c6ed47ef17fe41/json-20180813.jar')
JSON_SHA256 = '518080049ba83181914419d11a25d9bc9833a2d729b6a6e7469fa52851356da8'

STUBS = {
'android/content/Context.java': r'''package android.content; public class Context {}''',
'android/content/DialogInterface.java': r'''package android.content;
public interface DialogInterface {
 int BUTTON_POSITIVE=-1,BUTTON_NEGATIVE=-2,BUTTON_NEUTRAL=-3;
 interface OnClickListener {void onClick(DialogInterface d,int which);}
 interface OnShowListener {void onShow(DialogInterface d);}
 interface OnKeyListener {boolean onKey(DialogInterface d,int code,android.view.KeyEvent event);}
 void dismiss();
}''',
'android/content/res/AssetManager.java': r'''package android.content.res;
public class AssetManager {public java.io.InputStream open(String name)throws java.io.IOException {
 return new java.io.FileInputStream(System.getProperty("cell.asset"));
}}''',
'android/os/Looper.java': r'''package android.os; public class Looper {public static Looper getMainLooper(){return new Looper();}}''',
'android/os/Handler.java': r'''package android.os; import java.util.*;
public class Handler {
 public static final List<Runnable> delayed=new ArrayList<>(); public Handler(Looper l){}
 public boolean postDelayed(Runnable r,long delay){if(delay!=20000)throw new AssertionError("bounded native timeout"); delayed.add(r);return true;}
 public void removeCallbacks(Runnable r){delayed.remove(r);}
 public static void fire(){for(Runnable r:new ArrayList<>(delayed)){delayed.remove(r);r.run();}}
}''',
'android/net/Uri.java': r'''package android.net; public class Uri {
 private final String s; private Uri(String s){this.s=s;}
 public static Uri fromFile(java.io.File f){return new Uri(f.toURI().toString());}
 public String toString(){return s;}
}''',
'android/view/KeyEvent.java': r'''package android.view; public class KeyEvent {
 public static final int KEYCODE_BACK=4,ACTION_UP=1; public int getAction(){return ACTION_UP;}
}''',
'android/view/Gravity.java': r'''package android.view; public class Gravity {public static final int TOP=48,END=8388613,START=8388611;}''',
'android/view/View.java': r'''package android.view; public class View {
 public static final int VISIBLE=0,GONE=8; public int visibility; public boolean enabled=true;
 public interface OnClickListener {void onClick(View v);} private OnClickListener click;
 public void setOnClickListener(OnClickListener c){click=c;} public boolean performClick(){if(enabled&&click!=null){click.onClick(this);return true;}return false;}
 public void setVisibility(int v){visibility=v;} public void setEnabled(boolean b){enabled=b;}
 public void setPadding(int a,int b,int c,int d){} public void setLayoutParams(ViewGroup.LayoutParams p){}
}''',
'android/view/ViewGroup.java': r'''package android.view; public class ViewGroup extends View {
 public final java.util.List<View> children=new java.util.ArrayList<>();
 public void addView(View v){children.add(v);} public void addView(View v,LayoutParams p){children.add(v);}
 public static class LayoutParams {public static final int MATCH_PARENT=-1,WRAP_CONTENT=-2;public LayoutParams(int w,int h){}}
}''',
'android/widget/TextView.java': r'''package android.widget; public class TextView extends android.view.View {
 public String text=""; public TextView(android.content.Context c){} public void setText(CharSequence s){text=s.toString();}
 public CharSequence getText(){return text;} public void setGravity(int g){} public void setTextIsSelectable(boolean b){}
}''',
'android/widget/Button.java': r'''package android.widget; public class Button extends TextView {public Button(android.content.Context c){super(c);}}''',
'android/widget/EditText.java': r'''package android.widget; public class EditText extends TextView {
 public String error;public EditText(android.content.Context c){super(c);}public void setInputType(int t){}
 public void setMinLines(int n){}public void setError(CharSequence s){error=s.toString();}public void setSelection(int n){}
}''',
'android/widget/ProgressBar.java': r'''package android.widget; public class ProgressBar extends android.view.View {public ProgressBar(android.content.Context c){}}''',
'android/widget/ScrollView.java': r'''package android.widget; public class ScrollView extends android.view.ViewGroup {public ScrollView(android.content.Context c){}}''',
'android/widget/LinearLayout.java': r'''package android.widget; public class LinearLayout extends android.view.ViewGroup {
 public static final int VERTICAL=1; public LinearLayout(android.content.Context c){}public void setOrientation(int i){}
 public static class LayoutParams extends android.view.ViewGroup.LayoutParams {public LayoutParams(int w,int h){super(w,h);}}
}''',
'android/widget/FrameLayout.java': r'''package android.widget; public class FrameLayout extends android.view.ViewGroup {
 public static class LayoutParams extends android.view.ViewGroup.LayoutParams {
 public int gravity,topMargin,rightMargin;public LayoutParams(int w,int h){super(w,h);}public LayoutParams(int w,int h,int g){super(w,h);gravity=g;}}
}''',
'android/text/InputType.java': r'''package android.text;public class InputType {public static final int TYPE_CLASS_TEXT=1,TYPE_TEXT_FLAG_MULTI_LINE=131072;}''',
'android/app/AlertDialog.java': r'''package android.app; import android.content.*;import android.widget.*;import android.view.*;import java.util.*;
public class AlertDialog implements DialogInterface {
 public static final List<AlertDialog> shown=new ArrayList<>(); public String title="",message=""; public View view;
 public String[] items; private OnClickListener itemClick;private OnShowListener onShow;private OnKeyListener key;
 private final Map<Integer,Button> buttons=new HashMap<>();
 public void show(){shown.add(this);if(onShow!=null)onShow.onShow(this);}public void dismiss(){shown.remove(this);}
 public boolean isShowing(){return shown.contains(this);}public void setMessage(CharSequence s){message=s.toString();}
 public void setCancelable(boolean b){}public void setOnShowListener(OnShowListener l){onShow=l;}public void setOnKeyListener(OnKeyListener l){key=l;}
 public Button getButton(int n){return buttons.get(n);}public void choose(int n){dismiss();itemClick.onClick(this,n);}
 public static AlertDialog top(){return shown.get(shown.size()-1);}public static void clear(){shown.clear();}
 public static class Builder {
  private final AlertDialog d=new AlertDialog();private final Context context;
  public Builder(Context c){context=c;}public Builder setTitle(CharSequence s){d.title=s.toString();return this;}
  public Builder setMessage(CharSequence s){d.message=s.toString();return this;}public Builder setView(View v){d.view=v;return this;}
  public Builder setItems(CharSequence[] a,OnClickListener l){d.items=new String[a.length];for(int n=0;n<a.length;n++)d.items[n]=a[n].toString();d.itemClick=l;return this;}
  public Builder setCancelable(boolean b){return this;}
  private Builder button(int n,CharSequence s,OnClickListener l){Button b=new Button(context);b.setText(s);b.setOnClickListener(v->{if(l!=null)l.onClick(d,n);d.dismiss();});d.buttons.put(n,b);return this;}
  public Builder setPositiveButton(CharSequence s,OnClickListener l){return button(BUTTON_POSITIVE,s,l);}
  public Builder setNegativeButton(CharSequence s,OnClickListener l){return button(BUTTON_NEGATIVE,s,l);}
  public Builder setNeutralButton(CharSequence s,OnClickListener l){return button(BUTTON_NEUTRAL,s,l);}
  public AlertDialog create(){return d;}public AlertDialog show(){d.show();return d;}
 }
}''',
'io/github/canele452/personalinkvault/office/OfficeEditorActivity.java': r'''package io.github.canele452.personalinkvault.office;
import java.util.*;import android.view.*;import org.json.*;
public final class OfficeEditorActivity extends android.content.Context {
 public boolean ready=true,finishing,destroyed,accept=true,defer,plannerFails,missingPlanner;public int completes,safeCloses,finishes,planCalls;
 public String plannedOld,plannedNew;public Runnable duringPlan;
 public final List<View> added=new ArrayList<>();public final List<String> scripts=new ArrayList<>(),ids=new ArrayList<>();
 public final List<Runnable> ui=new ArrayList<>();public OfficePresentationCells cells;public JSONObject synchronous;
 boolean isCellEditorReady(){return ready;} boolean postCellScript(String id,String script){
  if(!accept)return false;ids.add(id);scripts.add(script);
  if(synchronous!=null){JSONObject b=synchronous;synchronous=null;cells.onNativeMessage(CellUiHarness.reply(id,b));}return true;
 }
 void completeCellScript(){completes++;}void closeCellEditor(){if(cells.blocksSave())throw new AssertionError("unsafe save close");safeCloses++;}
 JSONObject planCellText(String oldText,String newText)throws java.io.IOException{
  planCalls++;plannedOld=oldText;plannedNew=newText;
  if(!cells.blocksSave())throw new AssertionError("planning must own pending ticket");
  if(!android.os.Handler.delayed.isEmpty())throw new AssertionError("native script timeout starts after planning");
  if(duringPlan!=null)duringPlan.run();
  if(missingPlanner)throw new UnsatisfiedLinkError("missing fixture planner");
  if(plannerFails)throw new java.io.IOException("bounded fixture planner failed");
  JSONObject plan=new JSONObject().put("protocol","piv-text-style-map-1").put("fixture",true);
  return plan;
 }
 public void runOnUiThread(Runnable r){if(defer)ui.add(r);else r.run();}public void drain(){for(Runnable r:new ArrayList<>(ui)){ui.remove(r);r.run();}}
 public void addContentView(View v,ViewGroup.LayoutParams p){added.add(v);}public android.content.res.AssetManager getAssets(){return new android.content.res.AssetManager();}
 public boolean isFinishing(){return finishing;}public boolean isDestroyed(){return destroyed;}public void finish(){finishes++;finishing=true;}
}'''
}

HARNESS = r'''
package io.github.canele452.personalinkvault.office;
import android.app.AlertDialog;import android.content.DialogInterface;import android.os.Handler;
import android.view.*;import android.widget.*;import java.io.*;import java.nio.charset.StandardCharsets;import java.util.*;import org.json.*;
public final class CellUiHarness {
 static final String ID="70bf425f-c413-457a-82cc-119c3f6cc8ae";static int checks;
 static void require(boolean b,String m){checks++;if(!b)throw new AssertionError(m);}
 static OfficeEditorActivity host(String format){OfficeEditorActivity h=new OfficeEditorActivity();h.cells=new OfficePresentationCells(h,ID,new File("working.pptx"),format);return h;}
 static JSONObject request(OfficeEditorActivity h){String s=h.scripts.get(h.scripts.size()-1);int p=s.lastIndexOf("})(");require(p>=0&&s.endsWith(");"),"fixed closed program invoked as expression");return new JSONObject(s.substring(p+3,s.length()-2));}
 static JSONObject table(){return new JSONObject().put("slide",0).put("shape",0).put("pageCount",1).put("shapeCount",1).put("name","표 😀")
  .put("rows",1).put("columns",2).put("x",0).put("y",0).put("width",100).put("height",100).put("cells",new JSONArray()
  .put(new JSONObject().put("row",0).put("column",0).put("text","한글 😀\n전체 원문").put("editable",true))
  .put(new JSONObject().put("row",0).put("column",1).put("text","병합 셀 원문").put("editable",false)));}
 static JSONObject body(OfficeEditorActivity h,boolean success,boolean changed){JSONObject r=request(h);JSONObject b=new JSONObject()
  .put("protocol","piv-cell-1").put("sessionId",ID).put("documentUrl",r.getString("documentUrl")).put("action",r.getString("action"))
  .put("success",success).put("mayHaveMutated",changed);return success?b.put(r.getString("action").equals("read")?"tables":"table",r.getString("action").equals("read")?new JSONArray().put(table()):table()):b.put("code","stale_snapshot");}
 static byte[] reply(String id,JSONObject b){return ("executescriptresult: {\"id\":\""+id+"\",\"ok\":"+b+"}").getBytes(StandardCharsets.UTF_8);}
 static byte[] reply(OfficeEditorActivity h,JSONObject b){return reply(h.ids.get(h.ids.size()-1),b);}
 static void read(OfficeEditorActivity h){h.cells.installButton();((Button)h.added.get(0)).performClick();require(h.cells.blocksSave(),"read owns pending state before native reply");}
 static void answer(OfficeEditorActivity h){require(h.cells.onNativeMessage(reply(h,body(h,true,false))),"owned read reply is consumed");}
 static EditText edit(View v){if(v instanceof EditText)return (EditText)v;if(v instanceof ViewGroup)for(View child:((ViewGroup)v).children){EditText e=edit(child);if(e!=null)return e;}return null;}
 static AlertDialog editor(OfficeEditorActivity h){answer(h);AlertDialog.top().choose(0);AlertDialog.top().choose(0);AlertDialog d=AlertDialog.top();require(edit(d.view)!=null,"editable cell opens native multiline input");return d;}
 static void button(AlertDialog d,int which){d.getButton(which).performClick();}
 static void basic()throws Exception{
  OfficeEditorActivity h=host("pptx");h.cells.installButton();h.cells.installButton();require(h.added.size()==1,"button installed once");
  require(((Button)h.added.get(0)).getText().toString().equals("표 셀"),"literal native entry button");
  ((Button)h.added.get(0)).performClick();JSONObject request=request(h);require(request.getString("action").equals("read")&&request.getString("sessionId").equals(ID),"button sends bound read only");
  AlertDialog d=editor(h);require(edit(d.view).getText().toString().equals("한글 😀\n전체 원문"),"full native Unicode text is prefilled");
  require(!h.cells.blocksSave()&&h.completes==1,"read clears owner and native watchdog before dialog callbacks");
  for(String format:new String[]{"docx","xlsx","pdf"}){OfficeEditorActivity other=host(format);other.cells.installButton();require(other.added.isEmpty(),"only presentation formats expose cells");}
  OfficeEditorActivity waiting=host("ppt");waiting.ready=false;waiting.cells.installButton();require(waiting.added.isEmpty(),"entry waits for actual native readiness");
 }
 static void drafts()throws Exception{
  OfficeEditorActivity h=host("odp");read(h);AlertDialog d=editor(h);EditText text=edit(d.view);String draft="새 한글 😀\n두 번째 줄";
  text.setText("x".repeat(8193));button(d,DialogInterface.BUTTON_POSITIVE);require(h.scripts.size()==1&&!h.cells.blocksSave()&&text.error!=null,"oversized draft is rejected before native enqueue");
  text.setText("\ud800");button(d,DialogInterface.BUTTON_POSITIVE);require(h.scripts.size()==1&&!h.cells.blocksSave(),"unpaired UTF16 draft is rejected before native enqueue");text.setText(draft);
  button(d,DialogInterface.BUTTON_POSITIVE);JSONObject sent=request(h);require(sent.getString("action").equals("replace")&&sent.getString("text").equals(draft),"apply sends exact full Unicode draft");
  require(h.planCalls==1&&h.plannedOld.equals("한글 😀\n전체 원문")&&h.plannedNew.equals(draft),"planner receives exact selected original and draft");
  require(sent.getJSONObject("stylePlan").getString("protocol").equals("piv-text-style-map-1"),"fixed replace carries validated plan");
  require(sent.getJSONObject("expected").getJSONArray("cells").length()==2,"replace contains full uncropped table snapshot");
  require(d.isShowing()&&text.getText().toString().equals(draft),"editor and draft stay behind pending progress");
  h.cells.onNativeMessage(reply(h,body(h,false,false)));require(!h.cells.blocksSave()&&d.isShowing()&&text.getText().toString().equals(draft),"clean failure preserves typed draft");
  AlertDialog.top().dismiss();button(d,DialogInterface.BUTTON_NEUTRAL);require(request(h).getString("action").equals("read"),"refresh sends a new bound read");
  JSONObject fresh=body(h,true,false);fresh.getJSONArray("tables").getJSONObject(0).getJSONArray("cells").getJSONObject(0).put("text","새 현재 원문");
  h.cells.onNativeMessage(reply(h,fresh));require(d.isShowing()&&text.getText().toString().equals(draft),"refresh keeps same editor target and draft");
  button(d,DialogInterface.BUTTON_POSITIVE);require(request(h).getJSONObject("expected").getJSONArray("cells").getJSONObject(0).getString("text").equals("새 현재 원문"),"apply after refresh uses newly observed full original");
  require(h.planCalls==2&&h.plannedOld.equals("새 현재 원문"),"refreshed source is replanned before dispatch");
  JSONObject done=body(h,true,true);done.getJSONObject("table").getJSONArray("cells").getJSONObject(0).put("text",draft);
  h.cells.onNativeMessage(reply(h,done));require(!h.cells.blocksSave()&&!d.isShowing(),"verified replace releases editor and displays refreshed cells");
 }
 static void ownership()throws Exception{
  OfficeEditorActivity h=host("pptx");read(h);byte[] owned=reply(h,body(h,true,false));byte[] foreign=reply("foreign",body(h,true,false));byte[] original=foreign.clone();
  require(!h.cells.onNativeMessage(foreign)&&Arrays.equals(foreign,original)&&h.cells.blocksSave(),"foreign bytes untouched and pending owner retained");
  h.defer=true;require(h.cells.onNativeMessage(owned),"owned callback queues UI delivery");Arrays.fill(owned,(byte)0);h.drain();require(!h.cells.blocksSave(),"callback copies bounded frame before UI queue");
  require(!h.cells.onNativeMessage(reply(h,body(h,true,false)))&&h.completes==1,"duplicate response cannot consume twice");
  OfficeEditorActivity sync=host("pptx");sync.cells.installButton();JSONObject b=body(h,true,false);sync.synchronous=b;
  ((Button)sync.added.get(0)).performClick();require(!sync.cells.blocksSave()&&sync.completes==1,"synchronous enqueue reply observes registered owner");
 }
 static void back()throws Exception{
  OfficeEditorActivity h=host("pptx");read(h);require(h.cells.handleBack()&&h.safeCloses==0&&h.finishes==0,"Back waits while operation is pending");
  require(AlertDialog.top().message.contains("변경을 확인한 뒤 닫습니다"),"pending close remains responsive with clear wait message");
  answer(h);require(h.safeCloses==1&&h.completes==1&&!h.cells.blocksSave(),"clean completion clears pending before safe close callback");
 }
 static void timeout()throws Exception{
  OfficeEditorActivity h=host("pptx");read(h);Handler.fire();require(h.cells.blocksSave()&&OfficeEngineHealth.requiresRestart()&&h.completes==1,"read timeout quarantines native session and cancels watch");
  require(h.safeCloses==0&&h.finishes==0&&h.cells.handleBack(),"uncertain state never auto saves or closes");
  button(AlertDialog.top(),DialogInterface.BUTTON_POSITIVE);require(h.finishes==1&&h.safeCloses==0,"explicit recovery close uses finish without save");
 }
 static void uncertain()throws Exception{
  OfficeEditorActivity h=host("pptx");read(h);AlertDialog d=editor(h);edit(d.view).setText("draft");button(d,DialogInterface.BUTTON_POSITIVE);
  h.cells.onNativeMessage(reply(h,body(h,false,true)));require(h.cells.blocksSave()&&OfficeEngineHealth.requiresRestart()&&h.safeCloses==0,"ambiguous replacement blocks publishing");
  require(edit(d.view).getText().toString().equals("draft"),"uncertain failure keeps draft available behind recovery");
 }
 static void close()throws Exception{
  OfficeEditorActivity h=host("pptx");read(h);byte[] own=reply(h,body(h,true,false));h.defer=true;h.cells.onNativeMessage(own);h.cells.close();int complete=h.completes;
  h.destroyed=true;h.drain();Handler.fire();require(h.completes==complete&&h.safeCloses==0&&h.finishes==0,"closed queued replies and timers never call host");
  require(!h.cells.onNativeMessage(own)&&h.cells.blocksSave(),"closed controller is terminal and ignores stale replies");
  require(AlertDialog.shown.isEmpty(),"close dismisses owned native dialogs");
 }
 static void readonly()throws Exception{
  OfficeEditorActivity h=host("ppt");read(h);answer(h);AlertDialog.top().choose(0);AlertDialog.top().choose(1);
  require(edit(AlertDialog.top().view)==null&&AlertDialog.top().message.contains("병합 셀 원문"),"uneditable cell shows full read-only native text");
  require(h.scripts.size()==1,"viewing protected cell does not enqueue mutation");
 }
 static void rejectedSend()throws Exception{
  OfficeEditorActivity h=host("pptx");h.accept=false;h.cells.installButton();((Button)h.added.get(0)).performClick();
  require(!h.cells.blocksSave()&&h.completes==0&&h.safeCloses==0,"rejected send clears own pending without cancelling another host watchdog");
 }
 static void planningFailure()throws Exception{
  OfficeEditorActivity h=host("pptx");read(h);AlertDialog d=editor(h);EditText text=edit(d.view);text.setText("보존할 초안 😀");int complete=h.completes;
  h.plannerFails=true;h.duringPlan=()->require(h.cells.handleBack(),"Back observes owned planning ticket");button(d,DialogInterface.BUTTON_POSITIVE);
  require(h.planCalls==1&&h.scripts.size()==1&&!h.cells.blocksSave(),"failed planner releases clean ticket before native dispatch");
  require(h.completes==complete&&!OfficeEngineHealth.requiresRestart()&&Handler.delayed.isEmpty(),"planning failure never cancels parent watch or quarantines engine");
  require(h.safeCloses==0&&d.isShowing()&&text.getText().toString().equals("보존할 초안 😀"),"close-after-pending never discards failed planner draft");
  AlertDialog.top().dismiss();h.duringPlan=null;h.plannerFails=false;h.missingPlanner=true;button(d,DialogInterface.BUTTON_POSITIVE);
  require(h.planCalls==2&&h.scripts.size()==1&&!h.cells.blocksSave()&&h.completes==complete&&d.isShowing(),"missing native planner is clean and preserves dialog");
  AlertDialog.top().dismiss();h.missingPlanner=false;button(d,DialogInterface.BUTTON_POSITIVE);require(h.scripts.size()==2&&h.cells.blocksSave(),"same draft can retry after clean planning failure");
  JSONObject failed=body(h,false,false);require(h.cells.handleBack(),"Back can request close during dispatched replacement");h.cells.onNativeMessage(reply(h,failed));
  require(h.safeCloses==0&&d.isShowing()&&text.getText().toString().equals("보존할 초안 😀"),"clean dispatched replace failure also retains draft after close request");
 }
 static void planningStale()throws Exception{
  OfficeEditorActivity h=host("pptx");read(h);AlertDialog d=editor(h);edit(d.view).setText("draft");int completes=h.completes;
  h.duringPlan=()->{h.cells.close();h.destroyed=true;};button(d,DialogInterface.BUTTON_POSITIVE);
  require(h.planCalls==1&&h.scripts.size()==1&&h.completes==completes&&Handler.delayed.isEmpty(),"closed owner is checked after planner return before dispatch");
 }
 static void scriptLimit()throws Exception{
  OfficeEditorActivity h=host("pptx");read(h);JSONObject payload=body(h,true,false);JSONObject large=payload.getJSONArray("tables").getJSONObject(0);large.put("name","한".repeat(170000));
  h.cells.onNativeMessage(reply(h,payload));AlertDialog.top().choose(0);AlertDialog.top().choose(0);AlertDialog d=AlertDialog.top();EditText text=edit(d.view);text.setText("보존할 초안");int complete=h.completes;
  button(d,DialogInterface.BUTTON_POSITIVE);
  require(h.planCalls==1&&h.scripts.size()==1&&!h.cells.blocksSave(),"complete UTF8 script over 512KiB is rejected before dispatch without truncation");
  require(h.completes==complete&&Handler.delayed.isEmpty()&&!OfficeEngineHealth.requiresRestart(),"script preflight does not start timeout, cancel parent watch or quarantine");
  require(d.isShowing()&&text.getText().toString().equals("보존할 초안"),"oversized complete script preserves editor draft");
 }
 public static void main(String[] args)throws Exception{
  switch(args[0]){case"basic":basic();break;case"drafts":drafts();break;case"ownership":ownership();break;case"back":back();break;case"timeout":timeout();break;case"uncertain":uncertain();break;case"close":close();break;case"readonly":readonly();break;case"reject":rejectedSend();break;case"plan-failure":planningFailure();break;case"plan-stale":planningStale();break;case"script-limit":scriptLimit();break;default:throw new AssertionError();}
  System.out.println("HOST ONLY: "+args[0]+" "+checks+" controller checks passed; Android/UNO runtime unverified.");
 }
}
'''


class PresentationCellUiTests(unittest.TestCase):
    def test_actual_native_controller_ownership_drafts_close_and_quarantine(self):
        self.assertTrue(CONTROLLER.is_file(), 'OfficePresentationCells native dialog controller is not implemented')
        self.assertTrue(JSON_JAR.is_file(), 'Existing read-only org.json JAR is required')
        self.assertEqual(hashlib.sha256(JSON_JAR.read_bytes()).hexdigest(), JSON_SHA256)
        suffix = '.exe' if os.name == 'nt' else ''
        java_home = os.environ.get('JAVA_HOME')
        javac = str(Path(java_home) / f'bin/javac{suffix}') if java_home else shutil.which('javac')
        java = str(Path(java_home) / f'bin/java{suffix}') if java_home else shutil.which('java')
        self.assertTrue(javac and java, 'A JDK is required; this does not execute Android/JNI')
        with tempfile.TemporaryDirectory(prefix='office-cell-ui-') as folder:
            root = Path(folder)
            sources = []
            for name, contents in STUBS.items():
                source = root / name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text(contents, encoding='utf-8')
                sources.append(str(source))
            harness = root / 'io/github/canele452/personalinkvault/office/CellUiHarness.java'
            harness.write_text(HARNESS, encoding='utf-8')
            sources += [str(harness), str(CONTROLLER)]
            sources += [str(JAVA / name) for name in ('OfficeCellReply.java', 'OfficeScriptSession.java', 'OfficeEngineHealth.java')]
            compiled = subprocess.run([javac, '-encoding', 'UTF-8', '-cp', str(JSON_JAR), '-d', folder] + sources,
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            for scenario in ('basic', 'drafts', 'ownership', 'back', 'timeout', 'uncertain', 'close', 'readonly', 'reject', 'plan-failure', 'plan-stale', 'script-limit'):
                result = subprocess.run([java, '-Dcell.asset=' + str(PROGRAM), '-cp', folder + os.pathsep + str(JSON_JAR),
                                         'io.github.canele452.personalinkvault.office.CellUiHarness', scenario],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('controller checks passed', result.stdout)
                print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main(verbosity=2)
