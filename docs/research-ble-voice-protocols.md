# BLE 语音音频协议调研：Voice Stick / Recorder 协议 / ATVV 三方对比

调研日期：2026-08-11（协议事实基于当日拉取的源码与文档）

> 2026-08-13 状态说明：本文是实现前的协议调研，第三方资料中的 `RC003/ARN9` 名称不用于
> MicFlurry 设备识别。当前实机由 IOHID 报告为 `小米语音遥控器`，受支持指纹是 manufacturer
> `MIOM`、vendor ID `10007`、product ID `12984`；当前实现和验收事实以
> `docs/TODO-swift-core.md` 为准。

## 结论摘要

1. **Voice Stick**（github.com/78/voicestick）用 GATT notify 传输 **Opus**（60ms/包，CBR 20kbps），实时 PTT、尽力而为、无 ACK。
2. **Recorder 协议**（本仓库用户的另一个项目）是面向可靠录音的完备协议：24 字节信封 + 8 种类型化消息 + ACK/RESUME/COMMIT + 显式分片。
3. **ATVV**（Google ATV Voice over BLE，MicFlurry milestone-2 的目标协议）是遥控器语音的事实标准：**IMA ADPCM 8/16 kHz、高 nibble 优先、大端、bonded 加密**，会话极简（u8 sessionID），无重传，靠 **AUDIO_SYNC** 重同步有状态解码器。
4. **open-voice-bridge**（github.com/nijez/open-voice-bridge，Xiaomi RC003/ARN9 macOS 真机验收）实现的架构与 MicFlurry milestone-2 几乎相同（BLE → IMA ADPCM 解码 → CoreAudio 输出 → BlackHole 回环 → 虚拟麦克风），是 milestone-2 最直接的参考实现。

## 信息来源

| 来源 | 用途 |
|---|---|
| github.com/78/voicestick（firmware + desktop/macos + docs/protocol.md） | Voice Stick 协议 |
| docs/protocol.md（voicestick） | Voice Stick 帧/状态/控制/OTA 格式 |
| firmware/components/audio_pipeline/audio_pipeline.c、voice_ble/voice_ble.c | Voice Stick 固件实现 |
| desktop/macos/Sources/VoiceStickApp/BleProtocol.swift、VoiceStickCoordinator.swift | Voice Stick macOS 解析 |
| github.com/b0o/ATVVoice（docs/research/report.md、docs/specs/*.md） | G20S Pro 逆向 + ATVV 协议细节 |
| github.com/Infineon/mtb-example-btstack-freertos-cyw20829-voice-remote | ATVV 遥控器端官方参考固件（命令表/帧格式事实标准） |
| github.com/nijez/open-voice-bridge（Sources/XiaomiRemoteBridgeMac/ATVVProtocol.swift、XiaomiBluetoothBridge.swift） | ATVV v1.0 在 macOS 的真机实现 |

---

## 1. Voice Stick 协议

### GATT

- 服务 UUID：`8f2f0b84-6e6f-4b23-88f7-3a3ceafc5100`
- 特征：`audio_tx`(5101, notify)、`state_tx`(5102, notify)、`control_rx`(5103, write w/o response)、`ota_rx`(5104, write)、`ota_tx`(5105, notify)

### 音频帧（AudioBleFrame，16 字节头，小端）

```
0   version       = 1
1   type          = 0x01 audio
2-3 header_len    = 16
4-7 session_id    u32 LE
8-11 seq          u32 LE（0 起始）
12  flags         bit0=start, bit1=end
13  reserved      = 0
14-15 payload_len u16 LE
16+ payload       一个原始 Opus 包
```

### 实现要点

- 16 kHz / 单声道 / 60ms（960 samples）/ 帧；Opus CBR 20kbps、复杂度 1、VOICE 信号、DTX 关；`OPUS_MAX_PACKET_SIZE 220` 保证单包 ≤ MTU，**不分片**
- 双任务：audio_task（采集+编码入队，队满**丢最老包**）+ tx_task（出队发送，失败重试 50×30ms 后丢弃）
- 会话级资源（encoder/codec/i2s）按录音 session 创建销毁
- 结束：先 drain 队列（≤500ms）再发 `END + 空 payload` 帧
- state_tx 用 JSON（button_down/up、device_info），control_rx 用 JSON（ui_state、interaction_mode）
- macOS 端不解码 Opus，直接包装成 Ogg Opus 转发 ASR；`frame.sessionID != 活跃会话` 即丢弃
- 可靠性：无 ACK、无 CRC、无续传。设计目标 = 实时 ASR，丢帧可接受

---

## 2. Recorder 协议（用户另一项目，要点记录）

### GATT（服务前缀 `7D50A2xx-7B22-4D5B-9F39-2A0F3D8C0000`）

- `...0001` Control point：加密 write + indicate（生命周期消息）
- `...0002` Audio data：indicate（AUDIO_BATCH、分片、INPUT_ACTION）
- `...0003` Device status：加密 read + notify
- 所有特征要求加密认证连接

### 通用信封（24 字节，网络字节序）

```
0    version = 2
1    type
2-3  flags（v1 必须 0）
4-5  payload 字节数（max 512）
6-7  reserved（必须 0）
8-23 session ID（16 字节，全零 = 尚无会话）
24+  类型化 payload
```

### 消息类型

| 值 | 名称 | Payload |
|---|---|---|
| 1 | SESSION_BEGIN | codec u8; channels u8; sampleRate u32; frameSamples u16; bitrate u32; preSkip u16; firstSequence u32; inputIntent u8 |
| 2 | AUDIO_BATCH | sequence u32; packetCount u8(1~7); 重复 [packetLen u16 + Opus packet] |
| 3 | SESSION_END | batchCount u32; validInputSamples u64; streamCRC32 u32; endReason u8 |
| 4 | ACK | highest durable contiguous sequence u32 |
| 5 | RESUME | highest durable contiguous sequence u32 |
| 6 | COMMIT | validated stream CRC32 u32 |
| 7 | ERROR | error code u16; offending message type u8 |
| 8 | INPUT_ACTION | action u8（1 = Return） |

约定：codec 1 = Opus；0xFFFFFFFF = 尚无持久化 batch；end reason 1=释放/2=硬限制/3=采集溢出/4=内部错误；CRC = CRC-32/ISO-HDLC，按序对每个 Opus packet 计算、每 packet 前加 2 字节网络序长度；INPUT_ACTION 走 Audio Data indicate、全零 session ID、断连不重试。

### BLE 分片（10 字节前缀）

```
0  分片版本 = 1
1  flags：bit0=first, bit1=last
2-5 逻辑消息 token u32
6-7 fragment offset u16
8-9 逻辑消息总大小 u16
```

同 token 分片必须连续有序；非法 offset 重置重组；逻辑消息最大 536 字节（24 信封 + 512 payload）。

### 设计评价（调研时的判断）

- 面向**可靠持久化录音**：ACK 前设备必须缓存未确认包；RESUME 与"仅 RAM 缓冲"矛盾（断连后缓存丢失）
- 大端需要两端转换（BLE/ESP32/macOS 都是小端），纯开销；建议除非有跨语言客户端需求否则改小端
- v1 锁死 flags/reserved，扩展需 bump 大版本
- AUDIO_BATCH 批量摊薄 24B 头是优于 Voice Stick 的设计
- 无 AUDIO_SYNC 类机制 —— 因为 Opus 帧自包含，不需要

---

## 3. ATVV 协议（MicFlurry milestone-2 目标）

### GATT

- 服务：`AB5E0001-5A21-4F05-BC7D-AF01F617B664`
- TX `AB5E0002`（Host→Remote，write）
- RX `AB5E0003`（Remote→Host，notify，音频）
- CTL `AB5E0004`（Remote→Host，notify，控制）
- 要求 bonded 加密（AES-128-CCM）

### 命令表（Infineon 官方参考固件逐字节确认）

| 命令 | 字节 | 方向 |
|---|---|---|
| GET_CAPS_REQUEST | `0x0A ver(2BE) codecs(2BE)` | Host→Remote |
| MIC_OPEN | `0x0C 0x00 codec(1)` | Host→Remote |
| MIC_CLOSE | `0x0D`（v1.0 加 sessionID u8） | Host→Remote |
| MIC_EXTEND | `0x0E`（v1.0） | Host→Remote |
| GET_CAPS_RESP | `0x0B ver(2BE) codecs interaction bpf(2BE)` | Remote→Host |
| START_SEARCH | `0x08` | Remote→Host |
| AUDIO_START | `0x04 interaction codec sessionID` | Remote→Host |
| AUDIO_STOP | `0x00` | Remote→Host |
| AUDIO_SYNC | `0x0A` + predictor(2BE) + stepindex(1) | Remote→Host |
| MIC_OPEN_ERROR | `0x0C` | Remote→Host |

### 关键事实

- 字节序：**大端**
- Codec 位掩码：`0x01`=ADPCM 8k，`0x02`=ADPCM 16k，`0x04`=Opus（v1.0+）
- ADPCM：IMA/DVI，高 nibble 优先（`byte >> 4` 先解码），4:1 压缩，89 项 step table + 8 项 index table
- session ID：**u8**；帧内无 session 字段，靠 CTL 消息带

### 两个版本变体（实现前必须确定支持哪个）

| | ATVV v0.4（draft；G20S Pro/Infineon） | ATVV v1.0（Xiaomi RC003/ARN9） |
|---|---|---|
| GET_CAPS_RESP | `0x0B ver(2) [0] codecs(2) bpf(2) bpc(2)`，9B | `0x0B ver(2) codecs(1) interaction(1) bpf(2)`，7B |
| 帧尺寸 | 134B（8k，256 samples ≈ 32ms） | 120B 默认（16k 时 240 samples = 15ms） |
| 帧格式 | 6B 头：seq(2BE)+0x00+predictor(2BE)+step(1) + 128B ADPCM；**每帧独立解码** | **纯 ADPCM 无头**；连续解码器状态 + AUDIO_SYNC 重同步 |
| 分片 | bpc=20B（134 = 6×20+14 拆 7 通知）；MTU 大时单帧发 | 单通知一帧 |

注意：v0.4 的 6B 帧头与 v1.0 的纯 ADPCM 是**解码器级差异**——写错一种就是噪声（G20S Pro 逆向中 step index 爆炸到 73、predictor 漂移到 -13339 的案例）。

### 会话流（v1.0）

```
配对加密 → 使能 RX/CTL notify → GET_CAPS → GET_CAPS_RESP
按住麦克风键 → START_SEARCH(0x08) → Host: MIC_OPEN(0x0C 0x00 0x02)
→ AUDIO_START(0x04, interaction codec sessionID) → 每 15ms 一帧 120B notify
→ 期间可能插发 AUDIO_SYNC(predictor+step) 供解码器重同步
松手 → AUDIO_STOP(0x00)（或部分遥控器重发 START_SEARCH）→ MIC_CLOSE(0x0D sessionID)
```

### 解码器重同步（关键可靠性机制）

ADPCM 是有状态编码（predictor + step index 贯穿全流），丢一帧即错位。ATVV 的解法不是重传，而是遥控器发 **AUDIO_SYNC（0x0A + predictor 2BE + step 1B）**，主机在下一帧解码前把解码器状态 reset 为该值（ovb 用 `pendingSync` 实现）。**MicFlurry 必须实现这一点。**

### 后处理（atvvoice 逆向 + ovb 均验证有效）

原始 ATVV 音频很轻（RMS ≈ 236，峰值 ±6000 而非 ±32768）。建议后处理链：

1. 去 click（单样本尖峰用插值替换）
2. 三角低通 `[0.25, 0.5, 0.25]`
3. RMS 归一化（目标 ≈ 10000，95 分位裁剪的抗尖峰增益计算）

---

## 4. 三方总对比

| 维度 | Voice Stick | Recorder | ATVV v1.0 |
|---|---|---|---|
| 定位 | 实时 PTT 流（尽力而为） | 可靠录音（持久化） | 遥控器语音（实时、简单、行业标准） |
| 编码 | Opus 20kbps CBR 60ms | Opus（SInt16 可协商） | IMA ADPCM 8/16k，高 nibble 优先，15/30ms |
| GATT | 5 特征 + JSON | 3 特征 + 24B 信封 | 3 特征 + 1B 命令 |
| 帧头开销 | 16B | 24B（+10B 分片前缀） | 0~3B（v1.0 纯 ADPCM；v0.4 6B） |
| session ID | u32 | 16B | u8 |
| 生命周期 | 音频帧 START/END flag | SESSION_BEGIN/END + ACK/RESUME/COMMIT | MIC_OPEN/CLOSE + AUDIO_START/STOP |
| 解码器同步 | 无（Opus 自包含） | 无（Opus 自包含） | AUDIO_SYNC（predictor+step） |
| 可靠性 | 无（丢最老 + 重试后丢） | 强（ACK+CRC+RESUME） | 无（丢帧不重传；v0.4 用 seq 检测缺口仅告警） |
| 能力协商 | 无 | SESSION_BEGIN 全参数 | GET_CAPS / GET_CAPS_RESP |
| 分片 | 无（编码参数适配 MTU） | token/offset 显式重组 | 按 bpc 拆 20B 块（MTU 大时单帧） |
| 字节序 | 小端 | 大端 | 大端 |
| 安全 | 未提 | 强制加密认证 | bonded + AES-128-CCM |
| 状态通道 | JSON 事件 | 无独立通道 | CTL 命令流 |
| 错误通道 | 无 | ERROR(code+type) | MIC_OPEN_ERROR |

---

## 5. 对 MicFlurry milestone-2 的启示与行动项

milestone-2 规划（`ATVV remote → CoreBluetooth → IMA ADPCM decoder → streaming resampler → AUHAL → MicFlurry_2_UID`）与 open-voice-bridge 的已验证架构一致。行动项：

1. **历史参考**：ovb 的 `ATVVProtocol.swift`（156 行：能力协商 + 解码器 + FrameAccumulator + 会话门）曾作为 ATVV 实现的移植蓝本。注意其只接受 16kHz，MicFlurry 还需要 8kHz + SRC。
2. **AUDIO_SYNC 必须实现**，否则丢帧后解码器持续错位。
3. **后处理（去 click + LPF + RMS 归一化）**：16kHz SInt16 → Float32 转换前建议做，否则录进 WAV 的波形过小（RMS ≈ 236 vs 目标 10000）。
4. **结束边界**：部分遥控器松键不发 AUDIO_STOP 而是**重发 START_SEARCH**，两种都要处理；ovb 还处理了 300ms 内的隐式音频竞态。
5. **版本选择**：milestone 写"ATVV v1"→ 采用 v1.0 变体（120B 纯 ADPCM 帧 + AUDIO_SYNC）；若需兼容 G20S Pro 类旧遥控器则需支持 v0.4（134B + 6B 帧头）。
6. **可靠性定位**：MicFlurry 的 producer→BlackHole→consumer 是实时流，Recorder 协议的 ACK/RESUME/COMMIT 在这里是过度设计；ATVV 的"丢帧 + AUDIO_SYNC 重同步"足够。
7. **协商注意**：v1.0+ 遥控器可能同时报 ADPCM+Opus（codec 位 0x04），选择逻辑需显式偏好 16kHz ADPCM。

---

## 6. 踩坑清单（实现 ATVV 时的已知陷阱）

1. **MIC_OPEN 字节序**：codec 必须 `0x0C 0x00 0x02`（BE）；发成 `0x0C 0x02 0x00` 会被拒（MIC_OPEN_ERROR）。
2. **v0.4 vs v1.0 帧格式**：G20S Pro 每帧 6B 头（seq+predictor+step）逐帧独立；Xiaomi 纯 ADPCM 靠 AUDIO_SYNC。写错解码器即噪声（step index 爆炸）。
3. **GET_CAPS_RESP 布局随版本不同**：v0.4 的 codecs 是 2B（偏移 3-4），v1.0 是 1B（偏移 3）+ interaction（偏移 4）；部分设备 codecs 为 0 时实际放在偏移 4（ovb 的 fallback 逻辑）。
4. **START_SEARCH 代替 AUDIO_STOP**：部分遥控器松键重发 START_SEARCH。
5. **8kHz 音频偏轻**：需归一化，且 8k→16k 需 SRC（ovb 直接拒绝 8kHz 是偷懒）。
6. **分片差异**：v0.4 默认 bpc=20B（134B 帧拆 7 个通知）；macOS CoreBluetooth 通常能协商大 MTU，单帧通知即可，但 FrameAccumulator 仍需处理残帧。
