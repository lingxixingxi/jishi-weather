# 迹时天气 (jishiweather)

> 本地化出行天气研判 —— 航空级多源聚合天气简报，**纯本地计算**，不依赖任何自建服务器。

输入出发地 / 目的地 / 时间，沿你**实际要走的路线**逐段研判天气：哪段有雨、几点下、路面湿滑风险，给出绿 / 黄 / 红出行建议。

## 功能（v0.1.3）

五个功能页，底部导航切换：

- **地点查询**：方圆 10km 区域天气（中心 + 4 方位采样点交叉验证）→ **5 源逐小时融合** → 逐小时条**可点选联动**（区域概览 / 采样点明细 / 多源研判 / 雷达外推四处同步切换）→ 7 天预报（本地多源聚合）
- **出行路线**：高德规划返回**多条候选路线** → 由你选定实际要走的那条 → 每 10km 采样 → 按到达时刻取天气 → 天气突变点自动切段 → 逐段研判 + 整体建议等级；并做**台风 × 路线重叠分析**（±6h 时间窗、受影响路段、机构分歧）
- **赛道研判**：预置赛道坐标库 → **研判时刻可选**（当前 / 指定时刻）→ 路面**含水模型**（过去 6h 降水 − 蒸散 + 当前雨强×0.5）→ 分级（干/微湿/湿/积水）+ **表面温度** + **预计干燥时间** + **多源参考**（ECMWF/GFS/ICON/和风并列 + 降水分歧）+ **Ventusky 坐标核对**
- **台风研判**：中央气象台台风网实况路径 + **多机构预报** → 按**预报路径最近距离 + 7 级风圈 + 强度**给出本地影响等级（无影响/关注/警戒/严重影响）
- **摄影指数**：**火烧云**（日落/日出）与**星空**机会评分（0~100）。**三层乘法模型** —— 先判断「地面能否看到天」（总云量门槛，阴天直接否决），再算质量分；星空另有**月光因子**（月明星稀）、**光污染 Bortle 因子**（机位可设、本地记忆）与「万里无云」级别的严苛云门槛；空气质量用 **AOD（气溶胶光学厚度）**；另附**今日光线时刻**（黄金/蓝调/月出月落）与**未来 7 天趋势**

另有：

- **气象预警**：地点查询页置顶展示本区县/本市生效预警（中央气象台预警接口，按行政区划码过滤）
- **雷达回波外推**：以运动矢量外推未来 2 小时回波，超出范围时明确标注
- **卫星云图 / 雷达拼图叠加**：风云四号真彩云图与中央气象台雷达拼图可叠加在地图上
- **使用当前位置**：一键定位（室内信号弱时有超时兜底）

## 数据源（均免 key 或用户自备 key）

| 数据源 | 用途 | Key | 实测 |
|---|---|---|---|
| [Open-Meteo](https://open-meteo.com/) | 逐小时气象（主源，含 ECMWF/GFS/ICON 多模型）；ET0 / 短波辐射 / 分层云量 / 能见度 / 日出日落 | 免 key | ✅ |
| [中央气象台](http://www.nmc.cn/) | 站点实况（过去 24h 逐小时）、7 天预报、**气象预警**、雷达拼图 | 免 key | ✅ |
| [中央气象台台风网](http://typhoon.nmc.cn/) | 台风实况路径 + 多机构预报（国内直连，响应 ~0.1s） | 免 key | ✅ |
| [风云四号卫星](http://www.nmc.cn/publish/satellite/fy4b-visible.htm) | FY-4B 真彩云图（30 分钟一张） | 免 key | ✅ |
| [RainViewer](https://www.rainviewer.com/) | 雷达瓦片（任意缩放） | 免 key | ✅ |
| [和风天气](https://www.qweather.com/) | 国内逐小时（第 5 源） | **需自备** | ✅ |
| [高德开放平台](https://lbs.amap.com/) | 地理编码、驾车路线规划、地图显示、混合定位 | **需自备** | ✅ |

> 高德需要两个 Key：**Web服务**（地理编码/路线规划）和 **Android 平台**（地图 SDK + 定位 SDK）。

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

- `android/key.properties` → `AMAP_KEY=`（**Android 平台** Key，地图 SDK + 定位 SDK）
- `lib/config/secrets.dart` → `amapWebKey`（**Web服务** Key）、`amapAndroidKey`

**申请 Android 平台 Key 需要**（用 `keytool` 获取 SHA1）：

```bash
# 调试签名 SHA1
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android

# 发布签名 SHA1（先生成自己的 keystore，见下）
keytool -list -v -keystore release.keystore -alias jishiweather
```

- PackageName：`com.lingxi.jishiweather`
- 发布版 SHA1、调试版 SHA1：**同一个 Key 可以同时登记这两个**，
  这样 debug 与 release 包都能用地图与定位（本项目实测确认）

### 3. 发布签名（可选）

`android/key.properties` 里填入 `storeFile` / `storePassword` / `keyAlias` /
`keyPassword` 即启用正式签名；**不填则自动回退到 debug 签名**（能构建、
能自测，但不可上架、也无法给已发布版本做升级）。

```bash
# 生成密钥库（有效期 30 年）
keytool -genkey -v -keystore release.keystore -alias jishiweather \
  -keyalg RSA -keysize 2048 -validity 10950
```

> 密钥库丢失 = 无法给已上架的 App 发更新（只能换包名重发），请多处备份。

### 4. 构建

```bash
flutter pub get
flutter build apk --debug     # 调试包
flutter build apk --release   # 发布包

# 按架构出包（体积更小、引擎架构匹配）
flutter build apk --release --target-platform android-arm64   # 64 位（主流）
flutter build apk --release --target-platform android-arm     # 32 位（老机型）
```

> 注：`--target-platform` 只切换 **Flutter 引擎**的架构；第三方插件（如高德）
> 自带的多 ABI `.so` 仍会全部打进包里，因此两个包体积接近。如需进一步瘦身，
> 可在 `build.gradle.kts` 里配置 `ndk.abiFilters` 或使用 `--split-per-abi`。

> 国内网络建议配置镜像加速：Gradle 发行包用腾讯云镜像、Maven 用阿里云镜像（见 `android/settings.gradle.kts`）。

## 项目结构

```
lib/
├── main.dart                  应用入口
├── theme/app_theme.dart       深色航空风主题
├── config/secrets.dart        Key 配置（gitignore，见 secrets.example.dart）
├── data/track_circuits.dart   预置赛道坐标库（高德地理编码校准）
├── models/
│   ├── hourly_weather.dart    统一小时气象模型（多源比对用）
│   ├── typhoon_track.dart     台风路径点 / 风圈 / 等级映射
│   └── weather_warning.dart   气象预警模型（标题解析 + 行政区划匹配）
├── services/
│   ├── open_meteo.dart        Open-Meteo 多模型逐小时
│   ├── open_meteo_extra.dart  扩展变量（ET0 / 辐射 / 分层云量 / 日出日落）
│   ├── multi_source_service.dart  5 源并发融合
│   ├── amap_service.dart      高德：地理编码 / 多路线规划 / 沿途采样
│   ├── nmc_service.dart       中央气象台：实况 / 预报 / 台风路径
│   ├── warning_service.dart   中央气象台预警（全国全量 + 本地过滤）
│   ├── radar_service.dart     雷达拼图下载 + 回波外推
│   ├── rainviewer_service.dart 雷达瓦片
│   └── satellite_service.dart 风云四号云图
├── engine/
│   ├── route_analyzer.dart    路线研判：到达时刻取值 / 分段 / 绿黄红分级
│   ├── radar_verdict.dart     雷达定调：哪一源与实况最吻合
│   ├── typhoon_verdict.dart   台风影响研判：距离 + 风圈 + 强度
│   ├── track_verdict.dart     赛道湿滑：含水 / 分级 / 表面温度 / 干燥时间
│   └── photo_index.dart       摄影指数：火烧云 / 星空评分
└── screens/
    ├── home_screen.dart       底部导航外壳（5 页）
    ├── location_screen.dart   地点查询（含预警、雷达、卫星、多源研判）
    ├── route_screen.dart      出行路线（含多路线选择）
    ├── track_screen.dart      赛道研判
    ├── typhoon_screen.dart    台风研判
    └── photo_screen.dart      摄影指数
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
| 数据层（Open-Meteo / 高德 / 中央气象台 / 和风） | ✅ |
| 研判引擎（到达时刻 / 分段 / 分级） | ✅ |
| UI：地点查询 + 出行路线（多路线选择） | ✅ |
| APK 构建 + 真机运行 | ✅ |
| 高德地图真实地图显示 + 雷达/卫星叠加 | ✅ |
| 5 源融合 + 雷达定调 + 回波外推 | ✅ |
| 气象预警 | ✅ |
| 台风研判 | ✅ |
| 赛道研判 | ✅ |
| 摄影指数 | ✅ |
| GitHub 开源发布 | 📋 待办 |
