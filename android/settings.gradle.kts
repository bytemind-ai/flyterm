pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Flutter 3.47 的最低要求就是 8.11.1，这里取的正是下限而不是最新版：
    // AGP 9.x 只读 newDsl，会让 flutter-gradle-plugin 直接 apply 失败
    // （gradle.properties 里的 android.newDsl=false 是配套的 opt-out）。
    // 配套约束：AGP 8.11 要求 Gradle >= 8.13，见 gradle-wrapper.properties。
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
