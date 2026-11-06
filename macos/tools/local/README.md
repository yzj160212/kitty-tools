# 本地 fork 的同步流程

这份是 fork 自己的东西（上游没有），记着两件事：**怎么跟上游**、**本地改了哪些**。上游不碰 `macos/tools/`，rebase 时这个目录不会冲突。

## 分支约定

| 名字 | 是什么 |
|---|---|
| `local` | 我们唯一的工作分支。本地改动全在这里，每次 `rebase` 到 `upstream/macos` 上 |
| `upstream/macos` | 作者仓库 `YyAdnBug/kitty-tools` 的 macos 分支，只读。`upstream` 的 push URL 已改成 `DISABLED-do-not-push-to-upstream`，误 push 直接报错 |
| `origin` | 自己的 fork（`yzj160212/kitty-tools`），只用来备份 `local` |

## 上游更新了怎么办

```bash
cd ~/Projects/kitty-tools
git fetch upstream
macos/tools/local/audit.sh        # 1. 机械审查：摊开 上次审过 → 现在 的 diff
                                  # 2. 人工读（联网、执行面、凭据、构建脚本），有问题就停，不构建
git rebase upstream/macos         # 3. 重放我们的提交；冲突按语义解，两边都要的都留
macos/tools/local/verify.sh       # 4. 核对本地改动还在
# 5. 构建（Release + 本地自签）→ 装进 /Applications → 重启 App
git push origin local             # 6. 备份到自己的 fork（改写过历史时要 --force-with-lease）
# 7. 把这次审到的新 commit 写进 macos/tools/local/AUDITED
```

构建命令（签名换成本地自签，不依赖作者的团队证书）：

```bash
cd macos
xcodebuild -project KittyTools.xcodeproj -scheme KittyTools -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" build
ditto build/Build/Products/Release/"Kitty Tools.app" "/Applications/Kitty Tools.app"
```

## 本地改了什么（两条提交 + 脚本）

**1. 不预置智谱 GLM 的免费翻译服务**
低冲突策略：**代码原样留着，只让它默认不出现**。改两处 `TranslateService.swift`——
`TranslateServiceStore.defaults` 从 `[.zhipu]` 改成空，`missingBuiltins` 过滤掉 `.zhipu`（设置「+」里不再列它）。
我们这份构建没有 `Secrets.xcconfig`，Info.plist 的内置 key 位是空的，所以就算手动改偏好把它打开也翻不了——等于不可用。

翻译自己配，本机 Ollama：设置 › 翻译 ›「+」› AI 服务 › Ollama，地址 `http://127.0.0.1:11434/v1`，填模型名（`ollama list` 里的），打开「启用」，本机地址不要 API Key。

**2. 「关闭显示器」全局快捷键**
`HotKeyAction.displayOff`（枚举末尾），默认 ⌃⌥⌘P，执行 `pmset displaysleepnow`：只关屏、机器不睡，任意键或点触控板就亮回来，和启动器的「关闭显示器」系统命令同一条路，不需要新权限。设置 › 快捷键 › 系统 里可改键或清除。

## 冲突高发区（rebase 时先看这里）

| 文件 | 为什么 | 怎么解 |
|---|---|---|
| `Shell/HotKeyCenter.swift` | 上游每加一个热键动作都挤在 `allCases` / `title` / `defaultHotKey` / 分组表里 | 枚举只往末尾加，两边的新动作都留 |
| `App/AppDelegate.swift` | `run(_:)` 的分发 switch | 两边的 `case` 都留 |
| `Settings/ShortcutsSheet.swift` | 上游改钉图那组的文案，我们加了「系统」组 | 都留 |
| `Config/Base.xcconfig` | 上游改版本号 | 版本号**跟着上游走**，不要锁死 |
| `KittyToolsTests/TranslateTests.swift` | 枚举末尾顺序那条断言 | 把我们新加的动作接在列尾 |

`TranslateService.swift` 现在只有两行改动，正常 rebase 不会冲突；真撞上了也是「默认值那行」和「过滤那行」，一眼能看懂。

## 审计锚点

`AUDITED` 存着「最后一个完整审过的上游 commit」。
- 已完整审过：`5ada3b5`（联网出口、凭据、剪贴板、更新链路、构建脚本）
- 已按 diff 审过：`5ada3b5..3d2e04e`（4 个 commit：文字钉图、启动器不列常用、「新」标记规则、0.7.2 版本号），结论「未见异常」

审完新的区间就把 `AUDITED` 更新成新的 commit，别让下次重审老代码。