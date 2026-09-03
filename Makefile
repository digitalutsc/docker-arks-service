# Operations for the whole ARK service Docker stack.
#
#   make install   build and start everything, from nothing
#   make up        start an already-built stack
#   make down      stop it, keeping the data
#   make clean     remove it entirely, data and image included
#   make rebuild   clean, then install
#
# The application source is not in this repository; ARKS_SRC in .env says
# where it is. See README.md.

SHELL := /bin/sh
.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help check env build install up down clean rebuild admin info logs ps shell manage

COMPOSE ?= docker compose
DEFAULT_SRC := ../arks-service-new
IMAGE := arkservice-web:local

# Read one value out of .env at recipe time. Not at parse time: `make install`
# creates .env during its own run, long after this file has been read.
ENVGET = $$(sed -n 's/^$(1)=//p' .env 2>/dev/null | tail -1)

# Compose interpolates the mandatory DJANGO_SECRET_KEY for every command it
# runs, tearing down included. Taking the stack apart should not depend on a
# .env that may be blank or gone, so teardown supplies a throwaway value; it
# reaches no container, because down starts none.
TEARDOWN_ENV := DJANGO_SECRET_KEY=unused-while-tearing-the-stack-down

help: ## Show this help
	@sed -n 's/^\([a-z-]*\):.*## \(.*\)/\1|\2/p' $(MAKEFILE_LIST) | awk -F'|' '{printf "  %-9s %s\n", $$1, $$2}'

install: env check build ## Build and start the whole stack from nothing
	@$(COMPOSE) up -d --wait
	@$(MAKE) --no-print-directory admin
	@$(MAKE) --no-print-directory info

up: env ## Start an already-built stack
	@$(COMPOSE) up -d --wait
	@$(MAKE) --no-print-directory info

down: ## Stop the stack, keeping the data
	@$(TEARDOWN_ENV) $(COMPOSE) down

clean: ## Remove the stack entirely: containers, volumes and the built image
	@$(TEARDOWN_ENV) $(COMPOSE) down --volumes --remove-orphans
	@docker image rm -f $(IMAGE) >/dev/null 2>&1 || true
	@echo "Stack removed. .env was kept: it holds this machine's secret key and admin password."

rebuild: clean install ## Blow the stack away and install it again from scratch

build: env ## Build the application image
	@$(COMPOSE) build --pull

check: ## Check that Docker and the application checkout are both there
	@command -v docker >/dev/null 2>&1 || { echo "docker is not installed."; exit 1; }
	@$(COMPOSE) version >/dev/null 2>&1 || { echo "docker compose v2 is required."; exit 1; }
	@src="$(call ENVGET,ARKS_SRC)"; src="$${src:-$(DEFAULT_SRC)}"; \
	test -f "$$src/manage.py" || { \
	  echo "No application checkout at $$src (there is no $$src/manage.py)."; \
	  echo "Set ARKS_SRC in ./.env to where the arks-service-new checkout is."; \
	  exit 1; }; \
	echo "Application source: $$src"

env: ## Create .env if absent and fill in any blank secrets
	@./scripts/ensure-env.sh

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
