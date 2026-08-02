# Changes from Upstream

This document describes how this repository differs from the upstream [`docker/full-keycloak-auth`](https://gitlab.com/panoramax/server/api/-/tree/main/docker/full-keycloak-auth) example on `main`. Changes are organized thematically for ease of reading.


## Pre-built image

**`docker-compose.yml`** — replaced the `x-base-geovisio` build anchor (which pointed at the API source tree) with `image: panoramax/api:${GEOVISIO_IMAGE_TAG:-latest}`. This decouples the deployment repo from the API source code so it can be maintained independently. The image is published to [Docker Hub](https://hub.docker.com/r/panoramax/api).

`WEBSITE_IMAGE_TAG` was introduced as a separate variable from `GEOVISIO_IMAGE_TAG` — the website image is on Docker Hub and needs its own tag; using one variable for both produced incorrect image references when deploying a non-DockerHub API image.


## Coolify platform compatibility

Coolify has several constraints that differ from plain Docker Compose:

- **Named networks removed** — Coolify does not support custom named networks in compose files; the default bridge network is used instead.
- **`deploy.replicas` replaced with explicit services** — Coolify ignores `deploy.replicas`, so upstream's single `background-worker` with `replicas: ${PICTURE_WORKERS_REPLICATS:-5}` was replaced with four explicitly named services (`background-worker-1` … `-4`) sharing a `&worker-default` anchor. `PICTURE_WORKERS_REPLICATS` no longer applies; change the worker count by adding or removing numbered services.
- **Bind mounts replaced with baked-in files** — Coolify resolves bind mount paths relative to the Docker host, not the helper container, so files that upstream bind-mounts (`nginx.conf`, `robots.txt`, `1-init-keycloak-db.sh`, `keycloak-realm.json`) are copied into their images at build time. This adds `Dockerfile.nginx` and `Dockerfile.postgres` (replacing the `nginx:*` and `postgis/postgis:16-3.4` image references) and two `COPY` lines in `Dockerfile.keycloak`. Each build context gets a `.dockerignore` that denies everything and re-admits only the files its Dockerfiles `COPY`, so docs, secrets, `pictures_storage/`, and anything added later stay out by default.
- **`restart: "no"` on one-shot services** — Coolify injects `restart: unless-stopped` on every service. Without an explicit override, `migrations` and `keycloak-import` (both of which exit 0 on success) would restart in a tight loop.
- **`exclude_from_hc: true`** on `migrations`, `keycloak-import`, `keycloak-export`, `backup`, and the workers — tells Coolify not to include them in its deployment health gate (the one-shot jobs exit intentionally; the others have no HTTP endpoint). This is a custom Coolify feature that is not recognized by most docker compose validators, so a script is provided in `CONTRIBUTING.md` to aid with validation.
- **Traefik labels** — `traefik.enable=false` is set on `auth`, `api`, `keycloak-export`, and the workers so Coolify/Traefik does not route public traffic directly to them; all external traffic flows through nginx.
- **`INFRA_NB_PROXIES` default raised to 2** — Traefik (Coolify) and nginx both sit in front of the API, so two proxy hops must be declared for Flask to trust the correct `X-Forwarded-For` for URL generation and rate limiting.


## Nginx and reverse proxy

- **Port 80** — nginx listens on 80 instead of 8080, and `reverseproxy`'s fixed `8080:8080` host mapping became a bare `- 80`, so Traefik's default routing works with no extra configuration. (This is the only service still publishing a host port; it is the Coolify/Traefik ingress.)
- **RFC 7239 `Forwarded` header stripped** — Traefik sets `Forwarded` without a port, which Keycloak 26's `ForwardedHeadersParser` fails to parse, misidentifying the request origin. nginx sends `proxy_set_header Forwarded "";` and Keycloak uses `X-Forwarded-*` instead.
- **`Host` header added to the `/oauth` block** — so Keycloak sees the real hostname when constructing redirect URLs, asset paths, and CSP headers.
- **Security response headers** — `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, and `Strict-Transport-Security: max-age=31536000` on the `/api` and website routes. Not on `/oauth`, where Keycloak manages its own. No `X-Frame-Options`/`frame-ancestors` — the Panoramax viewer stays embeddable — and no `limit_req`, so CLI bulk uploads are never throttled (login brute-force is covered by Keycloak).
- **Branding overrides served from the proxy** — the upstream `panoramax/website` image bakes its logo, favicon, and social preview image in at build time, so replacing them would otherwise mean forking and rebuilding the frontend. nginx serves six assets out of a `branding` volume instead, each with `try_files … @website` falling back to the website's own file when no override is present — an empty volume behaves exactly like a stock deployment, and each asset can be replaced on its own. The logo is matched by regex (`^/assets/logo-[^/]+\.png$`) because Vite content-hashes it into a filename that changes with every website release. Every block declares its own `default_type`, since this `nginx.conf` does not `include mime.types`. Filenames and the install procedure are in [`configuration_options.md` → Branding](./configuration_options.md#branding-logo-favicon-social-image).
- **`/permanent/` and `/derivates/` blocks removed** — upstream served pictures from a local `pic_data` volume through these locations and a UUID-to-path rewrite. With S3 storage, clients fetch those paths directly from S3, so the blocks and the rewrite are gone.
- **Healthchecks added** to `reverseproxy` (`curl -sf http://localhost/api`) and `website` (`curl -sf http://localhost:3000`) so Coolify can gate on them being ready.


## Keycloak: import, export, and health

- **Realm import split into a one-shot `keycloak-import` service** — upstream runs `start --optimized --import-realm` on `auth`. That flag triggers Keycloak's own internal restart once import completes, and on a fresh deploy the restart can happen before the import's DB write commits, so the next boot finds no realm and imports again, forever. `keycloak-import` now runs `kc.sh import --optimized --file …/geovisio_realm.json --override false` once against the DB (`restart: "no"`), and `auth` starts with plain `start --optimized`. Both `auth` and `keycloak-export` gate on `service_completed_successfully`. `--file` points at the realm JSON directly; `--dir` only logged a directory scan and never actually imported it.
- **`auth` healthcheck is a bare TCP connect** to port 8080. Upstream probes `/oauth/health/ready` on the management port; those endpoints are not reliably available in this build, and a request-level check only passes once realm import finishes — long enough that Coolify's restart supervisor killed the container first, looping indefinitely. This is a liveness check, not readiness: dependents may see a few seconds of 503s right after `auth` is marked healthy.
- **`KC_HOSTNAME_PATH: /oauth` retained** — tells Keycloak it is served under the `/oauth` prefix so redirect URLs and asset paths are correct behind nginx. Upstream dropped this setting; it is kept here because nginx does serve Keycloak under that prefix.
- **`KC_HTTP_MANAGEMENT_HEALTH_ENABLED: "true"`** — enables the management health endpoint on port 9000. Retained for manual diagnostics; the healthcheck no longer depends on it.
- **`keycloak-export` sidecar** — replaces what would otherwise be a manual Coolify Scheduled Task. `keycloak-export-loop.sh` (baked into `Dockerfile.keycloak`) runs `kc.sh export --optimized --dir /export --users realm_file --realm geovisio` at startup and every `KC_EXPORT_INTERVAL_SECONDS` (default daily), writing to the `kc_export` volume that `backup-config.sh` ships. `kc.sh export` reads Postgres directly and needs no live HTTP server, so it runs as its own container with only the DB env vars.
  - `--optimized` is required: plain `kc.sh export` re-augments the Quarkus build config at runtime, and since `KC_DB=postgres` is a build-time property not set as a runtime env var here, that silently dropped the JDBC driver config and broke every export.
  - The loop **retries in place every 30s** rather than exiting. Without it, an export that ran before the realm existed — or that raced `auth` over Liquibase's changelog table on a fresh schema — would exit under `set -eu` and restart the whole container, booting a second JVM against the same DB on every retry.
  - Runs as `user: "0:0"` — the `kc_export` named volume is root-owned and the Keycloak image runs as uid 1000. The container listens on no port and only invokes the CLI, so the tradeoff is low-risk.
- **`OAUTH_PROFILE_USE_IFRAME` left unset** — upstream sets it `True` on the `api` service, embedding the Keycloak account page in an iframe. It was reverted here after conflicting with the Traefik/Coolify proxy headers, so the profile page opens as an external link instead (the API's own default). Worth re-testing: the revert predates the `Forwarded`/`Host` header fixes above, and Keycloak is same-origin in this deployment.
- **A dedicated Keycloak container was necessary** rather than folding the export into the Alpine `backup` sidecar: `kc.sh export` needs the full glibc-based Keycloak/Quarkus runtime.


## S3 object storage

Migrated from local filesystem storage to S3-compatible object storage:

- Replaced the single `FS_URL` with `FS_TMP_URL`, `FS_PERMANENT_URL`, and `FS_DERIVATES_URL`, so each storage tier can point at a different bucket or prefix.
- Added `S3_PERMANENT_PUBLIC_URL` and `S3_DERIVATES_PUBLIC_URL` (feeding `API_*_PICTURES_PUBLIC_URL`, which upstream sets to the local `/permanent` and `/derivates` paths) so pictures are served straight from S3 without proxying through the API.
- Removed the `pic_data` volume and its mounts from nginx, `api`, and the workers.
- **`FS_URL` explicitly blanked** — the pre-built `panoramax/api` image bakes in `ENV FS_URL="/data/geovisio"`. A shared `x-base-geovisio-env` anchor sets `FS_URL: ""` on `migrations`, `api`, and the workers so the split S3 variables are used instead.
- **`&acl=public-read`** is documented on the public-bucket storage URLs, so uploads are readable without a bucket policy — needed on providers that do not support them. `backup/fix-object-acls.sh` backfills existing objects if needed.


## Keycloak realm hardening

Changes to `keycloak-realm.json`:

- **Self-registration disabled** — `registrationAllowed: false`; accounts must be created by an admin. `API_REGISTRATION_IS_OPEN` (hardcoded `True` upstream) is now a variable defaulting to `False`, so the website UI and federation metadata agree with the realm.
- **Email verification required** — `verifyEmail: true`.
- **Brute-force detection enabled** — `bruteForceProtected: true` with `failureFactor` lowered from 30 to 10 (temporary lockout; `permanentLockout` stays `false` so an attacker cannot lock out a known user permanently). Previously off, allowing unlimited online password guessing.
- **Password policy added** — `length(12) and notUsername(undefined)`; previously there was none, so a 1-character password was accepted.
- **Direct access grant disabled on the `geovisio` client** — the API and CLI use the authorization-code flow plus bearer API tokens, not the password grant, so this removes an unused headless brute-force channel with no functional impact. (`admin-cli` keeps it.)
- **Least-privilege token scope** — `fullScopeAllowed: false` on `geovisio` (the only client in the realm still `true`). Panoramax reads identity from the `profile`/`email` scopes and authorizes in its own DB, so logins, the API, and CLI uploads are unaffected.
- **Refresh-token rotation** — `revokeRefreshToken: true` with `refreshTokenMaxReuse: 0` makes each refresh token single-use, limiting replay of a stolen one.
- **Login theme fixed** — the `geovisio` client had `loginTheme: "base"`, which rendered an unstyled login page; corrected to `"keycloak"`.

**These apply to fresh deploys only.** The import runs `--override false`, so it will not retroactively update a running `geovisio` realm, and the `master` realm (admin console) is never covered by the import. Manual admin-console / `kcadm.sh` steps for an existing instance are in [`deployment_instructions.md` §6.1](./deployment_instructions.md#61-keycloak-realm-hardening).


## Network exposure and supply chain

- **Internal services no longer published to the host** — removed the `ports:` mappings from `db`, `api`, `website`, and `auth` (which upstream publishes on 8080, 9000, and 8443). The short `- <n>` form publishes to `0.0.0.0` on a random host port, which bypassed the reverse proxy and exposed a superuser Postgres (`gvs`), Keycloak's management port, and the un-fronted API/website directly on the host network. All four are still reachable by service name over the compose network (`db:5432`, `api:5000`, `website:3000`, `auth:8080`), which is how nginx and the other services already reach them; `docker exec` remains the debugging path.
- **supercronic download checksum-verified** — `backup/Dockerfile` fetches the pinned `v0.2.33` binary to a temp path and checks it against the SHA1 published on the upstream release (`71b0d58c…`) before installing, so the build fails closed on a mismatch. (aptible/supercronic publishes only SHA1.)
- **nginx base image refreshed** — `nginx:1.25.5` (early 2024) → `nginx:1.27.5` to clear accrued CVEs. Config-compatible.
- **Image-pinning guidance** — `deployment_instructions.md` §4 recommends pinning `GEOVISIO_IMAGE_TAG`/`WEBSITE_IMAGE_TAG` to a released version rather than `latest`. The defaults remain `latest` so the images stay user-configurable.


## Backup and restore subsystem

This repo adds backup scripts and instructions, described in [`backup/backup_architecture.md`](./docker/full-keycloak-auth/backup/backup_architecture.md) (how the code works) and [`backup_and_restore_instructions.md`](./backup_and_restore_instructions.md) (how to operate it).

- **New `backup/` directory** — `Dockerfile` (Alpine + restic, rclone, `postgresql16-client`, supercronic), `entrypoint.sh` (renders the cron schedule from env vars via `envsubst`), `crontab.template`, and the scripts: `backup-db.sh`, `backup-images.sh`, `backup-config.sh`, `backup-healthcheck.sh`, `restic-check.sh`, plus the manually-invoked `backup-now.sh` (one-off full run), `prune-orphan-images.sh` (deletes production HD files with no DB row), and `fix-object-acls.sh` (sets `public-read` per object on providers without bucket policies).
- **`docker-compose.yml`** — added the `backup` service (restic repository derived from `BACKUP_S3_*`, reusing the app secrets rather than re-entering them), a `backup_scratch` volume for working files, a `kc_export` volume mounted read-only for the Keycloak realm snapshot, and the `branding` volume mounted read-only. Its healthcheck (`backup-healthcheck.sh`, 1h interval, 26h start period) reports stale backups.
- **What is backed up** — Postgres dumps (geovisio + keycloak schemas) and secrets encrypted with restic; permanent HD pictures mirrored S3-to-S3 with rclone; the Keycloak realm export as a portable recovery artefact; the nightly config run also covers any operator-supplied branding assets, which live nowhere else — not in git, not in the DB — so this is their only recovery path. Derivates are deliberately excluded and regenerated on restore.
- **`restic init` is automatic** — `entrypoint.sh` detects an uninitialized repo and initializes it, instead of requiring a manual first-run step that a fresh deploy would otherwise crash-loop on every night.
- **supercronic runs with `-no-reap`** — its zombie-reaping activates when it detects PID 1 and crashed on startup before any job ran, restarting the container in a tight loop. Docker's own init (`init: true`, tini) handles reaping.
- **rclone connection strings quote `endpoint`/`region`** — rclone's inline connection-string syntax uses `:` as the remote/path separator, so an unquoted `endpoint=https://host` parsed as an "unsupported protocol scheme" error. `backup-images.sh` runs with `-v` as well, since rclone's default log level suppresses the final transfer-stats line and a clean nightly run otherwise produced no output at all.


## Faster shutdown and redeploys

The docker compose config was optimized to ensure that stopping and restarting the service happens quickly:

- **`stop_signal: SIGKILL` on `api` and the worker anchor.** Coolify stops a compose project's containers strictly serially, and these five ignore `SIGTERM` — they were observed dying at exactly the grace ceiling on every redeploy, making the waits fully additive. Sending `SIGKILL` up front is safe: picture jobs live in a DB-backed queue so a killed worker's job stays pending and is reprocessed, and `api` does no in-process picture processing (`PICTURE_PROCESS_THREADS_LIMIT: 0`), has no live requests once `reverseproxy` stops first, rolls back killed transactions atomically, and leaves any orphaned temp upload to the existing orphan-prune.
- **`keycloak-export-loop.sh` runs `sleep … & wait $!` so shutdown interrupts it immediately.

See [`CONTRIBUTING.md` → Coolify behaviours to know](./CONTRIBUTING.md#coolify-behaviours-to-know) for the platform quirks behind this.


## Secrets and required variables

**Required variables are enforced.** Variables with no default that would cause a broken or cryptic deployment if unset carry `:?` in `docker-compose.yml`, so Compose (and Coolify) refuse to start and name the missing variable rather than passing empty strings into containers.

**The five application secrets are Coolify Magic Environment Variables.** Upstream expects the operator to supply each by hand; here each reference is `${SERVICE_PASSWORD_64_<ID>}` (no `:?` guard — Coolify guarantees a value), so [Coolify](https://coolify.io/docs/knowledge-base/environment-variables#magic-environment-variables) generates a strong 64-character value the first time the compose file is loaded. The no-symbol `SERVICE_PASSWORD_64_*` form was chosen deliberately because `PG_PASSWORD`/`KC_DB_PASSWORD` are embedded in `postgres://` and JDBC connection strings, where a symbol would corrupt the URL. Container-facing names are unchanged, so `backup-config.sh`, `backup-db.sh`, `prune-orphan-images.sh`, and `1-init-keycloak-db.sh` still see the plain names, and `secrets.env` still stores them that way.

| Container-facing name     | Coolify UI name                             |
| ------------------------- | ------------------------------------------- |
| `OAUTH_CLIENT_SECRET`     | `SERVICE_PASSWORD_64_OAUTHCLIENTSECRET`     |
| `FLASK_SECRET_KEY`        | `SERVICE_PASSWORD_64_FLASKSECRETKEY`        |
| `PG_PASSWORD`             | `SERVICE_PASSWORD_64_PGPASSWORD`            |
| `KC_DB_PASSWORD`          | `SERVICE_PASSWORD_64_KCDBPASSWORD`          |
| `KEYCLOAK_ADMIN_PASSWORD` | `SERVICE_PASSWORD_64_KEYCLOAKADMINPASSWORD` |

The `ID` portion must contain no underscores — Coolify silently generates nothing if it does ([coollabsio/coolify#11043](https://github.com/coollabsio/coolify/issues/11043#issuecomment-5152246623)), which is why the names above squash the container-facing ones. See [`CONTRIBUTING.md`](./CONTRIBUTING.md#coolify-magic-environment-variables) before adding or renaming one.

`RESTIC_PASSWORD` was left as a secret the user needs to generate since the user must also save it separately so that it can be used to restore from backup.

**Restore impact.** Magic vars regenerate on a fresh instance and will not match the backup, so `backup_and_restore_instructions.md` requires overwriting each `SERVICE_PASSWORD_64_*` with the value from the recovered `secrets.env` — matched via the table above — *before* the first deploy, or `keycloak-import` bakes the wrong `OAUTH_CLIENT_SECRET` into the realm and login fails. The `kcadm.sh` snippets in the runbooks authenticate with `$KC_BOOTSTRAP_KEYCLOAK_ADMIN`/`$KC_BOOTSTRAP_KEYCLOAK_ADMIN_PASSWORD`, the names `docker-compose.yml` actually sets on `auth`.

**Other parameterised values.** `KC_DB_PASSWORD` replaced a hardcoded password in `1-init-keycloak-db.sh` and `docker-compose.yml`. `VITE_TITLE`, `VITE_META_TITLE`, `VITE_META_DESCRIPTION`, and `VITE_TILES` became variables with the upstream values as defaults. `API_PICTURES_LICENSE_SPDX_ID`, `API_PICTURES_LICENSE_URL`, and `API_SUMMARY` were hardcoded upstream and are now variables, again keeping the upstream values as defaults, so an operator can set the instance's picture licence and metadata from the Coolify UI without editing the compose file.

`API_SUMMARY` is the one whose default is not a simple scalar. It stays readable in `docker-compose.yml` as a multi-line `>-` folded block with the interpolation wrapped around the JSON (`${API_SUMMARY:-{ … }}`); Compose folds it to a single line and matches the braces correctly, including the nested `${INSTANCE_NAME:-…}` inside. Note that the block scalar indicator has to sit after the `key:`, not inside the `${…:-}` — writing `API_SUMMARY: ${API_SUMMARY:-|` makes the `|` a literal character in a plain multi-line scalar, which then fails to parse as soon as the JSON's first `": "` appears.

**`INSTANCE_NAME`'s two defaults were aligned.** The website fell back to `A geovisio instance` while the API's `API_SUMMARY` fell back to `A Panoramax instance`, so an operator who left it unset got different names in the site header and the federation metadata; both now use `A Panoramax instance`. That alignment only holds while `API_SUMMARY` is unset — an operator-supplied `API_SUMMARY` carries its own `name` and replaces the default wholesale, so `INSTANCE_NAME` no longer reaches the API side at all and the two can diverge again. Anyone setting `API_SUMMARY` should put the same name in its `name` field.

SMTP is not configured by environment variable in either upstream or here — the realm imports with an empty `smtpServer`, and an admin sets email up in the Keycloak console. Keeping it out of the automated import avoids Keycloak's strict validation of `smtpServer.from`, which hard-failed the import whenever SMTP was unset.


## Documentation and repo tooling

Upstream ships its guidance as an `env.example` file and comments in the compose file. This repo replaces those with a documentation set at the repo root — [`README.md`](./README.md), [`deployment_instructions.md`](./deployment_instructions.md), [`configuration_options.md`](./configuration_options.md) (the successor to `env.example`, covering every variable), [`backup_and_restore_instructions.md`](./backup_and_restore_instructions.md), and [`CONTRIBUTING.md`](./CONTRIBUTING.md) — plus `backup/backup_architecture.md` next to the code it describes.

`scripts/check-upstream.sh` reports upstream commits touching `docker/full-keycloak-auth/` since the last one reviewed, and `--record` writes that commit SHA to `.upstream-sync`. Because this repo mirrors upstream's directory path, git can diff the two directly; see [`CONTRIBUTING.md` → Syncing with upstream](./CONTRIBUTING.md#syncing-with-upstream).
