// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

/// 路径面包屑：可横向滚动的路径段，点任一段跳到那一层。
///
/// 深路径下这是最省事的导航方式。长路径自动滚到最右段（当前目录）。
class SftpBreadcrumb extends StatefulWidget {
  const SftpBreadcrumb({
    super.key,
    required this.path,
    required this.onSegmentTap,
  });

  final String path;
  final ValueChanged<String> onSegmentTap;

  /// 把 `/var/log/nginx` 切成 `['/', 'var', 'log', 'nginx']` 并逐段累积成
  /// 可点击的绝对路径。
  static List<({String label, String path})> segmentsOf(String path) {
    if (path == '/' || path.isEmpty) {
      return const [(label: '/', path: '/')];
    }
    final out = <({String label, String path})>[(label: '/', path: '/')];
    var acc = '';
    for (final seg in path.split('/').where((s) => s.isNotEmpty)) {
      acc = '$acc/$seg';
      out.add((label: seg, path: acc));
    }
    return out;
  }

  @override
  State<SftpBreadcrumb> createState() => _SftpBreadcrumbState();
}

class _SftpBreadcrumbState extends State<SftpBreadcrumb> {
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _scheduleScrollToEnd();
  }

  @override
  void didUpdateWidget(SftpBreadcrumb old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _scheduleScrollToEnd();
  }

  /// 滚到最右（当前目录）。
  ///
  /// **必须有这一步。** 面包屑是横向可滚的，深路径下一屏只放得下前几段 ——
  /// 用户看到的是 `/`、`var`，而当前目录在屏幕外。他会去点屏幕上唯一看得见
  /// 的那段（往往正是**当前**段，而当前段按设计不可点），于是表现成
  /// 「点了面包屑没反应」。滚到末尾让「当前在哪」始终可见。
  void _scheduleScrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final segments = SftpBreadcrumb.segmentsOf(widget.path);
    // 路径已经是根时没有「上一级」可去。
    final canGoUp = widget.path != '/' && widget.path.isNotEmpty;
    final parentPath = canGoUp
        ? (widget.path.substring(0, widget.path.lastIndexOf('/')).isEmpty
              ? '/'
              : widget.path.substring(0, widget.path.lastIndexOf('/')))
        : null;

    return SizedBox(
      height: 28,
      child: Row(
        children: [
          // 常驻的「上一级」按钮：无论路径多深、面包屑滚到哪里，它都在。
          // 深路径下靠点面包屑里的父段不现实（父段可能被滚出屏幕），而这
          // 是最高频的导航动作。
          if (canGoUp)
            SizedBox(
              width: 32,
              child: InkWell(
                onTap: () => widget.onSegmentTap(parentPath!),
                child: const Center(
                  child: Icon(
                    Icons.arrow_upward,
                    size: 16,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView.separated(
              controller: _scrollCtrl,
              scrollDirection: Axis.horizontal,
              itemCount: segments.length,
              separatorBuilder: (_, __) => const Icon(
                Icons.chevron_right,
                size: 12,
                color: Colors.white24,
              ),
              itemBuilder: (ctx, i) {
                final seg = segments[i];
                final isLast = i == segments.length - 1;
                return InkWell(
                  onTap: isLast ? null : () => widget.onSegmentTap(seg.path),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        seg.label,
                        style: TextStyle(
                          fontSize: 13,
                          color: isLast ? Colors.white : Colors.white60,
                          fontWeight: isLast
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
