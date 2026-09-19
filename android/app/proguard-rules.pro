# ============================================================
# ProGuard / R8 规则 —— 迹时天气
# ============================================================
#
# ⚠️ 为什么必须有这个文件：
# 高德地图 SDK 的 native 引擎（libAMapOpenMap.so）在 GLSurfaceView
# 的 onSurfaceCreated 阶段会通过 JNI GetStaticMethodID 反射查找 Java 类。
# 如果 R8 把这些类混淆/删除，JNI 查找失败会直接触发 art::Runtime::Abort
# → 进程 abort 闪退（无 Java 异常栈，只有 tombstone）。
#
# 实测堆栈（release 包点击地图后崩溃）：
#   #05 art::JNI<false>::GetStaticMethodID
#   #06 libAMapOpenMap.so
#   #20 oh.onSurfaceCreated+58
#
# 所以：高德相关包必须全部 keep。

# ===== 高德地图 / 定位 / 搜索 官方规则 =====
-keep class com.amap.api.**{*;}
-keep class com.autonavi.**{*;}
-keep class com.loc.**{*;}
-keep class com.amap.api.col.**{*;}

-dontwarn com.amap.api.**
-dontwarn com.autonavi.**
-dontwarn com.loc.**

# 高德 SDK 内部用到的通用保留项
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# ===== amap_map 插件（本项目 fork）=====
-keep class com.amap.flutter.**{*;}

# ===== Flutter 引擎 =====
-keep class io.flutter.**{*;}
-dontwarn io.flutter.embedding.**

# ===== 保留 native 方法名（JNI 按名查找）=====
-keepclasseswithmembernames class * {
    native <methods>;
}

# ===== 保留注解与反射用到的成员 =====
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
