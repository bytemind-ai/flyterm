// SPDX-License-Identifier: GPL-3.0-or-later
fn main() {
    // Read SHA from rust/server-sha.txt written by build-server-assets.sh.
    // This file is the single source of truth for the server version SHA,
    // shared by build.rs (binary embed), VERSION asset, and Gradle check.
    //
    // Fallback: if the file is absent (e.g. direct `cargo test` without the
    // build script), compute the SHA using the same git scope as the script.
    let sha_file = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent() // rust/
        .unwrap()
        .join("server-sha.txt");

    let sha = std::fs::read_to_string(&sha_file)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            // Fallback: compute from git, same scope as the build script.
            std::process::Command::new("git")
                .args([
                    "log",
                    "-1",
                    "--format=%h",
                    "--",
                    "rust/flyterm-server/",
                    "rust/aqt_protocol/",
                ])
                .current_dir(
                    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                        .parent()
                        .unwrap() // rust/
                        .parent()
                        .unwrap(), // repo root
                )
                .output()
                .ok()
                .and_then(|o| String::from_utf8(o.stdout).ok())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "unknown".to_string())
        });

    println!("cargo:rustc-env=GIT_SHA={sha}");
    println!("cargo:rerun-if-changed=../server-sha.txt");
    println!("cargo:rerun-if-changed=src/");
    println!("cargo:rerun-if-changed=../../.git/HEAD");
}
