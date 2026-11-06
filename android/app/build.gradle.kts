import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 发布签名凭据 ───────────────────────────────────────────────────────────
// 从 android/key.properties 读。该文件与 keystore 本体都不进 git。
// CI 上在构建前把它从 secret 写出来；本地开发者各自放一份。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}

// 四项必须齐全。缺一项就当作完全没有 —— 半套凭据会让 AGP 报一个很难读的
// 错（或更糟：签出一个别人验不过的包），不如在这里一次判干净。
val hasReleaseSigning = listOf(
    "storeFile", "storePassword", "keyAlias", "keyPassword",
).all { !keystoreProps.getProperty(it).isNullOrBlank() }

// 开源贡献者没有发布密钥。传 -PallowDebugSigning=true 显式回落到 debug
// 签名 —— **显式**是关键：下面的守卫保留，静默回落才是要防的事。
val allowDebugSigning = project.hasProperty("allowDebugSigning") &&
    project.property("allowDebugSigning").toString().toBoolean()

android {
    namespace = "sh.flyterm.app"
    compileSdk = 36
    // 取所有插件要求里的最高版本：jni 与 speech_to_text 都要 28.2.13676358。
    // NDK 向后兼容，统一到最高版即可消除 Gradle 的版本冲突告警。
    //
    // 这个值不只给 AGP 用 —— 下面 buildAqtClientFfi 的 ANDROID_NDK_HOME 也从
    // 它推导（见 `val ndkVer = android.ndkVersion`），所以改它会连带把 Rust
    // 交叉编译切到同一个 NDK，两边不会再用不同版本的 libc++。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // flutter_local_notifications 硬性要求：它用了 java.time 等 API desugaring
        // 才能在 minSdk 24 上运行的 JDK 库。不开启的话 Gradle 直接拒绝构建
        // （"requires core library desugaring to be enabled"）。
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "sh.flyterm.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        setProperty("archivesBaseName", "flyterm-${flutter.versionName}")
    }

    signingConfigs {
        create("release") {
            // 凭据来自 android/key.properties，不再写死在本文件里 —— 本文件进
            // git，而上架密钥一旦泄进提交历史就很难清干净（删掉了历史里还在）。
            //
            // 密钥本体：android/app/flyterm-release.keystore
            //   RSA 4096 / SHA384withRSA / 10000 天 / CN=FlyTerm
            // 换密钥的窗口只有上架前这一次——进了 Google Play 就只能走 key
            // rotation。旧的那把（CN=AITerm，签 com.termiq.app 用）备份在
            // android/app/aiterm-release.keystore.bak。两者都不进 git。
            //
            // 缺凭据时这里留空，由下面的 packageRelease 守卫显式报错，
            // 而不是在这里静默回退成 debug 签名。
            if (hasReleaseSigning) {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (!hasReleaseSigning && allowDebugSigning) {
                signingConfigs.getByName("debug")
            } else {
                signingConfigs.getByName("release")
            }
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir("src/main/jniLibs")
        }
    }
}

// Build aqt_client_ffi Rust cdylib for Android ARM64 via cargo ndk subcommand
val cargoBinDir = file(System.getProperty("user.home")).resolve(".cargo/bin")
val cargoBinPath = cargoBinDir.absolutePath
val cargoExe = cargoBinDir.resolve("cargo").let {
    if (it.exists()) it.absolutePath else "cargo"
}
val cargoNdkPluginPath = cargoBinDir.resolve("cargo-ndk")

tasks.register<Exec>("buildAqtClientFfi") {
    description = "Build aqt_client_ffi Rust cdylib for Android ARM64"
    workingDir = file("../../rust/aqt_client_ffi")
    // Use "cargo ndk" (cargo subcommand invocation), not the binary directly
    commandLine(cargoExe, "ndk", "-o", "../../android/app/src/main/jniLibs", "-t", "arm64-v8a", "--", "build", "--release")

    // Augment PATH so cargo / rustup toolchains are found
    environment("PATH", "$cargoBinPath:${System.getenv("PATH") ?: ""}")
    // Propagate ANDROID_NDK_HOME; fall back to sdk.dir/ndk/<ndkVersion> from local.properties
    val ndkHome: String = System.getenv("ANDROID_NDK_HOME")
        ?: run {
            val localPropsFile = rootProject.file("local.properties")
            val sdkDir: String = if (localPropsFile.exists()) {
                val props = Properties()
                localPropsFile.inputStream().use { props.load(it) }
                props.getProperty("sdk.dir") ?: "/opt/android-sdk"
            } else {
                "/opt/android-sdk"
            }
            val ndkVer = android.ndkVersion
            "$sdkDir/ndk/$ndkVer"
        }
    environment("ANDROID_NDK_HOME", ndkHome)

    // cargo-ndk 缺失时怎么办，取决于 jniLibs 下有没有现成的 .so。
    //
    // **那个 .so 不进 git。** 它是编译产物；在一个 SSH 客户端的公开仓库里
    // 放一个无法与源码比对的预编译二进制，本身就是信任负担。更实际的危害
    // 是源码/二进制漂移：改过 rust/aqt_client_ffi/ 但没装 cargo-ndk 的人，
    // 会拿旧 .so 打出一个表面正常的包，没有任何提示。
    // （jniLibs/arm64-v8a/.gitkeep 保留 —— 目录要在，内容不要。）
    //
    // 三分支：
    //   有 cargo-ndk            → 重新编译，始终以源码为准
    //   没有，但本地已有 .so    → 警告后沿用（增量构建不必每次重编）
    //   两者都没有              → **明确失败**。产出一个缺原生库的 APK 比
    //                             构建失败糟得多 —— 它要到运行时才炸。
    // 注意：这里**只做布尔判断，不抛异常**。在 onlyIf 里抛 GradleException，
    // Gradle 只会显示 "Could not evaluate onlyIf predicate"，把你写的消息整个
    // 吞掉。硬失败交给下面独立的 verifyAqtNativeLib 任务。
    onlyIf {
        val haveCargoNdk = cargoNdkPluginPath.exists() || System.getenv("CARGO_NDK") != null
        if (!haveCargoNdk &&
            file("src/main/jniLibs/arm64-v8a/libaqt_client_ffi.so").exists()
        ) {
            logger.warn(
                "\n⚠  cargo-ndk 未安装，沿用 jniLibs 下已有的 libaqt_client_ffi.so。\n" +
                "⚠  若你改过 rust/aqt_client_ffi/，这个包里的原生库是**旧的**。\n" +
                "⚠  安装：cargo install cargo-ndk\n",
            )
        }
        haveCargoNdk
    }

    isIgnoreExitValue = false
}

// 硬失败守卫 —— 必须是独立任务，不能写在 buildAqtClientFfi 的 onlyIf 里
// （那样抛出的异常会被 Gradle 包成 "Could not evaluate onlyIf predicate"，
// 消息整个丢失，实测过）。
//
// 它要回答的问题只有一个：真正进包的那个 .so 到底在不在。无论
// buildAqtClientFfi 是跑了、跳过了、还是沿用了旧文件，这里都验最终结果。
tasks.register("verifyAqtNativeLib") {
    description = "Fail early if the AQT native library is missing from jniLibs"
    mustRunAfter("buildAqtClientFfi")
    doLast {
        val lib = file("src/main/jniLibs/arm64-v8a/libaqt_client_ffi.so")
        if (lib.exists()) return@doLast
        throw GradleException(
            """

            Missing native library: android/app/src/main/jniLibs/arm64-v8a/libaqt_client_ffi.so

            It is built from rust/aqt_client_ffi/ by cargo-ndk, and is not kept
            in git (a prebuilt binary nobody can diff against the source is a
            liability in an SSH client, and it lets the .so drift silently out
            of sync with the Rust source).

            Install the toolchain and build again:

                cargo install cargo-ndk
                rustup target add aarch64-linux-android

            缺少原生库。它由 cargo-ndk 从 rust/aqt_client_ffi/ 编译得到，不进
            git。装好上面两条再重新构建 —— 不拦住的话会产出一个运行时才崩的包。
            """.trimIndent(),
        )
    }
}

// buildAqtClientFfi 可能被 onlyIf 跳过，所以 preBuild 必须同时依赖校验任务。
tasks.named("preBuild") {
    dependsOn("buildAqtClientFfi", "verifyAqtNativeLib")
}

// ── Server assets: auto-rebuild on staleness ─────────────────────────────────
// Computes expected VERSION = <cargo_version>-<git short SHA of last commit
// touching rust/flyterm-server or rust/aqt_protocol>. If bundled VERSION
// mismatches, runs scripts/build-server-assets.sh automatically. The script
// itself is fast-path skip-if-fresh, so this hook is ~16ms on a cache hit.
//
// Flags (pass via `-P`):
//   -PskipServerRebuild   verify-only, fail-loud on mismatch (legacy / CI mode)
//   -PforceServerRebuild  call script with --force regardless of freshness
tasks.register("ensureServerAssetsFresh") {
    description = "Verify (and auto-rebuild) assets/flyterm-server/VERSION against current git HEAD"
    group = "verification"
    doLast {
        val versionFile = rootProject.file("../assets/flyterm-server/VERSION")
        val script = rootProject.file("../scripts/build-server-assets.sh")
        val cargoToml = rootProject.file("../rust/flyterm-server/Cargo.toml")
        val repoRoot = rootProject.file("..")
        val skipRebuild = project.hasProperty("skipServerRebuild")
        val forceRebuild = project.hasProperty("forceServerRebuild")

        // Expected SHA: last commit touching the rust crates that produce the
        // daemon binary. Pure Dart/doc changes don't shift this.
        val expectedSha: String? = try {
            val proc = ProcessBuilder(
                "git", "log", "-1", "--format=%h",
                "--", "rust/flyterm-server", "rust/aqt_protocol"
            ).directory(repoRoot).redirectErrorStream(true).start()
            proc.waitFor()
            if (proc.exitValue() == 0)
                proc.inputStream.bufferedReader().readText().trim().ifEmpty { null }
            else null
        } catch (_: Exception) { null }

        if (expectedSha == null) {
            println("NOTE: git not available; skipping server assets check")
            return@doLast
        }

        val cargoVersion = cargoToml.readLines()
            .firstOrNull { it.startsWith("version =") }
            ?.replace(Regex("""version\s*=\s*""""), "")
            ?.trim('"')
            ?: error("Could not parse version from Cargo.toml")
        val expected = "$cargoVersion-$expectedSha"
        val actual = if (versionFile.exists()) versionFile.readText().trim() else null

        val needsRebuild = forceRebuild || actual != expected
        if (!needsRebuild) {
            println("[ensureServerAssetsFresh] OK: $actual")
            return@doLast
        }

        if (skipRebuild) {
            throw GradleException(
                "\n╔══════════════════════════════════════════════════════════════╗\n" +
                "║  Server assets stale, -PskipServerRebuild was passed         ║\n" +
                "╠══════════════════════════════════════════════════════════════╣\n" +
                "║  Bundled:  ${actual ?: "(missing)"}\n" +
                "║  Expected: $expected\n" +
                "╠══════════════════════════════════════════════════════════════╣\n" +
                "║  Fix:  drop -PskipServerRebuild OR run                       ║\n" +
                "║        scripts/build-server-assets.sh manually               ║\n" +
                "╚══════════════════════════════════════════════════════════════╝"
            )
        }

        if (!script.exists()) {
            throw GradleException("build-server-assets.sh not found at $script")
        }
        println("[ensureServerAssetsFresh] rebuilding: ${actual ?: "(missing)"} → $expected")
        val args = mutableListOf("bash", script.absolutePath)
        if (forceRebuild) args += "--force"
        val proc = try {
            ProcessBuilder(args)
                .directory(repoRoot)
                .redirectErrorStream(true)
                .start()
        } catch (e: java.io.IOException) {
            throw GradleException(
                "Failed to spawn bash for build-server-assets.sh: ${e.message}\n" +
                "On Windows, run scripts/build-server-assets.sh via WSL,\n" +
                "or pass -PskipServerRebuild if assets are pre-built."
            )
        }
        proc.inputStream.bufferedReader().lineSequence().forEach { println("  $it") }
        proc.waitFor()
        if (proc.exitValue() != 0) {
            throw GradleException("build-server-assets.sh failed (exit ${proc.exitValue()})")
        }
        val newActual = if (versionFile.exists()) versionFile.readText().trim() else null
        if (newActual != expected) {
            throw GradleException(
                "build-server-assets.sh completed but VERSION still mismatched: " +
                "got '${newActual ?: "(missing)"}', expected '$expected'"
            )
        }
        println("[ensureServerAssetsFresh] OK after rebuild: $newActual")
    }
}

tasks.named("preBuild") {
    dependsOn("ensureServerAssetsFresh")
}
// ─────────────────────────────────────────────────────────────────────────────

flutter {
    source = "../.."
}

dependencies {
    // 配合上面的 isCoreLibraryDesugaringEnabled。版本跟随 flutter_local_notifications
    // 文档要求的下限（>= 2.1.4）。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// 缺签名凭据时让 release 打包**显式失败**。
//
// 不加这道守卫的话，signingConfig 留空会让 AGP 退回用 debug key 签名，或者
// 产出一个未签名包——两种结果都能一路跑到上架或分发给测试员才被发现，而那时
// 包已经装到别人机器上了。宁可在这里停下来。
tasks.configureEach {
    if (name.startsWith("package") && name.endsWith("Release")) {
        doFirst {
            if (hasReleaseSigning) return@doFirst
            if (allowDebugSigning) {
                logger.lifecycle(
                    "\n⚠  DEBUG-SIGNED BUILD — NOT FOR DISTRIBUTION\n" +
                    "⚠  调试签名包，不可分发。Android 的 debug keystore 是\n" +
                    "⚠  公开已知的固定密钥，任何人都能伪造「更新」。\n",
                )
                return@doFirst
            }
            throw GradleException(
                """
                Missing release signing credentials: ${keystorePropsFile.absolutePath}
                Required (all four): storeFile / storePassword / keyAlias / keyPassword
                The keystore itself lives under android/app/ (storeFile resolves
                relative to that directory). Neither file is in git.

                Building from source? Use debug signing instead:
                    ./gradlew assembleRelease -PallowDebugSigning=true
                    # or: scripts/build_apk.sh   (adds the flag automatically)

                缺少发布签名凭据。四项必须齐全。自行构建请改用：
                    scripts/build_apk.sh
                """.trimIndent(),
            )
        }
    }
}
