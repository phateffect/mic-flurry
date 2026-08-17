# 已验证的遥控器硬件档案

本文记录 MicFlurry 在真机上 attach 验证过的遥控器。数据来源是 `micflurryd` 实机的
GATT Device Information Service 读取和 IOHID 身份属性，不是第三方资料。

CoreBluetooth UUID 是 macOS 为本机分配的配对标识，只在同一台 Mac 上稳定；跨机器识别设备
必须使用 IOHID 指纹或 GATT DIS 字段。

## RC003（小米语音遥控器）

- CoreBluetooth UUID（本机）:`0BAB71C8-BF4E-2307-B1C7-C3E7EF125056`
- IOHID product 字符串：`小米语音遥控器`
- IOHID 指纹：manufacturer `MIOM`,VendorID `0x2717` (10007),ProductID `0x32b8` (12984)
- GATT DIS:model `RC003`,serial `250519`,hardware `V2.0`,firmware `2671`,software
  `A.7.0.6`,manufacturer `MIOM`
- ATT MTU 515;16 kHz ATVV 音频通知实测 120 字节/帧
- 状态：已注册 known device;ATVV 语音、HID seize、按键映射全部验证通过

## RC001（小米蓝牙语音遥控器）

2026-08-14 首次接入并 attach 验证。

- CoreBluetooth UUID（本机）:`458774D6-9E4B-C697-2D40-8E7FCAAA5AD9`
- 系统广播名：`小米Remote电池`（仅作诊断展示，不参与识别）
- IOHID product 字符串：`小米蓝牙语音遥控器`（仅作诊断展示，不参与识别）
- IOHID 指纹：manufacturer `MIOM`,VendorID `0x2717` (10007),ProductID `0x32b8` (12984)
  —— 与 RC003 完全相同，只用于识别受支持的硬件家族
- GATT DIS:model `RC001`,serial `250513`,hardware `V2.0`,firmware `2671`,software
  `A.6.0.3`（低于 RC003 的 A.7.0.6),manufacturer `MIOM`
- ATT MTU 515；ATVV 1.0、codec mask `0x02`、interaction model `3`，实测一次 8.6 秒
  16 kHz 会话收到 523 个 120 字节通知，解码 125,520 帧，丢帧 0
- HID seize 实测成功；方向键、OK (`0x28`)、返回 (`0xf1`)、Home (`0x4a`)、音量加减
  (`0x80`/`0x81`) 与 RC003 映射一致；电视、语音、菜单、关机分别为 `0x35`、`0x3e`、
  `0x65`、`0x66`。2026-08-14 在最终 private build 上再次验证这四个键的完整按下/释放，
  分别映射为 `tv`、`microphone`、`menu`、`power`；语音键同时正常触发 ATVV 音频会话
- 状态：已注册并完成 ATVV 语音、HID seize 和全部 13 个实体键映射验证

## 待办：型号差异化处理

两台遥控器 VID/PID 指纹相同。MicFlurry 先以 IOHID manufacturer/VID/PID 识别硬件家族，
attach 后再用 GATT DIS 的 manufacturer/model/hardware 结构化指纹映射到 RC001 或 RC003。
广播名与 IOHID product 字符串不参与身份或型号判断。后续新增型号继续通过同一目录注册
IOHID 家族指纹、GATT DIS 型号指纹和 helper profile，不增加名称匹配分支。
