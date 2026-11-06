# aqt_protocol fuzz

Requires nightly toolchain + cargo-fuzz:

```bash
rustup install nightly
cargo install cargo-fuzz
cd rust/aqt_protocol
cargo +nightly fuzz run frame_decode -- -max_total_time=60
```

Run for 60 s as a sanity check. Use `-max_total_time=3600` (1 h) before each major release.
