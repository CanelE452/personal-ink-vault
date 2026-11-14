use ink_vault_native::{ink_vault_free, ink_vault_request, ink_vault_version};
use serde_json::{Value, json};
use std::ffi::{CStr, CString};

unsafe fn invoke(input: *const std::ffi::c_char) -> Value {
    let output = unsafe { ink_vault_request(input) };
    assert!(!output.is_null());
    let result = serde_json::from_str(unsafe { CStr::from_ptr(output) }.to_str().unwrap()).unwrap();
    unsafe { ink_vault_free(output) };
    result
}

#[test]
fn ffi_handles_null_invalid_utf8_and_invalid_json_without_unwinding() {
    unsafe {
        assert_eq!(invoke(std::ptr::null())["error"]["code"], "null_input");
        let invalid = [255_u8, 0_u8];
        assert_eq!(
            invoke(invalid.as_ptr().cast())["error"]["code"],
            "invalid_utf8"
        );
        let malformed = c"{";
        assert_eq!(invoke(malformed.as_ptr())["error"]["code"], "invalid_json");
        ink_vault_free(std::ptr::null_mut());
    }
}

#[test]
fn ffi_response_survives_input_release_and_is_freed_by_rust_on_repeated_calls() {
    unsafe {
        for _ in 0..1000 {
            let input = CString::new(r#"{"op":"sha256","bytes":[]}"#).unwrap();
            let output = ink_vault_request(input.as_ptr());
            drop(input);
            let response: Value =
                serde_json::from_str(CStr::from_ptr(output).to_str().unwrap()).unwrap();
            assert_eq!(
                response["sha256"],
                json!("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
            );
            ink_vault_free(output);
        }
        assert_eq!(
            CStr::from_ptr(ink_vault_version()).to_str().unwrap(),
            "0.1.0"
        );
    }
}
