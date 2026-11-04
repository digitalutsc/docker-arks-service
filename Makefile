# Operations for the whole ARK service Docker stack.
#
#   make up        bring everything up, from nothing if need be
#   make install   the same, but always rebuild the image first
#   make down      stop it, keeping the data
#   make clean     remove it entirely, data and image included
#   make rebuild   clean, then install
#
# The application source is not in this repository; ARKS_SRC in .env says
# where it is, and `make up` clones it there if it is missing. See README.md.

SHELL := /bin/sh
.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help check env src build install up down clean rebuild confirm-external admin info logs ps shell manage import-dump

COMPOSE ?= docker compose
IMAGE := arkservice-web:local

# Where `make import-dump` leaves the review CSV it brings back out.
REPORT ?= import-report.csv

# yes skips the question clean and rebuild ask on a machine whose COMPOSE_FILE
# names an external server, and lets import-dump write into an external database.
CONFIRM ?=

# Read one value out of .env at recipe time. Not at parse time: `make up`
# creates .env during its own run, long after this file has been read.
ENVGET = $$(sed -n 's/^$(1)=//p' .env 2>/dev/null | tr -d '\r' | tail -1)

# The Compose files in use, as Compose itself picks them: COMPOSE_FILE from
# the environment if it is set there, otherwise from .env.
COMPOSE_FILES = $${COMPOSE_FILE:-$(call ENVGET,COMPOSE_FILE)}

# Compose interpolates every mandatory value for every command it runs,
# tearing down included: DJANGO_SECRET_KEY always, MYSQL_HOST and
# MYSQL_PASSWORD under docker-compose.external-db.yml, and BROKER_HOST under
# docker-compose.external-broker.yml. Taking the stack apart
# should not depend on a .env that may be blank or gone, so teardown supplies
# throwaway values; they reach no container and no server, because down starts
# nothing and connects to nothing.
TEARDOWN_ENV := DJANGO_SECRET_KEY=unused-while-tearing-the-stack-down \
                MYSQL_HOST=unused-while-tearing-the-stack-down \
                MYSQL_PASSWORD=unused-while-tearing-the-stack-down \
                BROKER_HOST=unused-while-tearing-the-stack-down

help: ## Show this help
	@sed -n 's/^\([a-z-]*\):.*## \(.*\)/\1|\2/p' $(MAKEFILE_LIST) | awk -F'|' '{printf "  %-12s %s\n", $$1, $$2}'

# Safe to run every time: nothing already set in .env is regenerated, a
# checkout that is already there is left alone, the image is only built when
# there is none, and an existing administrator keeps its password.
up: env check src ## Bring the whole stack up, from nothing if need be
	@docker image inspect $(IMAGE) >/dev/null 2>&1 || $(COMPOSE) build --pull
	@$(COMPOSE) up -d --wait --remove-orphans || { \
	  echo; \
	  echo "  The stack did not become healthy in time. A first start can take several"; \
	  echo "  minutes: a MySQL container sets up its volume, then web runs the migrations"; \
	  echo "  before it answers its health check. Against an external database, web waits"; \
	  echo "  until it can reach that server. Nothing has been undone; the containers keep going."; \
	  echo; \
	  echo "    docker compose ps                # which service is unhealthy"; \
	  echo "    docker compose logs -f db web    # wait for web's \"Listening at\", then Ctrl-C"; \
	  echo "    make up                          # then run this again; it is safe to repeat"; \
	  echo; \
	  echo "  An error or a Traceback in those logs is a real failure, not slowness."; \
	  echo; \
	  exit 1; }
	@$(MAKE) --no-print-directory admin
	@$(MAKE) --no-print-directory info

install: build up ## The same as up, but always rebuild the image first

# --remove-orphans here and in up: a container for a service the Compose
# files no longer define (such as redis, before it was renamed broker) would
# otherwise keep running beside its replacement.
down: ## Stop the stack, keeping the data
	@$(TEARDOWN_ENV) $(COMPOSE) down --remove-orphans

clean: confirm-external ## Remove the stack entirely: containers, volumes and the built image
	@$(TEARDOWN_ENV) $(COMPOSE) down --volumes --remove-orphans
	@docker image rm -f $(IMAGE) >/dev/null 2>&1 || true
	@echo "Stack removed. .env was kept: it holds this machine's secret key and admin password."
	@echo "An external database or broker (the docker-compose.external-*.yml files) is never touched by clean."

rebuild: confirm-external clean install ## Blow the stack away and install it again from scratch

# Asked before clean and rebuild when the Compose files name an external
# server. clean never touches that server, but a machine set up that way is
# production, where taking the stack apart is an outage and drops the broker's
# queued jobs. A development stack, which names no external file, is not
# asked. CONFIRM=yes skips the question, for scripts.
confirm-external:
	@case "$(COMPOSE_FILES)" in *external*) \
	  [ "$(CONFIRM)" = yes ] && exit 0; \
	  echo "COMPOSE_FILE uses an external database or broker: this looks like production."; \
	  echo "This stops the service and removes the stack's containers, volumes and image."; \
	  echo "The external servers themselves are not touched."; \
	  printf 'Type yes to go ahead: '; \
	  read answer || answer=; \
	  [ "$$answer" = yes ] || { echo "Nothing done."; exit 1; } ;; \
	esac

build: env check src ## Build the application image
	@$(COMPOSE) build --pull

check: ## Check that Docker and Compose v2 are there
	@command -v docker >/dev/null 2>&1 || { echo "docker is not installed."; exit 1; }
	@$(COMPOSE) version >/dev/null 2>&1 || { echo "docker compose v2 is required."; exit 1; }
	@# The MySQL, external and proxy overrides use !override and !reset, which
	@# older Compose rejects with a parse error that does not say why.
	@case "$(COMPOSE_FILES)" in *mysql*|*external*|*proxy*) \
	  v=$$($(COMPOSE) version --short 2>/dev/null | sed 's/^v//'); \
	  echo "$$v" | awk -F. '{ exit !($$1 > 2 || ($$1 == 2 && ($$2 > 24 || ($$2 == 24 && $$3 + 0 >= 4)))) }' \
	    || { echo "docker-compose.mysql.yml, docker-compose.proxy.yml and the external-db/external-broker files need Docker Compose 2.24.4 or later (found $$v)."; exit 1; } ;; \
	esac

env: ## Create .env if absent and fill in the application path and any blank secrets
	@./scripts/ensure-env.sh

src: env ## Clone the application checkout into ARKS_SRC if it is not there
	@./scripts/ensure-src.sh

admin: ## Create the administrator account from .env, or leave it alone
	@user="$(call ENVGET,DJANGO_SUPERUSER_USERNAME)"; \
	mail="$(call ENVGET,DJANGO_SUPERUSER_EMAIL)"; \
	pass="$(call ENVGET,DJANGO_SUPERUSER_PASSWORD)"; \
	$(COMPOSE) exec -T \
	  -e DJANGO_SUPERUSER_USERNAME="$$user" \
	  -e DJANGO_SUPERUSER_EMAIL="$$mail" \
	  -e DJANGO_SUPERUSER_PASSWORD="$$pass" \
	  web python manage.py shell --no-imports < scripts/bootstrap_admin.py

info: ## Print the stack's address and administrator login
	@port="$(call ENVGET,ARKS_PORT)"; port="$${port:-8000}"; \
	user="$(call ENVGET,DJANGO_SUPERUSER_USERNAME)"; \
	echo; \
	echo "  Public resolver   http://localhost:$$port/"; \
	echo "  Staff interface   http://localhost:$$port/admin/"; \
	echo "  Sign in as        $$user"; \
	echo; \
	echo "  The generated password is DJANGO_SUPERUSER_PASSWORD in .env, which"; \
	echo "  make clean keeps. An account that already existed keeps its own."; \
	echo

logs: ## Follow the logs of every service
	@$(COMPOSE) logs -f

ps: ## Show what is running
	@$(COMPOSE) ps

shell: ## Open a shell inside the application container
	@$(COMPOSE) exec web sh

manage: ## Run a management command: make manage ARGS="mint utsc 10"
	$(if $(strip $(ARGS)),,$(error Usage: make manage ARGS="<command> [options]"))
	@$(COMPOSE) exec web python manage.py $(ARGS)

# The export never enters the image: it is copied into the running container,
# read, and removed again. Nothing is mounted, so the file can live anywhere.
#
# It imports into whatever database the stack is pointed at. Under
# docker-compose.external-db.yml that is the external server, so a real run
# writes real data there. It therefore refuses there without CONFIRM=yes;
# rehearse with ARGS="--dry-run" first (which needs CONFIRM=yes too).
#
# It goes to /data rather than /tmp because `docker compose cp` writes as root
# while the container runs unprivileged, and /tmp is sticky — the application
# user could not delete its own import afterwards. /data belongs to that user.
#
# One shell line from the copy to the removal, so the copy of the export (with
# its staff passwords) is deleted from the container whether the import
# succeeds or not; the importer's exit status is passed on afterwards.
import-dump: ## Import a legacy export: make import-dump DUMP=/path/ark.sql [ARGS="--dry-run"]
	$(if $(strip $(DUMP)),,$(error Usage: make import-dump DUMP=/path/to/ark.sql [ARGS="--dry-run"]))
	@test -f "$(DUMP)" || { echo "No such file: $(DUMP)"; exit 1; }
	@case "$(COMPOSE_FILES)" in *external-db*) \
	  [ "$(CONFIRM)" = yes ] || { \
	    echo "COMPOSE_FILE uses docker-compose.external-db.yml, so this would import into the"; \
	    echo "external MySQL server, not a container. Run it again with CONFIRM=yes if that is"; \
	    echo "what you mean, after a rehearsal with ARGS=\"--dry-run\"."; \
	    exit 1; } ;; \
	esac
	@echo "Copying $(DUMP) into the web container ..."
	@$(COMPOSE) cp "$(DUMP)" web:/data/legacy-dump$(suffix $(DUMP)) \
	  && $(COMPOSE) exec -T web python manage.py import_legacy \
	       --legacy-dump /data/legacy-dump$(suffix $(DUMP)) --report /data/import-report.csv $(ARGS); \
	status=$$?; \
	if [ $$status -eq 0 ]; then $(COMPOSE) cp web:/data/import-report.csv "$(REPORT)" || status=$$?; fi; \
	$(COMPOSE) exec -T web rm -f /data/legacy-dump$(suffix $(DUMP)) /data/import-report.csv; \
	if [ $$status -eq 0 ]; then echo "Review report copied to: $(REPORT)"; \
	else echo "import-dump failed (exit $$status); the copy of the export was removed from the container."; fi; \
	exit $$status
