# Rehearsing the production migration

This stack imports a legacy export into a throwaway PostgreSQL database, so you
can see exactly what the migration will do before it happens anywhere that
matters. Nothing here ever touches the legacy service, and `make clean` puts you
back to nothing.

**Production does not use Docker.** It runs bare on the LAMP VM against MySQL.
The rules the importer applies, the review report and the real cutover runbook
all live in
[`MIGRATION.md` in the application repository](https://github.com/digitalutsc/arks-service-new/blob/main/MIGRATION.md) — read
that one for what the migration *means*. This page is only about driving it
here.

PostgreSQL is a fair rehearsal because the schema stays inside the portable
subset both engines share, and CI runs the whole suite against each. What it
cannot tell you is how MySQL will sort or compare a particular string. For that,
switch the stack to MySQL 8.0 first (see "Database" in [README.md](README.md))
and rehearse there. The dry run on the VM is still the last word, since its
server version and collation may differ.

## 1. Get the export

Ask for a phpMyAdmin export of the ARK database, or run on the server:

```bash
mysqldump --single-transaction --default-character-set=utf8mb4 ARK_CORE > ARK_CORE.sql
```

Keep it outside both git checkouts — `../legacy/ARK_CORE.sql` is a good spot —
and treat it as a secret: its `user` table holds staff passwords that can be
decrypted with a key that is published in the legacy source. `chmod 600` it and
delete it when you are done. `.gitignore` here covers `*.sql`, but do not lean
on that.

`.sql.gz` works everywhere a `.sql` does, and copies into the container far
faster.

## 2. Import it

```bash
make up                                             # if the stack is not up yet
make import-dump DUMP=../legacy/ARK_CORE.sql ARGS="--dry-run"
make import-dump DUMP=../legacy/ARK_CORE.sql
make manage ARGS="ark_stats"
```

The dry run writes and rolls back inside one transaction, so it reports exactly
what the real run will do without keeping any of it. Both runs leave an
`import-report.csv` beside this README listing every row that could not be
carried over verbatim — read it before the real run, not after.

For the September 2026 production export (219 MB, 3.0M rows) expect:

```
  arks created             97596
  minted at recovered      97595
  bindings created       2758369
  elements merged           2743
  resolutions              70898
  redirects skipped         1606
```

`make manage ARGS="ark_stats"` then shows 77,649 of those ARKs as bound, leaving
19,947 that legacy minted and never gave any metadata to.

Running it a second time creates nothing: the import is idempotent, so you can
rehearse as often as you like.

`make import-dump` copies the file into the running container, reads it there,
and deletes it again. Nothing is mounted and nothing enters the image, so the
export can live anywhere on your machine.

## 3. Look at what you got

```bash
curl -sI http://localhost:8000/ark:/61220/utsc0 | grep -i location
curl -s  'http://localhost:8000/ark:/61220/utsc0?'
open http://localhost:8000/admin/
```

Worth checking by hand:

- a **bound ARK** redirects to its target, with `&` in the URL rather than `&amp;`
- an **unbound ARK** answers 404 — a fifth of production was minted and never
  given a URL, and legacy answered those with its own 404 page
- the **`?` page** lists the metadata, with entities decoded
- **minting continues** where legacy stopped:
  `make manage ARGS="mint dsu_ark 1"` gives `61220/utsc97640`. Only do that in a
  rehearsal — it is a real mint.

## 4. Compare against the live legacy service

```bash
make manage ARGS="resolve_diff \
    --legacy-base https://ark.digital.utsc.utoronto.ca \
    --new-base http://localhost:8000 \
    --known /data/import-report.csv --sample 500"
```

This runs inside the `web` container, which can reach both the internet and its
own port; `localhost` is always an allowed host. Start with `--sample`, then
drop it for the full run and add `--out /data/cutover-diff.csv`, which
`docker compose cp web:/data/cutover-diff.csv .` brings back out.

To pass `--known`, put the report where the container can see it first:
`docker compose cp import-report.csv web:/data/import-report.csv`.

Two things to know. Every path it fetches increments that ARK's redirect counter
on the legacy service. And a green result here is encouraging rather than
conclusive: the real gate is the same command run on the VM against the imported
MySQL database.

## 5. Start over

```bash
make clean && make install     # empty database
```

Or just re-run the import on top of itself; it is idempotent either way.

## Troubleshooting

**`No such file:`** — `DUMP` is relative to this directory.

**`make import-dump` fails at the copy step** — the stack is not running.
`make up`.

**`is not valid utf-8`** — re-export with
`mysqldump --default-character-set=utf8mb4`, or say what it is:
`ARGS="--encoding latin-1"`.

**No space left on device** — the export is copied into the container's writable
layer. Use the gzipped one, or give Docker Desktop a bigger disk.

**The import is much slower than the totals suggest** — reading the file is
seconds; writing several million rows to PostgreSQL is the rest. It is one
transaction, so an interrupted run leaves nothing behind.

Everything else is in
[`MIGRATION.md` in the application repository](https://github.com/digitalutsc/arks-service-new/blob/main/MIGRATION.md).
