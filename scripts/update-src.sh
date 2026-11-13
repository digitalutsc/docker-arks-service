#!/bin/sh
# Move the application checkout to ARKS_REF: fetch, then check out that tag,
# or fast-forward that branch. With ARKS_REF blank, the default branch.
#
# This is the one script that changes an existing checkout, and only when it
# is asked to by name (`make update`). It refuses when the checkout has
# uncommitted changes to tracked files, and it never discards commits: a
# branch that cannot be fast-forwarded stops with git's own message.
set -eu
cd "$(dirname "$0")/.."

current_value() {
    sed -n "s/^$1=//p" .env 2>/dev/null | tr -d '\r' | tail -1
}

describe() {
    git -C "$src" describe --tags --always --dirty 2>/dev/null || echo unknown
}

src=$(current_value ARKS_SRC)
if [ -z "$src" ] || [ ! -f "$src/manage.py" ]; then
    echo "There is no application checkout yet. Run \`make up\` first; it clones one." >&2
    exit 1
fi
if ! git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$src is not a git checkout, so there is nothing to update it from." >&2
    exit 1
fi

if [ -n "$(git -C "$src" status --porcelain --untracked-files=no)" ]; then
    echo "$src has uncommitted changes:" >&2
    git -C "$src" status --short --untracked-files=no >&2
    echo "Nothing was changed. Commit or stash them, then run make update again." >&2
    exit 1
fi

before=$(describe)
ref=$(current_value ARKS_REF)

echo "Fetching ${ref:-the default branch} for $src ..."
git -C "$src" fetch --tags origin

if [ -z "$ref" ]; then
    # origin/HEAD names the default branch; a clone always has it.
    ref=$(git -C "$src" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's#^origin/##')
    if [ -z "$ref" ]; then
        echo "ARKS_REF is blank and the checkout does not say what origin's default branch is." >&2
        echo "Set ARKS_REF in ./.env to a tag or a branch." >&2
        exit 1
    fi
fi

if git -C "$src" rev-parse --quiet --verify "refs/tags/$ref^{commit}" >/dev/null; then
    # A release: sit exactly on the tag.
    git -C "$src" -c advice.detachedHead=false checkout --quiet --detach "refs/tags/$ref"
elif git -C "$src" rev-parse --quiet --verify "refs/remotes/origin/$ref^{commit}" >/dev/null; then
    # A branch: be on it, at origin's latest. `checkout` creates the local
    # branch from origin's when there is none yet.
    git -C "$src" checkout --quiet "$ref"
    git -C "$src" -c advice.diverging=false merge --quiet --ff-only "origin/$ref" || {
        echo "$src has commits on $ref that origin does not, so it cannot simply be moved forward." >&2
        echo "Nothing was discarded. Sort the branch out by hand (push, rebase or reset), then run make update again." >&2
        exit 1
    }
elif git -C "$src" rev-parse --quiet --verify "$ref^{commit}" >/dev/null; then
    # A commit.
    git -C "$src" -c advice.detachedHead=false checkout --quiet --detach "$ref"
else
    echo "ARKS_REF=$ref is not a tag, a branch or a commit in $src after fetching." >&2
    echo "Nothing was changed. Check ARKS_REF in ./.env." >&2
    exit 1
fi

after=$(describe)
if [ "$before" = "$after" ]; then
    echo "Application source: $src is already at $after."
else
    echo "Application source: $src moved from $before to $after."
fi
