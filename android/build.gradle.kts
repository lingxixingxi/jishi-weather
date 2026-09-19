allprojects {
    repositories {
        // 国内镜像优先（显著加速依赖下载）
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// ===== 强制所有子项目（含插件）使用 compileSdk 36 =====
// 原因：amap_map 插件默认用 android-35 编译，而 flutter_plugin_android_lifecycle
// 要求依赖方 compileSdk ≥ 36，不覆盖会导致 checkDebugAarMetadata 失败。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        try {
            val method = androidExt.javaClass.getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
            method.invoke(androidExt, 36)
        } catch (_: Exception) {
            // 某些子项目没有该方法，忽略
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
