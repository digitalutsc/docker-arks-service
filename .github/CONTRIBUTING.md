# Contributing to docker-arks-service

Thank you for your interest in docker-arks-service. It is the Docker stack for [arks-service](https://github.com/digitalutsc/arks-service), driven by `make`: a development or demonstration stack with its own database, or a production stack against existing MySQL and Valkey/Redis servers. It is maintained by the Digital Scholarship Unit (DSU) at the University of Toronto Scarborough Library for the library's own use, and published as open source so that others can use it and improve it.

## How we work

- **Pull requests are welcome.** We review every pull request and merge the ones that fit the project.
- **We don't take feature requests,** and we can't offer support or help with your installation. If you need a feature, you're welcome to build it and open a pull request, or to keep it in your own fork.
- **Bug reports are welcome** as issues, but we can't promise when, or whether, a bug will be fixed. A pull request with the fix is the fastest way to get one in.

## Reporting a bug

Search the existing issues first. Then open an issue that includes:

- what you did (the commands, URLs or steps),
- what you expected to happen, and what happened instead (the error message, traceback or log lines),
- the versions involved: the commit or release, Python, the database engine and version, and whether you run it bare or in Docker.

**Never attach database exports, `.env` files, passwords, keys or production data** to an issue or pull request. Reduce the problem to an example with made-up data.

## Reporting a security vulnerability

Please don't open a public issue. Report it privately with **Report a vulnerability** on the repository's **Security** tab.

## Submitting a pull request

1. Fork the repository and create a branch from `main`.
2. Keep each pull request to one change. Describe what it changes and why, and link the issue it fixes, if there is one.
3. Add or update tests that cover the change.
4. Update the documentation if behaviour, settings or commands change.
5. Run the checks below before you push. CI runs them on every pull request, and a pull request is reviewed once they pass.
6. A maintainer reviews the pull request. We may ask for changes, or decline a change that is outside what the project needs; if we do, we'll say why.

## Setting up a development environment

You need Docker with Compose 2.24.4 or later, and `make`.

```bash
make up        # creates .env, fetches the application if it is missing, builds, starts and prints the login
make install   # rebuild the image after changing the application
make clean     # remove the stack, its volumes and its image (asks first on a production setup)
```

## Checks

```bash
shellcheck scripts/*.sh
make check
docker compose config --quiet          # for each COMPOSE_FILE combination you touched
make up && make clean                  # the smoke test: the stack must come up healthy
```

CI (`.github/workflows/ci.yml`) runs `static` (shellcheck, `docker compose config` for every `COMPOSE_FILE` line in `.env.example`, and checks that `make env` is idempotent) and `smoke` (`make up` on PostgreSQL, then on MySQL with arks-cli, resolver and worker checks, and `make clean`) and `production` (`make up` against a MySQL server outside the stack over TLS, with `docker-compose.remote-proxy.yml`: the bind address, Secure cookies, dropped capabilities, the Celery health checks, the access-log fields, `make backup-media`, `make rollback`, and `make clean` leaving that server's data alone). Outside pull requests, `scan` builds the image and fails on High or Critical vulnerabilities that have a fix (Grype); the whole workflow also runs weekly.

## Conventions

- **Every Docker file lives here;** the application repository has none.
- **`.env` format:** comments on their own lines and no quotes around values, because both Compose and the Makefile read it.
- **Override files combine in any order:** each `docker-compose.*.yml` changes only its own service and resets only its own `depends_on` key.
- **Never overwrite an operator's `.env`,** and never touch an external database or broker from `make clean`.
- **Document new settings** in `.env.example` and the README.

## Licensing

This project is licensed under the [BSD 2-Clause License](../LICENSE). By submitting a pull request, you agree that your contribution is licensed under the same terms.
