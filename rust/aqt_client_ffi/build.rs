// SPDX-License-Identifier: GPL-3.0-or-later
fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let out_dir = format!("{crate_dir}/include");
    std::fs::create_dir_all(&out_dir).ok();
    let target_h = format!("{out_dir}/aqt_client_ffi.h");
    let mut config = cbindgen::Config::default();
    config.language = cbindgen::Language::C;
    config.include_guard = Some("AQT_CLIENT_FFI_H".to_string());
    // cbindgen 默认跑 `cargo metadata --all-features`（不带 --filter-platform），
    // 会解析全 workspace 依赖图。Cargo.lock 里的 wit-bindgen 0.57.1 需要
    // edition2024（Rust 1.85+），而 rust-toolchain.toml 锁定 1.75 → metadata
    // 直接报错，header 静默不生成（旧版 .ok() 吞掉错误）。
    //
    // only_target_dependencies=true 会让 cbindgen 加 --filter-platform $TARGET
    // （build.rs 环境里 TARGET=aarch64-apple-ios），只解析当前 target 需要的
    // 依赖 —— iOS 路径不碰 wasi/wit-bindgen，绕开 edition2024 问题。
    config.only_target_dependencies = true;
    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
        .ok()
        .map(|b| b.write_to_file(target_h));
}
