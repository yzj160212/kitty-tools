# 本地 fork：固定构建流程（SOP）

发给助手一个仓库地址（或说「构建最新版」）时，**按这个顺序做，一步不跳**。目标：拿到一个能用的本地构建，同时不丢本地定制、不让作者的官方包把定制覆盖掉。

适配的对象：`YyAdnBug/kitty-tools` 的 `macos` 分支 / `macos-v*` 标签（Swift + Xcode 工程，Apple Silicon，macOS 15+）。

## 0. 环境前提

```bash
xcodebuild -version      # 需要 Xcode；工程用 Swift 6
uname -m                 # 必须 arm64（工程写死 ARCHS = arm64）
```

签名一律用**本地自签**（ad-hoc）：作者的团队证书 `HTX9F4KG39` 我们拿不到，有它也行、没有不影响。

## 1. 彻底卸载旧版（保留用户数据）

用户明确要求「彻底卸载」时执行；只装新版覆盖时跳到第 2 步。

```bash
osascript -e 'tell application id "com.yy.kitty-tools.native" to quit'
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -u "/Applications/Kitty Tools.app"
/usr/bin/trash "/Applications/Kitty Tools.app"
osascript -e 'tell application "System Events" to delete login item "Kitty Tools"'
tccutil reset All com.yy.kitty-tools.native        # 签名换了，旧授权本来就是废的
/usr/bin/trash ~/Library/Application\ Support/com.yy.kitty-tools.native.dev \
  ~/Library/Preferences/com.yy.kitty-tools.native.dev.plist \
  ~/Library/Caches/com.yy.kitty-tools.native.dev 2>/dev/null
```

**不动**：`~/Library/Application Support/com.yy.kitty-tools.native/`（剪贴板历史、便签、截图历史、翻译服务配置）和钥匙串里的翻译密钥。删之前必须问用户。

## 2. 取源码

```bash
cd ~/Projects/kitty-tools
git fetch upstream --tags
git tag --list 'macos-v*' | sort -V | tail -3     # 看最新版
git rev-list --count <上次审计的commit>..<新标签>   # 规模，心里有数
```

## 3. 源码安全审查（硬性，先审后编）

```bash
macos/tools/local/audit.sh <上次审计commit> <新标签>
```

- 审的对象是 **diff**，不是整个仓库；锚点存在 `macos/tools/local/AUDITED`
- 机械扫描给线索，**判定靠人**：新增联网主机、危险 API（URLSession / Process / dlopen / osascript / SecItem / 事件监听）、遥测关键词、权限与构建脚本改动、需人工通读的文件
- **命中即停**：后门、静默外发、硬编码凭据、远程下载执行、越权、混淆 → 停止，不构建，先报 `文件:行` + 能力 + 影响面
- 结论只用三种词：确定问题 / 可疑 / 未见异常

历史结论：`5ada3b5` 整仓审过；`5ada3b5..3d2e04e`、`3d2e04e..8bbc2f8`、`8bbc2f8..macos-v0.8.1` 按 diff 审过，均未见异常。

## 4. rebase 本地定制

`local` 分支上挂着三条定制提交，rebase 到新标签上：

```bash
git rebase macos-v0.8.1
```

冲突按语义解，**不能简单选一边**。解完逐条核对（这几处是「看起来合上了其实被改坏」的高发区）：

| 核对点 | 期望 |
|---|---|
| `HotKeyCenter.swift` 的 `enum HotKeyAction` | `displayOff` 仍在**末尾**（注册 id 是下标，挪位会串） |
| `TranslateService.swift` | `defaults = []`、`missingBuiltins` 里有 `kind != .zhipu` |
| `Updater.swift` | `isSupported` 含 `&& !Self.isAdHocSigned`、`isAdHocSigned` 仍在 |
| `AboutTab.swift` | 自签构建走「本地构建版不支持 App 内更新」那一支 |

## 5. 构建（Release + 本地自签）

```bash
cd macos
xcodebuild -project KittyTools.xcodeproj -scheme KittyTools -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" build
```

`-derivedDataPath build` 让产物落在 `macos/build/`（已在 `.gitignore`）。

## 6. 构建后核对（不许跳）

```bash
tools/local/verify.sh build/Build/Products/Release/"Kitty Tools.app"
```

14 项检查：无内置智谱 key、默认服务列表为空、`displayOff` 三处接线、自签守卫编进二进制、产物确实是 ad-hoc。**任一项失败就不许装**。

## 7. 安装 + 冒烟

```bash
ditto build/Build/Products/Release/"Kitty Tools.app" /Applications/"Kitty Tools.app"
codesign --verify --deep --strict /Applications/"Kitty Tools.app"   # deep：连访达扩展一起验
open -a /Applications/"Kitty Tools.app"
tools/local/verify.sh                                               # 对装好的那份再跑一遍
log show --last 2m --predicate 'subsystem BEGINSWITH "com.yy.kitty-tools"' | grep -i error
```

## 8. 收尾

```bash
printf '%s\n' "$(git rev-parse macos-v0.8.1)" > macos/tools/local/AUDITED
git add -A && git commit -m "local: 审计锚点更新到 <版本>"
git push --force-with-lease origin local
rm -f ~/Projects/fork-patches/*.patch
git format-patch -q macos-v0.8.1..local -o ~/Projects/fork-patches   # 兜底，防仓库损坏
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -u "$PWD/build/Build/Products/Release/Kitty Tools.app"
/usr/bin/trash macos/build macos/build-debug \
  ~/Library/Application\ Support/com.yy.kitty-tools.native.dev 2>/dev/null
```

## 两条本地定制的口径

**1. 不预置智谱 GLM（低冲突策略）**
代码原样留着，只让它默认不出现：`TranslateServiceStore.defaults` 为空、`missingBuiltins` 过滤 `.zhipu`。我们这份构建没有 `Secrets.xcconfig`，Info.plist 的内置 key 是空的，所以即使手动加回来也翻不了。翻译自己配（本机 Ollama：设置 › 翻译 ›「+」› AI 服务 › Ollama）。

**2. 「关闭显示器」全局快捷键**
`HotKeyAction.displayOff`，默认 ⌃⌥⌘P，走 `pmset displaysleepnow`：只关屏、机器不睡，任意键或点触控板就亮回来。

**3. 自签构建不自动更新**
`Updater.isSupported` 加 `&& !Self.isAdHocSigned`（读签名的 adhoc 位）。**这条必须留着**：作者官方包带团队证书，能通过 `Updater.requirement` 验签，一更新就会把上面两条整套覆盖——2026-11-07 真发生过（装成了官方 0.7.3，内置 key 也回来了）。

## 自签构建的已知限制（不是 bug，别去「修」）

| 限制 | 原因 |
|---|---|
| App 内更新用不了 | 已主动禁用（见上） |
| **访达右键点了没反应** | `FinderLink.fromOwnExtension` 要求发送方是 `HTX9F4KG39` 签名的自家扩展，自签过不了这关。功能默认关，不开就不影响 |
| `FinderLinkTests.senderSignatureIsChecked` 预期失败 | 它断言测试宿主（App）能通过团队签名校验，自签必然不过 |
| 部分 Launchpad / 侧栏单测失败 | 与本工程无关（macOS 27 环境问题），改前改后同样失败 |
| 每次重编要重新给权限 | 签名指纹变了，屏幕录制 / 辅助功能 / 麦克风都要重勾 |

## 冲突高发区速查

| 文件 | 为什么 |
|---|---|
| `Shell/HotKeyCenter.swift` | 上游每加一个热键动作都挤在 `allCases` / `title` / `defaultHotKey` / 分组表 |
| `App/AppDelegate.swift` | `run(_:)` 分发 switch、功能起停 |
| `Settings/ShortcutsSheet.swift`、`Settings/HotkeysTab.swift` | 分组与行文案 |
| `App/Updater.swift` | 上游改更新链路（0.8.1 加了 release 清单） |
| `Config/Base.xcconfig` | 版本号，**跟着上游走**，本地不另起 |

`TranslateService.swift` 只有两行改动，正常不冲突；真撞了也是「默认值那行」和「过滤那行」。
