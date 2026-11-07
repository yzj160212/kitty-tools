#!/usr/bin/env bash
# 构建装好之后马上跑一遍：本地改过的设定、加上的功能还在不在。
# rebase 成功不等于改动还在——上游重构之后代码可能被静默改回去，只有这里能发现。
#
# 本 fork 的策略（低冲突）：智谱 GLM 的代码原样留着，只是不预置、不从「+」里列出来。
# 所以这里检查的是「默认没有它、菜单里没有它、包里不带作者的 key」，而不是「代码里没有它」。
#
# 用法：
#   tools/local/verify.sh                                  # 检查 /Applications/Kitty Tools.app
#   tools/local/verify.sh "/path/to/另一份.app"
set -uo pipefail
cd "$(dirname "$0")/../../.."

APP="${1:-/Applications/Kitty Tools.app}"
fail=0
ok()   { printf '  \033[32m通过\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31m失败\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '  信息  %s\n' "$1"; }

echo "== 产物 =="
if [ ! -d "$APP" ]; then bad "找不到 $APP"; echo; echo "1 项失败"; exit 1; fi
ok "存在：$APP"
EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || echo '')"
BIN="$APP/Contents/MacOS/${EXEC:-Kitty Tools}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
BUNDLEID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
info "版本 $VERSION（$BUILD） · $BUNDLEID"
codesign --verify --strict "$APP" >/dev/null 2>&1 && ok '签名自洽（codesign --verify --strict）' || bad '签名校验不通过'
# 先存变量再判断：pipefail 下 grep -q 提前退出会让 codesign 吃到 SIGPIPE，整个管道报错（build-dmg.sh 里踩过同一个坑）
SIGNATURE="$(codesign -dvv "$APP" 2>&1 || true)"
case "$SIGNATURE" in
  *"TeamIdentifier=not set"*) info 'ad-hoc 签名（App 内更新用不了，属预期）' ;;
esac

echo
echo '== 本地改动一：不预置智谱 GLM 的免费翻译服务 =='
if grep -qE 'static let defaults: \[TranslateService\] = \[\]' macos/KittyTools/Translate/TranslateService.swift 2>/dev/null; then
  ok '默认服务列表是空的（新装不会自动带上智谱）'
else
  bad '默认服务列表的写法变了：确认没有把智谱塞回默认值'
fi
if grep -q 'kind != .zhipu' macos/KittyTools/Translate/TranslateService.swift 2>/dev/null; then
  ok '设置「+」里过滤掉了智谱（missingBuiltins）'
else
  bad '「+」菜单又开始列智谱了（missingBuiltins 的过滤没了）'
fi
KEY="$(/usr/libexec/PlistBuddy -c 'Print :KittyBuiltinZhipuKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$KEY" ]; then
  ok '包里没有作者的智谱内置 key（这一位是空的）'
else
  bad '包里带上了智谱内置 key：不该把别人的额度打进自己的构建'
fi
if [ -f macos/KittyTools/Translate/Providers/Zhipu.swift ]; then
  info 'Zhipu.swift 还在——本策略是「代码留着、服务不预置」，属预期'
else
  info 'Zhipu.swift 不在了——上游自己删了？那这两条检查要跟着改'
fi

echo
echo '== 本地改动二：「关闭显示器」全局快捷键 =='
if grep -q '\bdisplayOff\b' macos/KittyTools/Shell/HotKeyCenter.swift 2>/dev/null; then
  ok 'HotKeyAction.displayOff 在'
else
  bad 'HotKeyAction.displayOff 不见了（上游加了新的热键动作把枚举改了？）'
fi
if grep -q 'case .displayOff: "关闭显示器"' macos/KittyTools/Shell/HotKeyCenter.swift 2>/dev/null; then
  ok '标题「关闭显示器」在'
else
  bad 'displayOff 的标题被改了'
fi
if grep -q 'SystemControl.perform(.command(.sleepdisplays)' macos/KittyTools/App/AppDelegate.swift 2>/dev/null; then
  ok '热键分发接到了 pmset displaysleepnow 那条命令'
else
  bad 'AppDelegate 里 displayOff 的执行分支不见了'
fi
if LC_ALL=C grep -aq '关闭显示器' "$BIN"; then
  ok '二进制里有「关闭显示器」'
else
  bad '二进制里找不到「关闭显示器」'
fi
if grep -q 'displayOff' macos/KittyTools/Settings/ShortcutsSheet.swift 2>/dev/null; then
  ok '速查表里有「系统」那一组'
else
  bad '速查表里的系统组没了'
fi

echo
echo '== 本地改动三：自签构建不自动更新（否则官方包会盖掉定制）=='
if grep -q 'isAdHocSigned' macos/KittyTools/App/Updater.swift 2>/dev/null \
  && grep -q 'isSupported: Bool { Bundle.main.bundleIdentifier == Self.bundleID && !Self.isAdHocSigned }' macos/KittyTools/App/Updater.swift 2>/dev/null; then
  ok 'Updater 里有 ad-hoc 识别，且 isSupported 依赖它'
else
  bad 'Updater 的 ad-hoc 守卫不见了（上游改了 Updater.swift？）：现在官方包会被当成合法更新装上来'
fi
if LC_ALL=C grep -aq '本地构建版（自签名）不支持 App 内更新' "$BIN"; then
  ok '二进制里有「本地构建版不支持 App 内更新」的文案（守卫真编进去了）'
else
  bad '二进制里找不到那段文案：守卫可能没生效'
fi
case "$SIGNATURE" in
  *"TeamIdentifier=not set"*) ok '这份产物是 ad-hoc 签名（与守卫一致）' ;;
  *) bad '这份产物不是 ad-hoc（装了官方包？）：本地定制可能已经不在了' ;;
esac

echo
echo '== 运行时数据（只是提示）=='
STORED="$(defaults read "$BUNDLEID" translateServices 2>/dev/null || true)"
if printf '%s' "$STORED" | grep -qi zhipu; then
  info '偏好里的服务列表还存着 zhipu：那台机器上它是启用状态（我们这份机器的列表是空的）'
else
  info '偏好里没有存 zhipu 的服务条目'
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m全部通过\033[0m：本地改动都在，可以安装了。\n'
else
  printf '\033[31m%d 项失败\033[0m：先解决再装，别把改动丢了还装上去。\n' "$fail"
fi
exit "$fail"