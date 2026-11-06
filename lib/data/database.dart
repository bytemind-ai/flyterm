// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class AppDatabase {
  static const _dbName = 'flyterm.db';
  static const _dbVersion = 43;

  /// [overridePath] 让测试能在一个真实文件上跑升级路径（见
  /// `test/data/database_v38_test.dart`）。生产调用点一律不带它 ——
  /// 路径由 `getDatabasesPath()` 决定。
  static Future<Database> open({
    bool inMemory = false,
    String? overridePath,
  }) async {
    assert(!(inMemory && overridePath != null),
        'inMemory 与 overridePath 互斥');
    final path = overridePath ??
        (inMemory ? ':memory:' : join(await getDatabasesPath(), _dbName));
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        username TEXT NOT NULL,
        auth_type TEXT NOT NULL DEFAULT 'password',
        key_id TEXT,
        last_connected_at INTEGER,
        startup_command TEXT,
        use_tmux INTEGER NOT NULL DEFAULT 0,
        jump_host_id TEXT,
        mosh_port_range TEXT NOT NULL DEFAULT '60000:61000',
        mosh_pid INTEGER,
        group_name TEXT,
        agent_forwarding INTEGER NOT NULL DEFAULT 0,
        server_type TEXT NOT NULL DEFAULT 'ssh',
        address_family TEXT NOT NULL DEFAULT 'auto',
        connection_strategy TEXT NOT NULL DEFAULT 'quic',
        use_daemon INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE ssh_keys (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        public_key TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE ai_providers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        model TEXT NOT NULL,
        base_url TEXT,
        is_default INTEGER NOT NULL DEFAULT 0,
        extra_params TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE tunnels (
        id          TEXT    PRIMARY KEY,
        server_id   TEXT    NOT NULL,
        direction   TEXT    NOT NULL,
        local_port  INTEGER NOT NULL,
        remote_host TEXT    NOT NULL,
        remote_port INTEGER NOT NULL,
        label       TEXT    NOT NULL,
        auto_start  INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE tab_sessions (
        id             TEXT    PRIMARY KEY,
        server_id      TEXT    NOT NULL,
        tmux_key       TEXT    NOT NULL,
        position       INTEGER NOT NULL,
        is_active      INTEGER NOT NULL DEFAULT 0,
        sftp_last_path TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE favorite_commands (
        id         TEXT    PRIMARY KEY,
        name       TEXT    NOT NULL,
        command    TEXT    NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        ai_enabled INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE known_hosts (
        host             TEXT    NOT NULL,
        port             INTEGER NOT NULL,
        key_type         TEXT    NOT NULL,
        fingerprint_md5  TEXT    NOT NULL,
        first_seen       INTEGER NOT NULL,
        last_seen        INTEGER NOT NULL,
        PRIMARY KEY (host, port, key_type)
      )
    ''');
    await _createMoshProcessesTable(db);
    await db.execute('''
      CREATE TABLE agent_sessions (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id   TEXT NOT NULL,
        title       TEXT,
        archive     TEXT NOT NULL,
        event_count INTEGER NOT NULL,
        starred     INTEGER NOT NULL DEFAULT 0,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_agent_sessions_server
        ON agent_sessions(server_id, updated_at DESC)
    ''');
    await _createAqtSessionStateTable(db);
    await _createAgentSkillsTable(db);
    await _createServerNotesTable(db);
    await _createAgentSkillAssetsTable(db);
    await _createSftpPathsTable(db);
  }

  static Future<void> _createMoshProcessesTable(Database db) => db.execute('''
      CREATE TABLE IF NOT EXISTS mosh_processes (
        id TEXT PRIMARY KEY,
        server_id TEXT NOT NULL,
        tab_id TEXT,
        tmux_key TEXT,
        pid INTEGER NOT NULL,
        udp_port INTEGER,
        host TEXT NOT NULL,
        ssh_port INTEGER NOT NULL,
        username TEXT NOT NULL,
        port_range TEXT,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

  /// `AqtSessionStateRepository`（`lib/ssh/aqt/aqt_session_state.dart`）的
  /// 半张表——session token 那半留在 FlutterSecureStorage，不进这里。
  ///
  /// `server_ttl_secs` 存的是服务端在 ResumeAck 里下发的值，不是本地常量：
  /// 这张表要修的正是旧设计的坑——`AqtSessionStore`（Keychain 里存 JSON）
  /// 和 `scrollback_store.dart`（这里存屏幕内容）曾经各写各的 TTL 认知，
  /// 一侧改了另一侧没跟上（服务端 7 天 vs 客户端写死的 110 分钟）。
  static Future<void> _createAqtSessionStateTable(Database db) => db.execute('''
      CREATE TABLE IF NOT EXISTS aqt_session_state (
        tab_id TEXT PRIMARY KEY,
        -- QUIC 协议层的数字 tab id。RESUME 帧靠它点名恢复哪个 tab，
        -- 查不到服务端直接判 TabGone。是非敏感协议元数据，跟 port/spki
        -- 同类，所以放这里而不是 secure storage —— 后者是给凭据的，慢
        -- （Keychain/Keystore 走 IPC），而且两个 key 之间没有事务性：
        -- token 写成功而它写失败，就得到「有凭据但不知道恢复哪个 tab」。
        aqt_tab_id INTEGER NOT NULL DEFAULT 0,
        port INTEGER NOT NULL,
        spki BLOB NOT NULL,
        scrollback_cursor INTEGER NOT NULL DEFAULT 0,
        server_ttl_secs INTEGER,
        saved_at INTEGER NOT NULL
      )
    ''');

  static Future<void> _createAgentSkillsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS agent_skills (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL,
        description TEXT NOT NULL,
        body        TEXT NOT NULL,
        enabled     INTEGER NOT NULL DEFAULT 1,
        source      TEXT NOT NULL,
        updated_at  INTEGER NOT NULL,
        last_used_at INTEGER,
        hit_count   INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // NOCASE：`load_skill` 的匹配是大小写不敏感的，唯一约束必须用同一套
    // 折叠规则，否则 `Nginx` 和 `nginx` 能同时存在、而查询只找得到一个。
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_skills_name '
      'ON agent_skills(name COLLATE NOCASE)',
    );
  }

  /// 技能附件表。
  ///
  /// `skill_id` 外键，但**没有 ON DELETE CASCADE** —— SQLite 默认不开启
  /// foreign_keys pragma，级联不会生效；删除收口在
  /// `AgentSkillRepository.delete`（同事务显式删两表）。写了 `CASCADE` 反而
  /// 会造成“以为它会管”的错觉。
  ///
  /// `position` 而不是按 path 排序：附件在清单和详情页里的顺序应当稳定且
  /// 可控，按 path 排是“碰巧有序”，而 path 的字典序不是人理解的顺序。
  static Future<void> _createAgentSkillAssetsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS agent_skill_assets (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        skill_id   INTEGER NOT NULL,
        path       TEXT NOT NULL,
        content    TEXT NOT NULL,
        executable INTEGER NOT NULL DEFAULT 0,
        position   INTEGER NOT NULL DEFAULT 0,
        UNIQUE(skill_id, path)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_agent_skill_assets_skill '
      'ON agent_skill_assets(skill_id, position)',
    );
  }

  /// 目录历史 / 书签表。
  ///
  /// `(server_id, path)` 做主键而不是自增 id：同一台机器上的同一目录只该有
  /// 一条记录，重复访问是 upsert 而非追加。
  ///
  /// `pinned` 与 `last_used_at` 同表：书签（置顶）与历史本来就是一回事的两种
  /// 状态，拆表会让「先访问后置顶」需要跨表搬行。
  static Future<void> _createSftpPathsTable(Database db) async {
    // (server_id, path) 是主键 —— 同一台机器上同一目录只有一条记录，
    // 重复访问是 upsert 而不是追加。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sftp_paths (
        server_id TEXT NOT NULL,
        path TEXT NOT NULL,
        last_used_at INTEGER NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (server_id, path)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sftp_paths_recent '
      'ON sftp_paths (server_id, last_used_at DESC)',
    );
  }

  /// 跨机计划任务的两张表。
  ///
  /// **不声明 `ON DELETE CASCADE`**：sqflite 默认不开 `foreign_keys` pragma，
  /// 声明了也不会级联，留下的是一份永远查不到归属的孤儿 run 记录。级联在
  /// `ScheduledTaskRepository.delete` 里手写、用事务包起来 —— 与
  /// [_createAgentSkillAssetsTable] 和 `server_repository.dart` 的 `delete`
  /// 是同一条教训。
  ///
  /// 列名 / 值域必须与 `ScheduledTask.toMap()` 逐字对应（尤其 `kind` 与
  /// `catch_up_policy` 存的是 snake_case 字面量而不是 Dart 枚举名，见
  /// `scheduled_task.dart` 里 `_kindToDb` 的注释）。
  ///
  /// 外键列上**不建索引的是 `server_id`**：按服务器查计划目前没有调用点
  /// （列表页按 name 排、执行按 id 取），提前建是纯成本。`task_id` 则相反
  /// —— `runsFor` 每次看历史都要按它筛。
  ///
  /// **只给 `_onUpgrade` 的 v40 步骤用。** 表本身已于 v43 删除（见
  /// 2026-10-23 的移除设计），但历史迁移必须按顺序走完才能到 v43，
  /// 所以这个方法不能删。
  static Future<void> _createScheduledTasksTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_tasks (
        id                  TEXT PRIMARY KEY,
        server_id           TEXT,
        name                TEXT NOT NULL,
        kind                TEXT NOT NULL,
        schedule            TEXT NOT NULL,
        timezone            TEXT,
        command             TEXT,
        frozen_command      TEXT,
        intent              TEXT,
        authorized_at       INTEGER,
        permission_mode     TEXT NOT NULL,
        dynamic             INTEGER NOT NULL DEFAULT 0,
        enabled             INTEGER NOT NULL DEFAULT 1,
        catch_up_policy     TEXT NOT NULL DEFAULT 'run_late',
        last_run_at         INTEGER,
        last_status         TEXT,
        created_at          INTEGER NOT NULL,
        updated_at          INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_task_runs (
        id          TEXT PRIMARY KEY,
        task_id     TEXT NOT NULL,
        started_at  INTEGER NOT NULL,
        finished_at INTEGER,
        status      TEXT NOT NULL,
        exit_code   INTEGER,
        result_ref  TEXT,
        notified    INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_task_runs_task '
      'ON scheduled_task_runs (task_id, started_at DESC)',
    );
  }

  /// `ALTER TABLE … ADD COLUMN`，但列已经存在时静默跳过。
  ///
  /// ## 为什么裸 ALTER 在这里是个会让 app 打不开的 bug
  ///
  /// 建表函数（`_createScheduledTasksTables` 等）被**两处**共用：`_onCreate`
  /// 和它首次出现的那一步迁移。而它们写的是**当前**的 DDL —— 给表加一列时
  /// 顺手改了 DDL，那一步迁移从此就会建出带新列的表。
  ///
  /// 于是从更老的版本升级时：第 N 步建出带新列的表 → 第 N+k 步 ALTER 加同
  /// 一列 → `duplicate column name` → **整个 onUpgrade 抛异常，数据库打不开**。
  /// 跨度越大的升级越容易踩（恰恰是放久了才更新的用户）。
  ///
  /// 真实触发过一次：v39 → v42 在本仓库的测试里直接崩了。
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    if (cols.any((c) => c['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  /// 「我们往哪些机器的 crontab 里写过东西」。
  ///
  /// ## 为什么这件事必须被持久化
  ///
  /// 部署是 reconcile 语义：给某台机器一份「它该有的计划全集」，部署器把
  /// 远端的 flyterm 块对齐到这份全集 —— 全集为空就意味着把块摘干净。
  ///
  /// 问题在于「该去哪些机器」。如果从**剩下的计划**派生，那么用户删掉某台
  /// 机器上最后一条计划时，那台机器就从集合里消失了，于是永远不会被 reconcile
  /// —— 远端那条 cron 继续每天跑，而 app 端已经看不到它。用户既看不到也
  /// 删不掉，这正是 `ScheduledTaskRepository.delete` 想避免的「幽灵任务」。
  ///
  /// 所以「去哪些机器」不能从当前状态推导，必须记住历史。
  ///
  /// ## 为什么是一张表而不是让调用方传
  ///
  /// 删除路径有两个（agent 的 `delete_task`、列表页的删除按钮），停用路径
  /// 也有两个。让每个调用点自己记得把 serverId 传下来，就是四个能写错的
  /// 地方，而写错的后果是静默的。记在一处、由 `TaskScheduler.deployAll`
  /// 自己维护，调用点什么都不用知道。
  ///
  /// **只给 `_onUpgrade` 的 v41 步骤用。** 表本身已于 v43 删除（见
  /// 2026-10-23 的移除设计），但历史迁移必须按顺序走完才能到 v43，
  /// 所以这个方法不能删。
  static Future<void> _createDeployTargetsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_deploy_targets (
        server_id TEXT PRIMARY KEY
      )
    ''');
  }

  static Future<void> _createServerNotesTable(Database db) async {
    // server_id 直接做主键：一台机器一份笔记，天然唯一，不存在 agent_skills
    // 那种撞名问题，也就不需要额外的唯一索引。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS server_notes (
        server_id  TEXT PRIMARY KEY,
        body       TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ai_providers (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          model TEXT NOT NULL,
          base_url TEXT,
          is_default INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS tunnels (
          id          TEXT    PRIMARY KEY,
          server_id   TEXT    NOT NULL,
          direction   TEXT    NOT NULL,
          local_port  INTEGER NOT NULL,
          remote_host TEXT    NOT NULL,
          remote_port INTEGER NOT NULL,
          label       TEXT    NOT NULL,
          auto_start  INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE servers ADD COLUMN startup_command TEXT');
    }
    if (oldVersion < 5) {
      await db.execute(
        'ALTER TABLE servers ADD COLUMN use_tmux INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS tab_sessions (
          id        TEXT    PRIMARY KEY,
          server_id TEXT    NOT NULL,
          tmux_key  TEXT    NOT NULL,
          position  INTEGER NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 7) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS favorite_commands (
          id         TEXT    PRIMARY KEY,
          name       TEXT    NOT NULL,
          command    TEXT    NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 8) {
      await db.execute('ALTER TABLE ai_providers ADD COLUMN extra_params TEXT');
    }
    if (oldVersion < 9) {
      await db.execute('ALTER TABLE servers ADD COLUMN jump_host_id TEXT');
    }
    if (oldVersion < 10) {
      await db.execute(
        "ALTER TABLE servers ADD COLUMN use_mosh INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        "ALTER TABLE servers ADD COLUMN mosh_port_range TEXT NOT NULL DEFAULT '60000:61000'",
      );
    }
    if (oldVersion < 11) {
      await db.execute("ALTER TABLE servers ADD COLUMN mosh_pid INTEGER");
      await db.execute("ALTER TABLE servers ADD COLUMN group_name TEXT");
    }
    if (oldVersion < 12) {
      await db.execute(
        "ALTER TABLE servers ADD COLUMN agent_forwarding INTEGER NOT NULL DEFAULT 0",
      );
    }
    if (oldVersion < 13) {
      await db.execute(
        "ALTER TABLE servers ADD COLUMN server_type TEXT NOT NULL DEFAULT 'ssh'",
      );
    }
    if (oldVersion < 14) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS known_hosts (
          host             TEXT    NOT NULL,
          port             INTEGER NOT NULL,
          key_type         TEXT    NOT NULL,
          fingerprint_md5  TEXT    NOT NULL,
          first_seen       INTEGER NOT NULL,
          last_seen        INTEGER NOT NULL,
          PRIMARY KEY (host, port, key_type)
        )
      ''');
    }
    if (oldVersion < 15) {
      await db.execute(
        "ALTER TABLE servers ADD COLUMN address_family TEXT NOT NULL DEFAULT 'auto'",
      );
    }
    if (oldVersion < 16) {
      await _createMoshProcessesTable(db);
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.execute('''
        INSERT OR IGNORE INTO mosh_processes (
          id, server_id, tab_id, tmux_key, pid, udp_port, host, ssh_port,
          username, port_range, state, created_at, updated_at
        )
        SELECT
          'legacy-' || id || '-' || mosh_pid,
          id,
          NULL,
          NULL,
          mosh_pid,
          NULL,
          host,
          port,
          username,
          mosh_port_range,
          'pending_kill',
          $now,
          $now
        FROM servers
        WHERE mosh_pid IS NOT NULL
      ''');
      await db.execute(
        'UPDATE servers SET mosh_pid = NULL WHERE mosh_pid IS NOT NULL',
      );
    }
    if (oldVersion < 17) {
      await db.execute(
        "ALTER TABLE servers ADD COLUMN multiplexer_type TEXT NOT NULL DEFAULT 'none'",
      );
      await db.execute(
        "UPDATE servers SET multiplexer_type = 'tmux' WHERE use_tmux = 1",
      );
    }
    if (oldVersion < 18) {
      await db.execute(
        'ALTER TABLE servers ADD COLUMN shpool_configure_scrollback INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldVersion < 19) {
      await db.execute('''
        CREATE TABLE aqt_file_transfer_state (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          server_id    INTEGER NOT NULL,
          request_id   INTEGER NOT NULL,
          mode         INTEGER NOT NULL,
          local_path   TEXT NOT NULL,
          remote_path  TEXT NOT NULL,
          total_size   INTEGER NOT NULL,
          bytes_done   INTEGER NOT NULL,
          sha256_full  BLOB NOT NULL,
          status       INTEGER NOT NULL,
          updated_at   INTEGER NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_aqt_ft_server ON aqt_file_transfer_state(server_id)',
      );
    }
    if (oldVersion < 20) {
      await db.execute(
        "ALTER TABLE servers ADD COLUMN connection_strategy TEXT NOT NULL DEFAULT 'sshOnly'",
      );
    }
    if (oldVersion < 21) {
      await db.execute(
        "ALTER TABLE servers ADD COLUMN aqt_install_declined INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        "ALTER TABLE servers ADD COLUMN aqt_install_version TEXT",
      );
    }
    if (oldVersion < 22) {
      // shpool multiplexer removed (QUIC ring buffer covers its mobile-friendly
      // advantages; tmux covers process persistence with wider distro reach).
      // Migrate any existing 'shpool' rows to 'none'.
      await db.execute(
        "UPDATE servers SET multiplexer_type = 'none' WHERE multiplexer_type = 'shpool'",
      );
    }
    if (oldVersion < 23) {
      // Drop shpool_configure_scrollback column. v18+ upgraders have it; fresh
      // _onCreate v22 installs never did. SQLite < 3.35 (Android < 14) doesn't
      // support ALTER TABLE DROP COLUMN, so use the classic rebuild-and-rename
      // dance. SELECT clause omits the column entirely — works whether source
      // has it or not, so safe on both upgrade and idempotent re-run paths.
      await db.execute('''
        CREATE TABLE servers_new (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          host TEXT NOT NULL,
          port INTEGER NOT NULL DEFAULT 22,
          username TEXT NOT NULL,
          auth_type TEXT NOT NULL DEFAULT 'password',
          key_id TEXT,
          last_connected_at INTEGER,
          startup_command TEXT,
          use_tmux INTEGER NOT NULL DEFAULT 0,
          jump_host_id TEXT,
          use_mosh INTEGER NOT NULL DEFAULT 0,
          mosh_port_range TEXT NOT NULL DEFAULT '60000:61000',
          mosh_pid INTEGER,
          group_name TEXT,
          agent_forwarding INTEGER NOT NULL DEFAULT 0,
          server_type TEXT NOT NULL DEFAULT 'ssh',
          address_family TEXT NOT NULL DEFAULT 'auto',
          multiplexer_type TEXT NOT NULL DEFAULT 'none',
          connection_strategy TEXT NOT NULL DEFAULT 'sshOnly',
          aqt_install_declined INTEGER NOT NULL DEFAULT 0,
          aqt_install_version TEXT
        )
      ''');
      await db.execute('''
        INSERT INTO servers_new (
          id, name, host, port, username, auth_type, key_id,
          last_connected_at, startup_command, use_tmux, jump_host_id,
          use_mosh, mosh_port_range, mosh_pid, group_name,
          agent_forwarding, server_type, address_family, multiplexer_type,
          connection_strategy, aqt_install_declined, aqt_install_version
        )
        SELECT
          id, name, host, port, username, auth_type, key_id,
          last_connected_at, startup_command, use_tmux, jump_host_id,
          use_mosh, mosh_port_range, mosh_pid, group_name,
          agent_forwarding, server_type, address_family, multiplexer_type,
          connection_strategy, aqt_install_declined, aqt_install_version
        FROM servers
      ''');
      await db.execute('DROP TABLE servers');
      await db.execute('ALTER TABLE servers_new RENAME TO servers');
    }
    if (oldVersion < 24) {
      // Connection config redesign:
      // 4 strategies collapse to 3, drop dead columns.

      // 1. Dirty data: use_mosh=1 was historical source-of-truth even when
      //    connection_strategy stayed at default 'sshOnly'.
      await db.execute(
        "UPDATE servers SET connection_strategy = 'mosh' "
        "WHERE use_mosh = 1 AND connection_strategy = 'sshOnly'",
      );
      // 2. Collapse enum values
      await db.execute(
        "UPDATE servers SET connection_strategy = 'ssh' "
        "WHERE connection_strategy = 'sshOnly'",
      );
      await db.execute(
        "UPDATE servers SET connection_strategy = 'quic' "
        "WHERE connection_strategy IN ('quicFallbackSsh', 'quicOnly')",
      );
      // 3. multiplexer_type='tmux' → use_tmux=1 (master-era source-of-truth)
      await db.execute(
        "UPDATE servers SET use_tmux = 1 WHERE multiplexer_type = 'tmux'",
      );
      // 4. Rebuild dance: drop use_mosh / multiplexer_type /
      //    aqt_install_declined / aqt_install_version columns.
      //    Required because Android < 14 system SQLite < 3.35 doesn't
      //    support ALTER TABLE DROP COLUMN.
      await db.execute('''
        CREATE TABLE servers_new (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          host TEXT NOT NULL,
          port INTEGER NOT NULL DEFAULT 22,
          username TEXT NOT NULL,
          auth_type TEXT NOT NULL DEFAULT 'password',
          key_id TEXT,
          last_connected_at INTEGER,
          startup_command TEXT,
          use_tmux INTEGER NOT NULL DEFAULT 0,
          jump_host_id TEXT,
          mosh_port_range TEXT NOT NULL DEFAULT '60000:61000',
          mosh_pid INTEGER,
          group_name TEXT,
          agent_forwarding INTEGER NOT NULL DEFAULT 0,
          server_type TEXT NOT NULL DEFAULT 'ssh',
          address_family TEXT NOT NULL DEFAULT 'auto',
          connection_strategy TEXT NOT NULL DEFAULT 'quic'
        )
      ''');
      await db.execute('''
        INSERT INTO servers_new (
          id, name, host, port, username, auth_type, key_id,
          last_connected_at, startup_command, use_tmux, jump_host_id,
          mosh_port_range, mosh_pid, group_name, agent_forwarding,
          server_type, address_family, connection_strategy
        )
        SELECT
          id, name, host, port, username, auth_type, key_id,
          last_connected_at, startup_command, use_tmux, jump_host_id,
          mosh_port_range, mosh_pid, group_name, agent_forwarding,
          server_type, address_family, connection_strategy
        FROM servers
      ''');
      await db.execute('DROP TABLE servers');
      await db.execute('ALTER TABLE servers_new RENAME TO servers');
    }
    if (oldVersion < 25) {
      // QUIC daemon-strict mode opt-in. Default 0 (existing once-only behavior).
      await db.execute(
        "ALTER TABLE servers ADD COLUMN use_daemon INTEGER NOT NULL DEFAULT 0",
      );
    }
    if (oldVersion < 26) {
      // Persist last SFTP browsing path per server so the inline SFTP view
      // reopens at the same directory after app restart.
      await db.execute(
        "ALTER TABLE servers ADD COLUMN sftp_last_path TEXT",
      );
    }
    if (oldVersion < 27) {
      // Persist last view mode (0=terminal, 1=sftp) so the tab reopens in
      // the same view after app restart.
      await db.execute(
        "ALTER TABLE servers ADD COLUMN sftp_view_mode INTEGER NOT NULL DEFAULT 0",
      );
    }
    if (oldVersion < 28) {
      // Move SFTP state to tab_sessions (per-tab) to fix multi-tab collision.
      await db.execute(
        "ALTER TABLE tab_sessions ADD COLUMN sftp_last_path TEXT",
      );
      await db.execute(
        "ALTER TABLE tab_sessions ADD COLUMN sftp_view_mode INTEGER NOT NULL DEFAULT 0",
      );
    }
    if (oldVersion < 29) {
      // Remove unused columns:
      //   servers.sftp_last_path  (v26 — superseded by tab_sessions.sftp_last_path)
      //   servers.sftp_view_mode  (v27 — viewMode persistence reverted)
      //   tab_sessions.sftp_view_mode  (v28 — viewMode persistence reverted)
      // SQLite < 3.35 (Android < 14) has no ALTER TABLE DROP COLUMN — use
      // the standard rebuild-dance.
      await db.execute('''
        CREATE TABLE servers_new (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          host TEXT NOT NULL,
          port INTEGER NOT NULL DEFAULT 22,
          username TEXT NOT NULL,
          auth_type TEXT NOT NULL DEFAULT 'password',
          key_id TEXT,
          last_connected_at INTEGER,
          startup_command TEXT,
          use_tmux INTEGER NOT NULL DEFAULT 0,
          jump_host_id TEXT,
          mosh_port_range TEXT NOT NULL DEFAULT '60000:61000',
          mosh_pid INTEGER,
          group_name TEXT,
          agent_forwarding INTEGER NOT NULL DEFAULT 0,
          server_type TEXT NOT NULL DEFAULT 'ssh',
          address_family TEXT NOT NULL DEFAULT 'auto',
          connection_strategy TEXT NOT NULL DEFAULT 'quic',
          use_daemon INTEGER NOT NULL DEFAULT 1
        )
      ''');
      await db.execute('''
        INSERT INTO servers_new (
          id, name, host, port, username, auth_type, key_id,
          last_connected_at, startup_command, use_tmux, jump_host_id,
          mosh_port_range, mosh_pid, group_name, agent_forwarding,
          server_type, address_family, connection_strategy, use_daemon
        )
        SELECT
          id, name, host, port, username, auth_type, key_id,
          last_connected_at, startup_command, use_tmux, jump_host_id,
          mosh_port_range, mosh_pid, group_name, agent_forwarding,
          server_type, address_family, connection_strategy, use_daemon
        FROM servers
      ''');
      await db.execute('DROP TABLE servers');
      await db.execute('ALTER TABLE servers_new RENAME TO servers');
      // tab_sessions: drop sftp_view_mode, keep sftp_last_path.
      await db.execute('''
        CREATE TABLE tab_sessions_new (
          id             TEXT    PRIMARY KEY,
          server_id      TEXT    NOT NULL,
          tmux_key       TEXT    NOT NULL,
          position       INTEGER NOT NULL,
          is_active      INTEGER NOT NULL DEFAULT 0,
          sftp_last_path TEXT
        )
      ''');
      await db.execute('''
        INSERT INTO tab_sessions_new (
          id, server_id, tmux_key, position, is_active, sftp_last_path
        )
        SELECT
          id, server_id, tmux_key, position, is_active, sftp_last_path
        FROM tab_sessions
      ''');
      await db.execute('DROP TABLE tab_sessions');
      await db.execute('ALTER TABLE tab_sessions_new RENAME TO tab_sessions');
    }
    if (oldVersion < 30) {
      // Default `use_daemon` flipped from 0 → 1 for QUIC servers so cold
      // start (app kill → reopen) actually recovers the session. Once mode
      // (use_daemon=0) ties the server process to the SSH channel — when
      // the app closes, SSH closes, SIGHUP kills the server, the PTY dies,
      // and cold-RESUME has no source. Daemon mode runs setsid+nohup so
      // the server survives app close and the PTY keeps running.
      //
      // Migration: existing QUIC servers with use_daemon=0 (almost
      // certainly the default, not an explicit user choice — until now
      // the form's checkbox defaulted to off) are flipped to 1. Users who
      // explicitly want clean teardown can re-toggle via the server form.
      // Non-QUIC servers (SSH / Mosh) ignore the field — leave as-is.
      await db.execute(
        "UPDATE servers SET use_daemon = 1 "
        "WHERE connection_strategy = 'quic' AND use_daemon = 0",
      );
    }
    if (oldVersion < 31) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS agent_sessions (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          server_id   TEXT NOT NULL,
          title       TEXT,
          archive     TEXT NOT NULL,
          event_count INTEGER NOT NULL,
          starred     INTEGER NOT NULL DEFAULT 0,
          created_at  INTEGER NOT NULL,
          updated_at  INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_agent_sessions_server
          ON agent_sessions(server_id, updated_at DESC)
      ''');
    }
    if (oldVersion < 32) {
      // 不迁移 AqtSessionStore（Keychain 里的旧 session JSON）的数据：
      // 会话恢复协议本身破坏兼容（QUIC 会话恢复重新设计），
      // 旧 token 对新服务端必然无效，搬过来只会让第一次连接白试一次注定失败
      // 的 RESUME。旧数据留在原处，随 AqtSessionStore 的移除一起
      // 清理（Keychain 条目本身不受 DB 版本管理）。
      await _createAqtSessionStateTable(db);
    }
    if (oldVersion < 33) {
      // scrollback 快照格式换代（同属 QUIC 会话恢复重新设计）：
      // ringOff/ringHash（byte offset 语义）+ cols 换成 headLine（行号语义）。这里没有 SQL 要跑——快照本身是
      // `scrollback_store.dart` 管理的磁盘文件（`<支持目录>/scrollback/`），
      // 不在 sqlite 表里，DB 版本号在这一步纯粹是记录一次格式换代的落地
      // 时点，与 v32 的处理方式保持一致的记账习惯。
      //
      // 旧快照不迁移：ringOff 对新协议（服务端按行号索引 scrollback）没有
      // 意义，搬不动。实际的失效机制在 scrollback_store.dart 里——
      // `_kFormatVersion` 同步提到 2，v1 快照解码时 version 不符直接返回
      // null（fail-open），等价于"这个 tab 没有快照"：用户冷启动那一次
      // 历史是空的，可接受，之后正常写盘的都是新格式。
    }
    if (oldVersion < 34) {
      await _createAgentSkillsTable(db);
    }
    if (oldVersion < 35) {
      // DEFAULT 0 不可改成 1：见 FavoriteCommand.aiEnabled 的说明。用户已有
      // 的收藏不该因为一次版本升级就全部对 AI 开放。
      await db.execute(
        'ALTER TABLE favorite_commands '
        'ADD COLUMN ai_enabled INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 36) {
      // last_used_at 可空：null 与 0 在排序里含义不同 —— 前者是「从未用过」，
      // 后者会被读成 1970 年用过一次。NOT NULL DEFAULT 0 会让所有存量 skill
      // 看起来都「用过」，正好毁掉这一列存在的意义。
      await db.execute(
        'ALTER TABLE agent_skills ADD COLUMN last_used_at INTEGER',
      );
      await db.execute(
        'ALTER TABLE agent_skills ADD COLUMN hit_count INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 37) {
      // 只建表。prefs 里那批旧的 AGENTS.md 缓存副本由
      // `ServerNotesManager.migrateFromPrefs()` 搬 —— 这一层拿不到
      // SharedPreferences，也不该为此引入那个依赖。
      await _createServerNotesTable(db);
    }
    if (oldVersion < 38) {
      // 只建表。存量技能自然都是「无附件」—— 附件是可选的，没有迁移动作。
      await _createAgentSkillAssetsTable(db);
    }
    if (oldVersion < 39) {
      // 只建空表、不回填 —— 升级前用户浏览过哪些目录没有任何地方记录过，
      // 唯一能拿到的是 tab_sessions.sftp_last_path（每个 tab 一条），数量
      // 太少不值得为它写迁移。
      await _createSftpPathsTable(db);
    }
    if (oldVersion < 40) {
      // 只建空表、不回填：v40 之前压根没有计划任务这个概念，无源可迁。
      // 已经在远端 crontab 里手写了定时任务的用户不会自动被接管 —— 那需要
      // 解析既有 crontab 猜意图，猜错的代价是重复执行一条写操作。
      await _createScheduledTasksTables(db);
    }
    if (oldVersion < 41) {
      // 回填成「所有当前有计划的机器」：升级前它们的 crontab 里确实已经
      // 写进去了 flyterm 的块，而这张表的用途正是「将来还要去摘」。不回填
      // 的话，v40 时期建的计划一旦被删，那条 cron 就再也没人去摘了。
      await _createDeployTargetsTable(db);
      await db.execute(
        'INSERT OR IGNORE INTO scheduled_deploy_targets (server_id) '
        'SELECT DISTINCT server_id FROM scheduled_tasks '
        'WHERE server_id IS NOT NULL',
      );
    }
    if (oldVersion < 42) {
      // `frozen_command` 把「当前要跑的命令」与「用户批准的那串字符」拆成
      // 两列 —— 只有一列时执行前的逐字节比对恒等于通过，整套冻结机制是
      // 摆设（见 `ScheduledTask.frozenCommand` 的论证）。
      await _addColumnIfMissing(
          db, 'scheduled_tasks', 'frozen_command', 'TEXT');
      // 只回填**已授权**的行。那些行的 command 在 v41 时期就是冻结快照
      // （两条写入路径都只在批准之后才写它），不回填它们就会在升级后全部
      // 被判成 notFrozen 而停跑 —— 用户昨天还在跑的备份今天静悄悄没了。
      //
      // 未授权的行**不碰**：给一条从没批准过的计划配一份冻结快照，就是
      // 凭空伪造一份授权记录。
      await db.execute(
        'UPDATE scheduled_tasks SET frozen_command = command '
        'WHERE authorized_at IS NOT NULL',
      );
    }
    if (oldVersion < 43) {
      // 移除跨机计划任务（2026-10-23）。三张表 + 一个索引整体删掉。
      //
      // **上面 v40/v41/v42 三步不能删** —— 从 v39 升上来必须按顺序走完
      // 才能到这里。中间白建白回填一次，无害；删掉那几步反而会让老库在
      // v42 那步 ALTER 一个不存在的表时崩掉。
      //
      // `IF EXISTS` 不是防御性冗余：新装的库走 `_onCreate` 到 43，这三张
      // 表从不存在；而手工降级过的库也可能缺其中一张。
      await db.execute('DROP INDEX IF EXISTS idx_task_runs_task');
      await db.execute('DROP TABLE IF EXISTS scheduled_task_runs');
      await db.execute('DROP TABLE IF EXISTS scheduled_deploy_targets');
      await db.execute('DROP TABLE IF EXISTS scheduled_tasks');
    }
  }
}
