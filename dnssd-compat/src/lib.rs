//! Windows DNS-SD compatibility surface required by UxPlay.
//!
//! UxPlay resolves these seven symbols from `dnssd.dll` at runtime. Keeping the
//! implementation here lets Panecast advertise its AirPlay receiver without
//! installing Apple's legacy Bonjour SDK or a machine-wide Bonjour service.

#![cfg_attr(not(test), deny(unsafe_op_in_unsafe_fn))]

use std::{
    collections::HashMap,
    ffi::{c_char, c_void, CStr},
    ptr,
};

use mdns_sd::{ServiceDaemon, ServiceInfo};

type DNSServiceFlags = u32;
type DNSServiceErrorType = i32;
type DNSServiceRef = *mut c_void;
type DNSServiceRegisterReply = Option<
    unsafe extern "system" fn(
        DNSServiceRef,
        DNSServiceFlags,
        DNSServiceErrorType,
        *const c_char,
        *const c_char,
        *const c_char,
        *mut c_void,
    ),
>;

const DNS_SERVICE_ERR_NO_ERROR: DNSServiceErrorType = 0;
const DNS_SERVICE_ERR_UNKNOWN: DNSServiceErrorType = -65_537;
const DNS_SERVICE_ERR_NO_MEMORY: DNSServiceErrorType = -65_539;
const DNS_SERVICE_ERR_BAD_PARAM: DNSServiceErrorType = -65_540;
const TXT_STATE_MAGIC: u64 = 0x5349_5454_4552_5458;
const MAX_TXT_RECORD_LEN: usize = u16::MAX as usize;
const MAX_C_STRING_LEN: usize = 1024;

/// ABI-compatible with Apple's 16-byte `TXTRecordRef` on 64-bit Windows.
#[repr(C, align(8))]
pub struct TXTRecordRef {
    private_data: [u8; 16],
}

struct TxtState {
    entries: Vec<TxtEntry>,
    encoded: Vec<u8>,
}

struct TxtEntry {
    key: String,
    value: Vec<u8>,
}

struct Registration {
    daemon: ServiceDaemon,
    fullname: String,
}

impl Drop for Registration {
    fn drop(&mut self) {
        let _ = self.daemon.unregister(&self.fullname);
        let _ = self.daemon.shutdown();
    }
}

/// Creates an internally owned DNS-SD TXT record.
///
/// # Safety
///
/// `txt_record` must point to writable storage matching the 16-byte `TXTRecordRef` ABI.
#[no_mangle]
pub unsafe extern "system" fn TXTRecordCreate(
    txt_record: *mut TXTRecordRef,
    buffer_len: u16,
    buffer: *mut c_void,
) {
    ffi_void(|| {
        if txt_record.is_null() {
            return;
        }
        // UxPlay always requests internally managed storage. Rejecting external
        // storage avoids silently violating ownership semantics we do not need.
        if buffer_len != 0 || !buffer.is_null() {
            unsafe { clear_txt_ref(txt_record) };
            return;
        }
        let state = Box::new(TxtState {
            entries: Vec::new(),
            encoded: Vec::new(),
        });
        unsafe { write_txt_state(txt_record, Box::into_raw(state)) };
    });
}

/// Releases storage previously created by [`TXTRecordCreate`].
///
/// # Safety
///
/// `txt_record` must be null or point to a `TXTRecordRef` initialized by this DLL.
#[no_mangle]
pub unsafe extern "system" fn TXTRecordDeallocate(txt_record: *mut TXTRecordRef) {
    ffi_void(|| {
        let Some(state) = (unsafe { take_txt_state(txt_record) }) else {
            return;
        };
        drop(unsafe { Box::from_raw(state) });
    });
}

/// Adds or replaces one value in a DNS-SD TXT record.
///
/// # Safety
///
/// `txt_record` and `key` must be valid for the call; when `value_size` is nonzero,
/// `value` must reference at least that many readable bytes.
#[no_mangle]
pub unsafe extern "system" fn TXTRecordSetValue(
    txt_record: *mut TXTRecordRef,
    key: *const c_char,
    value_size: u8,
    value: *const c_void,
) -> DNSServiceErrorType {
    ffi_error(|| {
        let Some(state) = (unsafe { txt_state_mut(txt_record) }) else {
            return DNS_SERVICE_ERR_BAD_PARAM;
        };
        let Some(key) = (unsafe { read_bounded_c_string(key) }) else {
            return DNS_SERVICE_ERR_BAD_PARAM;
        };
        if !valid_txt_key(&key) {
            return DNS_SERVICE_ERR_BAD_PARAM;
        }
        let value_size = usize::from(value_size);
        if value_size > 0 && value.is_null() {
            return DNS_SERVICE_ERR_BAD_PARAM;
        }
        let bytes = if value_size == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(value.cast::<u8>(), value_size) }.to_vec()
        };
        let entry_len = key.len() + usize::from(!bytes.is_empty()) + bytes.len();
        if entry_len > u8::MAX as usize {
            return DNS_SERVICE_ERR_BAD_PARAM;
        }

        if let Some(entry) = state
            .entries
            .iter_mut()
            .find(|entry| entry.key.eq_ignore_ascii_case(&key))
        {
            entry.key = key;
            entry.value = bytes;
        } else {
            state.entries.push(TxtEntry { key, value: bytes });
        }
        if !rebuild_txt_record(state) {
            return DNS_SERVICE_ERR_NO_MEMORY;
        }
        DNS_SERVICE_ERR_NO_ERROR
    })
}

/// Returns the encoded TXT record length.
///
/// # Safety
///
/// `txt_record` must be null or point to a live `TXTRecordRef` initialized by this DLL.
#[no_mangle]
pub unsafe extern "system" fn TXTRecordGetLength(txt_record: *const TXTRecordRef) -> u16 {
    ffi_value(0, || {
        unsafe { txt_state(txt_record) }
            .and_then(|state| u16::try_from(state.encoded.len()).ok())
            .unwrap_or(0)
    })
}

/// Borrows the encoded TXT record bytes.
///
/// # Safety
///
/// `txt_record` must be null or point to a live `TXTRecordRef`; the returned pointer is valid
/// only until the next mutation or deallocation of that record.
#[no_mangle]
pub unsafe extern "system" fn TXTRecordGetBytesPtr(
    txt_record: *const TXTRecordRef,
) -> *const c_void {
    ffi_value(ptr::null(), || {
        let Some(state) = (unsafe { txt_state(txt_record) }) else {
            return ptr::null();
        };
        if state.encoded.is_empty() {
            ptr::null()
        } else {
            state.encoded.as_ptr().cast()
        }
    })
}

#[allow(clippy::too_many_arguments)]
/// Registers one DNS-SD service and returns an opaque owned handle.
///
/// # Safety
///
/// All non-null C strings must be NUL-terminated and readable. `service_ref` must point to
/// writable pointer storage, and `txt_record` must reference `txt_len` readable bytes.
#[no_mangle]
pub unsafe extern "system" fn DNSServiceRegister(
    service_ref: *mut DNSServiceRef,
    flags: DNSServiceFlags,
    interface_index: u32,
    name: *const c_char,
    reg_type: *const c_char,
    domain: *const c_char,
    host: *const c_char,
    port: u16,
    txt_len: u16,
    txt_record: *const c_void,
    callback: DNSServiceRegisterReply,
    context: *mut c_void,
) -> DNSServiceErrorType {
    ffi_error(|| {
        if service_ref.is_null() || flags != 0 || interface_index != 0 {
            return DNS_SERVICE_ERR_BAD_PARAM;
        }
        unsafe { service_ref.write(ptr::null_mut()) };

        let Some(name) = (unsafe { read_bounded_c_string(name) }) else {
            return DNS_SERVICE_ERR_BAD_PARAM;
        };
        let Some(reg_type) = (unsafe { read_bounded_c_string(reg_type) }) else {
            return DNS_SERVICE_ERR_BAD_PARAM;
        };
        let domain = if domain.is_null() {
            "local.".to_owned()
        } else {
            let Some(domain) = (unsafe { read_bounded_c_string(domain) }) else {
                return DNS_SERVICE_ERR_BAD_PARAM;
            };
            domain
        };
        if name.is_empty() || reg_type.is_empty() {
            return DNS_SERVICE_ERR_BAD_PARAM;
        }
        let service_type = normalize_service_type(&reg_type, &domain);
        let hostname = if host.is_null() {
            make_hostname(&name)
        } else {
            let Some(host) = (unsafe { read_bounded_c_string(host) }) else {
                return DNS_SERVICE_ERR_BAD_PARAM;
            };
            normalize_hostname(&host)
        };
        let properties = match unsafe { parse_txt_properties(txt_len, txt_record) } {
            Some(properties) => properties,
            None => return DNS_SERVICE_ERR_BAD_PARAM,
        };

        let daemon = match ServiceDaemon::new() {
            Ok(daemon) => daemon,
            Err(_) => return DNS_SERVICE_ERR_UNKNOWN,
        };
        let info = match ServiceInfo::new(
            &service_type,
            &name,
            &hostname,
            "",
            u16::from_be(port),
            properties,
        ) {
            Ok(info) => info.enable_addr_auto(),
            Err(_) => return DNS_SERVICE_ERR_BAD_PARAM,
        };
        let fullname = info.get_fullname().to_owned();
        if daemon.register(info).is_err() {
            let _ = daemon.shutdown();
            return DNS_SERVICE_ERR_UNKNOWN;
        }

        let registration = Box::new(Registration { daemon, fullname });
        let registration = Box::into_raw(registration).cast::<c_void>();
        unsafe { service_ref.write(registration) };

        if let Some(callback) = callback {
            let name = std::ffi::CString::new(name).ok();
            let reg_type = std::ffi::CString::new(reg_type).ok();
            let domain = std::ffi::CString::new(domain).ok();
            if let (Some(name), Some(reg_type), Some(domain)) = (name, reg_type, domain) {
                unsafe {
                    callback(
                        registration,
                        0,
                        DNS_SERVICE_ERR_NO_ERROR,
                        name.as_ptr(),
                        reg_type.as_ptr(),
                        domain.as_ptr(),
                        context,
                    )
                };
            }
        }
        DNS_SERVICE_ERR_NO_ERROR
    })
}

/// Stops a service registration and releases its opaque handle.
///
/// # Safety
///
/// `service_ref` must be null or a live handle returned by [`DNSServiceRegister`] exactly once.
#[no_mangle]
pub unsafe extern "system" fn DNSServiceRefDeallocate(service_ref: DNSServiceRef) {
    ffi_void(|| {
        if !service_ref.is_null() {
            drop(unsafe { Box::from_raw(service_ref.cast::<Registration>()) });
        }
    });
}

fn rebuild_txt_record(state: &mut TxtState) -> bool {
    let length = state
        .entries
        .iter()
        .map(|entry| entry.key.len() + usize::from(!entry.value.is_empty()) + entry.value.len() + 1)
        .sum::<usize>();
    if length > MAX_TXT_RECORD_LEN {
        return false;
    }
    state.encoded.clear();
    state.encoded.reserve(length);
    for entry in &state.entries {
        let item_len = entry.key.len() + usize::from(!entry.value.is_empty()) + entry.value.len();
        state.encoded.push(item_len as u8);
        state.encoded.extend_from_slice(entry.key.as_bytes());
        if !entry.value.is_empty() {
            state.encoded.push(b'=');
            state.encoded.extend_from_slice(&entry.value);
        }
    }
    true
}

fn valid_txt_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= u8::MAX as usize
        && key
            .bytes()
            .all(|byte| (0x20..=0x7e).contains(&byte) && byte != b'=')
}

unsafe fn parse_txt_properties(
    txt_len: u16,
    txt_record: *const c_void,
) -> Option<HashMap<String, String>> {
    let len = usize::from(txt_len);
    if len == 0 {
        return Some(HashMap::new());
    }
    if txt_record.is_null() {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(txt_record.cast::<u8>(), len) };
    let mut cursor = 0;
    let mut properties = HashMap::new();
    while cursor < bytes.len() {
        let item_len = usize::from(bytes[cursor]);
        cursor += 1;
        if item_len == 0 || cursor + item_len > bytes.len() {
            return None;
        }
        let item = &bytes[cursor..cursor + item_len];
        cursor += item_len;
        let separator = item.iter().position(|byte| *byte == b'=');
        let (key, value) = match separator {
            Some(index) => (&item[..index], &item[index + 1..]),
            None => (item, &[][..]),
        };
        let key = std::str::from_utf8(key).ok()?.to_owned();
        if !valid_txt_key(&key) {
            return None;
        }
        properties.insert(key, String::from_utf8_lossy(value).into_owned());
    }
    Some(properties)
}

fn normalize_service_type(reg_type: &str, domain: &str) -> String {
    let reg_type = reg_type.trim_end_matches('.');
    let domain = domain.trim_matches('.');
    format!("{reg_type}.{domain}.")
}

fn normalize_hostname(host: &str) -> String {
    let host = host.trim_matches('.');
    if host.ends_with(".local") {
        format!("{host}.")
    } else {
        format!("{host}.local.")
    }
}

fn make_hostname(instance_name: &str) -> String {
    let mut label = instance_name
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '-' {
                character
            } else {
                '-'
            }
        })
        .collect::<String>();
    label = label.trim_matches('-').to_owned();
    if label.is_empty() {
        label.push_str("panecast-airplay");
    }
    label.truncate(63);
    format!("{label}.local.")
}

unsafe fn read_bounded_c_string(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    let bytes = unsafe { CStr::from_ptr(value) }.to_bytes();
    if bytes.len() > MAX_C_STRING_LEN {
        return None;
    }
    std::str::from_utf8(bytes).ok().map(ToOwned::to_owned)
}

unsafe fn write_txt_state(txt_record: *mut TXTRecordRef, state: *mut TxtState) {
    unsafe {
        clear_txt_ref(txt_record);
        ptr::write_unaligned(
            (*txt_record).private_data.as_mut_ptr().cast::<u64>(),
            state as u64,
        );
        ptr::write_unaligned(
            (*txt_record).private_data.as_mut_ptr().add(8).cast::<u64>(),
            TXT_STATE_MAGIC,
        );
    }
}

unsafe fn clear_txt_ref(txt_record: *mut TXTRecordRef) {
    unsafe { ptr::write_bytes((*txt_record).private_data.as_mut_ptr(), 0, 16) };
}

unsafe fn txt_state_ptr(txt_record: *const TXTRecordRef) -> Option<*mut TxtState> {
    if txt_record.is_null() {
        return None;
    }
    let (state, magic) = unsafe {
        (
            ptr::read_unaligned((*txt_record).private_data.as_ptr().cast::<u64>()),
            ptr::read_unaligned((*txt_record).private_data.as_ptr().add(8).cast::<u64>()),
        )
    };
    (state != 0 && magic == TXT_STATE_MAGIC).then_some(state as *mut TxtState)
}

unsafe fn txt_state(txt_record: *const TXTRecordRef) -> Option<&'static TxtState> {
    unsafe { txt_state_ptr(txt_record).map(|state| &*state) }
}

unsafe fn txt_state_mut(txt_record: *mut TXTRecordRef) -> Option<&'static mut TxtState> {
    unsafe { txt_state_ptr(txt_record).map(|state| &mut *state) }
}

unsafe fn take_txt_state(txt_record: *mut TXTRecordRef) -> Option<*mut TxtState> {
    let state = unsafe { txt_state_ptr(txt_record) };
    if !txt_record.is_null() {
        unsafe { clear_txt_ref(txt_record) };
    }
    state
}

fn ffi_error(action: impl FnOnce() -> DNSServiceErrorType) -> DNSServiceErrorType {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(action))
        .unwrap_or(DNS_SERVICE_ERR_UNKNOWN)
}

fn ffi_void(action: impl FnOnce()) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(action));
}

fn ffi_value<T>(fallback: T, action: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(action)).unwrap_or(fallback)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn empty_txt_ref() -> TXTRecordRef {
        TXTRecordRef {
            private_data: [0; 16],
        }
    }

    #[test]
    fn txt_record_encodes_and_replaces_values() {
        let mut record = empty_txt_ref();
        let key = CString::new("model").unwrap();
        let first = b"AppleTV3,2";
        let second = b"AppleTV6,2";
        unsafe {
            TXTRecordCreate(&mut record, 0, ptr::null_mut());
            assert_eq!(
                TXTRecordSetValue(
                    &mut record,
                    key.as_ptr(),
                    first.len() as u8,
                    first.as_ptr().cast()
                ),
                DNS_SERVICE_ERR_NO_ERROR
            );
            assert_eq!(
                TXTRecordSetValue(
                    &mut record,
                    key.as_ptr(),
                    second.len() as u8,
                    second.as_ptr().cast()
                ),
                DNS_SERVICE_ERR_NO_ERROR
            );
            let bytes = std::slice::from_raw_parts(
                TXTRecordGetBytesPtr(&record).cast::<u8>(),
                TXTRecordGetLength(&record) as usize,
            );
            assert_eq!(bytes, b"\x10model=AppleTV6,2");
            TXTRecordDeallocate(&mut record);
            assert_eq!(TXTRecordGetLength(&record), 0);
        }
    }

    #[test]
    fn txt_parser_rejects_truncated_items() {
        let bytes = [8_u8, b'a', b'=', b'b'];
        assert!(
            unsafe { parse_txt_properties(bytes.len() as u16, bytes.as_ptr().cast()) }.is_none()
        );
    }

    #[test]
    fn service_type_and_hostname_are_normalized() {
        assert_eq!(
            normalize_service_type("_airplay._tcp", "local."),
            "_airplay._tcp.local."
        );
        assert_eq!(normalize_hostname("receiver"), "receiver.local.");
        assert_eq!(make_hostname("客厅 Window"), "Window.local.");
    }

    #[test]
    fn invalid_txt_keys_are_rejected() {
        assert!(!valid_txt_key(""));
        assert!(!valid_txt_key("bad=key"));
        assert!(!valid_txt_key("控制"));
        assert!(valid_txt_key("srcvers"));
    }

    #[test]
    fn register_uses_network_byte_order_and_returns_an_owned_handle() {
        let name = CString::new("Panecast ABI Probe").unwrap();
        let service_type = CString::new("_panecast-probe._tcp").unwrap();
        let mut handle = ptr::null_mut();
        let result = unsafe {
            DNSServiceRegister(
                &mut handle,
                0,
                0,
                name.as_ptr(),
                service_type.as_ptr(),
                ptr::null(),
                ptr::null(),
                51_337_u16.to_be(),
                0,
                ptr::null(),
                None,
                ptr::null_mut(),
            )
        };
        assert_eq!(result, DNS_SERVICE_ERR_NO_ERROR);
        assert!(!handle.is_null());
        unsafe { DNSServiceRefDeallocate(handle) };
    }
}
