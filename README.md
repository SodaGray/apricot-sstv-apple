# Apricot SSTV for iPhone and Apple Watch

Receive slow-scan television (SSTV) pictures from a radio on your iPhone or
Apple Watch, and send your own from your iPhone.

[简体中文](#简体中文)

## Features

- **14 modes**, received and sent: Robot 36 / 72, Martin M1 / M2,
  Scottie S1 / S2 / DX, and PD50 / 90 / 120 / 160 / 180 / 240 / 290, all at
  full resolution.
- **Starts by itself** from the VIS header, or from the line syncs when the
  header was missed; or receive one chosen mode only.
- **Straight pictures**: the sender's clock error is measured from the line
  syncs and corrected as the picture comes in.
- **Apple Watch receives on its own** and sends each picture to the
  iPhone when the two are near each other. It taps your wrist as a
  picture starts, is saved or is lost, and stops listening by itself
  (after a set time without a picture, or when you lower your wrist) to
  save battery.
- **Sending**: place a photo in the frame, add your callsign, and send it
  through the headphone adapter or a USB audio interface with VOX, or
  share it as a WAV.
- **Raw audio**: each picture can keep the sound it was decoded from (on
  by default), to share as a WAV and decode again elsewhere.
- **English and Simplified Chinese**, with built-in help.
- **No data collected**: no ads, no accounts, no analytics, no third-party
  code, no network connections of its own.

## Requirements

- iPhone with iOS 26.1 or later
- Apple Watch with watchOS 10 or later (optional)
- Xcode 26 to build

## Building

Open `Apricot SSTV.xcodeproj` and run the **Apricot SSTV** scheme on an
iPhone, or **Apricot SSTV Watch Watch App** on an Apple Watch. There are no
packages or dependencies to fetch.

## Layout

| Folder | What |
|---|---|
| `Apricot SSTV/` | the iPhone app: receive, send, pictures, settings, help |
| `Apricot SSTV Watch Watch App/` | the watch app: receive, pictures, sync to iPhone |
| `Shared/` | both apps: the receiver, picture storage, the transfer format, strings |
| `Shared/Core/` | the C decoder and encoder |

`Shared/Core/` comes from [Apricot SSTV for the iPod nano][ipod]
(commit a238f65). The encoder is unchanged. The decoder has two changes,
described at the top of `sstv_dsp.h`: every mode is stored at full size,
and one mode can be chosen. The iPod repository has the host tools and the
decoder's test bench.

## Privacy

Apricot SSTV collects no data. The full policy is at
<https://bd1fpn.cn/apricot/privacy.html>, linked from the app (Settings →
Privacy Policy).

## License

Copyright © 2026 SodaGray (苏打灰).

Apricot SSTV is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License, version 3, as published
by the Free Software Foundation, **with an additional permission that
allows distribution through app stores** (see
[`APPSTORE-EXCEPTION.md`](APPSTORE-EXCEPTION.md)). It is distributed in the
hope that it will be useful, but WITHOUT ANY WARRANTY. See
[`LICENSE`](LICENSE).

## Contributing

Issues and pull requests are welcome. By contributing, you agree that your
contribution is licensed under the GPL v3 with the app-store permission
above, so that the app can stay on the App Store.

## Links

- Website: <https://bd1fpn.cn/>
- Apricot SSTV for the iPod nano: <https://github.com/SodaGray/apricot-sstv>

[ipod]: https://github.com/SodaGray/apricot-sstv

---

## 简体中文

在 iPhone 或 Apple Watch 上接收电台传来的慢扫描电视（SSTV）图片，也可以用
iPhone 发送你自己的图片。

- **14 种模式**，收发都支持：Robot 36 / 72、Martin M1 / M2、Scottie S1 / S2 / DX，
  以及 PD50 / 90 / 120 / 160 / 180 / 240 / 290，全部以原始分辨率接收。
- 通过 **VIS 头自动开始**，漏掉 VIS 头时也能按行同步开始；也可以只接收指定的一种模式。
- 根据行同步测量发送方的时钟偏差，**边接收边把图片拉直**。
- **Apple Watch 可以独立接收**，两台设备靠近时图片自动传到 iPhone。图片开始、保存、信号丢失时轻敲手腕；
  一段时间没有图片或放下手腕后自动停止接收，以节省电量（都可以设置）。
- **发送**：把照片放进画面、加上呼号，通过耳机转接器或 USB 声卡配合 VOX 发射，
  也可以分享为 WAV 文件。
- **原始音频**：每张图片可以保留解码它所用的声音（默认开启），可分享为 WAV 文件，
  用其他程序重新解码。
- 支持**英文和简体中文**，内置帮助。
- **不收集任何数据**：没有广告、账户、统计分析和第三方代码，App 本身不联网。

**环境要求**：iOS 26.1 或更高版本；Apple Watch 需要 watchOS 10 或更高版本（可选）；
编译需要 Xcode 26。打开 `Apricot SSTV.xcodeproj`，运行对应的 scheme 即可，
没有需要另外下载的依赖。

**许可证**：版权所有 © 2026 苏打灰（SodaGray）。本程序是自由软件，按 GNU 通用公共
许可证第 3 版发布，并附加一项**允许通过应用商店分发**的额外许可（见
[`APPSTORE-EXCEPTION.md`](APPSTORE-EXCEPTION.md)）。本程序不提供任何担保。
提交贡献即表示你同意按上述条款授权。

**隐私政策**：<https://bd1fpn.cn/apricot/privacy.html>
