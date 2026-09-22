# docker-arks-service

The Docker deployment of the
[ARK service](https://github.com/digitalutsc/arks-service-new). It contains no
application code: the source stays in its own repository and this stack builds
an image from it, cloning that repository first if you do not have it.

Use it to bring the whole service up on any machine with one command, for
development, demos and prototyping. **Production does not use Docker** — it runs
bare on the LAMP VM against the existing MySQL server, described in `DEPLOY.md`
in the application repository.

## What comes up

| Service | Image | Role |
|---|---|---|
| `web` | built here | gunicorn, serving the resolver and the staff interface on port 8000 |
| `worker` | the same image | Celery worker and beat, for bulk-bind jobs and counter flushes |
| `redis` | `redis:7-alpine` | Celery broker, login throttle, redirect-counter cache |
| `db` | `postgres:16-alpine`, or `mysql:8.0` with the [MySQL override](#database) | the database |

Only `web` publishes a port. Data lives in two named volumes, `pgdata` (or
`mysqldata` under MySQL) and `media`. The Compose project is named `arkservice` explicitly, so renaming
either checkout does not orphan them.

## Requirements

Docker with Compose v2 (`docker compose version`), and `git`. That is all: a
clone of this repository on its own is enough, and `make up` fetches the
application.

The application checkout can be in either of two places, and the first
`make up` records which in `.env` as `ARKS_SRC`:

```
arks-redesign/                      docker-arks-service/    this repository, alone
├── arks-service-new/               └── src/
└── docker-arks-service/                └── arks-service-new/   cloned for you, gitignored
```

A checkout beside this one is used where it is. Without one, the application is
cloned into `src/arks-service-new` inside this repository. Anywhere else works
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
git -C src/arks-service-new pull     # or wherever ARKS_SRC points
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
| `ARKS_SRC` | filled in on first run | Path to the application checkout: `../arks-service-new` if one is there, otherwise `./src/arks-service-new` |
| `ARKS_REPO` | empty | Where to clone the application from when `ARKS_SRC` has nothing in it. Empty means the same host and organisation this repository was cloned from |
| `ARKS_REF` | empty | Branch or tag to clone. Empty means the default branch |
| `ARKS_PORT` | `8000` | Host port the stack listens on |
| `DJANGO_SECRET_KEY` | generated | Session and CSRF signing key |
| `DJANGO_DEBUG` | `false` | Leave it false |
| `ARKS_EXTRA_HOSTS` | empty | Hostnames to answer on **beyond** localhost and 127.0.0.1, which are always allowed |
| `COMPOSE_FILE` | commented out | Set to `docker-compose.yml:docker-compose.mysql.yml` to run MySQL instead of PostgreSQL. See [Database](#database) |
| `POSTGRES_PASSWORD` | `ark` | Only reachable inside the Compose network. Set it before the first install |
| `MYSQL_PASSWORD` | `ark` | The same, for the MySQL override. Also used as the MySQL root password |
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
- **`POSTGRES_PASSWORD` and `MYSQL_PASSWORD` only take effect the first time
  the database volume is created.** Changing it later leaves the application unable to authenticate;
  `make clean` first, then change it.

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
    src: ${ARKS_SRC:-../arks-service-new}     # the application
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
[`MIGRATION.md` in the application repository](https://github.com/digitalutsc/arks-service-new/blob/main/MIGRATION.md).

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
`/healthz`, which reports the database and cache separately.

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
