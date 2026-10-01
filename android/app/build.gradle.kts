import java.util.Base64
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ===== 读取本地 key.properties（该文件不入库，开源版自行填写）=====
val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.exists()) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

// ===== 内测版 / 公测版 的**桌面名称** =====
//
// 两条分发路线共用同一个 applicationId，因此**不能同时安装**，
// 桌面名必须能区分，否则用户根本分不清自己装的是哪一个。
//
// 判定顺序：
//   1. 显式传参 `-PbetaBuild=true`
//      （flutter build apk ... -PbetaBuild=true）
//   2. 自动识别：从 Flutter 传下来的 `dart-defines` 属性里找 INJECT_KEYS=true
//      （Flutter Gradle Plugin 会把 --dart-define 以 base64 塞进这个
//        project property，旧格式是逗号分隔的多个 base64，新格式是
//        整包一个 base64 —— 两种都试）
//   3. 都取不到 → 按公测版处理
//
// ⚠️ 默认方向必须是「公测版」：万一识别失败，宁可内测包少一个「内测」
//    字样，也绝不能把「内测」印在公开发布的包上。
val isBetaBuild: Boolean = run {
    if (project.findProperty("betaBuild") == "true") return@run true
    val raw = (project.findProperty("dart-defines") as String?).orEmpty()
    if (raw.isBlank()) return@run false

    // ⚠️ 这里必须用文件顶部 import 进来的 Base64 简名：
    //    Gradle 的 Kotlin DSL 里 `java` 是 java 扩展，写 `java.util.Base64`
    //    会被解析成 `java`(extension).util → Unresolved reference 'util'
    fun decode(token: String): String? = runCatching {
        String(Base64.getDecoder().decode(token.trim()), Charsets.UTF_8)
    }.getOrNull()

    // 新格式：整个字符串是一个 base64
    decode(raw)?.contains("INJECT_KEYS=true")?.let { if (it) return@run true }
    // 旧格式：逗号分隔的多个 base64
    raw.split(",").any { decode(it) == "INJECT_KEYS=true" }
}

println(
    "[build] 通道判定 isBetaBuild=$isBetaBuild -> 桌面名=" +
        if (isBetaBuild) "迹时天气·内测" else "迹时天气"
)

android {
    namespace = "com.lingxi.jishiweather"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17

        // ⚠️ flutter_local_notifications 需要 Java 8+ 的日期时间 API
        // （java.time 等），Android 低版本没有这些类，必须靠 desugaring 补齐。
        // 不开会直接构建失败：
        //   Dependency ':flutter_local_notifications' requires
        //   core library desugaring to be enabled
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lingxi.jishiweather"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26          // Android 8.0（用户确认）
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 高德地图 Key：从 key.properties 注入到 AndroidManifest 的 ${AMAP_KEY}
        manifestPlaceholders["AMAP_KEY"] = keyProperties.getProperty("AMAP_KEY") ?: ""

        // 桌面名：内测版 / 公测版（判定见文件顶部 isBetaBuild）
        manifestPlaceholders["appLabel"] =
            if (isBetaBuild) "迹时天气·内测" else "迹时天气"
    }

    // ===== 发布签名 =====
    //
    // 从 `android/key.properties` 读取（该文件不入库，见 .gitignore）。
    // **未配置发布密钥时回退到 debug 签名** —— 这样开源 clone 下来不填任何
    // 密钥也能 `flutter build apk --release`（代价是包用调试签名，仅供本地
    // 测试，不可上架）。
    //
    // 实测（2026-09-20，真机）：高德 Android Key 同时登记了「发布版 SHA1」
    // 与「调试版 SHA1」，因此改用正式 release.keystore 签名后，地图 SDK 与
    // 定位 SDK 均可正常使用（已逐项验证瓦片渲染与混合定位）。
    val hasReleaseKey = !keyProperties.getProperty("storeFile").isNullOrBlank()

    signingConfigs {
        if (hasReleaseKey) {
            create("releaseKey") {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("releaseKey")
            } else {
                signingConfigs.getByName("debug")
            }

            // ⚠️ 必须关闭代码混淆/资源压缩。
            // 高德地图的 native 引擎（libAMapOpenMap.so）在 onSurfaceCreated
            // 阶段用 JNI GetStaticMethodID 反射查找 Java 类；R8 一旦改动这些类，
            // JNI 查找失败会直接 art::Runtime::Abort → 进程 abort 闪退
            // （实测 tombstone: #05 GetStaticMethodID -> #06 libAMapOpenMap.so
            //  -> #20 oh.onSurfaceCreated）。
            isMinifyEnabled = false
            isShrinkResources = false
            // 即便将来开启混淆，也用下面这份 keep 规则兜底
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// 注：高德定位类（com.amap.api.location.*）已由 amap_map 插件依赖的
// 3dmap-location-search 提供，无需再加 com.amap.api:location（否则类重复）。

dependencies {
    // core library desugaring 的实现（配合上面 compileOptions 里的开关）
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
