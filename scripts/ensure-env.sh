#!/bin/sh
# Make .env exist and make sure every secret in it has a value.
#
# Idempotent by design: a value that is already set is never touched, so
# re-running `make install` cannot invalidate sessions or reset a password
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

fill_if_blank() {
    key=$1
    if ! grep -q "^$key=" .env; then
        printf '%s=%s\n' "$key" "$(generate_secret)" >> .env
        echo "Added $key to .env with a generated value"
        return
    fi
    if [ -n "$(current_value "$key")" ]; then
        return
    fi
    value=$(generate_secret)
    awk -v k="$key" -v v="$value" '
        { line = $0; sub(/\r$/, "", line) }
        line == k "=" { print k "=" v; next }
        { print }
    ' .env > .env.tmp && mv .env.tmp .env
    chmod 600 .env
    echo "Generated $key in .env"
}

fill_if_blank DJANGO_SECRET_KEY
fill_if_blank DJANGO_SUPERUSER_PASSWORD
