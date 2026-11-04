# The image for the ARK service, used by the stack in development and production.
#
# The application source is NOT in this repository. It arrives through the
# named build context `src`, which docker-compose.yml points at the
# arks-service checkout (ARKS_SRC in .env). Everything taken from it is
# listed explicitly below, so nothing from a developer's working tree — .venv,
# .git, db.sqlite3, staticfiles — can leak into the image.
#
# The same image serves development and production. In production the stack
# points it at an existing MySQL server (docker-compose.external-db.yml);
# production can also run without Docker, as DEPLOY.md in the application
# repository describes.
#
# Two stages. The builder has the compiler and the MySQL headers that
# mysqlclient needs to build, and produces a virtual environment in
# /app/.venv. The runtime stage gets that environment and the shared library
# it links against, and none of the build tools.

# --- builder ------------------------------------------------------------------
FROM python:3.13-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_PYTHON=/usr/local/bin/python3 \
    UV_PYTHON_DOWNLOADS=never \
    UV_LINK_MODE=copy

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential default-libmysqlclient-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Pinned: :latest would change the build from under us.
COPY --from=ghcr.io/astral-sh/uv:0.9.18 /uv /usr/local/bin/uv

WORKDIR /app

# Both database drivers are installed: the stack runs PostgreSQL, but the same
# image is used to rehearse the MySQL path production uses. --frozen installs
# exactly what uv.lock says and fails if the lock is out of date with
# pyproject.toml, rather than quietly resolving something else.
COPY --from=src pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project --no-dev --extra postgres --extra mysql

# --- runtime ------------------------------------------------------------------
FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH=/app/.venv/bin:$PATH

# libmariadb3 is the client library mysqlclient links against (what
# default-libmysqlclient-dev builds it with on Debian); curl is for the
# healthcheck. psycopg's binary wheel carries its own libpq.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libmariadb3 curl \
    && rm -rf /var/lib/apt/lists/*

# Run as an unprivileged user: a container process that does not need root
# should not have it. Celery beat keeps its schedule file in /tmp
# (CELERY_BEAT_SCHEDULE_FILENAME); /app is the user's own all the same so a
# tool that writes beside manage.py still can. /data holds MEDIA_ROOT and is where
# `make import-dump` puts the export (see the Makefile).
RUN useradd --system --uid 10001 --home /app --shell /usr/sbin/nologin app \
    && mkdir -p /app /data/media \
    && chown app:app /app /data /data/media

WORKDIR /app

COPY --from=builder --chown=app:app /app/.venv /app/.venv

# The application itself, one line per top-level package. Adding a new Django
# app to arks-service means adding a line here — that is the price of
# keeping the application repository free of deployment files.
COPY --from=src --chown=app:app manage.py ./
COPY --from=src --chown=app:app arkservice/ arkservice/
COPY --from=src --chown=app:app core/ core/
COPY --from=src --chown=app:app minting/ minting/
COPY --from=src --chown=app:app resolver/ resolver/
COPY --from=src --chown=app:app admin_ui/ admin_ui/
COPY --from=src --chown=app:app jobs/ jobs/
COPY --from=src --chown=app:app templates/ templates/
COPY --from=src --chown=app:app static/ static/

USER app

# The image carries no data and no secrets. Byte-code caches from the host are
# dropped first; collectstatic then runs with DJANGO_DEBUG=false so the hashed
# manifest storage is used. The boot guard is skipped explicitly because there
# is no database or secret key at build time, and neither is needed to collect
# static files.
RUN find /app -path /app/.venv -prune -o -name '__pycache__' -type d -prune -exec rm -rf {} + \
    && DJANGO_DEBUG=false ARKSERVICE_SKIP_CONFIG_CHECK=1 \
       python manage.py collectstatic --no-input

EXPOSE 8000
# No CMD: docker-compose.yml sets the command for every service (gunicorn for
# web, Celery for worker and scheduler), so there is one place to change it.
