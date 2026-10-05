#!/bin/bash
# Post-build audit — the two questions worth re-asking of every build before it
# leaves this machine.
#
#   [1] LICENSE  is it still the verbatim FSL-1.1-ALv2 text, shipped inside the bundle,
#                and does the README still carry the no-network promise?
#   [2] LEAK     does this build carry anything identifying about whoever built it —
#                home path, email, machine name, real name? And how much longer can
#                new builds be signed at all?
#
# Why a script rather than a checklist: the leak scan is the part that can't be done
# by eye. A stray /Users/<name> baked into one string is invisible in the running app
# and permanent the moment the zip is published — and the whole no-network / no-data
# pitch on the site is what makes it worth catching.
#
# Three verdict levels, because not every hit is a defect:
#   FAIL  ships something that should never leave this machine        → exit 1
#   WARN  known and deliberate, but worth re-deciding each release
#   PASS
#
# Usage: tools/release-check.sh [path/to/Some.app]
#   default target is SpectiX.app; pass the installer bundle to audit a release
#   candidate instead:  tools/release-check.sh "installer/build/Install SpectiX.app"
set -uo pipefail
cd "$(dirname "$0")/.."

APP="${1:-SpectiX.app}"
[ -d "$APP" ] || { echo "✖ 找不到 $APP —— 先跑 ./build.sh"; exit 1; }

PLIST="$APP/Contents/Info.plist"
EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null)
BIN="$APP/Contents/MacOS/$EXEC"

FAILED=0
pass(){ echo "  PASS  $1"; }
warn(){ echo "  WARN  $1"; }
fail(){ echo "  FAIL  $1"; FAILED=1; }
note(){ echo "        $1"; }
head_(){ echo ""; echo "── $1 ─────────────────────────────"; }

echo "审计目标: $APP"
echo "bundle id: ${BUNDLE_ID:-?}   架构: $(lipo -archs "$BIN" 2>/dev/null || echo '?')"

# ── [1] LICENSE ──────────────────────────────────────────────────────────────
# Releases after 1.9 are FSL-1.1-ALv2 (1.9 and earlier were GPL-3.0): the license
# is the verbatim FSL text, and the no-network promise lives in the README
# instead of a license clause. Both are what the site and the bundle point at,
# so both must still be there.
head_ "[1/2] LICENSE 与不联网承诺"

if [ ! -f LICENSE ]; then
  fail "LICENSE 文件不存在"
elif [ "$(head -1 LICENSE)" != "# Functional Source License, Version 1.1, ALv2 Future License" ]; then
  fail "LICENSE 首行不是「# Functional Source License, Version 1.1, ALv2 Future License」—— 许可证被换掉了？"
elif [ "$(shasum -a 256 < LICENSE)" = "$(shasum -a 256 < opensource/overlay/LICENSE)" ]; then
  pass "LICENSE 是 FSL-1.1-ALv2，且与 opensource/overlay/LICENSE 一致"
else
  fail "LICENSE 与 opensource/overlay/LICENSE 不一致 —— 包里和公开仓的许可证会对不上"
fi

if [ -f "$APP/Contents/Resources/LICENSE" ] && cmp -s LICENSE "$APP/Contents/Resources/LICENSE"; then
  pass "包内带了同一份 LICENSE"
else
  fail "包内 Contents/Resources/LICENSE 缺失或不是当前 LICENSE —— FSL 的 Redistribution 条款要求每份副本都附上许可证"
fi

for readme in README.md opensource/overlay/README.md; do
  if grep -q '^## Privacy: no network' "$readme" 2>/dev/null; then
    pass "$readme 有「Privacy: no network」一节"
  else
    fail "$readme 缺「## Privacy: no network」一节 —— build.sh 的报错和官网都指向它"
  fi
done

# ── [2] LEAK ─────────────────────────────────────────────────────────────────
# grep -ra over the whole bundle on purpose: it covers the binary's string table,
# Info.plist, the hook scripts, the editor extension, and any nested .app in one
# pass, so a new payload added later is scanned without touching this script.
head_ "[2/2] 个人信息泄漏"

GIT_EMAIL=$(git config user.email 2>/dev/null || true)
LOCALPART="${GIT_EMAIL%%@*}"
MACHINE=$(scutil --get ComputerName 2>/dev/null || true)

leak_scan(){ # $1=label  $2=pattern (fixed string)
  local hits
  hits=$(grep -rlaF "$2" "$APP" 2>/dev/null | head -5)
  if [ -z "$hits" ]; then
    pass "$1"
  else
    fail "$1 —— 命中「${2}」"
    echo "$hits" | while read -r f; do note "${f#$APP/}"; done
  fi
}

leak_scan "无真实 home 路径" "/Users/$USER"
[ -n "$GIT_EMAIL" ]  && leak_scan "无 git 邮箱"     "$GIT_EMAIL"
[ -n "$LOCALPART" ]  && leak_scan "无邮箱用户名"     "$LOCALPART"
[ -n "$MACHINE" ]    && leak_scan "无机器名"        "$MACHINE"

# The identifiers above come from this machine's config, so they miss names that
# were baked in some other way: 1.0–1.8 shipped the author's personal reverse-DNS prefix in the binary's
# string table (old bundle ids kept for migration) and none of the checks above saw it.
# The public-repo exporter already keeps the list of names that must never go out;
# read it from there so the two gates cannot drift apart.
PERSONAL=$(sed -n "s/^PERSONAL='\(.*\)'$/\1/p" tools/export-public.sh)
if [ -z "$PERSONAL" ]; then
  fail "读不到 tools/export-public.sh 里的 PERSONAL 名单 —— 无法扫个人名字"
else
  hits=$(LC_ALL=C grep -rlaiE "$PERSONAL" "$APP" 2>/dev/null | head -5)
  if [ -z "$hits" ]; then
    pass "无个人名字 / 账号（export-public.sh 的 PERSONAL 名单）"
  else
    fail "包里有个人名字 / 账号 —— strings 一扫就能看到"
    echo "$hits" | while read -r f; do note "${f#$APP/}: $(LC_ALL=C grep -aoiE "$PERSONAL" "$f" | sort -u | head -3 | tr '\n' ' ')"; done
  fi
fi

# The placeholder home is the tell that a real one was never interpolated: the app
# shows example paths in its own UI, and "/Users/you" is what they must read as.
if grep -qaF "/Users/you" "$BIN" 2>/dev/null; then
  pass "示例路径用占位符 /Users/you"
fi

# The bundle id is the one identifier that is BOTH public (anyone can plutil -p the
# Info.plist) and permanent (changing it orphans every user's Accessibility grant
# and preferences domain). So it is a WARN to re-decide, never an automatic FAIL.
ID_SEG=$(echo "$BUNDLE_ID" | cut -d. -f2)
if [ -n "$ID_SEG" ] && [ -n "$GIT_EMAIL" ] && echo "$GIT_EMAIL" | grep -qiF "$ID_SEG"; then
  warn "bundle id 第二段「${ID_SEG}」出现在你的邮箱里 —— 下载者 plutil -p 即可看到"
  note "改它的代价：老用户的辅助功能授权与偏好域全部作废（系统当成新 app）"
else
  pass "bundle id 不含可识别到你的字段"
fi

# A dev build must never ship: it carries dev-only features (demo mode with fake
# accounts, always-on rings). build.sh gives every dev build the .dev id, and that
# is now the only mark it leaves — the old marker string went with the expiry code.
case "$BUNDLE_ID" in
  *.dev) fail "这是 dev 构建（bundle id ${BUNDLE_ID}）—— 发布包必须是 DEV_BUILD=0 / package.sh 出的" ;;
  "")    warn "读不到 bundle id —— 无法确认不是 dev 构建" ;;
  *)     pass "发布路径构建（bundle id 不带 .dev）" ;;
esac

# Signing identity: an ad-hoc build carries no name at all, a Developer ID build
# always carries the certificate holder's legal name and there is no way to sign
# without it short of an Apple organisation account.
SIGN_AUTH=$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p' | head -1)
if [ -z "$SIGN_AUTH" ]; then
  pass "未用 Developer ID 签名（ad-hoc 构建，签名不带姓名）"
else
  warn "签名会公开证书持有人姓名：$SIGN_AUTH"
  note "任何人跑 codesign -dvvv / spctl -a -vvv 就能看到；个人开发者账号无法隐藏"
  note "要显示为机构名需换 Apple Developer 组织账号（需 D-U-N-S + 法人实体）"
fi

# Limits signing NEW packages only — already-signed ones carry --timestamp plus a
# stapled ticket, which outlive the certificate that produced them.
CERT_PEM=$(security find-certificate -c "Developer ID Application" -p 2>/dev/null)
if [ -z "$CERT_PEM" ]; then
  note "本机无 Developer ID 证书 —— 只能出 ad-hoc 包"
else
  CERT_END=$(echo "$CERT_PEM" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if ! echo "$CERT_PEM" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
    fail "签名证书已过期（${CERT_END}）—— 无法再签新包"
  elif ! echo "$CERT_PEM" | openssl x509 -noout -checkend 2592000 >/dev/null 2>&1; then
    warn "签名证书 30 天内到期（${CERT_END}）—— 尽快续期"
  elif ! echo "$CERT_PEM" | openssl x509 -noout -checkend 7776000 >/dev/null 2>&1; then
    warn "签名证书 90 天内到期（${CERT_END}）"
  else
    pass "签名证书有效期至 $CERT_END"
  fi
  note "已签发布包不受此日期影响：--timestamp + 公证票据在证书过期后依然验证通过"
fi

echo ""
if [ "$FAILED" = 0 ]; then
  echo "✅ 两项检查通过（WARN 项需你自己拍板，不阻断发布）"
else
  echo "❌ 有 FAIL 项 —— 修掉再打包"
fi
exit $FAILED
