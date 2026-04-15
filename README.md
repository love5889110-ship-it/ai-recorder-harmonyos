# AIRecorder — HarmonyOS 智能对话录音 App

自动监听环境声音，检测到人声时自动开始录音，静音后自动停止并上传到服务端进行 AI 转录分析。专为商务场景设计（会议、客户拜访、通话记录）。

---

## 核心功能

| 功能 | 说明 |
|------|------|
| **VAD 自动录音** | 环境中出现人声自动开始录音，无需手动操作 |
| **噪音过滤** | RMS 阈值 + 滑动窗口，过滤键盘声/空调声等环境噪音 |
| **防碎片化** | 录音中持续检测声音，有声音就重置静音计时，保证一场会议录成一个文件 |
| **WiFi 感知** | 可配置家庭 WiFi 黑名单，在家时自动停止录音 |
| **自动上传** | 录音结束后自动上传到服务端，支持断点续传 |
| **手动管理** | 录音列表展示时长/文件大小，支持手动触发上传、重置上传标记 |
| **麦克风容错** | 启动失败时自动重试（最多3次，间隔3/6/9秒） |

---

## 技术架构

### 双 AudioCapturer 防碎片化设计

```
IDLE 状态
  └─ AudioCapturer (VAD 监听)
       每 48ms 读一帧，计算 RMS 音量
       滑动窗口内有声帧 ≥ 50% → 触发录音

RECORDING 状态
  ├─ AVRecorder (主录音，AAC 64kbps，16kHz)
  └─ recVadCapturer (独立 AudioCapturer)
       每 200ms 检测声音
       RMS > 0.010 → 重置静音计时器
       静音持续 3 分钟 → 停止录音
```

**为什么需要两个 AudioCapturer？**
AVRecorder 录音过程中无法同时读取 PCM 数据，必须用独立的 AudioCapturer 监测声音来重置静音计时。否则计时从录音开始就走，3分钟后必然切断，导致会议被分成多个碎片。

### 状态机

```
IDLE ──[声音触发]──► LISTENING ──[有声帧≥50%]──► RECORDING
  ▲                                                    │
  └──────────────[静音3分钟 / 用户停止]────────────────┘
```

---

## 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `VAD_THRESHOLD` | 0.015 | RMS 阈值，高于此值认为有人声（降低可更灵敏） |
| `VAD_WINDOW_MS` | 3000ms | 滑动窗口大小，3秒内 |
| `VAD_ACTIVE_RATIO` | 0.5 | 50% 以上帧有声才触发录音 |
| `SILENCE_STOP_MS` | 180000ms | 静音 3 分钟后停止录音 |
| `REC_VAD_THRESHOLD` | 0.010 | 录音中声音检测阈值（比监听阈值低，更敏感） |
| `HOME_WIFI_SSIDS` | `['chinanet-1802']` | 家庭WiFi黑名单，连接时不录音 |

---

## 源码结构

```
entry/src/main/ets/
├── entryability/
│   └── EntryAbility.ets      # App 入口，async 加载配置后初始化服务
├── pages/
│   └── Index.ets             # 主界面（录音状态/列表/设置/上传进度）
└── service/
    ├── RecorderService.ets   # 核心：VAD + AVRecorder + recVadCapturer
    ├── UploadManager.ets     # 上传管理（扫描/上传/进度回调）
    └── GlobalService.ets     # 全局单例
```

---

## 安装与部署

### 环境要求
- DevEco Studio 4.0+
- HarmonyOS SDK API 11+
- 手机与服务端在同一局域网

### 步骤

1. **用 DevEco Studio 打开项目**

2. **修改服务器地址**

   打开 [Index.ets](entry/src/main/ets/pages/Index.ets)，找到：
   ```typescript
   const DEFAULT_SERVER_URL = 'http://192.168.10.106:5678';
   ```
   改为你的服务端 IP（保持端口 5678 不变）。

3. **连接手机，点击 Run**

4. **首次运行**：弹出麦克风权限请求，点击「允许」

### 权限配置（module.json5 已包含）
```json
"requestPermissions": [
  { "name": "ohos.permission.MICROPHONE" },
  { "name": "ohos.permission.INTERNET" },
  { "name": "ohos.permission.GET_WIFI_INFO" }
]
```

---

## 配合服务端使用

服务端仓库：[ai-recorder-system](https://github.com/love5889110-ship-it/ai-recorder-system)

启动服务端后，App 上传的音频会：
1. 被 Whisper 自动转录为文字
2. 经 Claude / MiniMax 提炼关键信息、行动项、联系人
3. 在 Web 前端 `http://服务端IP:5678` 展示

---

## 常见问题

**Q: 录音自动停止太频繁（碎片化）**
- 确认 `recVadCapturer` 是否启动（查看 DevEco HiLog 中 `RecorderService` tag）
- 若出现 `error 6800301`，说明双 AudioCapturer 被系统拒绝，可将 `SILENCE_STOP_MS` 调大至 600000（10分钟）作为临时方案

**Q: 不在说话也开始录音（误触发）**
- 适当提高 `VAD_THRESHOLD`（0.015 → 0.020）
- 提高 `VAD_ACTIVE_RATIO`（0.5 → 0.6）

**Q: 完全不录音**
- 检查当前连接的 WiFi 名称是否在 `HOME_WIFI_SSIDS` 列表
- 查看 HiLog 是否有 `麦克风启动失败` 日志
- 确认 VAD_THRESHOLD 不要过高（0.015 是推荐值）

**Q: 上传显示"没有待上传文件"**
- 点击「重置上传标记」按钮，清除错误的 `.uploaded` 标记文件
- 确认服务端已启动且 IP 地址正确
