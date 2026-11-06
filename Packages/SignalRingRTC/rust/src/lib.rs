//! C ABI over ringrtc's native API for SignalSafe (a port of ringrtc's Electron binding,
//! src/rust/src/electron.rs, without Node).
//!
//! The ABI is designed so that Swift can call it without `unsafe`: endpoints are integer
//! handles, results are structs returned by value, and every buffer is a (pointer, length)
//! pair the header annotates `__counted_by(len) __noescape` (Swift imports those as `Span` /
//! `MutableSpan`). Nothing calls back into Swift: events are queued and handed out in
//! batches by `srr_wait_events`, which blocks (up to a timeout) on a thread the app owns.
//!
//! Commands and events are JSON (bytes as base64, 64-bit ids as strings); see commands.rs and
//! events.rs for the shapes. Video frames go through their own calls.

mod b64;
mod commands;
mod endpoint;
mod events;

use std::{
    collections::HashMap,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicU64, Ordering},
        mpsc::{Receiver, RecvTimeoutError},
    },
    time::Duration,
};

use endpoint::{CallEndpoint, Event};

/// `status`: 0 success (`length` bytes written), 1 failure (`length` bytes of UTF-8 error
/// written), 2 the output buffer was too small (`length` bytes needed; the result is kept
/// for `srr_take_pending`).
#[repr(C)]
pub struct SrrResult {
    pub status: i32,
    pub length: u64,
}

/// `status`: 0 a frame was written (`width` × `height` RGBA), 1 no new frame.
#[repr(C)]
pub struct SrrFrame {
    pub status: i32,
    pub width: u32,
    pub height: u32,
}

struct Handle {
    endpoint: Mutex<CallEndpoint>,
    events: Mutex<Receiver<Event>>,
    /// An event batch or command result that did not fit the caller's buffer.
    pending: Mutex<Option<Vec<u8>>>,
}

static ENDPOINTS: LazyLock<Mutex<HashMap<u64, Arc<Handle>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

fn handle(id: u64) -> Option<Arc<Handle>> {
    ENDPOINTS.lock().ok()?.get(&id).cloned()
}

/// # Safety
/// `ptr` must point to `len` readable bytes (or be null with `len` 0).
unsafe fn input<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(ptr, len) } }
}

/// # Safety
/// `ptr` must point to `cap` writable bytes (or be null with `cap` 0).
unsafe fn output<'a>(ptr: *mut u8, cap: usize) -> &'a mut [u8] {
    if ptr.is_null() || cap == 0 { &mut [] } else { unsafe { std::slice::from_raw_parts_mut(ptr, cap) } }
}

fn write(out: &mut [u8], bytes: Vec<u8>, status: i32, pending: Option<&Mutex<Option<Vec<u8>>>>) -> SrrResult {
    if bytes.len() <= out.len() {
        out[..bytes.len()].copy_from_slice(&bytes);
        SrrResult { status, length: bytes.len() as u64 }
    } else if let Some(p) = pending {
        let n = bytes.len() as u64;
        *p.lock().expect("pending") = Some(bytes);
        SrrResult { status: 2, length: n }
    } else {
        let n = bytes.len() as u64;
        SrrResult { status: 2, length: n }
    }
}

fn init_logging() {
    if log::set_logger(&endpoint::LOG).is_ok() {
        #[cfg(debug_assertions)]
        log::set_max_level(log::LevelFilter::Debug);
        #[cfg(not(debug_assertions))]
        log::set_max_level(log::LevelFilter::Info);
        #[cfg(debug_assertions)]
        ringrtc::webrtc::logging::set_logger(log::LevelFilter::Debug);
        #[cfg(not(debug_assertions))]
        ringrtc::webrtc::logging::set_logger(log::LevelFilter::Warn);
    }
}

/// `createCallEndpoint`. Returns 0 on failure.
///
/// # Safety
/// See `input`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn srr_endpoint_create(field_trials: *const u8, field_trials_len: usize) -> u64 {
    let trials = String::from_utf8_lossy(unsafe { input(field_trials, field_trials_len) }).into_owned();
    catch_unwind(|| {
        init_logging();
        match CallEndpoint::new(&trials) {
            Ok((endpoint, events)) => {
                let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
                let h = Arc::new(Handle { endpoint: Mutex::new(endpoint), events: Mutex::new(events), pending: Mutex::new(None) });
                ENDPOINTS.lock().expect("endpoints").insert(id, h);
                id
            }
            Err(e) => {
                log::error!("createCallEndpoint failed: {e}");
                0
            }
        }
    })
    .unwrap_or(0)
}

#[unsafe(no_mangle)]
pub extern "C" fn srr_endpoint_destroy(endpoint: u64) {
    let _ = catch_unwind(|| {
        ENDPOINTS.lock().expect("endpoints").remove(&endpoint);
    });
}

/// Runs a JSON command (`endpoint` may be 0 for the static ones) and writes its JSON result.
///
/// # Safety
/// See `input` / `output`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn srr_command(endpoint: u64, command: *const u8, command_len: usize, out: *mut u8, out_cap: usize) -> SrrResult {
    let command = unsafe { input(command, command_len) };
    let out = unsafe { output(out, out_cap) };
    let h = handle(endpoint);
    let result = catch_unwind(AssertUnwindSafe(|| -> anyhow::Result<serde_json::Value> {
        let cmd: commands::Command = serde_json::from_slice(command)?;
        if cmd.is_static() {
            return commands::run_static(cmd);
        }
        let h = h.as_ref().ok_or_else(|| anyhow::anyhow!("no such endpoint"))?;
        let mut ep = h.endpoint.lock().map_err(|_| anyhow::anyhow!("endpoint poisoned"))?;
        commands::run(&mut ep, cmd)
    }));
    match result {
        Ok(Ok(v)) => write(out, serde_json::to_vec(&v).unwrap_or_else(|_| b"null".to_vec()), 0, h.as_ref().map(|h| &h.pending)),
        Ok(Err(e)) => write(out, format!("{e:#}").into_bytes(), 1, None),
        Err(_) => write(out, b"panic".to_vec(), 1, None),
    }
}

/// The result that did not fit (status 2 earlier).
///
/// # Safety
/// See `output`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn srr_take_pending(endpoint: u64, out: *mut u8, out_cap: usize) -> SrrResult {
    let out = unsafe { output(out, out_cap) };
    let Some(h) = handle(endpoint) else { return SrrResult { status: 1, length: 0 } };
    let bytes = h.pending.lock().expect("pending").take();
    match bytes {
        Some(b) => write(out, b, 0, Some(&h.pending)),
        None => SrrResult { status: 1, length: 0 },
    }
}

/// Waits up to `timeout_ms` for events and writes them (and pending log messages) as a JSON
/// array; `[]` after a timeout.
///
/// # Safety
/// See `output`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn srr_wait_events(endpoint: u64, timeout_ms: u32, out: *mut u8, out_cap: usize) -> SrrResult {
    let out = unsafe { output(out, out_cap) };
    let Some(h) = handle(endpoint) else { return SrrResult { status: 1, length: 0 } };
    let result = catch_unwind(AssertUnwindSafe(|| -> Vec<u8> {
        if let Some(p) = h.pending.lock().expect("pending").take() {
            return p;
        }
        let mut batch = Vec::new();
        {
            let rx = h.events.lock().expect("events");
            match rx.recv_timeout(Duration::from_millis(timeout_ms as u64)) {
                Ok(e) => {
                    batch.push(e);
                    batch.extend(rx.try_iter());
                }
                Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => {}
            }
        }
        let mut ep = h.endpoint.lock().expect("endpoint");
        let json = events::to_json(&mut ep, batch);
        serde_json::to_vec(&json).unwrap_or_else(|_| b"[]".to_vec())
    }));
    match result {
        Ok(bytes) => write(out, bytes, 0, Some(&h.pending)),
        Err(_) => write(out, b"panic".to_vec(), 1, None),
    }
}

/// `sendVideoFrame`: `pixel_format` 0 I420, 1 NV12, 2 RGBA (ringrtc VideoPixelFormat).
/// Returns 0 on success.
///
/// # Safety
/// See `input`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn srr_send_video_frame(endpoint: u64, width: u32, height: u32, pixel_format: i32, data: *const u8, data_len: usize) -> i32 {
    let data = unsafe { input(data, data_len) };
    let Some(h) = handle(endpoint) else { return 1 };
    catch_unwind(AssertUnwindSafe(|| {
        let mut ep = h.endpoint.lock().expect("endpoint");
        match commands::send_video_frame(&mut ep, width, height, pixel_format, data) {
            Ok(()) => 0,
            Err(e) => {
                log::warn!("sendVideoFrame: {e}");
                1
            }
        }
    }))
    .unwrap_or(1)
}

/// `receiveVideoFrame` / `receiveGroupCallVideoFrame` (demux id 0 for a 1:1 call).
///
/// # Safety
/// See `output`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn srr_receive_video_frame(endpoint: u64, demux_id: u32, max_width: u32, max_height: u32, rgba: *mut u8, rgba_cap: usize) -> SrrFrame {
    let rgba = unsafe { output(rgba, rgba_cap) };
    let none = SrrFrame { status: 1, width: 0, height: 0 };
    let Some(h) = handle(endpoint) else { return none };
    catch_unwind(AssertUnwindSafe(|| {
        let mut ep = h.endpoint.lock().expect("endpoint");
        match commands::receive_video_frame(&mut ep, demux_id, max_width, max_height, rgba) {
            Some((w, h)) => SrrFrame { status: 0, width: w, height: h },
            None => none,
        }
    }))
    .unwrap_or(SrrFrame { status: 1, width: 0, height: 0 })
}
