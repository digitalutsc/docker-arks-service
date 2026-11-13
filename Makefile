# Operations for the whole ARK service Docker stack.
#
#   make up        bring everything up, from nothing if need be
#   make install   the same, but always rebuild the image first
#   make update    move the application checkout to ARKS_REF, then install
#   make down      stop it, keeping the data
#   make clean     remove it entirely, data and image included
#   make rebuild   clean, then install
#   make prune     remove this stack's dangling images and stale build cache
#   make rollback  go back to the image the last build replaced
#   make backup-media  save the media volume to BACKUP_DIR
#
# clean and rebuild ask first when COMPOSE_FILE names an external server, and
# import-dump into an external database refuses; CONFIRM=yes for either.
#
# The application source is not in this repository; ARKS_SRC in .env says
# where it is, and `make up` clones it there if it is missing. See README.md.

SHELL := /bin/sh
.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help check env src build install update up down clean rebuild prune rollback confirm-external admin info logs ps shell manage import-dump backup-media

COMPOSE ?= docker compose
IMAGE := arkservice-web:local
# The image the last build replaced, kept so `make rollback` has something to
# go back to. One generation only: the build before that is pruned.
PREV := arkservice-web:prev
# Holds the current image by name while a build runs. With the containerd
# image store an image whose only tag has moved is gone at once, so it cannot
# be tagged as $(PREV) afterwards by its ID.
STAGED := arkservice-web:replaced-by-build
# The Dockerfile labels the image with this, so pruning can be limited to
# images this stack built and leave every other project's alone.
LABEL := org.utsc.arkservice=app

# Where `make import-dump` leaves the review CSV it brings back out.
REPORT ?= import-report.csv

# Where `make backup-media` writes its archives.
BACKUP_DIR ?= backups

# yes skips the question clean and rebuild ask on a machine whose COMPOSE_FILE
# names an external server, and lets import-dump write into an external database.
CONFIRM ?=

# Read one value out of .env at recipe time. Not at parse time: `make up`
# creates .env during its own run, long after this file has been read.
ENVGET = $$(sed -n 's/^$(1)=//p' .env 2>/dev/null | tr -d '\r' | tail -1)

# The Compose files in use, as Compose itself picks them: COMPOSE_FILE from
# the environment if it is set there, otherwise from .env.
COMPOSE_FILES = $${COMPOSE_FILE:-$(call ENVGET,COMPOSE_FILE)}

# What the application checkout is at, for the image's revision label: the
# release tag when it sits on one, otherwise the nearest tag or the commit.
REVISION = $$(git -C "$(call ENVGET,ARKS_SRC)" describe --tags --always --dirty 2>/dev/null || echo unknown)
# What an image is made of: its layers and labels. Not its ID, which with
# build attestations is different for every build, even of the same thing.
CONTENT_OF = $$(docker image inspect -f '{{.RootFS.Layers}} {{.Config.Labels}}' $(1) 2>/dev/null || true)
# The label back out of an image.
REVISION_OF = $$(docker image inspect -f '{{index .Config.Labels "org.utsc.arkservice.revision"}}' $(1) 2>/dev/null | grep -v '^<no value>$$' | grep . || echo unknown)

# Compose interpolates every mandatory value for every command it runs,
# tearing down included: DJANGO_SECRET_KEY always, MYSQL_HOST and
# MYSQL_PASSWORD under docker-compose.external-db.yml, and BROKER_HOST under
# docker-compose.external-broker.yml, and ARKS_BIND_ADDRESS under
# docker-compose.remote-proxy.yml. Taking the stack apart
# should not depend on a .env that may be blank or gone, so teardown supplies
# throwaway values; they reach no container and no server, because down starts
# nothing and connects to nothing.
TEARDOWN_ENV := DJANGO_SECRET_KEY=unused-while-tearing-the-stack-down \
                MYSQL_HOST=unused-while-tearing-the-stack-down \
                MYSQL_PASSWORD=unused-while-tearing-the-stack-down \
                BROKER_HOST=unused-while-tearing-the-stack-down \
                ARKS_BIND_ADDRESS=127.0.0.1

help: ## Show this help
	@sed -n 's/^\([a-z-]*\):.*## \(.*\)/\1|\2/p' $(MAKEFILE_LIST) | awk -F'|' '{printf "  %-12s %s\n", $$1, $$2}'

# Safe to run every time: nothing already set in .env is regenerated, a
# checkout that is already there is left alone, the image is only built when
# there is none, and an existing administrator keeps its password.
up: env check src ## Bring the whole stack up, from nothing if need be
	@docker image inspect $(IMAGE) >/dev/null 2>&1 || ARKS_REVISION="$(REVISION)" $(COMPOSE) build --pull
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
	@docker image prune -f --filter label=$(LABEL) >/dev/null

# The checkout is only ever moved here, by name. ARKS_REF in .env says where
# to: a release tag (the checkout then sits exactly on it), a branch (fast-
# forwarded to origin's latest), or blank for the default branch. It refuses
# on uncommitted changes and never discards commits. `make build` and `make
# up` leave the checkout alone and only say when it is not at ARKS_REF.
update: env check ## Move the application checkout to ARKS_REF (tag or branch), then install
	@./scripts/update-src.sh
	@$(MAKE) --no-print-directory install

# --remove-orphans here and in up: a container for a service the Compose
# files no longer define (such as redis, before it was renamed broker) would
# otherwise keep running beside its replacement.
down: ## Stop the stack, keeping the data
	@$(TEARDOWN_ENV) $(COMPOSE) down --remove-orphans

clean: confirm-external ## Remove the stack entirely: containers, volumes and the built image
	@$(TEARDOWN_ENV) $(COMPOSE) down --volumes --remove-orphans
	@docker image rm -f $(IMAGE) $(PREV) >/dev/null 2>&1 || true
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

# Each build leaves the previous image behind untagged once nothing uses it,
# several hundred MB at a time. The prune removes only dangling images with
# this stack's label: tagged ones (a snapshot's arkservice-web:<tag>) and
# other projects' images stay. install prunes again after up, because the
# image the old containers were still running only dangles once up has
# replaced them.
#
# The image a build replaces is kept as $(PREV) for `make rollback`. It
# becomes $(PREV) only after the build has succeeded and only if the build
# produced different layers or labels, so a failed or unchanged build leaves the
# previous rollback point alone. Until then it is held as $(STAGED).
build: env check src ## Build the application image
	@old=$(call CONTENT_OF,$(IMAGE)); \
	if [ -n "$$old" ]; then docker tag $(IMAGE) $(STAGED); fi; \
	ARKS_REVISION="$(REVISION)" $(COMPOSE) build --pull \
	  || { docker image rm $(STAGED) >/dev/null 2>&1; exit 1; }; \
	new=$(call CONTENT_OF,$(IMAGE)); \
	if [ -n "$$old" ] && [ "$$old" != "$$new" ]; then docker tag $(STAGED) $(PREV); fi; \
	docker image rm $(STAGED) >/dev/null 2>&1 || true
	@docker image prune -f --filter label=$(LABEL) >/dev/null

# Swaps the two tags, so a second rollback undoes the first. Only the code
# goes back: web runs `migrate` on start, which never un-applies a migration,
# so the database keeps the newer schema. Check the release notes first.
rollback: check ## Go back to the image the last build replaced, and restart on it
	@docker image inspect $(PREV) >/dev/null 2>&1 || { \
	  echo "There is no $(PREV) image: no build has replaced one on this machine."; exit 1; }
	@cur=$$(docker image inspect -f '{{.Id}}' $(IMAGE) 2>/dev/null || true); \
	echo "Rolling back from $(call REVISION_OF,$(IMAGE)) to $(call REVISION_OF,$(PREV)) ..."; \
	docker tag $(PREV) $(IMAGE); \
	if [ -n "$$cur" ]; then docker tag "$$cur" $(PREV); fi
	@$(COMPOSE) up -d --wait --remove-orphans
	@echo "Now running $(call REVISION_OF,$(IMAGE)). Migrations were not reversed."
	@echo "make rollback again returns to the newer image."

# Build cache records carry no image labels, so they cannot be picked out by
# this stack's label; the cache prune takes unused build cache older than a
# day from every project (`docker buildx du` shows it first). Nothing a
# running container uses and no tagged image is removed. Old tags are only
# listed, for you to remove with docker image rm.
prune: ## Remove this stack's dangling images and stale build cache; list old tags
	@docker image prune -f --filter label=$(LABEL)
	@docker builder prune -f --filter until=24h
	@old=$$(docker image ls --format '{{.Repository}}:{{.Tag}}  {{.Size}}' \
	    | grep '^arkservice-' | grep -v '^$(IMAGE) '); \
	if [ -n "$$old" ]; then \
	  echo; \
	  echo "Other arkservice-* images, left alone (docker image rm to remove):"; \
	  echo "$$old" | sed 's/^/  /'; \
	fi

check: ## Check that Docker and Compose v2 are there
	@command -v docker >/dev/null 2>&1 || { echo "docker is not installed."; exit 1; }
	@$(COMPOSE) version >/dev/null 2>&1 || { echo "docker compose v2 is required."; exit 1; }
	@# The overrides use !override and !reset, and the health checks use
	@# start_interval; older Compose rejects each with an error that does not
	@# say why.
	@v=$$($(COMPOSE) version --short 2>/dev/null | sed 's/^v//'); \
	echo "$$v" | awk -F. '{ exit !($$1 > 2 || ($$1 == 2 && ($$2 > 24 || ($$2 == 24 && $$3 + 0 >= 4)))) }' \
	  || { echo "This stack needs Docker Compose 2.24.4 or later (found $$v)."; exit 1; }

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

# Behind a proxy the addresses that work are the public ones: web answers on
# loopback (or ARKS_BIND_ADDRESS) for the proxy only, the cookies are Secure,
# and Django refuses a Host it was not told about.
info: ## Print the stack's address and administrator login
	@port="$(call ENVGET,ARKS_PORT)"; port="$${port:-8000}"; \
	user="$(call ENVGET,DJANGO_SUPERUSER_USERNAME)"; \
	hosts=$$(echo "$(call ENVGET,ARKS_EXTRA_HOSTS)" | tr ',' ' '); \
	listen=; \
	case "$(COMPOSE_FILES)" in \
	  *remote-proxy*) listen="$(call ENVGET,ARKS_BIND_ADDRESS):$$port" ;; \
	  *proxy*) listen="127.0.0.1:$$port" ;; \
	esac; \
	lines() { label="$$1"; path="$$2"; shift 2; \
	  for base in "$$@"; do echo "  $$label $$base$$path"; label="                 "; done; }; \
	bases=; \
	if [ -z "$$listen" ]; then \
	  bases="http://localhost:$$port"; \
	  for h in $$hosts; do bases="$$bases http://$$h:$$port"; done; \
	else \
	  for h in $$hosts; do bases="$$bases https://$$h"; done; \
	fi; \
	echo; \
	if [ -n "$$bases" ]; then \
	  lines "Public resolver  " "/" $$bases; \
	  lines "Staff interface  " "/admin/" $$bases; \
	  if [ -n "$$listen" ]; then echo "  Through the proxy; web itself listens on $$listen."; fi; \
	else \
	  echo "  web listens on $$listen, for the proxy. Set ARKS_EXTRA_HOSTS in .env to"; \
	  echo "  the public hostname: Django refuses any other."; \
	fi; \
	echo "  Sign in as        $$user"; \
	echo "  Image revision    $(call REVISION_OF,$(IMAGE))"; \
	echo; \
	if [ -n "$(call ENVGET,DJANGO_SUPERUSER_PASSWORD)" ]; then \
	  echo "  The initial password is DJANGO_SUPERUSER_PASSWORD in .env, which make clean"; \
	  echo "  keeps. An account that already existed keeps its own. In production, change"; \
	  echo "  it after the first sign-in and then blank that line:"; \
	  echo "    make manage ARGS=\"changepassword $$user\""; \
	else \
	  echo "  DJANGO_SUPERUSER_PASSWORD is blank in .env: the account has its own password."; \
	fi; \
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

# The media volume holds the result files of bulk-bind jobs; everything else
# is in the database, which has its own backups, or in the broker, which holds
# nothing that outlives a restart for long. Streamed out of the running web
# container, so no other image is needed. Written under a temporary name and
# renamed, so a failed run never leaves something that looks like a backup.
# Restore: docker compose exec -T web tar xzf - -C /data/media < FILE
backup-media: ## Save the media volume to BACKUP_DIR: make backup-media [BACKUP_DIR=/path]
	@umask 077; mkdir -p "$(BACKUP_DIR)" || exit 1; \
	out="$(BACKUP_DIR)/media-$$(date +%Y%m%d-%H%M%S).tgz"; \
	if $(COMPOSE) exec -T web tar czf - -C /data/media . > "$$out.part"; then \
	  mv "$$out.part" "$$out"; echo "Media volume saved to $$out"; \
	else \
	  rm -f "$$out.part"; echo "backup-media failed; is the stack up (make ps)?"; exit 1; \
	fi
