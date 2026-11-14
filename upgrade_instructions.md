# Upgrading a Panoramax instance

How to move an existing instance to a newer release of this repo. The general procedure comes first, then notes for specific version jumps. For a first deploy, see [`deployment_instructions.md`](./deployment_instructions.md); to recover from a backup, see [`backup_and_restore_instructions.md`](./backup_and_restore_instructions.md).


## General procedure

1. **Take a backup first.** Run `backup-now.sh` in the `backup` container (see [`backup_and_restore_instructions.md`](./backup_and_restore_instructions.md)) and confirm the new snapshot with `restic snapshots`. Database migrations, both Panoramax's and Keycloak's, only go forward. Rolling back means redeploying the previous version and restoring this backup.
2. **Read the version notes below** for every release between your current version and the target, and make any Coolify environment variable changes they list.
3. **Stop the application in Coolify.** A redeploy stops every container anyway, but stopping first guarantees no background worker is mid-job while migrations run.
4. **Set `GEOVISIO_IMAGE_TAG`** (and `WEBSITE_IMAGE_TAG`, if pinned) to the target release, then deploy.
5. **Watch the startup order:** `migrations` and `keycloak-import` should exit with code 0 and the logs should show the schema migrations. After that, `auth`, `api`, `website` and `reverseproxy` should turn healthy. In Coolify, check that no container's restart count keeps climbing.
6. **Run the checks** in [Post-upgrade checks](#post-upgrade-checks).
7. **Take a fresh backup** so the newest restore point matches the new version.


## Post-upgrade checks

- `https://<DOMAIN>/api` returns 200, and `https://<DOMAIN>/api/configuration` shows the expected instance name, licence and summary.
- Logging in through the website works (this is the full OIDC round trip through Keycloak), and the Keycloak admin console opens at `https://<DOMAIN>/oauth/admin`.
- Open an existing picture, both a flat one and a 360° one. The SD image, thumbnail and 360° tiles load. In the browser's network tab, they come straight from the `S3_DERIVATIVES_PUBLIC_URL` host, not from `/api/pictures/...`. If they come through `/api`, the direct-S3 setting isn't reaching the API.
- Upload a picture. It gets blurred and processed, and its derivatives appear under the derivatives prefix and are publicly readable.
- The `background-worker-*` logs show no repeated errors.
- `backup-now.sh` completes, and after the next scheduled run the `backup` container reports healthy.


## 2.15.x → 2.17.0

Upstream changes: [2.16.0, 2.16.1 and 2.17.0 in the Panoramax changelog](https://gitlab.com/panoramax/server/api/-/blob/main/CHANGELOG.md). Upstream recommends going through each minor version on large instances, because the 2.17.0 migrations can take a while. Jumping straight from 2.15 to 2.17 works, but may mean a longer migration window while the application is stopped.

**Coolify environment variables:**

- **Rename the two derivatives variables, keeping their values exactly as they are.** Create `FS_DERIVATIVES_URL` with the same value as `FS_DERIVATES_URL`, and `S3_DERIVATIVES_PUBLIC_URL` with the same value as `S3_DERIVATES_PUBLIC_URL`. Then delete the two old variables. The deploy fails with a "required variable" error until both new ones are set.
  - Keep the `derivates` prefix inside the values. The bucket path is whatever these variables say, so nothing in object storage has to move. Upstream's new `derivatives/` default only applies to single-`FS_URL` installs, which this repo doesn't use. To rename the prefix anyway, see [Optional: rename the derivatives prefix](#optional-rename-the-derivatives-prefix) below.
- Set `GEOVISIO_IMAGE_TAG=2.17.0`.
- Nothing else needs to change in Coolify. The Keycloak bootstrap admin variables changed name, but only inside `docker-compose.yml`; they still read `KEYCLOAK_ADMIN` and the same generated password. They only take effect on a brand-new database anyway.

**Keycloak 26.6.0 → 26.7.2.** `keycloak-import` applies Keycloak's schema migrations on the first start; its log ends with `Realm 'geovisio' already exists. Import skipped`, and `auth` starts after it. Nothing to do. Before this release, `keycloak-import` couldn't migrate the schema, so any Keycloak version bump left it failing with `Database not up-to-date, please enable database migration` and `auth` never started. If you see that error, the deployed compose file is older than this release.

**PostGIS 16-3.4 → 16-3.7.** Same PostgreSQL major version (16.4 → 16.15), so the existing data directory is used as-is. Two one-time steps after the deploy:

1. **Rebuild text indexes for the new collation library.** The new image is built on a newer Debian, so the C library that defines text sort order changed (glibc 2.31 → 2.41). Postgres warns about it on every connection: `database "geovisio" has a collation version mismatch`. Indexes on text columns that were built with the old ordering can return wrong results until rebuilt. The loop below rebuilds every affected database's indexes, then records the new version, which silences the warning. It skips databases that are already up to date, so it is safe to re-run. It locks each table while it rebuilds, so run it straight after the deploy, before users are back. On a small instance it takes seconds.

   ```bash
   docker exec <db_container_name> sh -c '
   for db in $(psql -U gvs -d postgres -tAc "select datname from pg_database where datallowconn and datcollversion is distinct from pg_database_collation_actual_version(oid)"); do
     echo "== $db"
     psql -U gvs -d "$db" -v ON_ERROR_STOP=1 -c "REINDEX DATABASE \"$db\";" -c "ALTER DATABASE \"$db\" REFRESH COLLATION VERSION;"
   done'
   ```

2. **Update the PostGIS extension** inside the database. The new library is installed, but the database keeps the old extension version until told to upgrade:

   ```bash
   docker exec <db_container_name> psql -U gvs -d geovisio -c "SELECT postgis_extensions_upgrade();"
   ```

**Check the Keycloak master admin account exists.** Earlier versions of this repo never created one on a fresh deploy, for two reasons. First, from 17 July 2026 the bootstrap admin was passed to Keycloak under names it doesn't recognise. Second, Keycloak only creates that admin while initialising the master realm, and since the realm import moved into `keycloak-import`, that initialisation happens there, where the variables weren't set. So an instance first deployed with those versions most likely has no master-realm admin user. This release fixes both, but only for new databases. Check with the credential-login line from [`deployment_instructions.md` §6.1](./deployment_instructions.md#61-keycloak-realm-hardening):

```bash
docker exec -it <auth_container_name> sh -c '
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/oauth --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"'
```

If it reports invalid credentials, either the account doesn't exist or its password has since been changed in Keycloak. To create a temporary admin, use Keycloak's [admin recovery command](https://www.keycloak.org/server/bootstrap-admin-recovery). Keycloak requires every server node to be stopped while it runs, so stop `auth` and run the command from the `keycloak-export` container, which uses the same image and database settings. It prompts for a username (default `temp-admin`) and a password:

```bash
docker stop <auth_container_name>
docker exec -it <keycloak_export_container_name> /opt/keycloak/bin/kc.sh bootstrap-admin user --optimized
docker start <auth_container_name>
```

Log in to the admin console with that temporary account, create a permanent admin, and then delete the temporary one.

**Backups are unaffected.** Derivatives are never backed up. The database dumps, the picture mirror and `secrets.env` don't depend on the derivatives prefix name. Snapshots taken before the upgrade restore normally; restoring one just means entering the renamed variables in Coolify.


### Optional: rename the derivatives prefix

Purely cosmetic: the instance works indefinitely with a `derivates` prefix. To switch, copy the cache to the new prefix with the one-off script in the `backup` container. It reads the current location from `FS_DERIVATIVES_URL` and copies within the same bucket. It never deletes anything, and it doesn't touch the running instance.

```bash
# Dry run: shows source, destination and object counts; copies nothing.
docker exec -it <backup_container_name> migrate-derivatives-prefix.sh derivatives

# Copy (server-side, safe to interrupt and re-run), then verify every object arrived.
docker exec -it <backup_container_name> migrate-derivatives-prefix.sh --apply derivatives
```

Then follow the steps it prints:

1. Check that a copied file is publicly readable through the public URL. If it isn't, run `fix-object-acls.sh` on the new prefix; see [`backup_and_restore_instructions.md`](./backup_and_restore_instructions.md).
2. Change the prefix in both `FS_DERIVATIVES_URL` and `S3_DERIVATIVES_PUBLIC_URL`, and redeploy.
3. Run the picture checks above.
4. Only then delete the old prefix by hand.

The script can run before or after the upgrade. New derivatives generated between the copy and the variable switch land in the old prefix and would be missed, so run it with the application stopped, or simply re-run `--apply` right before switching. Each re-run copies only what's new.
