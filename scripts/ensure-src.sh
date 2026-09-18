#!/bin/sh
# Make sure the application checkout ARKS_SRC points at is there, cloning it
# if it is not.
#
# A checkout that already exists is never pulled, reset or otherwise touched:
# it is somebody's working tree. Updating it is a `git pull` of your own,
# followed by `make install` to bake the new code into the image.
set -eu
cd "$(dirname "$0")/.."

DEFAULT_REPO=https://github.com/digitalutsc/arks-service-new.git

current_value() {
    sed -n "s/^$1=//p" .env 2>/dev/null | tr -d '\r' | tail -1
}

src=$(current_value ARKS_SRC)
if [ -z "$src" ]; then
    echo "ARKS_SRC is blank in .env. Run \`make env\` to have it filled in." >&2
    exit 1
fi

if [ -f "$src/manage.py" ]; then
    echo "Application source: $src"
    exit 0
fi

# Something is already there and it is not the application. Cloning over it, or
# clearing it out first, is not this script's call to make.
if [ -e "$src" ] && { [ ! -d "$src" ] || [ -n "$(ls -A "$src")" ]; }; then
    echo "No application checkout at $src (there is no $src/manage.py)," >&2
    echo "and it is not empty, so nothing will be cloned over it." >&2
    echo "Set ARKS_SRC in ./.env to where the arks-service-new checkout is." >&2
    exit 1
fi

command -v git >/dev/null 2>&1 || {
    echo "git is not installed, and there is no application checkout at $src." >&2
    exit 1
}

# Without ARKS_REPO, ask for the application the same way this repository was
# cloned: both live in the same organisation, so whichever of SSH and HTTPS
# worked for this one, with whatever credentials, works for that one too.
repo=$(current_value ARKS_REPO)
if [ -z "$repo" ]; then
    origin=$(git remote get-url origin 2>/dev/null || true)
    # Only the last path component is swapped: a local origin may have the
    # name in a directory above it as well. An origin the swap does not change
    # is a fork or a rename, and says nothing about where the application is.
    repo=$(printf '%s' "$origin" \
        | sed 's#docker-arks-service\(\.git\)\{0,1\}/*$#arks-service-new\1#')
    if [ "$repo" = "$origin" ]; then
        repo=$DEFAULT_REPO
    fi
fi
ref=$(current_value ARKS_REF)

echo "No application checkout at $src; cloning $repo${ref:+ ($ref)} ..."
mkdir -p "$(dirname "$src")"
git clone ${ref:+--branch "$ref"} "$repo" "$src" || {
    echo >&2
    echo "Could not clone $repo${ref:+ at $ref} into $src." >&2
    if [ -n "$ref" ]; then
        echo "Check that ARKS_REF in ./.env names a branch or tag that exists." >&2
    fi
    echo "Set ARKS_REPO in ./.env to a URL you can reach, or clone the" >&2
    echo "application into $src by hand, then run make again." >&2
    exit 1
}

test -f "$src/manage.py" || {
    echo "Cloned $repo into $src, but there is no manage.py in it." >&2
    echo "Check ARKS_REPO and ARKS_REF in ./.env." >&2
    exit 1
}
echo "Application source: $src"
