#!/usr/bin/env bash
# 上游更新前的机械审查（配合 AUDITED：记着「已经审到哪个上游 commit」）。
# 只摊开改动、给线索，不做判定：判定由人做，结论写回 AUDITED 和本目录的 README。
# 审的对象永远是 diff，不是整个仓库：没变过的代码上次已经审过了。
#
# 用法：
#   tools/local/audit.sh             # 基线 = AUDITED 里那个 commit，终点 = upstream/macos
#   tools/local/audit.sh <base>      # 指定基线（重审某一段时用）
set -euo pipefail
cd "$(dirname "$0")/../../.." # → 仓库根

BASE="${1:-$(tr -d '[:space:]' < macos/tools/local/AUDITED)}"
NEW="${2:-upstream/macos}"
git rev-parse --verify --quiet "$BASE" >/dev/null || { echo "基线 $BASE 不认识，先 git fetch upstream"; exit 1; }
git rev-parse --verify --quiet "$NEW" >/dev/null || { echo "终点 $NEW 不认识，先 git fetch upstream"; exit 1; }

DIFF="$(git diff -U0 "$BASE..$NEW")"
ADDED="$(printf '%s\n' "$DIFF" | grep '^+' | grep -v '^+++' || true)"
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

printf '审查区间：%s → %s\n' "$(git log -1 --format='%h %s' "$BASE")" "$(git log -1 --format='%h %s' "$NEW")"
printf '中间有 %s 个上游提交：\n' "$(git rev-list --count "$BASE..$NEW")"
git log --oneline "$BASE..$NEW" | sed 's/^/  /'

section '1. 改动规模'
git diff --stat "$BASE..$NEW"

section '2. 联网端点（新增行里的 http/https 主机）'
printf '%s\n' "$ADDED" | grep -oE 'https?://[A-Za-z0-9._~-]+' | sed -E 's#https?://##' | sort | uniq -c | sort -rn || echo '（无）'
printf '\n这些主机是相对基线新增的，逐个确认归属（厂商 API / 本机 / 别人的服务）：\n'
git diff -U0 "$BASE..$NEW" | grep -E '^\+.*https?://' | grep -v '^+++' | head -40 || echo '（无）'

section '3. 危险 API / 执行面（新增行）'
found=0
for pat in 'URLSession' 'Process()' 'launchPath' 'dlopen' 'dlsym' 'osascript' 'NSAppleScript' 'base64Encoded' 'eval(' 'SecItem' 'Keychain' 'NSWorkspace.shared.open' 'addGlobalMonitor' 'CGEventTap'; do
  hits="$(printf '%s\n' "$ADDED" | grep -F "$pat" | head -5 || true)"
  if [ -n "$hits" ]; then found=$((found + 1)); printf '\n-- %s --\n%s\n' "$pat" "$hits"; fi
done
[ "$found" -eq 0 ] && echo '（无：新增代码里没有联网、起进程、加载动态库、读钥匙串、装事件监听）'

section '4. 遥测 / 指纹 / 上报关键词（新增行）'
printf '%s\n' "$ADDED" | grep -inE 'telemetry|analytics|crashlytics|sentry|firebase|mixpanel|amplitude|deviceId|installId|machineId|上报|埋点|统计' | head -20 || echo '（无）'

section '5. 权限 / 构建期执行 / 凭据文件是否被动过'
git diff --stat "$BASE..$NEW" -- \
  'macos/Config/Info.plist' 'macos/Config/*.entitlements' 'macos/Config/*.xcconfig' \
  'macos/build-dmg.sh' 'macos/KittyTools.xcodeproj/project.pbxproj' 'macos/tools' || true
printf '\n工程里的构建期脚本（壳脚本 Build Phase）—— 有输出就要逐行读完：\n'
git diff "$BASE..$NEW" -- 'macos/KittyTools.xcodeproj/project.pbxproj' | grep -E '^\+.*shellScript' || echo '（没有新增）'

section '6. 需要人工通读的文件（网络 / 凭据 / 构建 / 更新链路）'
git diff --name-only "$BASE..$NEW" \
  | grep -E 'Translate/(Providers|HTTP|SSE)|App/(Updater|AppDelegate)|Clipboard/(LinkPreview|ClipboardFilter|ClipboardWatcher)|StatusScreen/EmojiPack|Launcher/(IPAddresses|ExchangeRates|SystemControl|BrowserHistory|Bookmarks)|Storage/(Keychain|SettingsArchive|SettingsBackup|Database)|Screenshot/(ScreenRecorder|AudioRecorder)|Shell/(Subprocess|HotKeyCenter)' \
  || echo '（无）'

cat <<'EOF'

== 人工判定 ==
1. 第 2 节新增的每个主机、第 3 节每一处执行面、第 5 节的构建脚本，都要逐行读原文（不是只读 diff 摘要）。
2. 命中后门 / 静默上报 / 硬编码凭据 / 远程下载执行 / 越权访问 / 可疑混淆 → 停止，不构建，先报位置和能力。
3. 结论三种：确定问题 / 可疑 / 未见异常。
4. 过了才继续：git rebase upstream/macos → tools/local/verify.sh → 构建。
5. 审完把新 commit 写进 tools/local/AUDITED，别让下次重新审一遍老代码。
EOF