#!/bin/sh
# Make .env exist, and make sure the application path and every secret in it
# have a value.
#
# Idempotent by design: a value that is already set is never touched, so
# re-running `make up` cannot invalidate sessions or reset a password
# somebody has changed.
set -eu
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
    cp .env.example .env
    chmod 600 .env
    echo "Created .env from .env.example"
fi
# It holds a secret key and an administrator password either way.
chmod 600 .env

# Letters and digits only, on both paths. The value ends up in a URL, in a
# shell, in a Makefile and in Compose's own interpolation, and every one of
# those has characters it treats specially.
random_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | cut -c1-48
    else
        python3 -c 'import secrets; print(secrets.token_urlsafe(64))' \
            | tr -dc 'A-Za-z0-9' | cut -c1-48
    fi
}

# Django rejects a secret key shorter than 32 characters as unset, and this
# script would never regenerate it because it is no longer blank. Refuse to
# write a short one rather than produce a stack that cannot boot.
generate_secret() {
    value=$(random_secret)
    if [ "${#value}" -lt 32 ]; then
        echo "ensure-env.sh: could not generate a long enough secret (got ${#value}" \
             "characters). Is openssl or python3 working?" >&2
        exit 1
    fi
    printf '%s' "$value"
}

# A value is "set" only if something remains after stripping a trailing CR,
# so a .env saved with CRLF line endings does not read as already filled in.
current_value() {
    sed -n "s/^$1=//p" .env | tr -d '\r' | tail -1
}

# Write a value for a key that is absent or blank; one that is set is left alone.
set_if_blank() {
    key=$1
    value=$2
    if ! grep -q "^$key=" .env; then
        printf '%s=%s\n' "$key" "$value" >> .env
        return
    fi
    awk -v k="$key" -v v="$value" '
        { line = $0; sub(/\r$/, "", line) }
        line == k "=" { print k "=" v; next }
        { print }
    ' .env > .env.tmp && mv .env.tmp .env
    chmod 600 .env
}

fill_if_blank() {
    key=$1
    if [ -n "$(current_value "$key")" ]; then
        return
    fi
    # Assigned first: a failure inside $(...) only stops the script when it
    # is the whole command, not when it is an argument to another one.
    secret=$(generate_secret)
    set_if_blank "$key" "$secret"
    echo "Generated $key in .env"
}

# Where the application checkout is. Resolved once and written back, because
# Compose reads .env too and the two must agree on the path. A checkout beside
# this one is used where it is; otherwise the source goes inside this
# repository, under the gitignored src/, where `make src` clones it.
if [ -z "$(current_value ARKS_SRC)" ]; then
    if [ -f ../arks-service-new/manage.py ]; then
        src=../arks-service-new
    else
        src=./src/arks-service-new
    fi
    set_if_blank ARKS_SRC "$src"
    echo "Set ARKS_SRC=$src in .env"
fi

fill_if_blank DJANGO_SECRET_KEY
fill_if_blank DJANGO_SUPERUSER_PASSWORD
