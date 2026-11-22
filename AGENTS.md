# Repository Guidelines

## Project Structure & Module Organization

This is a Docker Compose infrastructure repository, not an application codebase. The seven domain packages are the primary modules: `infra/docker-compose.yml`, `observability/docker-compose.yml`, `security/docker-compose.yml`, `platform/docker-compose.yml`, `apps/docker-compose.yml`, `devops/docker-compose.yml` (GitLab + Runner, only started by the `sit` profile), and `portal/docker-compose.yml`. Service settings live in `<domain>/env/<service>.env`; deployment logic lives in `startup.sh`, `shutdown.sh`, and `common/`. Portal routing is under `portal/conf/conf.d` (HTTP) and `portal/conf/stream-conf.d` (TCP). Component-specific configuration, MySQL initialization SQL, assets, and design documents are under their matching service directories and `docs/`.

## Build, Test, and Development Commands

```bash
cp .env.local.example .env.local
bash startup.sh --profile local [data-directory]
bash shutdown.sh
for file in */docker-compose.yml; do docker compose --env-file .env.local -f "$file" config -q; done
bash common/check-consistency.sh
bash ci/scripts/test-profile.sh
bash ci/scripts/test-env-config.sh
bash ci/scripts/test-compose-style.sh
```

`startup.sh` runs preflight checks, creates volumes and the `glseven` network, then starts domains in batches. `shutdown.sh` stops them in reverse order. The `devops` domain is profile-gated: only `--profile sit` starts GitLab and its runner. The two validation commands check Compose syntax and cross-file portal consistency. There is no application build or unit-test suite.

## Coding Style & Naming Conventions

Use two-space indentation for YAML, Nginx, and component configuration. Keep Bash in `snake_case`, quote variables, and prefer reusable arrays or functions in existing scripts. Container names, hostnames, DNS references, and portal subdomains must match, for example `mysql`. Services reference each other by container DNS name, not fixed IP. Keep host-port publishing centralized in `portal/docker-compose.yml`; do not add `ports` to individual services. Service definitions use the shared templates in `common/base-service.yml` via `extends: *healthy` (or `*base`/`*common`); do not repeat `restart`, `common.env`, or standard healthcheck timings in domain compose files.

## Testing Guidelines

Validate every modified Compose file before committing. Run `bash common/check-consistency.sh`, especially after adding or renaming a service; a new service may require changes to its compose file, portal port mapping, HTTP or stream config, portal card, and README hosts list. For runtime verification, inspect container health and use the portal URL:

```bash
docker inspect -f '{{.State.Health.Status}}' <container>
curl -I http://<container>.glseven.local:<port>
```

## Commit & Pull Request Guidelines

Follow Conventional Commits with Chinese descriptions, as in `fix(security): ...` and `feat(apps): ...`. Pull requests should state the affected services, user-visible impact, validation performed, and any issue link. Include relevant logs or screenshots for startup, portal, or service failures.

## Security & Configuration Tips

Keep real credentials out of tracked files. Profile files (`.env.local` / `.env.sit`) are ignored and hold per-machine values such as `DOCKER_VOLUME`, `KAFKA_EXTERNAL_HOST`, and `REDIS_PASSWORD`; only `*.example` templates are tracked. Treat `<domain>/env/*` defaults as development-only and preserve their production warnings. Do not reuse this isolated development exposure model, especially etcd, in production.
