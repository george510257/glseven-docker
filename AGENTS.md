# Repository Guidelines

## Project Structure & Module Organization

This is a Docker Compose infrastructure repository, not an application codebase. The six domain files are the primary modules: `docker-compose-infra.yml`, `docker-compose-observability.yml`, `docker-compose-security.yml`, `docker-compose-platform.yml`, `docker-compose-apps.yml`, and `docker-compose-portal.yml`. Service settings live in `common/env/<service>.env`; deployment logic lives in `startup.sh`, `shutdown.sh`, and `common/`. Portal routing is under `portal/conf/conf.d` (HTTP) and `portal/conf/stream-conf.d` (TCP). Component-specific configuration, MySQL initialization SQL, assets, and design documents are under their matching service directories and `docs/`.

## Build, Test, and Development Commands

```bash
cp .env.example .env
bash startup.sh [data-directory]
bash shutdown.sh
for file in docker-compose-*.yml; do docker compose -f "$file" config -q; done
bash common/check-consistency.sh
```

`startup.sh` runs preflight checks, creates volumes and the `glseven` network, then starts domains in batches. `shutdown.sh` stops them in reverse order. The two validation commands check Compose syntax and cross-file portal consistency. There is no application build or unit-test suite.

## Coding Style & Naming Conventions

Use two-space indentation for YAML, Nginx, and component configuration. Keep Bash in `snake_case`, quote variables, and prefer reusable arrays or functions in existing scripts. Container names, hostnames, DNS references, and portal subdomains must match, for example `mysql`. Services reference each other by container DNS name, not fixed IP. Keep host-port publishing centralized in `docker-compose-portal.yml`; do not add `ports` to individual services.

## Testing Guidelines

Validate every modified Compose file before committing. Run `bash common/check-consistency.sh`, especially after adding or renaming a service; a new service may require changes to its compose file, portal port mapping, HTTP or stream config, portal card, and README hosts list. For runtime verification, inspect container health and use the portal URL:

```bash
docker inspect -f '{{.State.Health.Status}}' <container>
curl -I http://<container>.glseven.local:<port>
```

## Commit & Pull Request Guidelines

Follow Conventional Commits with Chinese descriptions, as in `fix(security): ...` and `feat(apps): ...`. Pull requests should state the affected services, user-visible impact, validation performed, and any issue link. Include relevant logs or screenshots for startup, portal, or service failures.

## Security & Configuration Tips

Keep real credentials out of tracked files. Root `.env` is ignored and holds interpolated values such as `DOCKER_VOLUME` and `REDIS_PASSWORD`. Treat `common/env/*` defaults as development-only and preserve their production warnings. Do not reuse this isolated development exposure model, especially etcd, in production.
