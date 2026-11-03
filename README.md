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
`DEPLOY.md` in the application repository.

## What comes up

| Service | Image | Role |
|---|---|---|
| `web` | built here | gunicorn, serving the resolver and the staff interface on port 8000 |
| `worker` | the same image | Celery worker and beat, for bulk-bind jobs and counter flushes |
| `redis` | `redis:7-alpine`, or `valkey/valkey:8-alpine` with the [Valkey override](#broker-and-cache-redis-or-valkey) | Celery broker, login throttle, redirect-counter cache |
| `db` | `postgres:16-alpine`, or `mysql:8.0` with the [MySQL override](#database). Not started at all with the [external database override](#production-an-external-mysql-server) | the database |

Only `web` publishes a port. Data lives in two named volumes, `pgdata` (or
`mysqldata` under MySQL, or neither against an external server) and `media`. The Compose project is named `arkservice` explicitly, so renaming
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
```

`make up` is the only one you need. It creates `.env` from `.env.example`,
generates a Django secret key and an administrator password into it, clones the
application if there is no checkout, builds the image if there is none, starts
the stack, waits until it actually answers, creates the administrator account,
and prints the address and the login. Running it again is safe, and it is also
the everyday way to start the stack: nothing already set is regenerated, an
existing checkout is never pulled or reset, an existing image is not rebuilt,
and an existing administrator is left alone.

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
| `COMPOSE_FILE` | commented out | Which overrides to use: MySQL container, external MySQL, Valkey. Commented out means PostgreSQL and Redis. See [Database](#database) and [Broker and cache](#broker-and-cache-redis-or-valkey) |
| `POSTGRES_PASSWORD` | `ark` | Only reachable inside the Compose network. Set it before the first install |
| `MYSQL_PASSWORD` | `ark` | The same, for the MySQL container, which also uses it as the root password unless `MYSQL_ROOT_PASSWORD` is set. With an external server, the password of `MYSQL_USER` there |
| `MYSQL_HOST` | empty | External server only, and required there: the MySQL endpoint |
| `MYSQL_PORT` | `3306` | External server only |
| `MYSQL_DATABASE` | `ark` | External server only: the database name. It must already exist |
| `MYSQL_USER` | `ark` | External server only. Needs to be allowed to create and alter tables in that database |
| `DJANGO_SUPERUSER_USERNAME` | `admin` | The account `make up` creates |
| `DJANGO_SUPERUSER_EMAIL` | `admin@example.org` | |
| `DJANGO_SUPERUSER_PASSWORD` | generated | Printed on the run that creates the account |
| `MINT_MAX_PER_REQUEST` | `10000` | Largest single mint. `0` removes the cap. Takes effect on the next `make up` |

`.env` is read by Compose and by the Makefile, which parse it slightly
differently. Two rules keep them agreeing: **comments on their own lines**, and
**no quotes around values**. A trailing comment or a pair of quotes ends up
inside the value, so a quoted password would create an account whose password
includes the quotes.

Two variables are less free than they look:

- **`ARKS_EXTRA_HOSTS` adds to the allowed hosts, it does not replace them.**
  The container healthcheck asks for `localhost`, and Django answers 400 to a
  hostname it does not know, so a stack that dropped `localhost` would never
  become healthy and `make up` would wait forever.
- **For a database container, `POSTGRES_PASSWORD` and `MYSQL_PASSWORD` only
  take effect the first time the database volume is created.** Changing it later leaves the application unable to authenticate;
  `make clean` first, then change it. Against an external server the password
  is that server's, and changes whenever its account does.
- **Database passwords are substituted into a URL.** Use letters and digits.
  An external server's password you cannot choose has to be percent-encoded in
  `.env`: `@` as `%40`, `/` as `%2F`, `#` as `%23`, `%` as `%25`.

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
`db.sqlite3` and `staticfiles` out of the image, and it means the application
repository needs no Docker files of its own — not even a `.dockerignore`.

The cost: **adding a new top-level Django app to the application means adding a
`COPY --from=src` line to the Dockerfile here.** A missing one shows up
immediately as a `ModuleNotFoundError` on startup.

`web` builds the image and `worker` reuses it, so the source is compiled once.

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
`web` and `worker` at it. Migrations run on the first start, as they do on
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
COMPOSE_FILE=docker-compose.yml:docker-compose.external-db.yml:docker-compose.valkey.yml
MYSQL_HOST=mysql.example.utoronto.ca
MYSQL_PORT=3306
MYSQL_DATABASE=ark
MYSQL_USER=ark
MYSQL_PASSWORD=...
```

Drop `:docker-compose.valkey.yml` to run Redis instead; see
[Broker and cache](#broker-and-cache-redis-or-valkey). Then run `make up`.

- **The database must already exist**, and `MYSQL_USER` must be allowed to
  create and alter tables in it. The stack does not create databases or
  accounts on someone else's server.
- **`web` runs `migrate` every time it starts**, so the schema on that server
  is brought up to date by the stack, as `manage.py migrate` does in a bare
  deployment. Back the database up before a `make install` that brings new
  migrations.
- **`make up` waits for the server.** The `db` service is never created, and
  `web` and `worker` no longer wait for it. `web` only reports healthy once its
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
- **`make import-dump` writes into the external database.** Rehearse with
  `ARGS="--dry-run"` first, and rehearse the real thing against a MySQL
  container, not against production.

This file is an alternative to `docker-compose.mysql.yml`, not an addition:
use one or the other. It needs Docker Compose 2.24.4 or later, which
`make check` verifies. Nothing in it puts the stack behind a reverse proxy
with TLS yet; that is planned separately in `DOCKER-DEPLOY.md` at the
workspace root.

## Broker and cache: Redis or Valkey

The `redis` service is the Celery broker and the shared cache. It runs Redis
by default. To run [Valkey](https://valkey.io), the open-source fork, instead,
append the override to `COMPOSE_FILE` in `.env`, after any database file:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.valkey.yml
```

and run `make down && make up`. Remove it again to go back.

The application does not change. Valkey speaks the Redis protocol, so the
`redis://` URLs, Django's `RedisCache` and Celery's Redis transport all work
with it. The service keeps the name `redis` because the name describes the
role, which keeps every URL and `depends_on` valid.

Neither service keeps a volume, so switching loses only the redirect counts
not yet written to the database. On a live system flush them first:

```
make manage ARGS="flush_counters"
```

## Rehearsing the migration

`make import-dump DUMP=/path/to/ARK_CORE.sql` loads a legacy export — a
phpMyAdmin or `mysqldump` `.sql` file, gzipped or not — into this stack, so you
can see what the migration produces before it happens anywhere that matters. Add
`ARGS="--dry-run"` to have it report what it would do and keep none of it.

The file is copied into the running container, read there, and deleted again;
nothing is mounted and nothing enters the image, so the export can sit anywhere
on your machine. Every run leaves an `import-report.csv` here listing the rows
that could not be carried over exactly as legacy held them.

Full walk-through in [MIGRATION.md](MIGRATION.md); what the migration actually
does, and the real cutover runbook, are in
[`MIGRATION.md` in the application repository](https://github.com/digitalutsc/arks-service/blob/main/MIGRATION.md).

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
blank. Fill it in, or take the file out of `COMPOSE_FILE`.

**`ModuleNotFoundError` for an application package.** A new top-level package
was added to the application without a matching `COPY --from=src` line in the
Dockerfile.

**`make import-dump` fails while copying the file in.** The stack is not
running; `docker compose cp` needs a live container. `make up` first.

**Large `arkservice-web:latest` and `arkservice-worker:latest` images left over.**
Those are from the older Compose file that lived inside the application
repository, before the split. `make clean` does not touch them because they are
not this stack's. Remove them once by hand:

```bash
docker image rm arkservice-web:latest arkservice-worker:latest
```
