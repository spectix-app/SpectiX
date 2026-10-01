#!/bin/bash
# Exercise WindowFolderResolve (T317) — which project an ambiguous window title means.
#
# Why a script and not the app: the bug this guards against is a PHANTOM group, and a
# phantom is invisible in every record the app leaves behind. Both candidate paths are
# legitimate, the title looks fine, and nothing throws — the only way to see it is to
# look at the list with the right two worktrees open, in the right state, on the right
# Space. Reproducing that by hand takes minutes and can't be repeated on demand.
#
# WindowFolderResolve takes every input as an argument for exactly this reason: it
# compiles on its own (no AppController, no AppKit), so the six cases below run in a
# second. Case names match the plan in docs/jump.md.
#
# Usage: tools/empty-group-check.sh    (from anywhere; prints PASS/FAIL per case)
set -uo pipefail
cd "$(dirname "$0")/.."

ROOT=$(mktemp -d /tmp/spectix-emptygroup.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

MAIN=/Users/dev/Projects/acme/apps/web                # pinned in ProjectHistory
WT=/Users/dev/Projects/acme-wt-web/apps/web

cat > "$ROOT/main.swift" <<'SWIFT'
import Foundation

// Read cases from argv as: <name>|<candidates,>|<doc>|<active,>|<editorFolders,>|<taken,>
// and print "<name>\t<result>". A dash means "none" in any field.
func set(_ s: String) -> Set<String> { s == "-" ? [] : Set(s.split(separator: ",").map(String.init)) }
func list(_ s: String) -> [String] { s == "-" ? [] : s.split(separator: ",").map(String.init) }

for arg in CommandLine.arguments.dropFirst() {
    let f = arg.components(separatedBy: "|")
    let got = WindowFolderResolve.resolve(candidates: list(f[1]),
                                          doc: f[2] == "-" ? nil : f[2],
                                          activeCwds: set(f[3]),
                                          editorFolders: set(f[4]),
                                          taken: set(f[5]))
    print("\(f[0])\t\(got ?? "-")")
}
SWIFT

swiftc -O WindowFolderResolve.swift "$ROOT/main.swift" -o "$ROOT/resolve" 2>&1 | grep -v '^ *$' | head -20
[ -x "$ROOT/resolve" ] || { echo "FAIL  build"; exit 1; }

FAILED=0
run() {  # run <name> <expected> <candidates> <doc> <active> <editorFolders> <taken>
  local got
  got=$("$ROOT/resolve" "$1|$3|$4|$5|$6|$7" | cut -f2-)
  if [ "$got" = "$2" ]; then printf 'PASS  %s\n' "$1"
  else printf 'FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$got"; FAILED=1; fi
}

# S1 — the reported bug. Only the worktree window is open and it HAS sessions; its title
# is a webview's ("99 Ranch probe (127.0.0.1:8799) — web") so there is no doc. The
# pinned main-repo path ranks first and has no session, which is how it became a phantom.
run "S1 worktree-only window, sibling has sessions" "-" \
    "$MAIN,$WT" "-" "$WT" "$MAIN,$WT" "-"

# S2 — only the main repo is open, nothing has sessions, and the worktree ranks first.
# The editor's own folder list is what breaks the tie toward the window that exists.
run "S2 main-repo-only window, editor list decides" "$MAIN" \
    "$WT,$MAIN" "-" "-" "$MAIN" "-"

# S3 — both open, one has sessions, neither shows a document. Both windows decline: a
# missing grey header costs less than a phantom one (docs/desktop-app.md, same call).
run "S3 both open, sibling has sessions, both decline" "-" \
    "$MAIN,$WT" "-" "$WT" "$MAIN,$WT" "-"

# S4 — both open, neither has sessions, neither shows a document. The first window takes
# the ranked path; the second must resolve to the OTHER one, not repeat it.
run "S4a both sessionless, first takes the ranked path" "$MAIN" \
    "$MAIN,$WT" "-" "-" "$MAIN,$WT" "-"
run "S4b both sessionless, second takes the other" "$WT" \
    "$MAIN,$WT" "-" "-" "$MAIN,$WT" "$MAIN"

# S5 — T267 regression: a document under the worktree outranks the pinned main repo.
run "S5 document decides (T267)" "$WT" \
    "$MAIN,$WT" "$WT/src/app.ts" "-" "-" "-"
run "S5b document under the OTHER candidate" "$MAIN" \
    "$WT,$MAIN" "$MAIN/src/app.ts" "-" "-" "-"
# The document settles WHICH project this is even when the answer is "the one that
# already has a real group" — then the right output is nothing, not the runner-up.
# Without this case the strongest branch in resolve() has no test behind it.
run "S5c document names a candidate that has sessions" "-" \
    "$MAIN,$WT" "$WT/src/app.ts" "$WT" "-" "-"
run "S5d document names a candidate already taken" "-" \
    "$MAIN,$WT" "$WT/src/app.ts" "-" "-" "$WT"

# S6 — one candidate: byte-for-byte the pre-T317 behaviour, including the two rejections.
run "S6a single candidate resolves" "$MAIN" "$MAIN" "-" "-" "-" "-"
run "S6b single candidate with sessions yields nothing" "-" "$MAIN" "-" "$MAIN" "-" "-"
run "S6c single candidate already taken yields nothing" "-" "$MAIN" "-" "-" "-" "$MAIN"
run "S6d no candidate at all" "-" "-" "-" "-" "-" "-"

# Duplicate collapsing: one path reaches the candidate list from BOTH ProjectHistory and
# EditorWorkspaces. Left alone it makes an unambiguous name look ambiguous, and S6b's
# rejection would turn into S3's decline — same answer for the wrong reason, until the
# day the duplicate sits next to a real sibling.
run "dup collapses to one candidate" "$MAIN" "$MAIN,$MAIN" "-" "-" "-" "-"
run "dup does not mask a real sibling" "$WT" \
    "$MAIN,$WT,$MAIN" "$WT/x.ts" "-" "-" "-"

# A component boundary, not a prefix: /a/web-dash must never count as living under /a/web.
run "doc under a sibling with a shared prefix" "${MAIN}-dash" \
    "$MAIN,${MAIN}-dash" "${MAIN}-dash/x.ts" "-" "-" "-"

echo
[ $FAILED -eq 0 ] && echo "all checks passed" || echo "SOME CHECKS FAILED"
exit $FAILED
