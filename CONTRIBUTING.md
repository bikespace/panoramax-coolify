# Contributing

Notes for working on this repo. For operating a deployed instance, see the documents linked from the [README](./README.md).

---

## Coolify magic environment variables

Five of the deployment's secrets are supplied by [Coolify Magic Environment Variables](https://coolify.io/docs/knowledge-base/environment-variables#magic-environment-variables) rather than entered by hand — Coolify generates them the first time the compose file is loaded. The current name mapping is in [`configuration_options.md` → Secrets](./configuration_options.md#secrets).

Two constraints to keep in mind when adding or renaming one:

**The `ID`/`IDENTIFIER` portion must contain no underscores** — or any other non-letter. Coolify silently generates nothing when it does: the variable never appears in the UI, the reference resolves to an empty string, and the failure surfaces much later as something like `POSTGRES_PASSWORD could not be an empty value`. This is why the names in `docker-compose.yml` squash the underscores out of the container-facing names (`KC_DB_PASSWORD` → `SERVICE_PASSWORD_64_KCDBPASSWORD`). Coolify's docs mention the restriction only for the port-carrying form of magic variables, not the general case — see [coollabsio/coolify#11043](https://github.com/coollabsio/coolify/issues/11043#issuecomment-5152246623). Assume `[a-zA-Z]` are the only safe characters.

**Don't write a placeholder form of the magic-variable token into a comment.** Coolify's scanner reads comment text too, so a made-up example name in a `#` line gets picked up and mis-parsed as a real declaration. Describe the naming pattern in prose, or point at this file, rather than spelling out a fake one inside `docker-compose.yml`.

---

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

---

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

That updates `.upstream-sync`, which records the upstream **commit SHA** last reviewed (plus the date, as human context). A SHA rather than a date because it's exact and self-verifying: the next check diffs from that commit, so nothing can slip through a gap and there's no cutoff date to remember. Only `--record` writes to it, so the recorded SHA always means "a human reviewed this", not "someone ran the script".

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

Diffing our tree against upstream (`git diff HEAD upstream/main`) shows something else entirely: our **total divergence**, which is large and almost entirely intentional. Everything this repo added — the `backup/` directory, the Dockerfiles, `keycloak-export-loop.sh`, `env.example` — appears as a deletion, and `docker-compose.yml` always shows the `x-base-geovisio` anchor using `image: panoramax/api:${GEOVISIO_IMAGE_TAG:-latest}` instead of a `build:` block, since this repo does not include the API source code. See the [CHANGELOG](./CHANGELOG.md) for the full list. That diff is useful for auditing how far we've drifted, but it buries upstream's actual changes in hundreds of lines of noise.
