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
    echo "Created .env from .env.example"
fi

random_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-48
    else
        python3 -c 'import secrets; print(secrets.token_urlsafe(48))' | tr -d '\n-_'
    fi
}

fill_if_blank() {
    key=$1
    if ! grep -q "^$key=" .env; then
        printf '%s=%s\n' "$key" "$(random_secret)" >> .env
        echo "Added $key to .env with a generated value"
        return
    fi
    if [ -n "$(sed -n "s/^$key=//p" .env | tail -1)" ]; then
        return
    fi
    value=$(random_secret)
    awk -v k="$key" -v v="$value" '
        $0 == k "=" { print k "=" v; next }
        { print }
    ' .env > .env.tmp && mv .env.tmp .env
    echo "Generated $key in .env"
}

fill_if_blank DJANGO_SECRET_KEY
fill_if_blank DJANGO_SUPERUSER_PASSWORD
