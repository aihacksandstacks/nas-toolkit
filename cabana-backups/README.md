# Cabana Supabase Backups

Nightly logical backup of the Cabana Staff Platform's Supabase databases (prod +
sandbox), running on the NAS (Black-Betty). This directory is the version-tracked
source of truth for a system that otherwise only lives on the NAS at
`/opt/cabana-backups/scripts/` (originally installed 2026-05-21).

## What it does

- Runs `pg_dump` against both Supabase environments every night:
  - **prod** — project `nbhezncrdwqzzxmsmchr`
  - **sandbox** — project `omjieoavpotzknntmxex`
- Dumps in Postgres **custom format** (`--format=custom --compress=6 --no-owner
  --no-acl`), which is compressed and supports parallel `pg_restore`.
- Streams each dump to **NVMe staging** (`/volume2/cabana-backups-staging/tmp`),
  then atomically moves the finished file to the **RAID5 spinners** at
  `/opt/cabana-backups/<env>/YYYY-MM-DD.dump`
  (`/opt/cabana-backups` is a symlink to `/volume1/cabana-backups`).
- Keeps the **most recent 14 dumps per env** (`RETENTION_DAYS=14`); older ones
  are pruned.
- Rewrites `/opt/cabana-backups/status.json` after every run with per-env
  `status` / `finished_at` / `duration_sec` / `size_bytes` / `path` / `error`
  plus an `overall` (`ok` | `degraded`) rollup for monitoring.

Connections use Supabase's **session pooler on port 5432** (not the app's
transaction pooler on 6543), because `pg_dump` needs a session-mode connection.

## Schedule

Installed as a **root cron** entry on the NAS:

```
# cabana-supabase-nightly
30 4 * * * /opt/cabana-backups/scripts/backup-supabase.sh ALL >> /opt/cabana-backups/logs/cron.log 2>&1
```

**04:30 UTC daily** (00:30 America/New_York during EDT).

## The 2026-06-29 fix (docker pg_dump)

The original script called the **host** `pg_dump` on the NAS. The NAS ships
`pg_dump 15.14`, but Supabase's managed Postgres server is now **17.6**, and
`pg_dump` refuses to dump from a server newer than itself:

```
pg_dump: error: server version: 17.6; pg_dump version: 15.14
pg_dump: error: aborting because of server version mismatch
```

Fix: instead of the host binary, the dump now runs inside the **`postgres:latest`
Docker image**, which carries a current-enough `pg_dump`:

```bash
docker run --rm -e PGPASSWORD="…" -v "${tmp_dir}:${tmp_dir}" postgres:latest pg_dump …
```

The NVMe staging dir is bind-mounted into the container so the dump lands on the
host. (Docker already runs on the NAS for the Cabana app containers, so there is
no new dependency.) This one-line-in-spirit change is the reason this system is
now captured in version control — the fix previously existed only on the NAS.

## Restore

Dumps are custom-format, so restore with `pg_restore` (not `psql`):

```bash
# List / inspect contents without restoring
pg_restore --list /opt/cabana-backups/prod/2026-06-29.dump

# Restore into a target database (session pooler, port 5432)
pg_restore \
  --dbname="postgresql://<user>@<pooler-host>:5432/postgres?sslmode=require" \
  --no-owner --no-acl --clean --if-exists \
  /opt/cabana-backups/prod/2026-06-29.dump
```

Run it from the same `postgres:latest` container if the NAS host `pg_restore`
is older than the target server, mirroring the dump path.

## Known caveat (as of 2026-06-30)

**Sandbox currently fails; prod works.** The sandbox dump errors out on a **stale
database password** stored in `/opt/cabana-sandbox/.env` — the value the script
resolves at runtime no longer matches Supabase. `status.json` will show
`overall: "degraded"` with the sandbox env in `error` while prod stays `ok`.

Fix path: update the DB password in `/opt/cabana-sandbox/.env` on the NAS to the
current sandbox credential, then re-run
`/opt/cabana-backups/scripts/backup-supabase.sh SANDBOX` and confirm
`status.json` flips sandbox back to `ok`. (No change to these scripts is
required — they read the password from the app env at runtime.)

## Configuration (paths & env it needs)

No secrets live in this repo. At runtime on the NAS the scripts rely on:

**Config file** `/opt/cabana-backups/.env` (seeded by `install-on-nas.sh`, holds
paths + pooler hosts only — no passwords):

| Variable | Purpose |
|----------|---------|
| `SOURCE_PROD_ENV` | Path to prod app env (`/opt/cabana-prod/.env`) — password read at runtime |
| `SOURCE_SANDBOX_ENV` | Path to sandbox app env (`/opt/cabana-sandbox/.env`) — password read at runtime |
| `POOLER_PROD` | Supabase session-pooler host for prod |
| `POOLER_SANDBOX` | Supabase session-pooler host for sandbox |
| `RETENTION_DAYS` | Daily dumps kept per env (default 14) |

**Credentials are never stored by this system.** The DB password is resolved at
runtime from the app env files:
- **prod** — parsed out of the `SUPABASE_DATABASE_URL` connection string.
- **sandbox** — read from `SUPABASE_DB_PASSWORD`.

It is passed to `pg_dump` via `PGPASSWORD` for the duration of the run and never
written elsewhere.

**Filesystem layout on the NAS:**

| Path | Role |
|------|------|
| `/opt/cabana-backups` | Symlink → `/volume1/cabana-backups` (RAID5 spinners) |
| `/opt/cabana-backups/<env>/` | Finished dumps (`prod/`, `sandbox/`) |
| `/opt/cabana-backups/logs/` | Per-env + cron logs |
| `/opt/cabana-backups/status.json` | Latest run state (monitoring) |
| `/opt/cabana-backups/scripts/` | Deployed copy of `backup-supabase.sh` |
| `/opt/cabana-backups/.env` | Config (paths + pooler hosts, no secrets) |
| `/volume2/cabana-backups-staging/tmp` | NVMe staging scratch |

Requires: Docker (for `postgres:latest`), Python 3 (JSON escaping in
`status.json`), and root on the NAS to write to `/opt` and install the cron.

## Files

| File | What it is |
|------|------------|
| `backup-supabase.sh` | The nightly backup script (current, docker-`pg_dump` version). |
| `install-on-nas.sh` | Idempotent bootstrapper: creates dirs, seeds config, installs the cron, copies the script into place. Run as root on the NAS. |

## Deploying an update to the NAS

These scripts must be reads-only copied to the NAS out-of-band (a hook blocks
`scp` **to** the NAS from the dev machine). Once the files are on the NAS, run:

```bash
sudo /path/to/install-on-nas.sh
```

It is safe to re-run — it only refreshes the deployed script and perms, and
leaves an existing `/opt/cabana-backups/.env` and cron entry untouched.
