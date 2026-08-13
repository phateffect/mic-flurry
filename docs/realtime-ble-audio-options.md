# MicFlurry 实时 BLE 音频方案：ATVV 遥控器与 ESP32-S3/Opus

调研日期：2026-08-12

> 2026-08-13 实现状态：下文的 `RC003/ARN9` 是外部资料使用的型号标签，不作为 MicFlurry
> 的设备身份。实际测试设备由 IOHID 报告为 `小米语音遥控器`，受支持指纹是 manufacturer
> `MIOM`、vendor ID `10007`、product ID `12984`。该设备的 16 kHz ATVV 实时链路已经完成
> MicFlurry 真机验收；runtime 也会在 60 秒独立发送 `MIC_CLOSE`。实现状态以
> `docs/TODO-swift-core.md` 为准。保留本文其余内容作为设计和实现前审计记录。

## 范围与语境

本文基于 `docs/research-ble-voice-protocols.md` 继续核实，并只讨论 MicFlurry 自己的产品
选择。原调研中出现的“我们”“他们”“本仓库用户的另一个项目”等表述均属于原报告引用的
其他项目语境，不代表 MicFlurry，也不构成 MicFlurry 已经做出的决定。

这里的“实时音频流”定义为：设备采集音频后立即编码并持续通过 BLE 发送，Mac 在会话尚未
结束时就持续解码并写入 `MicFlurry Internal`。它不是“设备先录完整段音频，结束后再上传”。
实时流允许在拥塞时丢弃旧数据以维持时间轴，不追求录音协议式的 ACK、续传和最终一致性。
本项目的目标会话是短时语音：**典型约 10 秒，硬上限不超过 1 分钟**，不以常开麦克风或
小时级连续传输为目标。60 秒应由 runtime/firmware 的会话计时器强制执行，不能只依靠 UI
或用户最终松开按键。

本文比较两条可并存的设备路径：

1. 受支持的 `小米语音遥控器`，使用设备已有的 ATVV 1.0 + IMA ADPCM；
2. 自制 ESP32-S3，使用 MicFlurry 自定义 GATT profile + Opus。

本文主体是 2026-08-12 的研究和设计结论；上方状态说明记录后续实现与硬件验收结果。

## 结论摘要

1. **两条路径都可行，但不是同一种协议的两个 codec。** RC003 应作为 ATVV profile；
   ESP32-S3/Opus 应作为独立的 MicFlurry profile。它们只在解码后 PCM、重采样、CoreAudio
   输出、录音和状态上复用公共管线。
2. **受支持指纹已经完成 Milestone 2 真机闭环。** 历史 Rust 原型可从 macOS 已连接
   设备枚举、按 IOHID 指纹筛选、协商 ATVV、解码并写入 `MicFlurry Internal`。
3. **长期可控硬件路径应是 ESP32-S3/Opus。** 它可以明确规定帧长、序号、分片、统计和
   安全策略，音质/带宽比也优于 ADPCM；代价是固件、麦克风模拟前端、电源、协议和长期
   稳定性均由本项目负责。
4. **ATVV 1.0 原规范没有 Opus codec。** 规范只定义 8 kHz 与 16 kHz IMA ADPCM。
   某些参考固件中的 Opus 扩展不能视作 Google ATVV 1.0 的互操作合同。ESP32 Opus 不应
   复用 ATVV UUID 或 `0x04` codec 位。
5. **已验证设备是 HTT 语音源，不是任意时长的常开麦克风。** 它协商 interaction model
   `3`，在持续按住时仍于 60 秒停止；五次成功的 `MIC_EXTEND` 没有延长这一固件边界。
6. **ESP32 的原始吞吐不是主要风险，调度和流控才是。** 16 kHz 单声道 Opus
   20 kbps 只产生约 2.5 kB/s 压缩数据，远低于 ESP32-S3 的 BLE 吞吐能力。真正需要处理的
   是协商后的 ATT MTU、通知队列拥塞、有限缓冲、丢包/断连。独立音频时钟的漂移仍要
   观测，但在最长 1 分钟的边界内不必阻塞首版。

## 证据等级与来源

优先级按“原始规范/官方文档 > 可运行源码 > 第三方实机报告 > 推断”排序：

- [Google Voice over BLE spec 1.0（2020-07-11 归档）](https://web.archive.org/web/20260324183034/https://wangefan.github.io/linux_kernel_driver/resources/Google_Voice_over_BLE_spec_v1.0.pdf)：ATVV 1.0 命令、能力、codec、超时和同步语义的主要依据。归档 PDF 标有 `Google Confidential`，本文只做互操作性摘要，不把 PDF 复制进仓库。
- [Open Voice Bridge](https://github.com/nijez/open-voice-bridge)：RC003/ARN9 + macOS 的第三方实现和真机验收证据，不是 MicFlurry 的验收结果。
- [Voice Stick protocol](https://github.com/78/voicestick/blob/main/docs/protocol.md) 与其 [ESP32 音频管线](https://github.com/78/voicestick/blob/main/firmware/components/audio_pipeline/audio_pipeline.c)：ESP32 上 16 kHz/20 kbps Opus 经 GATT notify 实时发送的可运行先例。
- [RFC 6716](https://datatracker.ietf.org/doc/html/rfc6716)：Opus 帧长、实时延迟与丢包权衡。
- [Espressif BLE 连接说明](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/api-guides/ble/get-started/ble-connection.html)、[ESP-FAQ 吞吐数据](https://docs.espressif.com/projects/esp-faq/en/latest/esp-faq-en-master.pdf) 和 [I2S 文档](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/peripherals/i2s.html)：MTU/DLE、ESP32-S3 BLE 能力与 DMA 采音依据。
- [Apple BLE 参数指南 QA1931](https://developer.apple.com/library/archive/qa/qa1931/_index.html) 与 [CoreBluetooth notification 上限](https://developer.apple.com/documentation/corebluetooth/cbcentral/maximumupdatevaluelength)：Apple central 的连接参数和单通知尺寸约束。
- [Opus decoder API](https://opus-codec.org/docs/opus_api-1.5/group__opus__decoder.html)：丢包时 PLC/FEC 解码语义。

`Open Voice Bridge` 的“已真机验收”是有价值的外部证据，但它仍是第三方项目自述。
MicFlurry 已经用自己的二进制和 Mac 验证上述硬件指纹；这不自动证明所有以 `RC003/ARN9`
销售的设备都具有相同身份和行为。

## 对原调研的修正

原调研混合了 ATVV 0.4、Google ATVV 1.0、厂商实现和参考固件扩展。对 MicFlurry 最关键的
修正如下：

| 主题 | Google ATVV 1.0 原规范 | 对 MicFlurry 的结论 |
| --- | --- | --- |
| codec | `0x01` ADPCM 8 kHz；`0x02` ADPCM 16 kHz；能力位 `0x03` 表示两者及动态切换 | 不能把 `0x04` Opus 当作 ATVV 1.0 标准能力 |
| `MIC_OPEN` | 命令 `0x0C` + 1 字节 mic mode；`0x00` 是实时 Playback，`0x01` 是非实时 Capture | 当前代码的 `[0x0C, 0x00]` 正确；`0x0C 0x00 0x02` 不符合该规范 |
| `CAPS_RESP` | payload 至少 8 字节：version、codecs、interaction model、frame size、extra config、reserved，之后可跟固件数据 | 实测为 ATVV 1.00、codec `0x02`、interaction model `3`、frame size `120`、extra/reserved `0`、无 firmware payload |
| 音频帧 | AUDIO characteristic 只含连续 ADPCM 数据，无每帧 header；frame size 是协议分块大小，通常匹配单通知上限，但可以是任意值 | 不应把 120 字节误认为 ADPCM 自描述 codec frame；状态和序号来自控制面/约定计数 |
| DLE/MTU | 默认 audio frame 20 字节；推荐 16 kHz 时使用 160 字节和约 20 ms 连接间隔；`extra configuration` 可请求 DLE/ATT MTU | RC003 测试必须记录实际 MTU 和通知尺寸，不可硬编码“总是 120 字节” |
| 同步 | `AUDIO_SYNC` 可在丢帧、切换采样率或周期同步时出现，给出 codec、下一 frame number、predictor、step index | 必须在下一音频分块前应用状态，并用 frame number 做缺口/统计校验 |
| 长会话 | 设备端 Audio Transfer Timeout 建议 15 秒至 1 分钟；主机可每 5–10 秒发 `MIC_EXTEND(stream_id)` | runtime 每 10 秒 extend；实测设备仍在 60 秒主动停止 |
| 实时语义 | `MIC_OPEN(Playback=0)` 要求只缓存少量 connection intervals；拥塞时应降带宽或丢帧以保时间域 | MicFlurry 不应为“完整录音”无限排队或补传历史音频 |

规范第 2.2 节一处使用了“notification ... confirmed by Host”的措辞，但同一规范的 GATT
属性和后续流程都使用 notification。工程上仍应按 GATT notification 的无应用层确认语义
设计，不能据此发明逐包 ACK。

## 方案一：受支持遥控器 / ATVV 1.0

### 已知可行性

RC003 暴露 ATVV GATT 语音和 Bluetooth HID 按键。第三方项目报告其 macOS 适配已经完成
真机验收，路径为：

```text
RC003 microphone
  -> ATVV 16 kHz IMA ADPCM notifications
  -> macOS CoreBluetooth
  -> ADPCM decode
  -> CoreAudio loopback output
```

这与 MicFlurry 当前架构完全同构，只是最后的目标从 BlackHole 换成稳定 UID
`MicFlurry_2_UID`。因此 RC003 不是“理论可行”，而是“外部已有同类路径成功、MicFlurry
仍需独立验收”。

### 应按规范实现的会话

RC003 实机可能协商 On-request、PTT 或 HTT，不能只依据按钮观感猜测：

```text
bond/connect
  -> subscribe AUDIO + CTL
  -> GET_CAPS(version=1.0, legacy=0x0003, supported models)
  <- CAPS_RESP(actual codec/model/frame size)

On-request:
  <- START_SEARCH
  -> MIC_OPEN(mode=Playback/0x00)
  <- AUDIO_START(reason=0x00, codec, stream_id=0)

PTT/HTT:
  <- AUDIO_START(reason=0x01 or 0x03, codec, stream_id=1..0x80)

stream:
  <- optional AUDIO_SYNC
  <- raw ADPCM audio notifications ...
  -> MIC_EXTEND(stream_id) every 5–10 s while the project session remains active
  -> MIC_CLOSE(stream_id) when the user stops it or at the hard 60 s limit
  <- AUDIO_STOP(reason)
```

若 RC003 实际表现为收到 `START_SEARCH` 后才等待 `MIC_OPEN`，沿用 On-request 路径；若它
协商并主动发送 PTT/HTT `AUDIO_START`，则不能再用 `MIC_OPEN` 打断它。规范明确规定正在
进行的 PTT/HTT 会话应返回 `MIC_OPEN_ERROR(0x0F80)`。

### 优势

- 不需要自制硬件和固件即可验证 MicFlurry 整条实时音频链路；
- ATVV 已定义 pairing 后的能力协商、动态 8/16 kHz、会话、超时和 ADPCM 重同步；
- 遥控器具备电池、麦克风、语音键和成熟外壳，适合 PTT 使用；
- 当前 Milestone 2 已经实现大部分主机侧基础组件。

### 限制与风险

- 协议和固件行为由小米控制，无法修复设备端缓冲、采音增益或同步频率；
- 默认 ADPCM 16 kHz 约 64 kbps，带宽明显高于 16–20 kbps Opus；
- ADPCM 有状态，漏掉数据后必须等 `AUDIO_SYNC` 才能完全恢复；
- 设备定位是遥控器语音，默认应理解为短时 On-request/PTT/HTT，而非全天候连续麦克风；
- 同名 RC003/ARN9、多设备身份、HID 实例与 GATT 实例对应关系存在额外产品风险；
- 采购批次或固件升级可能改变协商结果，支持声明应包含已验收的型号与固件信息。

### 2026-08-12 实现前只读审计（历史记录）

以下结论记录当时的代码状态；其中活动 stream ID、`MIC_EXTEND`、可观测性和 macOS-first
设备恢复已经在 2026-08-13 实现。保留原清单用于说明这些改动的由来：

- 已正确使用 ATVV UUID、`GET_CAPS`、`MIC_OPEN(0x00)`、高 nibble 优先 ADPCM 和
  `AUDIO_SYNC` predictor/step index；
- `CAPS_RESP` 已能解析，但 runtime 目前忽略协商得到的 interaction model、frame size 和
  extra configuration；
- `AUDIO_START.stream_id` 已解析但没有保存为活动会话门，关闭时使用 `0xFF`；
- 尚无 `MIC_EXTEND` 定时发送，因此不能保证超过设备 Audio Transfer Timeout 的会话；
- 尚未使用 `AUDIO_SYNC.frame_no` 做缺口检测或同步点后的帧计数；
- 当前固定倍率线性重采样符合典型 10 秒、最长 1 分钟的首版边界；仍应在最长会话中观测
  queue depth，防止异常设备采样率导致明显 underrun/overflow；
- 这些是 RC003 真机验收前应处理或用实测证明无影响的事项，不代表当前实现已坏。

### 原定真机事实清单与当前覆盖

实机已确认产品名/IOHID 指纹、完整 `CAPS_RESP`、16 kHz codec、interaction model、frame
size、控制 reason/stream ID、60 秒边界、extend 结果、重复会话、重启恢复、PCM 电平和可懂度。
以下原清单中仍未完整覆盖的是 Device Information firmware、ATT MTU/通知长度分布、主动
丢包后的 `AUDIO_SYNC` 行为和 8 kHz 路径：

1. Device Information Service 的 model、firmware revision 和设备名；
2. `GET_CAPS` 请求与完整 `CAPS_RESP` 原始十六进制；
3. 协商后的 interaction model、codec、frame size、extra configuration 和 ATT MTU；
4. 语音键按下/松开时 CTL 消息的严格顺序、reason 与 stream ID；
5. AUDIO notification 的长度分布、间隔和每秒字节数；
6. `AUDIO_SYNC` 的启动、周期、丢帧后和采样率切换行为；
7. 不发送 `MIC_EXTEND` 时的真实超时，以及 5–10 秒 extend 是否稳定延长；
8. 断连、通知关闭、重复 `MIC_CLOSE` 和快速重复按键的行为；
9. PCM 的幅度、底噪、削波和可懂度；
10. 同一台 Mac 上 HID 与 GATT 是否稳定对应同一个物理设备。

支持声明因此限定到实测硬件指纹和 16 kHz 路径，不泛化到任意名称相同或标为
`RC003/ARN9` 的设备。

## 方案二：ESP32-S3 / 自定义 GATT / Opus

### 为什么不扩展 ATVV

Google ATVV 1.0 对音频只定义 IMA ADPCM。即使某个参考实现声明 Opus 位，也不能证明
RC003、Android TV 或其他 ATVV host 对相同帧格式互操作。复用 ATVV UUID 会产生三个问题：

- 枚举阶段会把自制设备误判为标准 ATVV remote；
- codec、音频 framing、分片和控制语义没有共同规范；
- 后续无法区分“Google ATVV 兼容”与“MicFlurry 私有扩展”。

因此 ESP32-S3 应使用新的 128-bit service UUID 和单独的 profile ID。UUID 数值可以在正式
协议冻结时生成；研究文档不提前占用随机常量。

### 推荐的第一版音频参数

| 参数 | 建议基线 | 理由 |
| --- | --- | --- |
| 输入 | 16 kHz、mono、SInt16 PCM | 语音足够，和 RC003/ASR 边界一致 |
| Opus application | `OPUS_APPLICATION_VOIP` | 面向语音而非音乐 |
| frame duration | 20 ms（320 samples） | RFC 6716 推荐的实时折中；比 Voice Stick 的 60 ms 更低延迟 |
| bitrate | 20 kbps CBR，允许协商 16/24 kbps | 每帧名义约 50 B，音质和 BLE 余量平衡 |
| channels | 1 | 产品是单麦克风 |
| complexity | 从 1–3 实测起步 | 给 I2S、BLE 和系统任务留下 CPU 余量 |
| DTX | v1 关闭 | 保持连续音频时钟；启用后必须另行表达静音时长 |
| in-band FEC | v1 关闭、保留能力位 | BLE 已有链路层重传；先以 sequence + PLC 建立可测基线 |
| receiver jitter target | 初始 2–3 帧（40–60 ms） | 吸收通知突发，仍保持交互延迟 |

20 ms CBR 的名义 payload 估算如下；真实实现仍必须以 encoder 返回长度为准：

| bitrate | 每秒 payload | 每个 20 ms packet |
| ---: | ---: | ---: |
| 16 kbps | 2,000 B | 40 B |
| 20 kbps | 2,500 B | 50 B |
| 24 kbps | 3,000 B | 60 B |

相比之下，16 kHz/16-bit mono PCM 是 32,000 B/s，ATVV ADPCM 是约 8,000 B/s。Opus 的
带宽余量很大，但不能把“平均 50 B”误当作永远不会分片，也不能假设 macOS 必然协商到
某个固定 MTU。

### 推荐 GATT 边界

建议只定义完成实时流所需的最小面：

| characteristic | 方向 | 属性 | 用途 |
| --- | --- | --- | --- |
| Capabilities/State | ESP -> Mac | read + notify | 协议版本、codec 参数、MTU结果、会话状态和累计统计 |
| Control | Mac -> ESP | write with response | 配置、开始、停止和显式错误；低频控制优先确定送达 |
| Audio | ESP -> Mac | notify | Opus packet 或其分片；不使用 indicate 阻塞实时流 |

音频面不要用 JSON，不要携带设备 UI 或 ASR 业务状态。Control/State 可以用紧凑的版本化
二进制消息。设备按钮如果需要独立按键语义，可使用 BLE HID 或另一个低频 input event，
不要混进高频音频 characteristic。

### 推荐会话与音频封装

会话开始消息至少固定：protocol version、session ID、codec、sample rate、channels、frame
duration、bitrate、最大 Opus packet 和 60 秒上限。会话结束消息至少带 end reason、最终
sequence、采集溢出数和发送丢弃数；ESP firmware 与 Mac runtime 任一方到达 60 秒都应主动
结束，另一方按幂等 stop 处理。

每个 Opus logical packet 使用递增 `sequence`。由于当前会话最多 60 秒（20 ms 时最多 3,000
个 packet），v1 不需要为小时级流付出 32-bit ID 开销。建议每个 notification 使用固定 8 字节
fragment header：

```text
offset  size  field
0       1     version = 1
1       1     flags: first / last
2       2     session_id, little-endian
4       2     sequence, little-endian (每个 Opus packet +1)
6       1     fragment_offset
7       1     packet_len
8       N     fragment payload
```

规则：

- `sequence` 标识完整 Opus packet，不标识单个 fragment；
- fragment 必须按 offset 递增；新 sequence 到来时丢弃尚未完成的旧 packet；
- v1 Opus packet 上限是 255 字节，`fragment_offset` 和 `packet_len` 都按字节计；
- session ID 在每次 start 时随机生成且不得为 0；最长 60 秒保证 sequence 不会回绕；
- session 不匹配、offset 重叠/越界或重复 last 均丢弃并计数；
- 收到 sequence 缺口时对缺失的 20 ms 帧调用 Opus PLC，而不是等待重传；
- 不为音频 packet 加应用层 ACK、RESUME 或 COMMIT；
- 控制面负责 start/end，音频 header 的 flags 只描述分片边界。

8 字节 header 在默认 ATT MTU 下仍留下 12 字节 fragment payload；一个名义 50 字节的 packet
约需 5 个 notification。扩大 MTU 后通常可以单通知发送。默认 MTU 路径是必须可工作的
fallback，但正式性能验收应同时记录扩大 MTU 是否成功和实际 notification 数。

### MTU、连接参数和流控

ATT 默认 MTU 是 23，notification value 通常只有 MTU 减 3 的空间。DLE 可以减少链路层
分片，但 ATT MTU 和 DLE 是相关而不同的协商，应用不能把二者混为一个开关。

ESP32-S3 作为 GATT server 应以连接事件得到的实际 MTU计算 notification payload 上限：

```text
fragment_payload_max = negotiated_att_mtu - 3 - 8
```

如果该值过小，仍按协议分片；不能发送超长 notification，也不能依赖 CoreBluetooth 向
central 应用公开 MTU。Apple 对自制 accessory 的通用建议是 connection interval 最小值不低于
15 ms，并满足 interval、latency 和 supervision timeout 的组合约束。推荐从 min=15 ms、
max=30 ms、peripheral latency=0 开始请求，再记录 Mac 实际接受值，不把请求值当结果。

Espressif 官方给出的 ESP32-S3 参考吞吐是约 0.73 Mbit/s（1M PHY）与 1.35 Mbit/s（2M
PHY），但这是特定测试条件下的能力上限，不是 Mac 链路 SLA。20 kbps Opus 即使加上协议和
BLE 开销也有足够量级余量，所以实现重点应是：

- I2S DMA、Opus encode 和 BLE send 使用分离的有界队列；
- BLE 堵塞时暂停出队，等 stack 可发送事件，不做忙等；
- 编码队列满时丢最老的**完整 Opus packet**，保持实时性；
- fragment 发送到一半失败时丢弃该 logical packet，接收端靠 sequence + PLC 恢复；
- 暴露 capture overflow、encode failure、queue drop、notify failure、sequence gap 和 jitter
  underrun 低频统计；
- 断连立即停止采音/编码或进入明确的有限重连状态，不能在 RAM 中无限积压历史音频。

### 安全边界

麦克风音频是敏感数据。正式 profile 应要求 bonding 和链路加密后才能订阅 Audio 或执行
Start。只有 Just Works 时虽然可以加密，但通常没有中间人认证；如果硬件有显示或安全输入，
优先使用 passkey/numeric comparison，否则至少提供物理配对窗口、清除 bond 操作和可见的
采音指示灯。不要把固定 passkey、设备地址或长期密钥写进公共源码。

### 当前时长内把时钟漂移作为观测项

ESP32-S3 的 16 kHz 采样时钟和 Mac 的 48 kHz CoreAudio 时钟来自不同晶振。即使两端都声称
精确采样率，也会有 ppm 级偏差。例如 100 ppm 在 60 秒内只累计约 6 ms 时间差：值得观测，
但通常可以由 40–60 ms jitter/render buffer 吸收。因此在本项目典型 10 秒、最长 1 分钟的
明确边界内，首版可以继续使用固定倍率 streaming resampler，不必先实现自适应时钟恢复。

首版仍应记录设备 sample count、host render count 和 queue depth，并在 60 秒边界测试最差
样机。如果实测 queue 持续逼近空/满、设备实际采样率异常，或者将来产品改为数十分钟常开，
再以 CoreAudio render queue 的目标水位缓慢调整 resampling ratio。这个未来机制不应为了
尚不存在的常开需求增加当前协议复杂度。

## 两种方案的直接比较

| 维度 | RC003 / ATVV | ESP32-S3 / MicFlurry Opus profile |
| --- | --- | --- |
| 实时模式 | 现成 On-request/PTT/HTT | 建议定义最长 60 秒的 PTT 或 toggle session |
| codec | 8/16 kHz IMA ADPCM | 建议 16 kHz Opus VOIP |
| 典型压缩码率 | 32/64 kbps | 建议 16–24 kbps |
| 丢失恢复 | 有状态 ADPCM + `AUDIO_SYNC` | packet 边界 + sequence + Opus PLC/FEC |
| 主机工作量 | 当前基础已存在，需实机纠偏 | 新 profile、Opus decoder、分片和能力协商 |
| 设备工作量 | 无法改固件 | 完整 I2S/codec/BLE/security/power 固件 |
| 协议控制权 | 低 | 高 |
| 项目时长边界 | 典型 10 秒；接近 1 分钟时需 `MIC_EXTEND` | 协议和固件共同强制最长 60 秒 |
| 互操作价值 | 可兼容一类 Android TV voice remote | 只兼容 MicFlurry，自定义但可稳定版本化 |
| 近期验证价值 | 最高 | 需要先有硬件原型 |
| 长期产品可控性 | 中低 | 最高 |

## 推荐的产品和实施顺序

### 决策

**支持两种 profile，先 RC003，后 ESP32-S3/Opus。** 它们不是互斥路线：RC003 提供现成
设备和 ATVV 兼容性，ESP32 提供本项目可控的硬件入口。不要为了“统一”而让 ESP32 模拟
ATVV，也不要让 RC003 的 ADPCM 特殊状态污染 Opus profile。

如果只能选择一个近期目标，选 RC003，因为它能最快暴露当前 CoreBluetooth、CoreAudio、
权限、重连和真实延迟问题。如果只能选择一个长期硬件平台，选 ESP32-S3/Opus，因为协议、
固件、会话长度和诊断能力都可控。

### 阶段 A：受支持 ATVV 设备事实闭环（核心路径完成）

1. 用 GATT 抓取/日志完成前述十项实机事实表；
2. 逐字节对照 Google 1.0 原规范，不再从其他 ATVV 版本猜布局；
3. 明确 RC003 的 interaction model、实际 timeout 和 `MIC_EXTEND`；
4. 验证短 PTT 的首音、尾音、同步后恢复、重连和可懂度；
5. 支持声明限定到已验证 IOHID 指纹，不使用可编辑名称或未证实的零售型号。

### 阶段 B：冻结 MicFlurry Voice GATT v1

1. 在写固件前冻结 service/characteristic、能力、控制消息、8 字节 fragment header、大小
   上限和错误语义；
2. 明确 v1 基线为 16 kHz mono、20 ms、20 kbps CBR、notify、无应用层 ACK；
3. 定义 bonding、物理配对和清除 bond 的产品行为；
4. 写字节级 golden vectors，让 Rust host 与 ESP-IDF 两端共享同一组协议样例；
5. 明确版本兼容规则：同 major 向后兼容，未知字段按长度跳过，破坏性变化升 major。

### 阶段 C：ESP32-S3 实时链路原型

1. I2S DMA 连续采集，不经过文件或 flash；
2. 采集、编码、BLE 三段有界队列和完整统计；
3. 验证大 MTU 单通知与默认 MTU 多分片两条路径；
4. 做 sequence gap、缺 fragment、拥塞、断连和重连故障注入；
5. 验证典型 10 秒和最长 60 秒会话，并连续重复至少 100 次 start/stop，检查资源、序号和
   queue 状态都能复位；
6. 最后再评估 DTX、in-band FEC、动态 bitrate 和省电，不把它们塞进首个闭环。

## 共同架构边界

主机侧应按 profile 与 codec 分层，而不是继续把 Bluetooth 等同于 ATVV：

```text
CoreBluetooth transport
  -> device/profile detection
      -> ATVV profile -> ADPCM state + AUDIO_SYNC
      -> MicFlurry Voice profile -> fragment reassembly + Opus packets
  -> decoded timestamped mono PCM
  -> streaming resampler / jitter control
  -> optional recording
  -> AUHAL -> MicFlurry_2_UID
```

建议公共 profile 输出包含 session、source sample rate、sequence/timestamp、PCM 和统计的事件，
而不是把 ATVV control bytes 或 Opus fragments 暴露给 TUI。UI/control plane 只看到设备、会话、
音量、延迟、drop 和错误；它不参与实时 packet 处理。

Voice Stick 值得借鉴的是“会话 + sequence + 有界队列 + Opus packet”思路，但其 60 ms 帧和
16 字节无分片 frame 不应原样照搬：60 ms 会增加首音延迟，且默认 MTU 下不能保证单通知。
可靠录音协议的 ACK/RESUME/COMMIT 也不适用于 MicFlurry 实时麦克风路径。

## 验收指标建议

以下是项目目标，不是当前测量结果：

- 在会话未结束时，消费端持续收到音频，证明不是 release 后批量上传；
- PTT 首音不被吞，松键后的尾音既不截断也不无限拖尾；
- 稳态交互端到端延迟以 p95 小于 150 ms 为初始目标，并分别记录 capture、codec、BLE、
  jitter buffer 和 CoreAudio 阶段；
- 正常链路下没有持续增长的 capture overflow、notify failure、sequence gap 或 CoreAudio
  underrun；
- 注入丢包/缺 fragment 后，Opus 在一帧内通过 PLC 继续，ATVV 在下一个 `AUDIO_SYNC`
  后恢复，不出现会话余下时间持续噪声；
- 默认 MTU 与扩大 MTU 都能工作；不能只在同一型号 Mac 的偶然协商结果下通过；
- 已验证设备覆盖 16 kHz 与长会话 extend；8 kHz 仍需另一受支持硬件验证；
- ESP32 验证完整 60 秒流的 queue depth 有界，并连续重复至少 100 个典型 10 秒会话而无
  资源泄漏、序号串线或状态残留；
- 断连、睡眠、取消订阅和应用退出都立即停止采音/发送并释放会话；
- 最终从可见 `MicFlurry` 录到的语音可懂、幅度合理、无持续爆音，并与设备侧 sample count
  和主机侧 drop 统计相符。

## 最终判断

受支持的 ATVV 遥控器已经证明 MicFlurry 的**兼容性与端到端路径**，但承诺应限定为经过
实机验证的硬件指纹和实时语音会话，不能宣传为常开麦克风。ESP32-S3 + Opus 是更合适的**自有、
长期产品路线的音频入口**，但必须采用独立协议，并从第一版就包含 sequence、MTU 分片、有界队列、
流控、加密和可观测性。

两者共同证明的产品核心仍然不变：设备只负责通过 BLE 提供实时压缩音频；MicFlurry
userspace 负责协议、解码、时间恢复和标准 CoreAudio 输出；HAL driver 不接收自定义 BLE/IPC
音频协议。
