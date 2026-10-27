#!/bin/bash
# sync-allison-branch.sh
# AVM — Accessible Virtual Machine
#
# Rebuilds a branch offered to the original project (2026-10-26):
# Allison Meloy's allisonfm85/accessible-virtual-machine plus a tree of
# this fork's, with her app's identity in place of this fork's. Every fix
# then reaches her pull requests with one command instead of being redone
# by hand.
#
# What changes on the way, and nothing else:
#   - bundle ID com.fullcircleat.AVM -> com.alllisonmeloy.AVM, and the USB
#     helper's launchd plist renamed to match; the same for the labels
#     that start with it (com.fullcircleat.avm-clipboard, in macOS guests);
#   - team 9G2D7CDZ5D -> 4NZJSBJ32X;
#   - amenathomas1997/... repository and CocoaSpice links -> allisonfm85/...;
#   - SUFeedURL and SUPublicEDKey, appcast.xml, and the version numbers:
#     hers, from her main;
#   - the update key's keychain account: Sparkle's default, ed25519;
#   - text between <!-- fork-only --> and <!-- /fork-only --> removed, and
#     <!-- upstream-only ... --> blocks uncommented.
# Then it checks that nothing of this fork's identity is left, and commits
# the result as one commit on top of the branch it goes on.
#
# A tree that already has her identity comes through unchanged, so a
# branch built by hand from her main (one feature of this fork's, say)
# goes through the same checks.
#
#   Tools/sync-allison-branch.sh           main onto for-allison, don't push
#   Tools/sync-allison-branch.sh --push    and push it (updates her PR)
#
# Any tree onto any base (2026-10-27, one pull request per feature):
#   --tree REV        the tree to take (default origin/main)
#   --onto REV[,REV]  the commit(s) it goes on; several make a merge
#                     (default origin/for-allison, else her main)
#   --branch NAME     the local branch to set (default for-allison)
#   --message FILE    the commit message (default a "Sync" message)
#   --tree-only       print the mapped tree's ID and stop: no commit
#   --no-fetch        don't fetch first
#
# It works in a temporary git worktree, so this checkout is never touched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"
UPSTREAM_REMOTE="${AVM_UPSTREAM_REMOTE:-upstream}"
TREE="origin/${AVM_SYNC_SOURCE:-main}"
ONTO=""
TARGET="for-allison"
MESSAGE=""
PUSH=0
TREE_ONLY=0
FETCH=1
usage() { echo "Usage: $0 [--tree REV] [--onto REV[,REV]] [--branch NAME] [--message FILE] [--tree-only] [--no-fetch] [--push]"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --push) PUSH=1 ;;
        --tree) TREE="$2"; shift ;;
        --onto) ONTO="$2"; shift ;;
        --branch) TARGET="$2"; shift ;;
        --message) MESSAGE="$2"; shift ;;
        --tree-only) TREE_ONLY=1 ;;
        --no-fetch) FETCH=0 ;;
        -h|--help) sed -n 2,40p "$0"; exit 0 ;;
        *) usage; exit 64 ;;
    esac
    shift
done

fail() {
    echo "FAILED: $1" >&2
    if [ $# -ge 2 ]; then echo "Next: $2" >&2; fi
    exit 1
}
# Progress goes to stderr, so --tree-only prints only the tree.
say() { echo "$@" >&2; }

if [ "$FETCH" = "1" ]; then
    git -C "$REPO_ROOT" fetch -q origin || fail "Couldn't reach this fork on GitHub."
    git -C "$REPO_ROOT" fetch -q "$UPSTREAM_REMOTE" || fail "Couldn't reach Allison's repository (remote $UPSTREAM_REMOTE)." "git remote add upstream https://github.com/allisonfm85/accessible-virtual-machine"
fi
if [ -n "$MESSAGE" ]; then
    [ -f "$MESSAGE" ] || fail "No message file at $MESSAGE."
    MESSAGE="$(cd "$(dirname "$MESSAGE")" && pwd)/$(basename "$MESSAGE")"
fi
SRC_SHA="$(git -C "$REPO_ROOT" rev-parse --verify "$TREE^{commit}")" || fail "$TREE isn't a commit."
HER="$UPSTREAM_REMOTE/main"
if [ -z "$ONTO" ]; then
    if git -C "$REPO_ROOT" rev-parse -q --verify "origin/$TARGET" >/dev/null; then
        ONTO="origin/$TARGET"
    else
        ONTO="$HER"
    fi
fi
PARENTS=()
IFS=',' read -r -a ONTO_LIST <<< "$ONTO"
for p in "${ONTO_LIST[@]}"; do
    PARENTS+=("$(git -C "$REPO_ROOT" rev-parse --verify "$p^{commit}")") || fail "$p isn't a commit."
done

WT="$(mktemp -d "${TMPDIR:-/tmp}/avm-sync.XXXXXX")"
cleanup() { git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$WT"; }
trap cleanup EXIT

git -C "$REPO_ROOT" worktree add -q --detach "$WT" "${PARENTS[0]}"
cd "$WT"

say "== Taking $TREE ($(git rev-parse --short "$SRC_SHA"))"
git read-tree -u --reset "$SRC_SHA"

say "== Putting back Allison's identity"
# This script is this fork's own tool (it names the fork's identity to
# find it), so her branch doesn't carry it.
if [ -f "Tools/$SELF" ]; then
    git rm -q --cached "Tools/$SELF" && rm -f "Tools/$SELF"
fi
if [ -f Resources/com.fullcircleat.AVM.usbhelper.plist ]; then
    git mv -f Resources/com.fullcircleat.AVM.usbhelper.plist Resources/com.alllisonmeloy.AVM.usbhelper.plist
fi
# (Nothing to change, as in a tree that already has her identity, is fine.)
{ git grep -lzI -e "com.fullcircleat" -e "9G2D7CDZ5D" -e "amenathomas1997" -e "fullcircleat-avm" -- . ':!*.msi' || true; } \
    | xargs -0 sed -i '' \
        -e 's/com\.fullcircleat\.AVM/com.alllisonmeloy.AVM/g' \
        -e 's/com\.fullcircleat\.avm-/com.alllisonmeloy.avm-/g' \
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
        path.write_text(re.sub(r"\n{3,}", "\n\n", new))
PY

say "== Checking"
LEFT="$(git grep -nI -e "fullcircleat" -e "9G2D7CDZ5D" -e "amenathomas" -e "Full Circle" -e "fork-only" -e "upstream-only" -- . ':!*.msi' || true)"
[ -z "$LEFT" ] || fail "This fork's identity is still in the branch:
$LEFT" "Add the case to this script, then run it again."
xmllint --noout appcast.xml Resources/autounattend.xml || fail "An XML file isn't valid after the sync."
plutil -lint -s AVM/Info.plist || fail "AVM/Info.plist isn't valid after the sync."
for f in Tools/*.sh; do [ -e "$f" ] || continue; bash -n "$f" || fail "$f has a syntax error after the sync."; done
say "   No fork identity left; XML, Info.plist and scripts are valid."

git add -A
NEW_TREE="$(git write-tree)"
if [ "$TREE_ONLY" = "1" ]; then
    echo "$NEW_TREE"
    exit 0
fi
if [ "${#PARENTS[@]}" = "1" ] && [ "$NEW_TREE" = "$(git rev-parse "${PARENTS[0]}^{tree}")" ]; then
    say "== Nothing to sync: $ONTO already matches $TREE."
    exit 0
fi
git diff --cached --stat "${PARENTS[0]}" | tail -1 >&2
if [ -z "$MESSAGE" ]; then
    MESSAGE="$WT/.sync-message"
    printf '%s\n\n%s\n%s\n' \
        "Sync with amenathomas1997/accessible-virtual-machine $TREE ($(git rev-parse --short "$SRC_SHA"))" \
        "Made by Tools/$SELF: this fork's $TREE with the original" \
        "project's identity, feed, key and version numbers kept." > "$MESSAGE"
fi
PARENT_ARGS=()
for p in "${PARENTS[@]}"; do PARENT_ARGS+=(-p "$p"); done
COMMIT="$(git commit-tree "$NEW_TREE" "${PARENT_ARGS[@]}" -F "$MESSAGE")"
say "== Committed $(git rev-parse --short "$COMMIT") for $TARGET"

if [ "$PUSH" = "1" ]; then
    git push -q origin "$COMMIT:refs/heads/$TARGET"
    say "== Pushed to origin/$TARGET; a pull request from it updates itself."
else
    git -C "$REPO_ROOT" update-ref "refs/heads/$TARGET" "$COMMIT"
    say "== Not pushed. Local branch $TARGET updated; review it, then run with --push."
fi
