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

## Bumping PostgreSQL Version

When upgrading to a new PostgreSQL 16.x minor version:

1. Find the latest version at https://ftp.postgresql.org/pub/source/
2. Download the SHA256: `curl https://ftp.postgresql.org/pub/source/vX.Y/postgresql-X.Y.tar.bz2.sha256`
3. Update `PG_VERSION` and `PG_SHA256` in `Dockerfile`
4. Also update the Alpine base image tag if a newer stable release is available (https://alpinelinux.org/releases/)
5. PGAudit is pulled from the `REL_${PG_MAJOR}_STABLE` branch — no version pin needed for minor bumps

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
