# HerdrGo App Store submission

This file keeps the first iOS submission material reviewable with the app.
Values marked `TODO` require an App Store Connect account, a legal decision,
or a live review bridge and must not be guessed in code.

## Build identity

- App name: `HerdrGo`
- Bundle ID: `dev.herdr.herdrWeb`
- Current version: `0.2.1`
- Current build: `3`
- Minimum OS: iOS 15.0
- Devices: iPhone and iPad
- Primary category: Developer Tools
- Secondary category: Productivity
- Price: Free

The bundle ID is not customer-facing. Keep it unless a new App ID and signing
setup are intentionally created before the first App Store Connect record.

## English metadata

- Name: `HerdrGo`
- Subtitle: `Coding agents in your pocket`
- Promotional text:

  `Watch, unblock, and steer the coding agents running on your own computer.`

- Keywords:

  `coding agents,developer tools,terminal,remote,Herdr,AI,productivity`

- Description:

  HerdrGo keeps the coding agents running on your computer within reach.

  See which agents are working, waiting, or finished. Open a session to read
  its real terminal output, reply, send the keys agents need, and respond to
  recognized approval prompts from a native mobile interface.

  Pair your own computer with one private QR code. HerdrGo then connects to the
  HerdrGo bridge through an encrypted EasyTier peer-to-peer network. There is
  no HerdrGo account, no advertising, and no central service that stores your
  terminal sessions.

  Features:

  - Status-first dashboard for multiple agents and computers
  - ANSI terminal output and full session history
  - Replies, special keys, and guarded approval actions
  - Agent creation on your paired computer
  - Image transfer directly to your paired computer
  - iPhone and iPad layouts

  Herdr 0.8.2 or newer and the free HerdrGo plugin are required on a computer
  you control.

- Privacy Policy URL: `https://herdr-go.github.io/privacy/`
- Support URL: `https://herdr-go.github.io/support/`
- Marketing URL: `https://herdr-go.github.io/`

## Simplified Chinese metadata

- Name: `HerdrGo`
- Subtitle: `随时掌控你的 Coding Agents`
- Promotional text:

  `在手机上查看、处理并继续推进运行在自己电脑上的 Coding Agents。`

- Keywords:

  `编程助手,开发工具,终端,远程控制,Herdr,AI,效率`

- Description:

  HerdrGo 让运行在你电脑上的 Coding Agents 随时触手可及。

  快速查看哪些 Agent 正在工作、等待处理或已经完成；打开会话即可阅读真实
  终端输出、发送回复和特殊按键，并通过原生移动界面安全处理已识别的授权提示。

  使用一个私密二维码即可配对自己的电脑。HerdrGo 随后通过加密的 EasyTier
  点对点网络连接 HerdrGo bridge。无需注册 HerdrGo 账号，没有广告，也没有
  集中保存终端会话的 HerdrGo 云服务。

  主要功能：

  - 以状态为先的多 Agent、多电脑总览
  - ANSI 终端输出和完整会话历史
  - 回复、特殊按键和带校验的授权操作
  - 在已配对电脑上创建 Agent
  - 将图片直接传送到已配对电脑
  - 支持 iPhone 和 iPad

  需要在你控制的电脑上安装 Herdr 0.8.2 或更高版本，以及免费的 HerdrGo
  Plugin。

- 隐私政策 URL：`https://herdr-go.github.io/zh/privacy/`
- 技术支持 URL：`https://herdr-go.github.io/zh/support/`
- 营销 URL：`https://herdr-go.github.io/zh/`

## App Review information

### Positioning

HerdrGo is a native status and control client for Herdr sessions running on a
computer owned and controlled by the user. It does not mirror a desktop UI,
host a cloud development environment, sell software, or execute downloaded
code on the iPhone or iPad. Commands are executed by the user's existing tools
on the paired host.

### Review notes template

Replace every `TODO` before submission:

> HerdrGo does not require an account. The app connects only to a HerdrGo
> bridge on a user-controlled computer after scanning a private pairing QR
> code.
>
> For App Review, we provide an isolated, continuously available test bridge.
> Open the attached `HerdrGo-review-pairing.png` on a second screen and follow
> these steps:
>
> 1. Launch HerdrGo and tap Add computer.
> 2. Scan the attached QR code.
> 3. Wait for the computer named `TODO` to show Connected.
> 4. Open the pre-created agent named `TODO`.
> 5. Review its terminal output, send a reply, and use the supplied approval
>    prompt to test the native action buttons.
>
> The review environment is isolated from production and contains no customer
> data. It will remain online throughout review.
>
> Contact: TODO name, TODO phone, TODO email.

Do not submit until the QR attachment works from a clean install and the bridge
can be reached from a network outside the developer's LAN.

## App Privacy answers

Current code audit:

- No account, advertising SDK, analytics SDK, or tracking SDK.
- Pairing profiles, preferences, and notification state stay on the device.
- Camera frames are processed on-device for QR pairing.
- A user-selected image is sent directly to the paired, user-controlled host.
- Terminal content and commands travel only between the app and paired bridge.
- Flutter plugins used by the iOS build include their own privacy manifests.

Provisional App Store Connect answer: **Data Not Collected** and **No
Tracking**. Confirm this only after documenting whether operators of the
default EasyTier relay retain IP addresses or other connection logs. If those
operators retain data beyond transient delivery, update both the privacy label
and public policy before submission.

## Encryption export compliance

The binary embeds EasyTier and uses encrypted networking. The technical audit
and recommended questionnaire answers are in
[`ios-export-compliance.md`](ios-export-compliance.md).

Leave `ITSAppUsesNonExemptEncryption` unset for the first upload. Complete the
App Store Connect questionnaire with the audited answers, then add the key that
matches Apple's result. This avoids incorrectly declaring that the third-party
static library contains no encryption.

## Remaining account actions

1. Accept current agreements in App Store Connect Business.
2. Create the iOS app record with `dev.herdr.herdrWeb`.
3. Decide whether the first public version remains `0.2.1` or becomes `1.0.0`.
4. Complete the current age-rating questionnaire.
5. Choose storefronts. Exclude mainland China until any required ICP or other
   network-tool documentation is confirmed.
6. Add the English and Simplified Chinese metadata above.
7. Add iPhone and iPad screenshots.
8. Select the uploaded build and complete export compliance.
9. Attach the review QR code and replace every review-note `TODO`.
10. Add for Review, then Submit for Review.
