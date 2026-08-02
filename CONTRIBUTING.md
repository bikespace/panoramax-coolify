# Contributing

Notes for working on this repo. For operating a deployed instance, see the documents linked from the [README](./README.md).


## Coolify magic environment variables

Five of the deployment's secrets are supplied by [Coolify Magic Environment Variables](https://coolify.io/docs/knowledge-base/environment-variables#magic-environment-variables) rather than entered by hand — Coolify generates them the first time the compose file is loaded. The current name mapping is in [`configuration_options.md` → Secrets](./configuration_options.md#secrets).

Two constraints to keep in mind when adding or renaming one:

**The `ID`/`IDENTIFIER` portion must contain no underscores** — or any other non-letter. Coolify silently generates nothing when it does: the variable never appears in the UI, the reference resolves to an empty string, and the failure surfaces much later as something like `POSTGRES_PASSWORD could not be an empty value`. This is why the names in `docker-compose.yml` squash the underscores out of the container-facing names (`KC_DB_PASSWORD` → `SERVICE_PASSWORD_64_KCDBPASSWORD`). Coolify's docs mention the restriction only for the port-carrying form of magic variables, not the general case — see [coollabsio/coolify#11043](https://github.com/coollabsio/coolify/issues/11043#issuecomment-5152246623). Assume `[a-zA-Z]` are the only safe characters.

**Don't write a placeholder form of the magic-variable token into a comment.** Coolify's scanner reads comment text too, so a made-up example name in a `#` line gets picked up and mis-parsed as a real declaration. Describe the naming pattern in prose, or point at this file, rather than spelling out a fake one inside `docker-compose.yml`.


## Coolify behaviours to know

Platform behaviours that aren't documented upstream and that this repo's compose file is shaped around. Each was found the hard way; changing the related settings without knowing them tends to reintroduce the original problem.

**Containers are stopped strictly serially.** `docker events` during a redeploy shows Coolify stopping one container, waiting for it to die, then starting on the next. Any service that ignores `SIGTERM` therefore adds its *entire* grace period to the total teardown time — the waits are additive, not overlapped. This is why `api` and the workers carry `stop_signal: SIGKILL` (see the [changes documentation](./changes_from_upstream.md#faster-shutdown-and-redeploys)); it took teardown from ~3 minutes to ~9 seconds.

**Coolify's UI "Stop Grace Period" overrides the compose `stop_grace_period` field** — but not `stop_signal`. Per-service `stop_grace_period` values are simply ineffective under Coolify, so `stop_signal` is the only lever that actually works for a service that won't shut down promptly.

**Coolify's Docker Compose buildpack injects every app-level environment variable into every service**, not just the ones that reference it. A variable meant for one container is visible in all of them, which can collide with another image's own conventions — a `PGHOST` intended for `backup` broke the `db` service's init script this way. Variables in that situation are hardcoded per-service in `docker-compose.yml` rather than exposed in the Coolify UI.

**Coolify restarts unhealthy containers on a shorter timeout than compose's `start_period`.** Restarts were observed at ~23–29s against a configured 60s `start_period`, so a service that is slow to become *ready* gets killed and restarted before it ever passes. Healthchecks here are liveness checks (`auth`'s is a bare TCP connect), not readiness checks.

**A `{` or `}` inside a `${VAR:-default}` breaks the build.** Coolify's compose parser reads part of a brace-containing default as a *second* variable name and emits it as a build argument — `--build-arg "color": "#abcdef", …` — whose unbalanced quotes kill the build command with `bash: -c: line 1: unexpected EOF while looking for matching '"'`. Colons and dashes are fine; several URL defaults and `CC-BY-SA-4.0` rely on that. This is why the JSON punctuation of `API_SUMMARY` lives literally in `docker-compose.yml` instead of in a default.

**A value containing `"` set through the Coolify UI does not reach the container intact.** Quotes in the compose file's own *defaults* are unaffected — it is only operator-supplied values that get mangled. This is why no `API_SUMMARY_*` variable carries JSON punctuation: a quoted value leaves the assembled string invalid, and `api` crash-loops on startup with `Parameter API_SUMMARY is not recognized`.

**Coolify only auto-discovers a variable that is the *entire* value of a compose key.** Anything embedded in a larger string — as each `API_SUMMARY_*` variable is, inside `API_SUMMARY` — never appears in the Environment Variables UI, which is why they are each also declared on their own line in the `api` service purely to be discovered. Those extra declarations deliberately carry no default: Compose resolves `${VAR}` against the process environment and the `--env-file`, never against a sibling key in the same `environment:` block, so a default written there would still leave `""` inside `API_SUMMARY`. It would *appear* to work under Coolify, which persists discovered defaults into the env file it passes to Compose, while silently breaking a plain `docker compose up`.

Related upstream bugs for the three behaviours above: [coollabsio/coolify#8851](https://github.com/coollabsio/coolify/issues/8851), [#3674](https://github.com/coollabsio/coolify/issues/3674), [#7542](https://github.com/coollabsio/coolify/issues/7542).


## Validating docker-compose.yml locally

`docker-compose.yml` uses Coolify's `exclude_from_hc` extension field, which isn't part of the Compose Specification — a plain `docker compose config` will reject it as an unknown key. Coolify strips this field server-side before validating; do the same locally. The command below also passes dummy values for the `${VAR:?}` variables the file requires, so it can be copy-pasted and run as-is — no real secrets or `.env` file needed just to check the file parses:

```bash
grep -v 'exclude_from_hc' docker/full-keycloak-auth/docker-compose.yml | \
  DOMAIN=x S3_DERIVATES_PUBLIC_URL=x S3_PERMANENT_PUBLIC_URL=x \
  FS_TMP_URL=x FS_PERMANENT_URL=x FS_DERIVATES_URL=x \
  BACKUP_S3_ENDPOINT=x BACKUP_S3_BUCKET=x BACKUP_S3_ACCESS_KEY=x BACKUP_S3_SECRET_KEY=x \
  RESTIC_PASSWORD=x \
  docker compose -f - config -q
```

No output and a zero exit code means the file is valid. The `SERVICE_PASSWORD_64_*` secrets aren't listed because they carry no `:?` guard — Coolify fills them in, and locally they resolve to empty strings without failing the parse.


## Syncing with upstream

The upstream deployment files live at `docker/full-keycloak-auth/` in the [panoramax/server/api](https://gitlab.com/panoramax/server/api) repo on the `main` branch. Because this repo uses the same path, git can diff them directly.

**Check for new upstream changes:**
```bash
sh scripts/check-upstream.sh
```

This fetches upstream and lists any commits touching `docker/full-keycloak-auth/` since the last one that was reviewed. It writes nothing; run it as often as you like. No setup needed — it fetches by URL rather than through a named remote.

Once you've reviewed what it reports — ported the changes, or decided they don't apply — mark them done:

```bash
sh scripts/check-upstream.sh --record
```

That updates `.upstream-sync`, which records the upstream **commit SHA** last reviewed (plus the date, as human context).

**Inspect or pull in a file.** These need the upstream remote configured (the check script does not):

```bash
git remote add upstream https://gitlab.com/panoramax/server/api.git
git fetch upstream
```

Then:

```bash
# Read a file as it exists upstream
git show upstream/main:docker/full-keycloak-auth/nginx.conf

# Overwrite our copy with the upstream version
git checkout upstream/main -- docker/full-keycloak-auth/nginx.conf
```

**Two different diffs — don't confuse them.** To see *what upstream changed*, diff upstream against upstream, which is what the check script does:

```bash
git diff <last_reviewed_sha>..upstream/main -- docker/full-keycloak-auth/
```

Diffing this repo against upstream (`git diff HEAD upstream/main`) mostly shows intentional divergences from the changes made to add features or ensure Coolify compatibility (described in `changes_from_upstream.md`).
