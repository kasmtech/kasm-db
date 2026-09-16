# CLAUDE.md — kasm-db

## Project Overview

Custom PostgreSQL Docker image for Kasm Workspaces. Builds PostgreSQL 16 from source on Alpine Linux, adding the PGAudit extension. Published to DockerHub as `kasmweb/postgres`.

## Key Files

- **`Dockerfile`** — Two-stage Alpine build: compiles PostgreSQL + PGAudit from source (builder stage), then assembles a minimal runtime image.
- **`docker-entrypoint.sh`** — Init script handling DB initialization, user/password setup, and startup.
- **`config/postgresql.conf`** — PostgreSQL runtime configuration (mounted at `/var/lib/postgresql/conf/`).
- **`config/pg_hba.conf`** — Client authentication rules.
- **`config/data.sql`** — Initial seed SQL run at first container start (`/docker-entrypoint-initdb.d/`).
- **`.gitlab-ci.yml`** — Multi-arch (amd64 + arm64) build pipeline pushing to `kasmweb/postgres` (releases) or `kasmweb/postgres-private` (feature branches).

## PostgreSQL/PGAudit Version Resolution

`PG_VERSION`, `PG_SHA256`, and `PGAUDIT_VERSION` are `ARG`s in `Dockerfile` with **no default** (only `PG_MAJOR` defaults, to `16`). When left unset, the build auto-resolves them at build time:

- `PG_VERSION` → latest `PG_MAJOR.x` minor listed at https://ftp.postgresql.org/pub/source/
- `PG_SHA256` → fetched fresh from the matching official `.sha256` file, so the download is still checksum-verified even when the version was auto-resolved
- `PGAUDIT_VERSION` → latest stable tag matching `PG_MAJOR.*` in the pgaudit repo (pre-release `beta`/`rc` tags excluded), checked out instead of floating on the `REL_${PG_MAJOR}_STABLE` branch head

This means a routine minor bump (including a CVE fix) lands automatically on the next build/pipeline run — no Dockerfile edit needed. It only ever rolls forward within `PG_MAJOR` (e.g. 16.12 → 16.15); a major upgrade (16 → 17) requires deliberately bumping the `PG_MAJOR` default, which is a separate, reviewed change (major PG upgrades also need a data migration, not just a new binary).

Both resolvers fail the build explicitly (`docker build` exits non-zero with a clear message) if nothing matches, instead of silently proceeding with an empty value.

**CI does not rely on the Dockerfile's own resolution.** Docker's layer cache is keyed on instruction text, not on what a `RUN`'s network calls return — a plain `docker build .` re-run without `--no-cache` would otherwise silently keep whatever version was resolved on a previous build, and the amd64/arm64 legs (separate parallel jobs) could independently resolve to *different* versions if a release lands mid-pipeline. `.gitlab-ci.yml` avoids both problems with a `resolve-pg-versions` job (stage `resolve`, runs before `build`) that resolves all three values once and publishes them as a dotenv artifact; every build job `needs` it and passes the same three values via `--build-arg`, so a new upstream release always changes the build-arg values (busting cache correctly) and both arches always land on identical versions. The Dockerfile's in-image auto-resolution remains as the path for ad-hoc local builds (`docker build .` with no CI involved) — for those, re-run with `--no-cache` (or pass explicit `--build-arg`s) if you need to force a re-check against upstream.

To pin an exact version instead of auto-resolving (e.g. to reproduce a specific release build), pass `--build-arg`:

```bash
docker build \
  --build-arg PG_VERSION=16.15 \
  --build-arg PG_SHA256=<sha> \
  --build-arg PGAUDIT_VERSION=16.1 .
```

Also update the Alpine base image tag if a newer stable release is available (https://alpinelinux.org/releases/) — this is not auto-resolved.

## Build & Test

The CI pipeline (`build-container-dev` job) handles the actual multi-arch build on GitLab runners. To build locally:

```bash
# Requires Docker; build takes ~15-30 min (compiles PostgreSQL from source)
docker build -t kasmweb/postgres:test .
```

## CI Tagging Scheme

- **Feature branches** → `kasmweb/postgres-private:<branch-name>` (multi-arch manifest)
- **develop** → `kasmweb/postgres:develop` (multi-arch manifest)
- **release/X.Y.Z** → `kasmweb/postgres:X.Y.Z` (multi-arch manifest)
- **Scheduled (rolling)** → `kasmweb/postgres:<branch>-rolling`
