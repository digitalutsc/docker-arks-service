# docker-arks-service

The Docker deployment of the
[ARK service](https://github.com/digitalutsc/arks-service). It contains no
application code: the source stays in its own repository and this stack builds
an image from it, cloning that repository first if you do not have it.

Use it to bring the whole service up on any machine with one command. For
development, demos and prototyping the stack brings its own database. For
production it can instead point at an existing MySQL server and start no
database container; see [Production: an external MySQL server](#production-an-external-mysql-server).
Production can also still run bare on a VM without Docker, as described in
`docs/DEPLOY.md` in the application repository.

Documents in this repository: this README (operator reference),
[`docs/MIGRATION.md`](docs/MIGRATION.md) (rehearsing the legacy import here) and
[`docs/GUIDES.md`](docs/GUIDES.md) (a study guide to every file, Make target,
Compose override and the configuration flow).

## What comes up

| Service | Image | Role |
|---|---|---|
| `web` | built here | gunicorn, serving the resolver and the staff interface on port 8000 |
| `worker` | the same image | Celery worker for bulk-bind jobs (the `celery` queue) |
| `scheduler` | the same image | Celery beat plus a one-process worker for the `periodic` queue: the redirect-counter flush and the other housekeeping tasks. See [Processes, restarts, logs and memory](#processes-restarts-logs-and-memory) |
| `broker` | `valkey/valkey:8-alpine`, or `redis:7-alpine` with [`BROKER_IMAGE`](#broker-and-cache-valkey-or-redis). Not started at all with the [external broker override](#production-an-external-valkey-or-redis-server) | Celery queues for bulk binds and the periodic tasks; cache for the login throttle, element-name lists and collection statistics, bulk-bind progress, and redirect counts not yet written to the database. Password-protected, and keeps its data |
| `db` | `postgres:16-alpine`, or `mysql:8.0` with the [MySQL override](#database). Not started at all with the [external database override](#production-an-external-mysql-server) | the database |

Only `web` publishes a port: on every interface by default, on 127.0.0.1 only
[behind a reverse proxy](#behind-a-reverse-proxy-with-tls). Data lives in
named volumes: `pgdata` (or `mysqldata` under MySQL, or neither against an
external server), `media`, and `brokerdata` (none against an external
broker). The Compose project is named `arkservice` explicitly, so renaming
either checkout does not orphan them.

## Requirements

Docker with Compose v2 (`docker compose version`), and `git`. That is all: a
clone of this repository on its own is enough, and `make up` fetches the
application.

The application checkout can be in either of two places, and the first
`make up` records which in `.env` as `ARKS_SRC`:

```
arks-redesign/                      docker-arks-service/    this repository, alone
├── arks-service/                   └── src/
└── docker-arks-service/                └── arks-service/   cloned for you, gitignored
```

A checkout beside this one is used where it is. Without one, the application is
cloned into `src/arks-service` inside this repository. Anywhere else works
too — set `ARKS_SRC` in `.env` yourself.

## Usage

```bash
make up          # bring everything up, from nothing if need be
make install     # the same, but always rebuild the image first
make down        # stop it, keeping the data
make clean       # remove it entirely: containers, volumes, image
make rebuild     # clean, then install
make prune       # free disk: this stack's dangling images and stale build cache
```

`make up` is the only one you need. It creates `.env` from `.env.example`,
generates a Django secret key and an administrator password into it, clones the
application if there is no checkout, builds the image if there is none, starts
the stack, waits until it actually answers, creates the administrator account,
and prints the address and the login. Running it again is safe, and it is also
the everyday way to start the stack: nothing already set is regenerated, an
existing checkout is never pulled or reset, an existing image is not rebuilt,
and an existing administrator is left alone: if the account already exists,
its password, active flag and staff status are not touched, even if someone
has since disabled or demoted it.

On a machine whose `COMPOSE_FILE` names an external database or broker (that
is, production), `make clean` and `make rebuild` ask you to type `yes` before
taking the stack apart, and `make import-dump` refuses to write into the
external database at all unless given `CONFIRM=yes`. `CONFIRM=yes` also
answers the question for scripts. A development stack is never asked.

### Updating the application

The code is baked into the image, so neither editing the checkout nor pulling it
changes what is running until the image is rebuilt:

```bash
git -C src/arks-service pull     # or wherever ARKS_SRC points
make install
```

### One stack per machine

The Compose project name is fixed, which is what keeps the volumes attached when
a checkout is renamed. It also means two clones of this repository on one
machine drive the **same** stack and the same data, not two.

`make` on its own lists every target. The useful extras:

```bash
make manage ARGS="createcollection 'UTSC Digital Collections' \
    --prefix utsc --naan 61220 --naa 'UTSC Library' --template .zd"
make manage ARGS="mint utsc 10"
make import-dump DUMP=../legacy/ARK_CORE.sql   # rehearse the migration
make logs        # follow every service
make ps          # what is running
make shell       # a shell inside the web container
```

### Disk housekeeping

Every `make build` and `make install` ends by deleting the images earlier
builds left behind untagged, but only those carrying this stack's label
(`org.utsc.arkservice=app`, set in the Dockerfile). Tagged images, such as a
snapshot's `arkservice-web:<tag>`, and other projects' images are never
touched. Images built before the label existed carry none: remove an old
untagged one once by hand (`docker image ls --filter dangling=true`).

`make prune` does the same image cleanup, then removes unused build cache
older than a day. Build cache carries no image labels, so that step is not
limited to this stack: it is Docker's ordinary `builder prune` with an age
filter, and `docker buildx du` shows what it would free. Finally it lists any
other `arkservice-*` image tags it found, for you to remove with
`docker image rm` if they are no longer wanted; it deletes none of them.

## Configuration

Everything is in `.env`, which `make up` creates and never overwrites.

| Variable | Default | Meaning |
|---|---|---|
| `ARKS_SRC` | filled in on first run | Path to the application checkout: `../arks-service` if one is there, otherwise `./src/arks-service` |
| `ARKS_REPO` | empty | Where to clone the application from when `ARKS_SRC` has nothing in it. Empty means the same host and organisation this repository was cloned from |
| `ARKS_REF` | empty | Branch or tag to clone. Empty means the default branch |
| `ARKS_PORT` | `8000` | Host port the stack listens on |
| `DJANGO_SECRET_KEY` | generated | Session and CSRF signing key |
| `DJANGO_DEBUG` | `false` | Leave it false |
| `ARKS_EXTRA_HOSTS` | empty | Hostnames to answer on **beyond** localhost and 127.0.0.1, which are always allowed |
| `COMPOSE_FILE` | commented out | Which overrides to use: MySQL container, external MySQL, external broker, reverse proxy. Commented out means a PostgreSQL container and a Valkey container. See [Database](#database), [Broker and cache](#broker-and-cache-valkey-or-redis) and [Behind a reverse proxy](#behind-a-reverse-proxy-with-tls) |
| `POSTGRES_DB` | `ark` | PostgreSQL container: the database it creates. Set it before the first install |
| `POSTGRES_USER` | `ark` | PostgreSQL container: the account it creates. Set it before the first install |
| `POSTGRES_PASSWORD` | `ark` | PostgreSQL container: that account's password. Only reachable inside the Compose network. Set it before the first install |
| `MYSQL_DATABASE` | `ark` | The database. The MySQL container creates it; an external server must already have it |
| `MYSQL_USER` | `ark` | The account. The MySQL container creates it; on an external server it must exist and be allowed to create and alter tables in that database |
| `MYSQL_PASSWORD` | `ark` | That account's password. The MySQL container also uses it as the root password unless `MYSQL_ROOT_PASSWORD` is set |
| `MYSQL_HOST` | empty | External server only, and required there: the MySQL endpoint |
| `MYSQL_PORT` | `3306` | External server only |
| `BROKER_IMAGE` | commented out | The broker container's image. Commented out means Valkey; `redis:7-alpine` runs Redis |
| `BROKER_PASSWORD` | generated | What clients authenticate with. The broker container enforces it; with an external broker it is that server's password. A deliberately blank line turns authentication off |
| `BROKER_HOST` | empty | External broker only, and required there: the Valkey or Redis endpoint |
| `BROKER_PORT` | `6379` | External broker only |
| `BROKER_USERNAME` | empty | External broker only: a named account (ACL user). Empty logs in as the default user with just the password |
| `BROKER_QUEUE_DB`, `BROKER_CACHE_DB` | `0`, `1` | External broker only: the database numbers for the Celery queue and the cache. They must differ |
| `BROKER_SCHEME`, `BROKER_URL_OPTIONS` | `redis`, empty | External broker only. For TLS: `rediss` and `?ssl_cert_reqs=required` |
| `DJANGO_SUPERUSER_USERNAME` | `admin` | The account `make up` creates |
| `DJANGO_SUPERUSER_EMAIL` | `admin@example.org` | |
| `DJANGO_SUPERUSER_PASSWORD` | generated | Printed on the run that creates the account |
| `MINT_MAX_PER_REQUEST` | `10000` | Largest single mint. `0` removes the cap. Takes effect on the next `make up` |
| `FALLBACK_DIR` | empty | A directory on this host holding operator-written `index.html`, `403.html`, `404.html`, `500.html` and their assets, mounted read-only into `web`. Empty means the built-in landing page and plain error pages. See [Fallback pages](#fallback-pages) |

The variables below are commented out in `.env.example`; `docker-compose.yml`
supplies the default shown and passes each one to `web`, `worker` and
`scheduler` alike, so the processes always agree. A change takes effect on the
next `make up`. Numbers and booleans need a value: a line such as
`DB_READ_TIMEOUT=` with nothing after it stops the application at start-up,
so comment a line out rather than blanking it.

| Variable | Default | Meaning |
|---|---|---|
| `TRUST_FORWARDED_FOR` | `false`; `true` with `docker-compose.proxy.yml` | Take the client address from `X-Forwarded-For` (the entry the proxy appended) for the login throttle. Only safe when nothing but the proxy can reach the port, which is what the proxy override arranges |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | empty | Comma-separated `https://` origins allowed to post forms. Only needed when a form is posted from a different hostname than the one that served it |
| `SECURE_HSTS_SECONDS` | `0` | HSTS lifetime. Leave 0 until TLS is known good on the hostname, then raise it |
| `ARK_PUBLIC_BASE_URL` | empty | Base URL shown for ARKs in the staff interface. Empty derives it from the request; set it only when the staff and resolver hostnames differ |
| `DB_CONN_MAX_AGE` | `60` | Seconds a database connection is reused |
| `DB_CONNECT_TIMEOUT`, `DB_READ_TIMEOUT`, `DB_WRITE_TIMEOUT` | `5`, `60`, `60` | MySQL only: seconds to connect, and to wait on a read or write, before giving up |
| `CACHE_SOCKET_TIMEOUT` | `0.5` | Seconds to connect to, and wait on, the cache before giving up, so a broker outage slows requests rather than hanging them |
| `BULK_BIND_MAX_ROWS` | `100000` | Largest bulk-bind upload, in rows |
| `BULK_BIND_MAX_BYTES` | `52428800` | Largest bulk-bind upload, in bytes (50 MB). A proxy in front needs a request-body limit at least this large |
| `BULK_BIND_RETENTION_DAYS` | `0` | Days to keep finished bulk-bind jobs and their results files (uploads are deleted as soon as a job has run). `0` keeps them forever |
| `CELERY_TASK_TIME_LIMIT` | `3600` | Seconds a background job may run before Celery stops it |
| `MANIFEST_TOTAL_TIMEOUT` | `10` | Seconds a `/manifest` fetch may take in all |
| `MANIFEST_MAX_CONCURRENT` | `4` | `/manifest` fetches at once per gunicorn process; more get 503 with `Retry-After` |
| `COLLECTION_STATS_SECONDS` | `300` | How often the stored collection counts shown on staff pages are refreshed |
| `SORT_SUBQUERY_MAX_ROWS` | `50000` | The most ARKs a staff list may hold and still offer the Redirects and Elements sorts |
| `EXPORT_SYNC_MAX_ROWS` | `100000` | The largest export the staff interface serves itself; above it, it shows the equivalent `export_arks` command |
| `WEB_MEM_LIMIT`, `WORKER_MEM_LIMIT`, `SCHEDULER_MEM_LIMIT`, `BROKER_MEM_LIMIT` | `1g`, `2g`, `256m`, `256m` | Memory ceiling per container. See [Processes, restarts, logs and memory](#processes-restarts-logs-and-memory) |
| `BROKER_MAXMEMORY` | `200mb` | Valkey/Redis `--maxmemory` for the broker container. Keep it below `BROKER_MEM_LIMIT`: with `noeviction` a full broker refuses writes rather than being killed |

`.env` is read by Compose and by the Makefile, which parse it slightly
differently. Two rules keep them agreeing: **comments on their own lines**, and
**no quotes around values**. A trailing comment or a pair of quotes ends up
inside the value, so a quoted password would create an account whose password
includes the quotes.

A few variables are less free than they look:

- **`ARKS_EXTRA_HOSTS` adds to the allowed hosts, it does not replace them.**
  The container healthcheck asks for `localhost`, and Django answers 400 to a
  hostname it does not know, so a stack that dropped `localhost` would never
  become healthy and `make up` would wait forever.
- **A database container's names and password only take effect the first
  time its volume is created.** That covers `POSTGRES_DB`, `POSTGRES_USER` and
  `POSTGRES_PASSWORD`, and the `MYSQL_*` values with the MySQL container.
  Changing one later leaves the application unable to log in; `make clean`
  first, then change it. Against an external server the values are that
  server's, and change whenever its account does.
- **The broker container applies `BROKER_PASSWORD` on every start.** The
  password is not stored with its data, so changing it is safe;
  `make down && make up` puts the new one into effect for the broker and the
  application together.
- **User names and passwords are substituted into URLs.** Use letters and
  digits. A password you cannot choose has to be percent-encoded in `.env`:
  `@` as `%40`, `/` as `%2F`, `#` as `%23`, `%` as `%25`, `:` as `%3A`.

The file is gitignored: it holds this machine's secret key and administrator
password, and is created mode 600. `make clean` deliberately keeps it.

## How the image gets the source

`make up` makes sure there is a checkout at `ARKS_SRC`, cloning one if the path
is empty (`scripts/ensure-src.sh`). Compose then passes that checkout to the
build as a named context:

```yaml
build:
  context: .                                  # this repository, for the Dockerfile
  additional_contexts:
    src: ${ARKS_SRC:-../arks-service}     # the application
```

The Dockerfile then copies from `src` one explicit line per top-level package,
rather than `COPY . .`. That is what keeps a developer's `.venv`, `.git`,
`db.sqlite3`, `media` and `staticfiles` out of the image, and it means the
application repository needs no Docker files of its own — not even a
`.dockerignore`: BuildKit sends the builder only the paths those lines name.
This repository's own `.dockerignore` keeps `.env`, exports and CSVs from
being sent as the main context, which the Dockerfile does not copy from.

The build has two stages. The first has the compiler and MySQL headers and
builds the virtual environment with `uv sync --frozen`, which fails if
`uv.lock` is out of date rather than resolving something else. The second,
the image that runs, gets that environment, the MySQL client library
(`libmariadb3`), `curl` for the healthcheck and the application, and runs as
an unprivileged user (uid 10001). The image has no `CMD`: `docker-compose.yml`
sets each service's command.

The cost: **adding a new top-level Django app to the application means adding a
`COPY --from=src` line to the Dockerfile here.** A missing one shows up
immediately as a `ModuleNotFoundError` on startup.

`web` builds the image and `worker` and `scheduler` reuse it, so the source
is compiled once.

## Database

The stack runs PostgreSQL by default. Production runs MySQL, and the image
installs both drivers. The application keeps its schema inside the portable
subset and its CI runs the suite against both engines.

To run the stack on MySQL 8.0 instead, uncomment this line in `.env`:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.mysql.yml
```

and run `make down && make up`. Compose reads `COMPOSE_FILE` from `.env` on its
own, so every `make` target picks up the override without further flags. The
override (`docker-compose.mysql.yml`) replaces the `db` service and points
`web`, `worker` and `scheduler` at it. Migrations run on the first start, as they do on
PostgreSQL. It needs Docker Compose 2.24.4 or later, which `make check`
verifies.

Each engine has its own volume, `pgdata` or `mysqldata`, so switching does not
lose the other engine's data. Comment the line out again and `make down && make
up` to go back. `make clean` removes the volumes of whichever engines the
current `.env` declares: both while the override is on, only `pgdata` when it is
off, so clean with the override on if you want its data gone too.

### Production: an external MySQL server

In production the stack runs against a MySQL server you already have, and
starts no database container. Set this in `.env`:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.external-db.yml
MYSQL_HOST=mysql.example.utoronto.ca
MYSQL_PORT=3306
MYSQL_DATABASE=ark
MYSQL_USER=ark
MYSQL_PASSWORD=...
```

Then run `make up`. The broker stays a container unless you also add the
[external broker override](#production-an-external-valkey-or-redis-server).

- **The database must already exist**, and `MYSQL_USER` must be allowed to
  create and alter tables in it. The stack does not create databases or
  accounts on someone else's server.
- **`web` runs `migrate` every time it starts**, so the schema on that server
  is brought up to date by the stack, as `manage.py migrate` does in a bare
  deployment. Back the database up before a `make install` that brings new
  migrations.
- **`make up` waits for the server.** The `db` service is never created, and
  `web`, `worker` and `scheduler` no longer wait for it. `web` only reports healthy once its
  `/healthz` check can reach the external server.
- **`MYSQL_HOST` and `MYSQL_PASSWORD` have no default.** Compose refuses to
  start without them and says which one is missing.
- **The containers must be able to reach the server.** From the containers'
  point of view `localhost` is the container itself. A MySQL server on the
  Docker host itself is `host.docker.internal` on Docker Desktop. On Linux it
  is the host's address on the Docker bridge, and the server must listen on it
  and allow the account from that network.
- **`make clean` never touches the external database.** It removes the
  stack's own containers, the `media` volume and the image.
- **`make import-dump` writes into the external database**, so it refuses
  unless given `CONFIRM=yes`. Rehearse with `ARGS="--dry-run" CONFIRM=yes`
  first, and rehearse the real thing against a MySQL container, not against
  production.

This file is an alternative to `docker-compose.mysql.yml`, not an addition:
use one or the other. It needs Docker Compose 2.24.4 or later, which
`make check` verifies. To put the stack behind Apache with TLS, add
`docker-compose.proxy.yml` as well; see
[Behind a reverse proxy](#behind-a-reverse-proxy-with-tls).

## Broker and cache: Valkey or Redis

The `broker` service is the Celery queue and the shared cache. A bulk-bind
upload is saved as a job in the database and queued here; the worker takes it
from the queue and runs it. The scheduled flush of redirect counts and the
other periodic tasks go the same way, on a queue of their own that the
scheduler takes them from. As the cache it holds the login throttle, the element-name lists and
collection statistics, bulk-bind progress, and redirect counts not yet written
to the database. The resolver does not read it: a redirect is two database
reads, and the cache's only part in resolution is buffering the hit counter.

It runs [Valkey](https://valkey.io), the open-source fork of Redis, by
default. To run Redis instead, set this in `.env`:

```
BROKER_IMAGE=redis:7-alpine
```

and run `make down && make up`. Comment it out again to go back to Valkey.

The application does not change. Valkey speaks the Redis protocol, so Django's
`RedisCache` and Celery's Redis transport work with it, and the URLs keep the
`redis://` scheme with `broker` as the host. Database 0 is the queue and
database 1 the cache; `docker-compose.yml` sets both, as shown below.

**The broker requires a password.** `make up` generates `BROKER_PASSWORD` in
`.env` the first time, the container starts with it as its server password,
and the application's URLs carry it (database 0 the queue, 1 the cache):

```
CELERY_BROKER_URL=redis://:<BROKER_PASSWORD>@broker:6379/0
REDIS_URL=redis://:<BROKER_PASSWORD>@broker:6379/1
```

It is the server's default user, so there is no user name. A line set
deliberately blank, `BROKER_PASSWORD=`, turns authentication off and is left
blank by `make up`; that only makes sense on a machine nobody else can reach.

The healthcheck runs `redis-cli ping` with that password and looks for `PONG`
rather than trusting the exit status, because `redis-cli` exits 0 even when
authentication fails. It works on both servers,
because the Valkey image ships `redis-cli` as a link to `valkey-cli`. Any
other image works if it speaks the protocol and provides `redis-cli`. To talk
to the server by hand, pass the password the same way:

```
docker compose exec broker sh -c 'REDISCLI_AUTH="$BROKER_PASSWORD" redis-cli INFO server'
```

The service used to be called `redis`. `make up` and `make down` remove
containers of services the files no longer define, so the old
`arkservice-redis-1` container goes away on the first `make up` after updating.

**The broker keeps its data** in the `brokerdata` volume. It appends every
write to a log on that volume, flushed once a second (`--appendonly yes
--appendfsync everysec`), so a restart or `make down && make up` loses neither
queued bulk-bind jobs nor redirect counts not yet written to the database.
It runs with `--maxmemory-policy noeviction`: the queue and the counters share
the server with the cache, and under memory pressure a write that fails
loudly is better than a queued job or a count silently evicted. Never give it
an `allkeys-*` policy. `make clean` removes the volume with the rest.

When switching between Valkey and Redis, do not count on one reading the
other's files. On a live system flush the counters and let running bulk binds
finish, then start the new server on an empty volume:

```
make manage ARGS="flush_counters"
make down
docker volume rm arkservice_brokerdata
make up
```

### Production: an external Valkey or Redis server

In production the broker can be a server you already have, such as one the
sysadmin runs or a managed service, instead of the container. Add the
override to `COMPOSE_FILE`, alone or with the external database, and fill in
the server's details:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.external-db.yml:docker-compose.external-broker.yml
BROKER_HOST=valkey.example.utoronto.ca
BROKER_PORT=6379
BROKER_USERNAME=ark
BROKER_PASSWORD=...
```

Then run `make up`.

- **The `broker` container is never created**, and `web`, `worker` and
  `scheduler` no longer wait for it. `web` only reports healthy once its `/healthz` check can
  reach the cache on that server.
- **Credentials.** Replace the generated `BROKER_PASSWORD` with the server's.
  Set `BROKER_USERNAME` when the server gives you a named account (an ACL
  user, as managed services do); leave it blank to log in as the default user
  with just the password. Leave `BROKER_PASSWORD=` blank only for a server
  without authentication.
- **Two database numbers.** The Celery queue uses `BROKER_QUEUE_DB` (0) and
  the cache `BROKER_CACHE_DB` (1). They must differ, so the server must offer
  at least two databases; a server in cluster mode offers only one and is not
  supported.
- **TLS.** Set `BROKER_SCHEME=rediss` and
  `BROKER_URL_OPTIONS=?ssl_cert_reqs=required`, usually with the port the
  server gives for TLS. Celery refuses a `rediss://` URL without
  `ssl_cert_reqs`.
- **`BROKER_HOST` has no default.** Compose refuses to start without it.
- **The containers must be able to reach the server**, as for an external
  database: `localhost` is the container itself.
- **`make clean` never touches the external server.**

The external database and broker files combine in either order, and each can
be used without the other. Like them, it needs Docker Compose 2.24.4 or later.
The persistence settings above apply to the broker container only; an
external server needs its own (append-only on, `noeviction`), which is that
server's administrator's to set.

## Behind a reverse proxy with TLS

On a VM where Apache terminates TLS in front of the stack, add
`docker-compose.proxy.yml` last in `COMPOSE_FILE`. **Production is all four
files:**

```
COMPOSE_FILE=docker-compose.yml:docker-compose.external-db.yml:docker-compose.external-broker.yml:docker-compose.proxy.yml
ARKS_EXTRA_HOSTS=ark.digital.utsc.utoronto.ca
```

A staging VM rehearsing against a MySQL container uses
`docker-compose.yml:docker-compose.mysql.yml:docker-compose.proxy.yml`.

What the override changes:

- **`web` publishes its port on 127.0.0.1 only** (`127.0.0.1:${ARKS_PORT}`).
  Apache on the same host reaches it there and nothing else can. Docker's
  published ports bypass the host firewall (`ufw` included), so binding to
  loopback is what keeps gunicorn off the network.
- **The session and CSRF cookies are marked Secure** on `web`, `worker` and
  `scheduler`, so browsers send them over HTTPS only, as in a bare production
  deployment.
- **`TRUST_FORWARDED_FOR` defaults to `true`**, because Apache appends the
  real client address to `X-Forwarded-For` and nothing but Apache can reach
  the port. Without the override it defaults to `false`: on a published port
  that header is whatever the client sends.

`ARKS_EXTRA_HOSTS` must name the public hostname, or Django answers 400; it
adds to `localhost`, which the healthcheck needs, and never replaces it.

The Apache vhost has the same shape as the bare deployment's
`deploy/apache-arkservice.conf` in the application repository, but proxies
everything to the container:

- `ServerName` the public hostname, TLS, `ProxyPreserveHost On`,
  `RequestHeader set X-Forwarded-Proto "https"`,
  `ProxyPass / http://127.0.0.1:8000/ nocanon`, `AllowEncodedSlashes NoDecode`.
- **No** `Alias /static/`: WhiteNoise serves static files from inside the
  image.
- A pooled-connection `ttl` below gunicorn's 5 s keep-alive, and a request
  body limit on the bulk-bind upload at least `BULK_BIND_MAX_BYTES`.
- Check `nocanon` with `curl -sI 'https://<host>/ark:/61220/<id>?' | head -1`:
  it must be `200`, not `302`.

A legacy export only ever reaches such a VM over SSH (`scp`), never through a
share or a ticket attachment. Import it with `make import-dump`, which needs
`CONFIRM=yes` against an external database, then `shred -u` it.

The override needs Docker Compose 2.24.4 or later, which `make check`
verifies. Docker-side planning for a staging VM is in `DOCKER-DEPLOY.md` at
the workspace root.

## Fallback pages

The public sees three pages that are not ARKs: the landing page at `/`, the
404 for an unknown or unbound identifier, and the error pages. By default they
are the application's built-in landing page and Django's plain error pages. To
replace them, put your own files in a directory on the host and name it:

```
FALLBACK_DIR=/srv/ark/fallback
```

then `make up`. The directory is mounted read-only into `web` at
`/data/fallback`; the application reads `index.html`, `403.html`, `404.html`
and `500.html` from it and serves anything else there (stylesheets, images,
fonts) under `/fallback/<name>`. Edits show within a minute, no restart. A
starting kit with all four pages and a stylesheet is
`docs/fallback-example/` in the application repository; its README has the
rules (pages are served as written with the real status code, `index.html`
may use three placeholders, inline `<style>` is allowed, remote assets are
not). A superuser sees which pages are in place, with previews, at the bottom
of the staff interface's Users page.

The directory is deliberately outside this repository: it is server content,
owned by whoever has shell access. With `FALLBACK_DIR` blank the stack's own
empty `fallback/` directory is mounted and the application ignores it.

## Processes, restarts, logs and memory

- **`web`** runs the migrations, then gunicorn: 3 processes of 8 threads.
  Each process is replaced after about 2000 requests (`--max-requests 2000
  --max-requests-jitter 200`), which caps slow memory growth, and keeps idle
  connections open for 5 s. On stop, in-flight requests get 30 s to finish
  (`--graceful-timeout 30`, `stop_grace_period: 35s`).
- **`worker`** runs bulk-bind jobs from the `celery` queue, two at a time.
  Each child process is replaced after 20 jobs or once it passes about 1 GB
  (`--max-tasks-per-child 20 --max-memory-per-child 1000000`), so one huge
  upload does not leave it holding that memory. Docker waits 120 s on stop, so
  a running job can finish. It can be scaled
  (`docker compose up -d --scale worker=2`); beat is not in it.
- **`scheduler`** runs Celery beat and a single-process worker for the
  `periodic` queue: the redirect-counter flush and the other housekeeping
  tasks. In its own process so a long bulk bind never holds the flush up.
  **Run exactly one**: two would schedule every task twice.
- **Every service restarts on its own** (`restart: unless-stopped`) after a
  crash or a reboot of the host, unless it was stopped on purpose.
  `make down` removes the containers, so development is unaffected.
- **Logs are capped**: Docker's `json-file` driver, five files of 10 MB per
  container. `make logs` reads them as before.
- **Memory is capped per container**: `web` 1 GB, `worker` 2 GB,
  `scheduler` and `broker` 256 MB, tunable with `WEB_MEM_LIMIT`,
  `WORKER_MEM_LIMIT`, `SCHEDULER_MEM_LIMIT` and `BROKER_MEM_LIMIT` (Docker
  sizes: `512m`, `1g`, ...). The database containers have no limit. A
  container that reaches its limit is killed and restarted; `docker inspect
  --format '{{.State.OOMKilled}}' arkservice-worker-1` says whether that is
  what happened.
- **Healthchecks run every 15 s.** `web` has 30 s of grace and then 10
  attempts, about three minutes, for a first start with every migration to
  run.

## Rehearsing the migration

`make import-dump DUMP=/path/to/ARK_CORE.sql` loads a legacy export — a
phpMyAdmin or `mysqldump` `.sql` file, gzipped or not — into this stack, so you
can see what the migration produces before it happens anywhere that matters. Add
`ARGS="--dry-run"` to have it report what it would do and keep none of it.

The file is copied into the running container, read there, and deleted again,
whether the import succeeds or fails (the importer's exit status is passed
on); nothing is mounted and nothing enters the image, so the export can sit
anywhere on your machine. Against an external database it refuses without
`CONFIRM=yes`, because it would write into that server. Every run leaves an `import-report.csv` here listing the rows
that could not be carried over exactly as legacy held them.

Full walk-through in [docs/MIGRATION.md](docs/MIGRATION.md); what the migration actually
does, and the real cutover runbook, are in
[`MIGRATION.md` in the application repository](https://github.com/digitalutsc/arks-service/blob/main/docs/MIGRATION.md).

A legacy export holds staff passwords in a form that can be decrypted. Keep it
out of both checkouts and delete it when you are done.

## Troubleshooting

**`make up` cannot clone the application.** The message names the URL it tried.
By default that is this repository's own `origin` with the repository name
swapped, so it fails when you can read this repository and not that one, or when
this one was not cloned from GitHub at all. Set `ARKS_REPO` in `.env` to a URL
you can reach, or clone the application into the `ARKS_SRC` path by hand.

**`make up` says there is no application checkout and refuses to clone.**
`ARKS_SRC` points at a directory that has files in it and no `manage.py`. It
will not clone over somebody's directory. Point `ARKS_SRC` at the checkout, or
blank it to have it worked out again.

**Compose refuses to start: `DJANGO_SECRET_KEY` is required.** `.env` has a
blank key. `make env` fills it in.

**The web container never becomes healthy.** `make logs` shows why. Almost
always a migration failure or an unreachable database; the healthcheck probes
`/healthz`, which reports the database and cache separately. Against an
external server, check `MYSQL_HOST` from the container's point of view (not
`localhost`), the firewall, and that the account may connect from the Docker
network.

**Compose refuses to start: `MYSQL_HOST` or `MYSQL_PASSWORD` is missing a
value.** `.env` turns on `docker-compose.external-db.yml` and leaves that value
blank. Fill it in, or take the file out of `COMPOSE_FILE`. The same goes for
`BROKER_HOST` and `docker-compose.external-broker.yml`.

**The broker is unhealthy, or the logs say `NOAUTH`, `WRONGPASS` or
`invalid username-password pair`.** The password, or the user name, does not
match the server. With the broker container, run `make down && make up` so
both sides start with the same `BROKER_PASSWORD`. With an external broker,
check `BROKER_USERNAME` and `BROKER_PASSWORD` against the server, and that the
password is percent-encoded.

**`ModuleNotFoundError` for an application package.** A new top-level package
was added to the application without a matching `COPY --from=src` line in the
Dockerfile.

**`make import-dump` fails while copying the file in.** The stack is not
running; `docker compose cp` needs a live container. `make up` first.

**A container keeps restarting, with exit code 137.** It reached its memory
limit and was killed. `docker inspect --format '{{.State.OOMKilled}}'
<container>` confirms it; raise the matching `*_MEM_LIMIT` in `.env` and
`make up`.

**`make clean` or `make rebuild` asks for `yes`.** `COMPOSE_FILE` names an
external database or broker, so the stack is taken to be production. Type
`yes`, or pass `CONFIRM=yes`.

**Disk filling up with old images.** `make prune`; see
[Disk housekeeping](#disk-housekeeping).

**Large `arkservice-web:latest` and `arkservice-worker:latest` images left over.**
Those are from the older Compose file that lived inside the application
repository, before the split. `make clean` does not touch them because they are
not this stack's. Remove them once by hand:

```bash
docker image rm arkservice-web:latest arkservice-worker:latest
```
