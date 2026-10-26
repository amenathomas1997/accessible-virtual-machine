#!/bin/bash
# sync-allison-branch.sh
# AVM — Accessible Virtual Machine
#
# Rebuilds the branch offered to the original project (2026-10-26):
# for-allison, Allison Meloy's allisonfm85/accessible-virtual-machine
# plus everything on this fork's main, with her app's identity in place
# of this fork's. Every fix then reaches her pull request with one command
# instead of being redone by hand.
#
# What changes on the way, and nothing else:
#   - bundle ID com.fullcircleat.AVM -> com.alllisonmeloy.AVM, and the USB
#     helper's launchd plist renamed to match;
#   - team 9G2D7CDZ5D -> 4NZJSBJ32X;
#   - amenathomas1997/... repository and CocoaSpice links -> allisonfm85/...;
#   - SUFeedURL and SUPublicEDKey, appcast.xml, and the version numbers:
#     hers, from her main;
#   - the update key's keychain account: Sparkle's default, ed25519;
#   - text between <!-- fork-only --> and <!-- /fork-only --> removed, and
#     <!-- upstream-only ... --> blocks uncommented.
# Then it checks that nothing of this fork's identity is left, and commits
# the result on top of for-allison as one "Sync" commit.
#
#   Tools/sync-allison-branch.sh           build the commit, don't push
#   Tools/sync-allison-branch.sh --push    and push it (updates her PR)
#
# It works in a temporary git worktree, so this checkout is never touched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${AVM_SYNC_SOURCE:-main}"
TARGET="for-allison"
UPSTREAM_REMOTE="${AVM_UPSTREAM_REMOTE:-upstream}"
PUSH=0
case "${1:-}" in
    --push) PUSH=1 ;;
    "") ;;
    -h|--help) sed -n 2,27p "$0"; exit 0 ;;
    *) echo "Usage: $0 [--push]"; exit 64 ;;
esac

fail() {
    echo "FAILED: $1"
    if [ $# -ge 2 ]; then echo "Next: $2"; fi
    exit 1
}

git -C "$REPO_ROOT" fetch -q origin || fail "Couldn't reach this fork on GitHub."
git -C "$REPO_ROOT" fetch -q "$UPSTREAM_REMOTE" || fail "Couldn't reach Allison's repository (remote $UPSTREAM_REMOTE)." "git remote add upstream https://github.com/allisonfm85/accessible-virtual-machine"
SRC_SHA="$(git -C "$REPO_ROOT" rev-parse "origin/$SOURCE")"
HER="$UPSTREAM_REMOTE/main"

WT="$(mktemp -d "${TMPDIR:-/tmp}/avm-sync.XXXXXX")"
cleanup() { git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$WT"; }
trap cleanup EXIT

if git -C "$REPO_ROOT" rev-parse -q --verify "origin/$TARGET" >/dev/null; then
    git -C "$REPO_ROOT" worktree add -q --detach "$WT" "origin/$TARGET"
else
    git -C "$REPO_ROOT" worktree add -q --detach "$WT" "$HER"
fi
cd "$WT"

echo "== Taking this fork's $SOURCE ($(git rev-parse --short "$SRC_SHA"))"
git read-tree -u --reset "$SRC_SHA"

echo "== Putting back Allison's identity"
# This script is this fork's own tool (it names the fork's identity to
# find it), so her branch doesn't carry it.
git rm -q --cached "Tools/$(basename "$0")" && rm -f "Tools/$(basename "$0")"
if [ -f Resources/com.fullcircleat.AVM.usbhelper.plist ]; then
    git mv -f Resources/com.fullcircleat.AVM.usbhelper.plist Resources/com.alllisonmeloy.AVM.usbhelper.plist
fi
git grep -lzI -e "com.fullcircleat" -e "9G2D7CDZ5D" -e "amenathomas1997" -e "fullcircleat-avm" -- . ':!*.msi' \
    | xargs -0 sed -i '' \
        -e 's/com\.fullcircleat\.AVM/com.alllisonmeloy.AVM/g' \
        -e 's/9G2D7CDZ5D/4NZJSBJ32X/g' \
        -e 's#amenathomas1997/accessible-virtual-machine#allisonfm85/accessible-virtual-machine#g' \
        -e 's#amenathomas1997/CocoaSpice#allisonfm85/CocoaSpice#g' \
        -e 's/fullcircleat-avm/ed25519/g'
git show "$HER:appcast.xml" > appcast.xml

python3 - "$(git show "$HER:AVM/Info.plist")" "$(git show "$HER:AVM.xcodeproj/project.pbxproj")" <<'PY'
import re, sys, pathlib
her_plist, her_pbx = sys.argv[1], sys.argv[2]

# Her feed and key; everything else in Info.plist stays as this fork has it.
plist = pathlib.Path("AVM/Info.plist")
text = plist.read_text()
for key in ("SUFeedURL", "SUPublicEDKey"):
    pattern = r"(<key>%s</key>\s*<string>)[^<]*(</string>)" % key
    value = re.search(pattern, her_plist).group(0)
    text = re.sub(pattern, lambda m: value, text)
plist.write_text(text)

# Her version numbers: she decides her own releases.
pbx = pathlib.Path("AVM.xcodeproj/project.pbxproj")
text = pbx.read_text()
for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
    value = re.search(r"%s = ([^;]+);" % key, her_pbx).group(1)
    text = re.sub(r"%s = [^;]+;" % key, "%s = %s;" % (key, value), text)
pbx.write_text(text)

# Fork-only text out, upstream-only text in.
for path in pathlib.Path(".").rglob("*.md"):
    if ".git" in path.parts:
        continue
    text = path.read_text()
    # Whole-line blocks go with their lines; an inline passage goes alone,
    # so no line break is lost (a lost one can turn a "---" into a heading).
    new = re.sub(r"^<!-- fork-only -->\n.*?^<!-- /fork-only -->\n", "", text, flags=re.S | re.M)
    new = re.sub(r"<!-- fork-only -->.*?<!-- /fork-only -->", "", new, flags=re.S)
    new = re.sub(r"^<!-- upstream-only\n(.*?)\n-->\n", r"\1\n", new, flags=re.S | re.M)
    if new != text:
        path.write_text(new)
PY

echo "== Checking"
LEFT="$(git grep -nI -e "fullcircleat" -e "9G2D7CDZ5D" -e "amenathomas" -e "Full Circle" -e "fork-only" -e "upstream-only" -- . ':!*.msi' || true)"
[ -z "$LEFT" ] || fail "This fork's identity is still in the branch:
$LEFT" "Add the case to this script, then run it again."
xmllint --noout appcast.xml Resources/autounattend.xml || fail "An XML file isn't valid after the sync."
plutil -lint -s AVM/Info.plist || fail "AVM/Info.plist isn't valid after the sync."
for f in Tools/*.sh; do bash -n "$f" || fail "$f has a syntax error after the sync."; done
echo "   No fork identity left; XML, Info.plist and scripts are valid."

git add -A
if git diff --cached --quiet; then
    echo "== Nothing to sync: $TARGET already matches $SOURCE."
    exit 0
fi
git diff --cached --stat | tail -1
git commit -q -m "Sync with amenathomas1997/accessible-virtual-machine $SOURCE ($(git rev-parse --short "$SRC_SHA"))

Made by Tools/sync-allison-branch.sh: this fork's $SOURCE with the original
project's identity, feed, key and version numbers kept."
echo "== Committed $(git rev-parse --short HEAD) on $TARGET"

if [ "$PUSH" = "1" ]; then
    git push -q origin "HEAD:refs/heads/$TARGET"
    echo "== Pushed to origin/$TARGET; the pull request to Allison updates itself."
else
    git -C "$REPO_ROOT" update-ref "refs/heads/$TARGET" HEAD
    echo "== Not pushed. Local branch $TARGET updated; review it, then run with --push."
fi
