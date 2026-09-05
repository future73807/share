# 屏幕共享应用

多人在线房间 + 实时屏幕共享,支持声音分享模式选择与回声抑制。

| 端 | 技术 | 位置 |
|---|---|---|
| 浏览器 Web 端 | Vue 3 + Vite + 浏览器原生 WebRTC | `src/`、`index.html` |
| Android 手机端 | Flutter + flutter_webrtc | `app/` |
| 信令服务器(两端共用) | Node.js + Socket.IO | `server.js` |

## 功能

- 多人房间:输入房间号/昵称加入,实时用户列表
- 屏幕共享:手机端走系统 MediaProjection(系统授权弹窗 → 前台服务 → 采集),浏览器端走 `getDisplayMedia`
- 声音分享模式(点分享时选择、共享中可切换):
  - 混合(屏幕+麦克风)
  - 仅屏幕声音(手机端为系统内音采集,需 Android 10+)
  - 仅麦克风
  - 无声
- 回声抑制:手机端麦克风走 VOICE_COMMUNICATION(硬件 AEC/NS/AGG),系统内音在原生层混入 WebRTC;浏览器端麦克风显式开启回声抑制/噪声抑制,共享时本地预览静音,避免二次采集回音
- 手机端加入页可手输服务器地址(填一次记住),服务器换地址无需重新打包

## 环境要求

- Node.js ≥ 14
- 构建 Android 包:Flutter SDK(3.x)+ Android SDK,`app/android` 已关闭 R8 混淆(flutter_webrtc 的 JNI 依赖类名反射,混淆会导致运行时崩溃)
- 屏幕内音采集:Android 10+(API 29)及以上

## 快速开始

### 常用命令速查

```bash
# ── 后端(信令服务器)──
node server.js                        # 启动,默认端口 3000

# 端口被占用时换端口(按你的终端三选一)
$env:PORT = "31200"; node server.js   # PowerShell
set PORT=31200 && node server.js      # CMD
PORT=31200 node server.js             # Git Bash / Linux / macOS

# ── Web 端 ──
npm install                         # 首次安装依赖
npx vite --port 8300                # 开发模式(热更新),浏览器开 http://localhost:8300
npm run build                       # 构建产物到 dist/(连同 server.js 一起部署)

# ── Android 端 ──
cd app
flutter pub get                     # 拉取依赖
flutter build apk --release         # 正式包 → app/build/app/outputs/flutter-apk/app-release.apk
flutter run                         # 调试运行(连接手机或模拟器)
```

### 1. 启动信令服务器

启动后看到 `服务器运行在 http://0.0.0.0:<端口>` 即成功,该地址就是两端要填的"服务器地址"。

### 2. 浏览器端

浏览器打开 `http://localhost:8300/?server=http://<信令服务器地址>`(不带 `?server=` 时默认连当前域名同端口 3000)。页面填房间号/昵称 → 加入会议 → 分享屏幕。

注意:浏览器的 `getDisplayMedia` 要求 HTTPS(`localhost` 例外)。

### 3. Android 端

安装到手机后:加入页填 **房间号 / 昵称 / 服务器地址**(如 `http://192.168.1.5:3000`,手机与服务器需在同一局域网;填一次记住)→ 加入会议 → 分享。

模拟器联调:服务器地址填 `http://10.0.2.2:<端口>`(宿主机回环),Manifest 已开启 `usesCleartextTraffic` 允许 HTTP。

## 信令协议(Socket.IO 事件)

| 事件 | 方向 | 说明 |
|---|---|---|
| `join-room` | 客户端→服务器 | 携带 `roomId / nickname / client`(client: `web` 或 `flutter`) |
| `room-users` | 服务器→客户端 | 房间成员 + 正在共享者列表 |
| `user-joined` / `user-left` | 服务器→房间 | 成员进出 |
| `start-sharing` / `share-started` | 双向 | 共享开始广播 |
| `stop-sharing` / `share-stopped` | 双向 | 共享结束广播 |
| `request-stream` | 观看者→共享者 | 携带请求端类型(服务器中继) |
| `accept-stream` | 共享者→观看者 | 通知观看者主动发 Offer(Flutter 观看者作为 ICE 控制端,提升 NAT 穿透成功率) |
| `offer` / `answer` / `ice-candidate` | 双向 | WebRTC 协商与候选(服务器按 `to` 中继) |

连接模型:共享者与每个观众一条 PeerConnection;观看者在共享者之前入房时通过 `room-users`/`share-started` 补拉流(带去重);ICE 候选在对端连接建立前到达会先缓存、建立后回放。

## 实现要点(踩坑记录)

- **Android 14+ 屏幕采集时序**:必须"系统授权 → 启动 `foregroundServiceType=mediaProjection` 前台服务并完成 `startForeground` → `getMediaProjection`",顺序错误即 SecurityException 闪退;服务内对 `startForeground` 做了重试保护,且使用 `START_NOT_STICKY` 防止僵尸进程重启后无授权再次崩溃。
- **权限**:Manifest 必须包含 `ACCESS_NETWORK_STATE`,否则 libwebrtc NetworkMonitor 会在原生层 SIGABRT(表现为建连后闪退)。
- **R8 混淆**:release 默认混淆会破坏 flutter_webrtc JNI 反射(进程无崩溃日志静默退出),`app/android/app/build.gradle.kts` 中已关闭;如需开启必须附加 `-keep class com.cloudwebrtc.**` / `org.webrtc.**`。
- **系统内音**:手机端用 `AudioPlaybackCapture` 采集,复用 flutter_webrtc 已授权的 MediaProjection(避免二次授权弹窗),经其 `capturePostProcessing` 音频处理钩子混入上行(`app/android/.../ScreenAudioMixProcessor.kt`)。
- Flutter 端与 Web 端均为完整 WebRTC 实现:共享者推流给每个观众,观众也可反向上屏(网页共享 → 手机观看)。

## 目录结构

```
├── server.js                  # 信令服务器(Express + Socket.IO)
├── src/                       # Vue Web 端
│   ├── main.js
│   └── components/ScreenShare.vue
├── index.html                 # Web 入口
├── app/                       # Flutter Android 端
│   ├── lib/main.dart
│   ├── lib/screen_share_page.dart
│   └── android/               # 原生层:ScreenSharePlugin(授权/前台服务/系统内音混音)
└── out/                       # 本地产物(打包 APK 等,已 gitignore)
```

## 常见问题

- **手机连不上服务器**:检查手机与服务器是否同一局域网;地址要带端口;确认 `node server.js` 在跑。Windows 下若端口被系统保留(报 EACCES),换一个端口(如 `PORT=31200`)。
- **点击分享后没弹授权框**:系统授权弹窗每次共享会话都会出现,属正常;若被"不再提示"过,去系统设置里重置该应用权限。
- **观众画面黑屏/转圈**:确认观看者在共享者开始共享后仍在房间内;ICE 不通时优先检查两端网络(应用内置 Google/小米双 STUN)。
- **有回音**:多为"观众端外放的声音被共享者麦克风再次采集"造成的设备间声学串音,硬件回声抑制无法消除别的设备喇叭的声音。规避方式:观众端戴耳机或静音;不需要讲话时选"仅屏幕声音"模式——该模式上行完全没有麦克风内容,零回音。
- **屏幕内声音没声音**:屏幕内音经麦克风轨道的处理链送出,请确认已授予麦克风权限(所有声音模式都需要);共享中可切换模式,无需重新发起。
