# docker-arks-service

The Docker deployment of the [ARK service](../arks-service-new). It contains no
application code: the source stays in its own repository and this stack builds
an image from it.

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
| `db` | `postgres:16-alpine` | the database |

Only `web` publishes a port. Data lives in two named volumes, `pgdata` and
`media`. The Compose project is named `arkservice` explicitly, so renaming
either checkout does not orphan them.

## Requirements

Docker with Compose v2 (`docker compose version`), and a checkout of the
application beside this one:

```
arks-redesign/
├── arks-service-new/       the application
└── docker-arks-service/    this repository
```

Anywhere else works too — set `ARKS_SRC` in `.env`.

## Usage

```bash
make install     # build and start everything, from nothing
make up          # start an already-built stack
make down        # stop it, keeping the data
make clean       # remove it entirely: containers, volumes, image
make rebuild     # clean, then install
```

`make install` is the one to run first. It creates `.env` from `.env.example`,
generates a Django secret key and an administrator password into it, builds the
image, starts the stack, waits until it actually answers, creates the
administrator account, and prints the address and the login. Running it again is
safe: nothing already set is regenerated, and an existing administrator is left
alone.

`make` on its own lists every target. The useful extras:

```bash
make manage ARGS="createcollection 'UTSC Digital Collections' \
    --prefix utsc --naan 61220 --naa 'UTSC Library' --template .zd"
make manage ARGS="mint utsc 10"
make logs        # follow every service
make ps          # what is running
make shell       # a shell inside the web container
```

## Configuration

Everything is in `.env`, which `make install` creates and never overwrites.

| Variable | Default | Meaning |
|---|---|---|
| `ARKS_SRC` | `../arks-service-new` | Path to the application checkout |
| `ARKS_PORT` | `8000` | Host port the stack listens on |
| `DJANGO_SECRET_KEY` | generated | Session and CSRF signing key |
| `DJANGO_DEBUG` | `false` | Leave it false |
| `ARKS_EXTRA_HOSTS` | empty | Hostnames to answer on **beyond** localhost and 127.0.0.1, which are always allowed |
| `POSTGRES_PASSWORD` | `ark` | Only reachable inside the Compose network. Set it before the first install |
| `DJANGO_SUPERUSER_USERNAME` | `admin` | The account `make install` creates |
| `DJANGO_SUPERUSER_EMAIL` | `admin@example.org` | |
| `DJANGO_SUPERUSER_PASSWORD` | generated | Printed on the run that creates the account |

`.env` is read by Compose and by the Makefile, which parse it slightly
differently. Two rules keep them agreeing: **comments on their own lines**, and
**no quotes around values**. A trailing comment or a pair of quotes ends up
inside the value, so a quoted password would create an account whose password
includes the quotes.

Two variables are less free than they look:

- **`ARKS_EXTRA_HOSTS` adds to the allowed hosts, it does not replace them.**
  The container healthcheck asks for `localhost`, and Django answers 400 to a
  hostname it does not know, so a stack that dropped `localhost` would never
  become healthy and `make install` would wait forever.
- **`POSTGRES_PASSWORD` only takes effect the first time the database volume is
  created.** Changing it later leaves the application unable to authenticate;
  `make clean` first, then change it.

The file is gitignored: it holds this machine's secret key and administrator
password, and is created mode 600. `make clean` deliberately keeps it.

## How the image gets the source

Compose passes the application checkout to the build as a named context:

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

The stack runs PostgreSQL. Production runs MySQL, and the image installs both
drivers, so you can point `DATABASE_URL` at a MySQL server to rehearse the
production path. The application keeps its schema inside the portable subset and
its CI runs the suite against both engines.

## Troubleshooting

**`make install` fails at the `check` step.** It cannot find `manage.py` under
`ARKS_SRC`. Set that path in `.env`.

**Compose refuses to start: `DJANGO_SECRET_KEY` is required.** `.env` has a
blank key. `make env` fills it in.

**The web container never becomes healthy.** `make logs` shows why. Almost
always a migration failure or an unreachable database; the healthcheck probes
`/healthz`, which reports the database and cache separately.

**`ModuleNotFoundError` for an application package.** A new top-level package
was added to the application without a matching `COPY --from=src` line in the
Dockerfile.

**Large `arkservice-web:latest` and `arkservice-worker:latest` images left over.**
Those are from the older Compose file that lived inside the application
repository, before the split. `make clean` does not touch them because they are
not this stack's. Remove them once by hand:

```bash
docker image rm arkservice-web:latest arkservice-worker:latest
```
