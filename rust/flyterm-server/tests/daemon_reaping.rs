// SPDX-License-Identifier: GPL-3.0-or-later
//! `--install` 必须收割所有旧 daemon，不只是 daemon.info 里那一个。
//!
//! 实测（2026-08-27）一台机器上有 4 个 daemon 同时在跑，3 个是孤儿，最久活了
//! 14 小时 43 分。根因：find_old_daemon 返回 Option<OldDaemon>，最多一个 ——
//! 它有 /proc cmdline 兜底，但 daemon.info 有效时走不到，兜底自身也是第一个
//! 匹配就 return。所以每次 --install 最多杀一个。

use flyterm_server::installer::reapable_pids;
use std::path::PathBuf;

#[test]
fn picks_processes_whose_exe_is_the_canonical_bin() {
    let canonical = PathBuf::from("/root/.flyterm-server/bin/flyterm-server");
    let entries = vec![
        (100, Some(canonical.clone())),
        (101, Some(PathBuf::from("/usr/bin/bash"))),
        (102, Some(canonical.clone())),
    ];
    let got = reapable_pids(&entries, &canonical, /* self_pid */ 999);
    assert_eq!(got, vec![100, 102]);
}

#[test]
fn never_reaps_self() {
    let canonical = PathBuf::from("/root/.flyterm-server/bin/flyterm-server");
    let entries = vec![
        (100, Some(canonical.clone())),
        (999, Some(canonical.clone())),
    ];
    let got = reapable_pids(&entries, &canonical, 999);
    assert_eq!(got, vec![100], "自己不能被收割");
}

#[test]
fn matches_renamed_binary_with_deleted_suffix() {
    // 原子替换是 rename，旧进程的 /proc/pid/exe 会变成
    // "<path> (deleted)"。那些进程正是最该被收割的。
    let canonical = PathBuf::from("/root/.flyterm-server/bin/flyterm-server");
    let entries = vec![(
        100,
        Some(PathBuf::from(
            "/root/.flyterm-server/bin/flyterm-server (deleted)",
        )),
    )];
    let got = reapable_pids(&entries, &canonical, 999);
    assert_eq!(got, vec![100]);
}

#[test]
fn ignores_unreadable_exe_links() {
    // 别人家的进程读不到 /proc/pid/exe（权限），readlink 返回 None。
    // 不认识就不杀 —— 宁可留孤儿，也不能误杀。
    let canonical = PathBuf::from("/root/.flyterm-server/bin/flyterm-server");
    let entries = vec![(100, None), (101, Some(canonical.clone()))];
    let got = reapable_pids(&entries, &canonical, 999);
    assert_eq!(got, vec![101]);
}

#[test]
fn empty_when_nothing_matches() {
    let canonical = PathBuf::from("/root/.flyterm-server/bin/flyterm-server");
    let entries = vec![(100, Some(PathBuf::from("/usr/bin/bash")))];
    assert!(reapable_pids(&entries, &canonical, 999).is_empty());
}
