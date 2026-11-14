mod engine;
mod hwp_body;
mod hwp_paragraphs;
mod hwp_table_rows;
mod legacy_office;
mod rhwp_pdf;
mod text_ranges;
mod xml;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    path::PathBuf,
};
type Result<T> = std::result::Result<T, ApiError>;
struct ApiError {
    code: &'static str,
    message: &'static str,
    work: Option<PathBuf>,
}
fn err(code: &'static str, message: &'static str) -> ApiError {
    ApiError {
        code,
        message,
        work: None,
    }
}
fn invalid() -> ApiError {
    err("invalid_request", "HWP 요청의 형식이 올바르지 않습니다.")
}
fn unsupported() -> ApiError {
    err(
        "unsupported_structure",
        "이 문서 부분은 구조를 보존하며 편집할 수 없습니다.",
    )
}
fn io_error(_: impl std::fmt::Display) -> ApiError {
    err(
        "file_error",
        "문서 작업 파일을 읽거나 저장하지 못했습니다. 원본은 보관됩니다.",
    )
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().ok_or_else(invalid)
}
impl ApiError {
    fn json(self) -> Value {
        let mut value = json!({"error":{"code":self.code,"message":self.message}});
        if let Some(work) = self.work {
            value["error"]["workingDirectory"] = json!(work);
            for ext in ["hwp", "hwpx"] {
                let path = work.join(format!("edited.{ext}"));
                if path.is_file() {
                    value["error"]["workingSourcePath"] = json!(path);
                }
            }
        }
        value
    }
}
/// # Safety
/// Non-null input must be a readable NUL-terminated C string. Release the response once with ink_hwp_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ink_hwp_request(input: *const c_char) -> *mut c_char {
    let response = std::panic::catch_unwind(|| {
        if input.is_null() {
            return err("null_input", "요청이 없습니다.").json();
        }
        // SAFETY: Caller owns this readable C string during the synchronous call.
        match unsafe { CStr::from_ptr(input) }.to_str() {
            Ok(v) => request_json(v),
            Err(_) => err("invalid_utf8", "요청 문자열을 읽지 못했습니다.").json(),
        }
    })
    .unwrap_or_else(|_| {
        err(
            "internal_error",
            "문서 작업을 완료하지 못했습니다. 원본은 보관됩니다.",
        )
        .json()
    });
    CString::new(response.to_string())
        .unwrap_or_else(|_| {
            c"{\"error\":{\"code\":\"internal_error\",\"message\":\"Response encoding failed\"}}"
                .to_owned()
        })
        .into_raw()
}
/// # Safety
/// Non-null value must be an unreleased allocation returned by ink_hwp_request.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ink_hwp_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: Caller transfers this library's owned response back exactly once.
        drop(unsafe { CString::from_raw(value) });
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn ink_hwp_version() -> *const c_char {
    c"ink_hwp_native/0.1.0+hwp-cli.4e6e8c2+rhwp.0.9.0-dev.4cf97fe5".as_ptr()
}
pub fn request_json(input: &str) -> Value {
    if input.len() > 4 * 1024 * 1024 {
        return invalid().json();
    }
    let request: Value = match serde_json::from_str(input) {
        Ok(v) => v,
        Err(_) => return err("invalid_json", "요청 JSON을 읽지 못했습니다.").json(),
    };
    engine::dispatch(&request).unwrap_or_else(ApiError::json)
}
