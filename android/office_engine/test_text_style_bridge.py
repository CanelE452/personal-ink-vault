"""HOST ONLY: compile the actual JNI bridge against ownership/loader stubs.

No Android runtime or Rust implementation is substituted as proof here. The
harness checks JNI byte handling, response ownership, and Office export routing.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parent
SOURCE = MODULE / 'src/main/cpp/office_bridge.cpp'

JNI = r'''
#pragma once
#include <string>
#include <vector>
#define JNIEXPORT
#define JNICALL
using jsize=int;using jint=int;using jboolean=unsigned char;using jbyte=signed char;
using jobject=void*;using jclass=void*;using jstring=const char*;
constexpr jboolean JNI_TRUE=1,JNI_FALSE=0;
struct ByteArray{std::vector<jbyte> bytes;};using jbyteArray=ByteArray*;
struct JNIEnv {
 bool error=false,failNew=false,failSet=false,failGet=false;std::string message;int deleted=0;
 bool ExceptionCheck(){return error;}jclass FindClass(const char*){return this;}
 void ThrowNew(jclass,const char* m){error=true;message=m;}void DeleteLocalRef(void*){deleted++;}
 const char* GetStringUTFChars(jstring s,void*){return s;}void ReleaseStringUTFChars(jstring,const char*){}
 jsize GetArrayLength(jbyteArray a){return a->bytes.size();}
 void GetByteArrayRegion(jbyteArray a,jsize s,jsize n,jbyte* out){if(failGet){error=true;return;}std::copy_n(a->bytes.data()+s,n,out);}
 jbyteArray NewByteArray(jsize n){if(failNew){error=true;return nullptr;}return new ByteArray{std::vector<jbyte>(n)};}
 void SetByteArrayRegion(jbyteArray a,jsize s,jsize n,const jbyte* in){if(failSet){error=true;return;}std::copy_n(in,n,a->bytes.data()+s);}
};
'''
COKIT = r'''
#pragma once
#include <string>
#include <vector>
enum class COKitDocumentType{TEXT,PRESENTATION,OTHER};
struct COKitDocument{std::string format, options;bool hasOptions=false,failSave=false;
 COKitDocumentType type=COKitDocumentType::PRESENTATION;
 std::vector<std::string> saves;
 bool saveAs(const char*,const char* kind,const char* flags){
  if(failSave)throw 1;
  saves.emplace_back(kind);format=kind;hasOptions=flags!=nullptr;options=flags?flags:"";return true;
 }
 COKitDocumentType getDocumentType(){return type;}int getParts(){return 1;}
 std::string getPresentationInfo(){return "{}";}};
'''
DLFCN = r'''
#pragma once
#define RTLD_NOW 2
#define RTLD_LOCAL 0
extern "C" void* dlopen(const char*,int);
extern "C" void* dlsym(void*,const char*);
extern "C" int dlclose(void*);
extern "C" char* dlerror();
'''
HARNESS = r'''
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <dlfcn.h>
#include "__SOURCE__"
static std::shared_ptr<COKitDocument> fixtureDocument;
std::shared_ptr<COKitDocument> getLOKDocumentForAndroidOnly(){return fixtureDocument;}
static int loads,lookups,closes,calls,frees;static bool missing,missingFree,nullResult;static std::string input,response="{\"protocol\":\"piv-text-style-map-1\"}";
static void* handle=reinterpret_cast<void*>(0x1234);
extern "C" char* fixtureRequest(const char* text){calls++;input=text;if(nullResult)return nullptr;char* p=new char[response.size()+1];std::memcpy(p,response.c_str(),response.size()+1);return p;}
extern "C" void fixtureFree(char* p){if(!p)throw std::runtime_error("free null response");frees++;delete[] p;}
extern "C" void* dlopen(const char* name,int flags){loads++;if(std::string(name)!="libink_vault_native.so"||flags!=(RTLD_NOW|RTLD_LOCAL))throw std::runtime_error("wrong process loader");return missing?nullptr:handle;}
extern "C" void* dlsym(void* h,const char* name){if(h!=handle)throw std::runtime_error("request/free resolve from same handle");lookups++;if(std::string(name)=="ink_vault_request")return reinterpret_cast<void*>(&fixtureRequest);if(std::string(name)=="ink_vault_free")return missingFree?nullptr:reinterpret_cast<void*>(&fixtureFree);throw std::runtime_error("wrong Rust ABI");}
extern "C" int dlclose(void*){closes++;return 0;}extern "C" char* dlerror(){return nullptr;}
static void require(bool b,const char* m){if(!b)throw std::runtime_error(m);}
static ByteArray array(const std::string& s){return ByteArray{std::vector<jbyte>(s.begin(),s.end())};}
static jbyteArray plan(JNIEnv& env,ByteArray& old,ByteArray& text){return Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_nativePlanCellText(&env,nullptr,&old,&text);}
int main(int argc,char** argv){try{
 std::string mode=argv[1];JNIEnv env;ByteArray old=array("old"),text=array("new");
 if(mode=="missing"||mode=="missing-free"){missing=mode=="missing";missingFree=mode=="missing-free";require(!plan(env,old,text)&&env.error&&calls==0&&frees==0,"unavailable paired ABI fails before request");require(closes==0,"loaded Rust handle remains process lifetime");}
 else if(mode=="pdf-export"){
  fixtureDocument=std::make_shared<COKitDocument>();
  auto save=Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_savePreviewPdf;
  fixtureDocument->type=COKitDocumentType::TEXT;
  require(save(&env,nullptr,"file:///synthetic.pdf","docx") && fixtureDocument->format=="pdf"
      && !fixtureDocument->hasOptions,"word preview uses default PDF options");
  fixtureDocument->type=COKitDocumentType::PRESENTATION;
  for(const char* format:{"ppt", "pptx", "odp"}){
   require(save(&env,nullptr,"file:///synthetic.pdf",format) && fixtureDocument->format=="pdf"
       && fixtureDocument->hasOptions,"all presentation previews request explicit PDF options");
   require(fixtureDocument->options==
      R"({"ExportHiddenSlides":{"type":"boolean","value":"true"},"ExportNotesPages":{"type":"boolean","value":"false"},"ExportOnlyNotesPages":{"type":"boolean","value":"false"}})",
      "ink PDF includes hidden slides and omits notes pages");
  }
  fixtureDocument->failSave=true;
  require(!save(&env,nullptr,"file:///synthetic.pdf","pptx") && env.error
      && env.message=="office_preview_failed","native PDF exception reaches recovery as an error");
 }
 else if(mode=="document-family"){
  fixtureDocument=std::make_shared<COKitDocument>();
  auto preview=Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_savePreviewPdf;
  auto save=Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_saveOriginal;
  using Type=COKitDocumentType;
  const std::pair<Type,const char*> supported[]={
    {Type::TEXT,"doc"},{Type::TEXT,"docx"},{Type::TEXT,"odt"},
    {Type::PRESENTATION,"ppt"},{Type::PRESENTATION,"pptx"},{Type::PRESENTATION,"odp"}
  };
  for(const auto& [expected,format]:supported){
   fixtureDocument->type=expected;
   require(preview(&env,nullptr,"file:///synthetic.pdf",format) && !env.error,
       "matching family produces a PDF preview");
   require(fixtureDocument->saves==std::vector<std::string>{"pdf"},"only preview is exported");
   fixtureDocument->saves.clear();
   require(save(&env,nullptr,"file:///edited",format) && !env.error,
       "matching family saves in the requested original format");
   require(fixtureDocument->saves==std::vector<std::string>{format} && !fixtureDocument->hasOptions,
       "source-only export must precede a fresh PDF load");
   fixtureDocument->saves.clear();

   fixtureDocument->type=expected==Type::TEXT ? Type::PRESENTATION : Type::TEXT;
   require(!preview(&env,nullptr,"file:///synthetic.pdf",format)
       && env.error && env.message=="office_format_mismatch" && fixtureDocument->saves.empty(),
       "a mismatched family creates no PDF preview");
   env=JNIEnv{};
   require(!save(&env,nullptr,"file:///edited",format)
       && env.error && env.message=="office_format_mismatch" && fixtureDocument->saves.empty(),
       "a mismatched family creates neither source nor PDF");
   env=JNIEnv{};
  }
 }
 else if(mode=="legacy-copy"){
  fixtureDocument=std::make_shared<COKitDocument>();
  auto save=Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_saveLegacyCopy;
  using Type=COKitDocumentType;
  fixtureDocument->type=Type::TEXT;
  require(save(&env,nullptr,"file:///owned/converted.docx","doc") && !env.error
      && fixtureDocument->saves==std::vector<std::string>{"docx"} && !fixtureDocument->hasOptions,
      "legacy DOC exports one DOCX copy without taking ownership");
  fixtureDocument->type=Type::PRESENTATION;
  fixtureDocument->saves.clear();
  require(save(&env,nullptr,"file:///owned/converted.pptx","ppt") && !env.error
      && fixtureDocument->saves==std::vector<std::string>{"pptx"} && !fixtureDocument->hasOptions,
      "legacy PPT exports one PPTX copy without taking ownership");
  fixtureDocument->saves.clear();
  require(!save(&env,nullptr,"file:///owned/converted.docx","doc") && env.error
      && env.message=="office_format_mismatch" && fixtureDocument->saves.empty(), "legacy family mismatch never saves");
  env=JNIEnv{};
  require(!save(&env,nullptr,"file:///owned/converted.pptx","pptx") && !env.error
      && fixtureDocument->saves.empty(), "modern input is outside the legacy export contract");
 }
 else if(mode=="bytes"){
  old=array(std::string("한😀\"\\\n\r\t")+std::string(1,'\0'));text=array("바뀜\u2028");auto result=plan(env,old,text);
  require(result&&!env.error&&frees==1,"owned UTF8 reply copied then freed exactly once");
  std::string remaining=input;for(const std::string& field:std::vector<std::string>{"\"op\":\"text_style_map\"","\"protocol\":\"piv-text-style-map-1\"","\"oldText\":\"한😀\\\"\\\\\\u000a\\u000d\\u0009\\u0000\"","\"newText\":\"바뀜\u2028\""}){auto at=remaining.find(field);require(at!=std::string::npos,"fixed request fields use standard UTF8 and escaped C0 including NUL");remaining.erase(at,field.size());}require(remaining=="{,,,}","fixed request has exactly four fields independent of property order");
  require(std::string(result->bytes.begin(),result->bytes.end())==response,"native response bytes exact");delete result;
  result=plan(env,old,text);delete result;require(loads==1&&lookups==2&&calls==2&&frees==2&&closes==0,"pair loaded once and never unloaded");
 }
 else if(mode=="null"||mode=="empty"||mode=="large"||mode=="allocation"||mode=="copy"){
  nullResult=mode=="null";if(mode=="empty")response="";if(mode=="large")response=std::string(1024*1024+1,'x');env.failNew=mode=="allocation";env.failSet=mode=="copy";
  auto result=plan(env,old,text);require(!result&&env.error&&frees==(nullResult?0:1),"every owned bad/allocation/copy response is freed exactly once");
 }
 else if(mode=="max-reply"){
  response=std::string(1024*1024,'x');auto result=plan(env,old,text);require(result&&!env.error&&result->bytes.size()==1024*1024&&frees==1,"exact 1MiB native reply boundary is allowed and freed once");delete result;
 }
 else if(mode=="input"){
  require(!Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_nativePlanCellText(&env,nullptr,nullptr,&text)&&env.error&&calls==0,"null input rejected before Rust");
  env=JNIEnv{};old=array(std::string(800001,'a'));require(!plan(env,old,text)&&env.error&&calls==0,"oversized old input rejected before Rust");
  env=JNIEnv{};old=array("a");text=array(std::string(32769,'a'));require(!plan(env,old,text)&&env.error&&calls==0,"oversized new input rejected before Rust");
  env=JNIEnv{};old=array("a");text=array("b");env.failGet=true;require(!plan(env,old,text)&&env.error&&calls==0,"JNI copy exception never invokes Rust");
  env=JNIEnv{};old=array(std::string(600000,'\0'));text=array("b");require(!plan(env,old,text)&&env.error&&calls==0,"escaped request budget is checked before Rust");
 }
 else throw std::runtime_error("unknown scenario");
 std::cout<<"HOST ONLY: JNI style planner "<<mode<<" boundary checks passed; no Android/Rust execution."<<std::endl;return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<std::endl;return 1;}}
'''


class TextStyleBridgeTests(unittest.TestCase):
    def test_actual_cpp_jni_utf8_loader_and_exact_response_ownership(self):
        compiler = os.environ.get('CXX') or shutil.which('cl.exe') or shutil.which('clang++') or shutil.which('g++')
        self.assertTrue(compiler, 'A host C++20 compiler is required; no Android runtime is executed')
        with tempfile.TemporaryDirectory(prefix='office-style-jni-') as folder:
            root = Path(folder)
            for name, text in [('jni.h', JNI), ('COKit.hxx', COKIT), ('dlfcn.h', DLFCN)]:
                (root / name).write_text(text, encoding='utf-8')
            source = root / 'style_bridge_harness.cpp'
            source.write_text(HARNESS.replace('__SOURCE__', SOURCE.as_posix()), encoding='utf-8')
            executable = root / ('bridge.exe' if os.name == 'nt' else 'bridge')
            if Path(compiler).name.lower() in ('cl', 'cl.exe'):
                command = [compiler, '/nologo', '/std:c++20', '/EHsc', '/utf-8', '/I'+folder,
                           str(source), '/Fe:'+str(executable), '/Fo:'+str(root/'bridge.obj')]
            else:
                command = [compiler, '-std=c++20', '-I'+folder, str(source), '-o', str(executable)]
            result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            for scenario in ('bytes', 'missing', 'missing-free', 'null', 'empty', 'large', 'allocation', 'copy', 'max-reply', 'input',
                             'pdf-export', 'document-family', 'legacy-copy'):
                result = subprocess.run([str(executable), scenario], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, scenario+': '+result.stdout+result.stderr)
                print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main(verbosity=2)
