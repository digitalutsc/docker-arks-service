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
.PHONY: help check env src build install up down clean rebuild admin info logs ps shell manage import-dump

COMPOSE ?= docker compose
IMAGE := arkservice-web:local

# Where `make import-dump` leaves the review CSV it brings back out.
REPORT ?= import-report.csv

# Read one value out of .env at recipe time. Not at parse time: `make up`
# creates .env during its own run, long after this file has been read.
ENVGET = $$(sed -n 's/^$(1)=//p' .env 2>/dev/null | tr -d '\r' | tail -1)

# Compose interpolates the mandatory DJANGO_SECRET_KEY for every command it
# runs, tearing down included. Taking the stack apart should not depend on a
# .env that may be blank or gone, so teardown supplies a throwaway value; it
# reaches no container, because down starts none.
TEARDOWN_ENV := DJANGO_SECRET_KEY=unused-while-tearing-the-stack-down

help: ## Show this help
	@sed -n 's/^\([a-z-]*\):.*## \(.*\)/\1|\2/p' $(MAKEFILE_LIST) | awk -F'|' '{printf "  %-12s %s\n", $$1, $$2}'

# Safe to run every time: nothing already set in .env is regenerated, a
# checkout that is already there is left alone, the image is only built when
# there is none, and an existing administrator keeps its password.
up: env check src ## Bring the whole stack up, from nothing if need be
	@docker image inspect $(IMAGE) >/dev/null 2>&1 || $(COMPOSE) build --pull
	@$(COMPOSE) up -d --wait
	@$(MAKE) --no-print-directory admin
	@$(MAKE) --no-print-directory info

install: build up ## The same as up, but always rebuild the image first

down: ## Stop the stack, keeping the data
	@$(TEARDOWN_ENV) $(COMPOSE) down

clean: ## Remove the stack entirely: containers, volumes and the built image
	@$(TEARDOWN_ENV) $(COMPOSE) down --volumes --remove-orphans
	@docker image rm -f $(IMAGE) >/dev/null 2>&1 || true
	@echo "Stack removed. .env was kept: it holds this machine's secret key and admin password."

rebuild: clean install ## Blow the stack away and install it again from scratch

build: env check src ## Build the application image
	@$(COMPOSE) build --pull

check: ## Check that Docker and Compose v2 are there
	@command -v docker >/dev/null 2>&1 || { echo "docker is not installed."; exit 1; }
	@$(COMPOSE) version >/dev/null 2>&1 || { echo "docker compose v2 is required."; exit 1; }

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
# It goes to /data rather than /tmp because `docker compose cp` writes as root
# while the container runs unprivileged, and /tmp is sticky — the application
# user could not delete its own import afterwards. /data belongs to that user.
import-dump: ## Import a legacy export: make import-dump DUMP=/path/ark.sql [ARGS="--dry-run"]
	$(if $(strip $(DUMP)),,$(error Usage: make import-dump DUMP=/path/to/ark.sql [ARGS="--dry-run"]))
	@test -f "$(DUMP)" || { echo "No such file: $(DUMP)"; exit 1; }
	@echo "Copying $(DUMP) into the web container ..."
	@$(COMPOSE) cp "$(DUMP)" web:/data/legacy-dump$(suffix $(DUMP))
	@$(COMPOSE) exec -T web python manage.py import_legacy \
	    --legacy-dump /data/legacy-dump$(suffix $(DUMP)) --report /data/import-report.csv $(ARGS)
	@$(COMPOSE) cp web:/data/import-report.csv "$(REPORT)"
	@$(COMPOSE) exec -T web rm -f /data/legacy-dump$(suffix $(DUMP)) /data/import-report.csv
	@echo "Review report copied to: $(REPORT)"
