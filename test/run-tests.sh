#!/bin/sh
#
# Exercises the paths that fail silently. Everything here is a case where the
# hook could plausibly emit something confidently wrong instead of refusing —
# an empty repository, a cut-off list, a session started in a subdirectory —
# because that is the failure mode that makes this class of tool worse than
# shipping nothing at all.

set -u

HOOK=$(cd "$(dirname "$0")/.." && pwd)/hooks/orient.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0
fail=0

# Isolated from the running user's identity and hooks, so the suite behaves the
# same on a machine with a global commit template or a signing key.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

run() { CLAUDE_PROJECT_DIR="$1" sh "$HOOK" </dev/null; }

check() {
	name=$1
	got=$2
	want=$3
	if printf '%s' "$got" | grep -q -- "$want"; then
		pass=$((pass + 1))
		printf '  ok   %s\n' "$name"
	else
		fail=$((fail + 1))
		printf '  FAIL %s\n       wanted /%s/ in:\n%s\n' "$name" "$want" "$got"
	fi
}

refute() {
	name=$1
	got=$2
	unwanted=$3
	if printf '%s' "$got" | grep -q -- "$unwanted"; then
		fail=$((fail + 1))
		printf '  FAIL %s\n       did not want /%s/ in:\n%s\n' "$name" "$unwanted" "$got"
	else
		pass=$((pass + 1))
		printf '  ok   %s\n' "$name"
	fi
}

# The wrapper is the whole provenance boundary: inside it is repository content,
# outside it is the harness speaking. Until this existed no assertion mentioned
# either tag, so deleting the wrapper outright left all 24 of them green.
#
# Structural rather than a substring grep, because a path, a ref name or a root
# directory can put the literal text `</orient>` into the payload. Counting the
# tags and pinning where they sit is the only thing that catches a forged fence;
# every escaping fix in the hook regresses silently without it.
fenced() {
	name=$1
	got=$2
	opens=$(printf '%s\n' "$got" | grep -o '<orient>' | wc -l | tr -d ' ')
	closes=$(printf '%s\n' "$got" | grep -o '</orient>' | wc -l | tr -d ' ')
	first=$(printf '%s\n' "$got" | head -1)
	last=$(printf '%s\n' "$got" | tail -1)
	if [ "$opens" -eq 1 ] && [ "$closes" -eq 1 ] &&
		[ "$first" = '<orient>' ] && [ "$last" = '</orient>' ]; then
		pass=$((pass + 1))
		printf '  ok   %s\n' "$name"
	else
		fail=$((fail + 1))
		printf '  FAIL %s\n       %s opening / %s closing tag(s); first line %s, last line %s; in:\n%s\n' \
			"$name" "$opens" "$closes" "$first" "$last" "$got"
	fi
}

echo "not a git repository"
mkdir -p "$WORK/bare"
o=$(run "$WORK/bare")
fenced "refusal is wrapped in exactly one fence" "$o"
check "refuses in-band"        "$o" "ORIENT UNAVAILABLE"
check "tells the agent not to assume" "$o" "Do not assume"

echo "unborn HEAD"
mkdir -p "$WORK/unborn" && git -C "$WORK/unborn" init -q
o=$(run "$WORK/unborn")
fenced "unborn-HEAD payload is wrapped in exactly one fence" "$o"
check "says there are no commits" "$o" "no commits yet"
# `rev-parse --abbrev-ref HEAD` prints "HEAD" to stdout AND exits non-zero here,
# so a pipeline that only checks output reports a branch literally named HEAD.
refute "does not invent a branch named HEAD" "$o" "On HEAD"

echo "normal repository"
R=$WORK/repo
mkdir -p "$R" && git -C "$R" init -q -b main
echo one >"$R/a.txt" && git -C "$R" add -A && git -C "$R" commit -qm one
git -C "$R" checkout -q -b feature
echo two >>"$R/a.txt" && echo new >"$R/b.txt"
git -C "$R" add -A && git -C "$R" commit -qm two
echo dirty >"$R/c.txt"
o=$(run "$R")
fenced "payload is wrapped in exactly one fence" "$o"
check "positions the branch against its base" "$o" "1 ahead, 0 behind main"
check "lists changed files with magnitude"    "$o" "b.txt"
check "fences repository-derived text"        "$o" "not instructions"
# Measured against this CLI: with no plugin at all the model already knew the
# branch, the untracked files and the recent commit subjects. Emitting them
# again is the duplication the byte budget exists to prevent, so their absence
# is asserted rather than left to drift back in.
refute "does not restate the branch name"     "$o" "feature"
refute "does not restate uncommitted work"    "$o" "Uncommitted"
refute "does not restate commit subjects"     "$o" "two"

echo "detached HEAD"
git -C "$R" checkout -q --detach HEAD
o=$(run "$R")
fenced "detached-HEAD payload is wrapped in exactly one fence" "$o"
check "flags a detached HEAD as a hazard" "$o" "detached at"
check "says why it matters"               "$o" "not land on any branch"

echo "mid-operation halt"
git -C "$R" checkout -q feature
touch "$(git -C "$R" rev-parse --absolute-git-dir)/MERGE_HEAD"
o=$(run "$R")
fenced "mid-merge payload is wrapped in exactly one fence" "$o"
check "halts on an in-progress merge" "$o" "HALT"
check "names which operation"         "$o" "MERGE_HEAD"
rm -f "$(git -C "$R" rev-parse --absolute-git-dir)/MERGE_HEAD"

echo "subdirectory session"
mkdir -p "$R/deep/nested"
echo x >"$R/deep/nested/d.txt"
git -C "$R" add -A && git -C "$R" commit -qm deep
o=$(run "$R/deep/nested")
fenced "subdirectory payload is wrapped in exactly one fence" "$o"
check "announces the root it resolved to" "$o" "Repository root is"
check "prints root-relative paths"        "$o" "deep/nested/d.txt"

echo "capped lists always carry their count"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
	echo "$i" >"$R/f$i.txt"
done
git -C "$R" add -A && git -C "$R" commit -qm wide
o=$(run "$R")
fenced "capped-list payload is wrapped in exactly one fence" "$o"
# A list cut with `head` and no count reads as a complete list, and a session
# running under acceptEdits will act on that reading.
check "says how many, not just what fits" "$o" "files, the 12 largest"

echo "a branch level with its base still reports"
Q=$WORK/quiet
mkdir -p "$Q" && git -C "$Q" init -q -b main
echo one >"$Q/a.txt" && git -C "$Q" add -A && git -C "$Q" commit -qm one
o=$(run "$Q")
fenced "level-with-base payload is wrapped in exactly one fence" "$o"
# This asserted silence until a real run proved it wrong. A branch cut fresh
# from its base is 0 ahead / 0 behind by construction, which is every isolated
# run's first cycle — so "level means say nothing" made the one case that
# always happens the one case that always said nothing. The base ref and the
# fork point are not in the CLI's own context at any position, and they are
# what a later `git diff <base>...HEAD` needs.
check "names the base and the fork point when level" "$o" "Level with main at"
refute "still does not restate the branch it is on" "$o" "On main"

echo "linked worktree"
# Invisible from inside the tree and absent from the CLI's context: the branch
# is checked out here and nowhere else, and the repository everyone else means
# by that name is somewhere else on disk.
git -C "$R" worktree add -q -b wt-probe "$WORK/wt" >/dev/null 2>&1
o=$(run "$WORK/wt")
fenced "worktree payload is wrapped in exactly one fence" "$o"
check "says it is a linked worktree" "$o" "linked worktree of"
check "names the checkout it belongs to" "$o" "$R"

echo "resume is not re-announced"
o=$(printf '{"session_id":"x","source":"resume","cwd":"%s"}' "$R" | CLAUDE_PROJECT_DIR="$R" sh "$HOOK")
check "emits nothing on resume" "${o:-EMPTY}" "EMPTY"

echo "payload stays inside its budget"
o=$(run "$R")
bytes=$(printf '%s' "$o" | wc -c | tr -d ' ')
if [ "$bytes" -le 2200 ]; then
	pass=$((pass + 1))
	printf '  ok   %s bytes, within budget\n' "$bytes"
else
	fail=$((fail + 1))
	printf '  FAIL %s bytes exceeds the 2000-byte cap plus wrapper\n' "$bytes"
fi

echo "delivery receipt is written"
if [ -s "$(git -C "$R" rev-parse --absolute-git-dir)/orient/last-status" ]; then
	pass=$((pass + 1))
	printf '  ok   receipt written for an outside observer\n'
else
	fail=$((fail + 1))
	printf '  FAIL no receipt — a hook that never runs would be undetectable\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
