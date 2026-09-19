package com.lingxi.jishiweather

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 高德定位 SDK 隐私合规（必须，否则 AMapLocationClient 初始化失败、定位不可用）
        // 说明：amap_flutter_location 插件未暴露这两个接口，官方要求在任何接口调用前设置。
        // 这里用反射调用，避免编译期依赖 —— 相关类由 amap_map 插件在运行时提供。
        applyAmapLocationPrivacy(this)
    }

    private fun applyAmapLocationPrivacy(context: Context) {
        try {
            val clazz = Class.forName("com.amap.api.location.AMapLocationClient")
            // updatePrivacyShow(Context, boolean isContains, boolean isShow)
            clazz.getMethod(
                "updatePrivacyShow",
                Context::class.java,
                Boolean::class.javaPrimitiveType,
                Boolean::class.javaPrimitiveType
            ).invoke(null, context, true, true)
            // updatePrivacyAgree(Context, boolean isAgree)
            clazz.getMethod(
                "updatePrivacyAgree",
                Context::class.java,
                Boolean::class.javaPrimitiveType
            ).invoke(null, context, true)
        } catch (e: Throwable) {
            // SDK 未就绪时忽略，不阻断启动
        }
    }
}
