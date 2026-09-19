# 迹时天气 (jishiweather)

> 本地化出行天气研判 —— 航空级多源聚合天气简报，**纯本地计算**，不依赖任何自建服务器。

输入出发地 / 目的地 / 时间，沿你**实际要走的路线**逐段研判天气：哪段有雨、几点下、路面湿滑风险，给出绿 / 黄 / 红出行建议。

## 功能（v0.1 · 开发中）

- **地点查询**：方圆 10km 区域天气（中心 + 4 方位采样点交叉验证），区域最高/最低温、降水概率
- **出行路线**：高德规划返回**多条候选路线** → 由你选定实际要走的那条 → 每 10km 采样 → 按到达时刻取天气 → 天气突变点自动切段 → 逐段研判 + 整体建议等级
- **使用当前位置**：一键定位（室内信号弱时有超时兜底）

规划中：赛道湿滑研判、摄影指数（火烧云/星空）、台风研判。

## 数据源（均免 key 或用户自备 key）

| 数据源 | 用途 | Key | 实测 |
|---|---|---|---|
| [Open-Meteo](https://open-meteo.com/) | 逐小时气象（主源，含 ECMWF/GFS/ICON 多模型） | 免 key | ✅ |
| [中央气象台台风网](http://typhoon.nmc.cn/) | 台风路径 + 多机构预报（国内直连，响应 ~0.1s） | 免 key | ✅ |
| [高德开放平台](https://lbs.amap.com/) | 地理编码、驾车路线规划、地图显示 | **需自备** | ✅ |

> 高德需要两个 Key：**Web服务**（地理编码/路线规划）和 **Android 平台**（地图 SDK）。

## 技术栈

- **Flutter**（Dart）原生 UI，深色航空驾驶舱风格 + 琥珀 accent
- **纯本地引擎**：研判逻辑用 Dart 实现，无后端依赖
- 高德地图 Android SDK（`amap_map`）
- 最低支持 **Android 8.0 (API 26)**

## 快速开始

### 1. 环境

- Flutter 3.x（本项目用 3.47.4 开发）
- JDK 17
- Android SDK（compileSdk 36）

```bash
flutter doctor
```

### 2. 配置 Key（必须，否则高德功能不可用）

```bash
cp android/key.properties.example android/key.properties
cp lib/config/secrets.example.dart lib/config/secrets.dart
```

然后填入你自己的高德 Key：

- `android/key.properties` → `AMAP_KEY=`（Android 平台 Key）
- `lib/config/secrets.dart` → `amapWebKey`（Web服务 Key）、`amapAndroidKey`

**申请 Android 平台 Key 需要**（用 `keytool` 获取 SHA1）：

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android
```

- PackageName：`com.lingxi.jishiweather`
- 发布版 SHA1：来自你的发布 keystore
- 调试版 SHA1：来自 `~/.android/debug.keystore`

### 3. 构建

```bash
flutter pub get
flutter build apk --debug     # 调试包
flutter build apk --release   # 发布包（需配置签名）
```

> 国内网络建议配置镜像加速：Gradle 发行包用腾讯云镜像、Maven 用阿里云镜像（见 `android/settings.gradle.kts`）。

## 项目结构

```
lib/
├── main.dart                  应用入口
├── theme/app_theme.dart       深色航空风主题
├── models/hourly_weather.dart 统一小时气象模型
├── services/
│   ├── open_meteo.dart        Open-Meteo 客户端（多模型）
│   ├── amap_service.dart      高德：地理编码 / 多路线规划 / 沿途采样
│   └── nmc_service.dart       中央气象台：台风列表/详情、站点实况
├── engine/route_analyzer.dart 研判引擎：到达时刻取值 / 分段 / 绿黄红分级
└── screens/
    ├── home_screen.dart       底部导航外壳
    ├── location_screen.dart   地点查询
    └── route_screen.dart      出行路线（含多路线选择）
```

## 隐私

- 定位数据仅用于本地天气查询，**不上传**
- 无账号系统、无埋点统计
- 高德 SDK 合规：地图初始化遵循高德隐私合规要求

## 许可

**Business Source License 1.1**（见 [LICENSE](LICENSE)）

- ✅ 个人、教育、研究、评估用途**免费**
- ⚠️ **生产环境使用、商业使用、或作为服务提供给第三方需获得商业授权**
- 📅 2030-09-16 起自动转为 **Apache License 2.0**

> 简言之：源码公开可读可学、个人免费用；想商用请联系作者。
> 商业授权咨询：欢迎开 Issue 联系。

## 开发状态

| 阶段 | 状态 |
|---|---|
| 环境搭建（Flutter / JDK17 / Android SDK） | ✅ |
| 项目骨架 + 主题 + 密钥外置 | ✅ |
| 数据层（Open-Meteo / 高德 / 中央气象台） | ✅ |
| 研判引擎（到达时刻 / 分段 / 分级） | ✅ |
| UI：地点查询 + 出行路线（多路线选择） | ✅ |
| **APK 构建 + 真机运行** | ✅ |
| 高德地图真实地图显示 | 🚧 进行中 |
| 台风研判 / 赛道研判 / 摄影指数 | 📋 规划中 |
