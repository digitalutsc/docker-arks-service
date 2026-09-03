# The dev and prototype image for the ARK service.
#
# The application source is NOT in this repository. It arrives through the
# named build context `src`, which docker-compose.yml points at the
# arks-service-new checkout (ARKS_SRC in .env). Everything taken from it is
# listed explicitly below, so nothing from a developer's working tree — .venv,
# .git, db.sqlite3, staticfiles — can leak into the image.
#
# Production does not use this image. It runs bare on the LAMP VM against the
# existing MySQL server; see DEPLOY.md in the application repository.
FROM python:3.13-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_PROJECT_ENVIRONMENT=/usr/local

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential default-libmysqlclient-dev pkg-config curl \
    && rm -rf /var/lib/apt/lists/*

# Pinned: :latest would change the build from under us.
COPY --from=ghcr.io/astral-sh/uv:0.9.18 /uv /usr/local/bin/uv

WORKDIR /app

# Dependencies first, so they cache independently of the source. Both database
# drivers are installed: the stack runs PostgreSQL, but the same image is used
# to rehearse the MySQL path production uses.
COPY --from=src pyproject.toml uv.lock ./
RUN uv sync --no-install-project --extra postgres --extra mysql --frozen 2>/dev/null \
    || uv sync --no-install-project --extra postgres --extra mysql

# The application itself, one line per top-level package. Adding a new Django
# app to arks-service-new means adding a line here — that is the price of
# keeping the application repository free of deployment files.
COPY --from=src manage.py ./
COPY --from=src arkservice/ arkservice/
COPY --from=src core/ core/
COPY --from=src minting/ minting/
COPY --from=src resolver/ resolver/
COPY --from=src admin_ui/ admin_ui/
COPY --from=src jobs/ jobs/
COPY --from=src templates/ templates/
COPY --from=src static/ static/

# The image carries no data and no secrets. Byte-code caches from the host are
# dropped first; collectstatic then runs with DJANGO_DEBUG=false so the hashed
# manifest storage is used. The boot guard is skipped explicitly because there
# is no database or secret key at build time, and neither is needed to collect
# static files.
RUN find /app -name '__pycache__' -type d -prune -exec rm -rf {} + \
    && DJANGO_DEBUG=false ARKSERVICE_SKIP_CONFIG_CHECK=1 \
       python manage.py collectstatic --no-input

# Run as an unprivileged user: a container process that does not need root
# should not have it, and MEDIA_ROOT is the only thing it writes.
RUN useradd --system --uid 10001 --home /app --shell /usr/sbin/nologin app \
    && mkdir -p /data/media \
    && chown -R app:app /app /data
USER app

EXPOSE 8000
# Threads rather than more processes: a /manifest fetch parks a worker on I/O,
# and 3 sync workers meant three slow targets could stall the whole service.
CMD ["gunicorn", "arkservice.wsgi:application", "--bind", "0.0.0.0:8000", \
     "--workers", "3", "--threads", "8", "--worker-class", "gthread", \
     "--timeout", "60", "--access-logfile", "-"]
