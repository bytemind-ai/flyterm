// SPDX-License-Identifier: GPL-3.0-or-later
/// End-to-end QUIC connectivity test via public C FFI.
///
/// Simulates exactly what the Android FFI client does:
///   aqt_connect → poll Connected → aqt_open_tab → poll TabOpened
///   → aqt_write_pty → poll PtyOutput containing "hello-quic"
use std::{
    ffi::CString,
    io::{BufRead, BufReader},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const TAB_TIMEOUT: Duration = Duration::from_secs(5);
const OUTPUT_TIMEOUT: Duration = Duration::from_secs(5);

// C FFI constants (match AqtEventKind repr in handle.rs)
const EVT_CONNECTED: u8 = 0;
const EVT_DISCONNECTED: u8 = 1;
const EVT_FAILED: u8 = 2;
const EVT_PTY_OUTPUT: u8 = 3;
const EVT_TAB_OPENED: u8 = 4;

fn main() {
    match run() {
        Ok(()) => {
            println!("\n✅  QUIC e2e: all steps passed.");
            std::process::exit(0);
        }
        Err(e) => {
            eprintln!("\n❌  QUIC e2e FAILED: {e}");
            std::process::exit(1);
        }
    }
}

fn poll_until(
    handle: *mut std::ffi::c_void,
    want: u8,
    timeout: Duration,
    label: &str,
) -> Result<(u32, Vec<u8>), String> {
    let deadline = Instant::now() + timeout;
    let mut data_buf = vec![0u8; 65536];
    loop {
        let mut kind: u8 = 255;
        let mut tab_id: u32 = 0;
        let mut data_len: usize = 0;
        let rc = unsafe {
            aqt_client_ffi::ffi::aqt_poll_event(
                handle,
                &mut kind,
                &mut tab_id,
                data_buf.as_mut_ptr(),
                data_buf.len(),
                &mut data_len,
            )
        };
        if rc == 0 {
            let data = data_buf[..data_len].to_vec();
            if kind == want {
                return Ok((tab_id, data));
            }
            if kind == EVT_FAILED {
                let reason = String::from_utf8_lossy(&data).to_string();
                return Err(format!("server sent Failed: {reason}"));
            }
            if kind == EVT_DISCONNECTED {
                return Err("server disconnected".to_string());
            }
            // Other events (ignored)
        }
        if Instant::now() > deadline {
            return Err(format!(
                "timeout waiting for {label} after {:.1}s",
                timeout.as_secs_f32()
            ));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn run() -> Result<(), String> {
    let bin = std::env::var("AQT_SERVER_BIN").unwrap_or_else(|_| {
        format!(
            "{}/.flyterm-server/bin/flyterm-server",
            std::env::var("HOME").unwrap_or_default()
        )
    });

    // ── Step 1: spawn server ──────────────────────────────────────────────
    println!("[1/6] Starting {}  --once ...", bin);
    let t0 = Instant::now();
    let mut server = Command::new(&bin)
        .args(["--once", "--bind", "0.0.0.0"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn failed: {e}"))?;

    // ── Step 2: parse bootstrap lines ────────────────────────────────────
    println!("[2/6] Parsing AQT_* lines ...");
    let stdout = server.stdout.take().unwrap();
    let reader = BufReader::new(stdout);
    let mut port = 0u16;
    let mut spki_b64 = String::new();
    let mut token_b64 = String::new();

    for line in reader.lines() {
        let l = line.map_err(|e| e.to_string())?;
        if l.starts_with("AQT_PORT=") {
            port = l[9..].trim().parse().unwrap_or(0);
        }
        if l.starts_with("AQT_PUBKEY=") {
            spki_b64 = l[11..].trim().to_string();
        }
        if l.starts_with("AQT_TOKEN=") {
            token_b64 = l[10..].trim().to_string();
        }
        if port > 0 && !spki_b64.is_empty() && !token_b64.is_empty() {
            break;
        }
    }
    if port == 0 {
        return Err("server did not print AQT_PORT".to_string());
    }
    println!(
        "    port={port} spki={}... token={}...",
        &spki_b64[..8.min(spki_b64.len())],
        &token_b64[..8.min(token_b64.len())]
    );

    // Decode base64
    let pad = |s: &str| -> String {
        let r = s.len() % 4;
        if r == 0 {
            s.to_string()
        } else {
            format!("{}{}", s, "=".repeat(4 - r))
        }
    };
    use base64::Engine;
    let engine = base64::engine::general_purpose::STANDARD;
    let spki = engine
        .decode(&pad(&spki_b64))
        .map_err(|e| format!("bad spki b64: {e}"))?;
    let token = engine
        .decode(&pad(&token_b64))
        .map_err(|e| format!("bad token b64: {e}"))?;
    if token.len() != 32 {
        return Err(format!("token must be 32 bytes, got {}", token.len()));
    }

    // ── Step 3: aqt_connect ───────────────────────────────────────────────
    println!("[3/6] aqt_connect to 127.0.0.1:{port} ...");
    let host_cstr = CString::new("127.0.0.1").unwrap();
    let sni_cstr = CString::new("aqt").unwrap();
    let params = aqt_client_ffi::ffi::AqtConnectParams {
        host: host_cstr.as_ptr(),
        port,
        spki_ptr: spki.as_ptr(),
        spki_len: spki.len(),
        token_ptr: token.as_ptr(),
        sni: sni_cstr.as_ptr(),
    };
    let mut handle: *mut std::ffi::c_void = std::ptr::null_mut();
    let rc = unsafe { aqt_client_ffi::ffi::aqt_connect(&params, &mut handle) };
    if rc != 0 {
        return Err(format!("aqt_connect returned {rc}"));
    }
    if handle.is_null() {
        return Err("aqt_connect returned null handle".to_string());
    }

    // ── Step 4: wait for Connected ────────────────────────────────────────
    println!("[4/6] Polling for Connected ...");
    poll_until(handle, EVT_CONNECTED, CONNECT_TIMEOUT, "Connected")?;
    println!("    ✓ Connected in {:.2}s", t0.elapsed().as_secs_f32());

    // ── Step 5: open tab ──────────────────────────────────────────────────
    println!("[5/6] aqt_open_tab (80×24) ...");
    let term_cstr = CString::new("xterm-256color").unwrap();
    let rc = unsafe { aqt_client_ffi::ffi::aqt_open_tab(handle, 80, 24, term_cstr.as_ptr()) };
    if rc != 0 {
        return Err(format!("aqt_open_tab returned {rc}"));
    }
    let (tab_id, _) = poll_until(handle, EVT_TAB_OPENED, TAB_TIMEOUT, "TabOpened")?;
    println!("    ✓ TabOpened tab_id={tab_id}");

    // ── Step 6: write + read echo ─────────────────────────────────────────
    println!("[6/6] Write 'echo hello-quic' + wait for output ...");
    let cmd = b"echo hello-quic\n";
    let rc = unsafe { aqt_client_ffi::ffi::aqt_write_pty(handle, tab_id, cmd.as_ptr(), cmd.len()) };
    if rc != 0 {
        return Err(format!("aqt_write_pty returned {rc}"));
    }

    // Collect PTY output until we see the echo
    let deadline = Instant::now() + OUTPUT_TIMEOUT;
    let mut collected = String::new();
    let mut data_buf = vec![0u8; 65536];
    loop {
        let mut kind: u8 = 255;
        let mut tid: u32 = 0;
        let mut dlen: usize = 0;
        let rc = unsafe {
            aqt_client_ffi::ffi::aqt_poll_event(
                handle,
                &mut kind,
                &mut tid,
                data_buf.as_mut_ptr(),
                data_buf.len(),
                &mut dlen,
            )
        };
        if rc == 0 && kind == EVT_PTY_OUTPUT {
            let s = String::from_utf8_lossy(&data_buf[..dlen]);
            collected.push_str(&s);
            if collected.contains("hello-quic") {
                println!("    ✓ Got PTY output containing 'hello-quic'");
                break;
            }
        }
        if kind == EVT_FAILED || kind == EVT_DISCONNECTED {
            return Err(format!("unexpected event {kind} while waiting for output"));
        }
        if Instant::now() > deadline {
            let preview: String = collected.chars().take(120).collect();
            return Err(format!("timeout. PTY output so far: {:?}", preview));
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    let total = t0.elapsed();
    unsafe { aqt_client_ffi::ffi::aqt_close(handle) };
    server.kill().ok();
    println!("\n  Total time: {:.2}s", total.as_secs_f32());
    Ok(())
}
