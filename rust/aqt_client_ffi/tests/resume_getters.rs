// SPDX-License-Identifier: GPL-3.0-or-later
//! FFI 只暴露「服务端说了什么」，不暴露任何需要客户端做算术的量。

#[test]
fn no_offset_getters_remain() {
    // 这两个符号存在的唯一目的，是让 Dart 侧算
    // `server_out_off - replay_bytes` 去反推「服务端是续传还是重建」。
    // 那个判据在服务端一改语义时静默失效（d7dc3ef → e382759）。
    //
    // 用源码断言而不是符号表：它们一旦复活就说明有人又在重建那个推断，
    // 而这正是本次重新设计要根除的东西。
    // 匹配**定义**而不是任何提及 —— 注释里写明「这里曾经是 xxx，为什么
    // 删掉」是有价值的，不该被这条断言禁掉。
    let src = include_str!("../src/ffi.rs");
    for banned in [
        "aqt_get_last_resume_server_out_off",
        "aqt_get_last_resume_replay_bytes",
    ] {
        assert!(
            !src.contains(&format!("fn {banned}")),
            "{banned} 的定义应当已被删除"
        );
    }

    let handle_src = include_str!("../src/handle.rs");
    for banned in ["last_resume_server_out_off", "last_resume_replay_bytes"] {
        // 注释里提到它们是可以的（说明为什么删），字段定义不行。
        assert!(
            !handle_src.contains(&format!("pub {banned}")),
            "{banned} 字段应当已被删除"
        );
    }
}

#[test]
fn disposition_codes_are_stable() {
    // Dart 侧按这些数值分派，改动会让它静默走错分支。
    assert_eq!(aqt_client_ffi::ffi::DISPOSITION_NONE, 0);
    assert_eq!(aqt_client_ffi::ffi::DISPOSITION_RESTORED, 1);
    assert_eq!(aqt_client_ffi::ffi::DISPOSITION_NEW_SESSION, 2);
    assert_eq!(aqt_client_ffi::ffi::DISPOSITION_TAB_GONE, 3);
}

#[test]
fn getters_are_null_safe() {
    // Dart 侧可能在 handle 还没建立时就问 —— 不能崩，返回中性值。
    unsafe {
        assert_eq!(
            aqt_client_ffi::ffi::aqt_get_resume_disposition(std::ptr::null()),
            aqt_client_ffi::ffi::DISPOSITION_NONE
        );
        assert_eq!(
            aqt_client_ffi::ffi::aqt_get_resume_in_seen_off(std::ptr::null()),
            0
        );
        let mut has: u8 = 9;
        assert_eq!(
            aqt_client_ffi::ffi::aqt_get_resume_exit_status(std::ptr::null(), &mut has),
            0
        );
        assert_eq!(has, 0, "拿不到时必须把 has_status 写成 0");
    }
}
