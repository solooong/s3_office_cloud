# Staging drill - acceptance run before production

This is the manual sequence used to prove a release on a staging VM with the
same shape as production: one Linux VM, docker compose, real DNS records for
two hostnames (cloud.example.com, office.example.com).

Run it top to bottom on a **fresh** clone with fresh volumes. Every step lists
the command, what you should see, and the evidence to attach to the release
ticket.

> Everything below runs from the repository root as a user in the `docker` group.
> `sudo` is only needed for `make doctor` (sysctl checks) and for installing logrotate.

---

## 0. Host and repository

| Step | Command | Expected |
|---|---|---|
| Clone | `git clone <repo> /opt/cloudsuite && cd /opt/cloudsuite` | clean checkout |
| Host check | `make doctor` | no FAIL lines; WARN lines explained |
| Secrets | `./scripts/generate-secrets.sh` | 8 secrets written, `.env` is `-rw-------` |
| Bootstrap | `make bootstrap` | directories created, compose renders, preflight OK |

Evidence: `make doctor 2>&1 | tee /tmp/drill-01-doctor.log`.

---

## 1. Start the stack

```bash
make up
make status
make logs SERVICE=proxy      # Ctrl-C once the TLS certificates are issued
```

Expected: proxy, web, app, cron, db, cache, s3, s3-init and onlyoffice are
running/healthy; `make status` prints `occ status: installed=true`.

---

## 2. Provision and apply policy

```bash
make configure
make rbac
```

Expected:

* SMTP, memcache (APCu + Redis), link policy and password policy applied;
* the five groups from `config/rbac/roles.yaml` exist with their display names;
* `occ config:app:get cloudsuite rbac_roles` returns the policy JSON.

---

## 3. Routing (Nginx Proxy Manager)

Start the stack with the admin overlay (it publishes the NPM GUI, the
SeaweedFS filer UI and the S3 master on loopback):

```bash
make admin-up      # docker-compose.yml + docker-compose.admin.yml
```

Open the NPM admin UI through an SSH tunnel
(`ssh -L 8181:127.0.0.1:8181 <host>`, then `http://127.0.0.1:8181`) and create:

| Field | CLOUD_DOMAIN | OFFICE_DOMAIN |
|---|---|---|
| Forward hostname | web | onlyoffice |
| Forward port | 8080 | 80 |
| Websockets | on | on |
| TLS | Let's Encrypt + Force SSL + HSTS | same |
| Advanced | `client_max_body_size <PHP_UPLOAD_LIMIT>;` | `proxy_read_timeout 3600s;` |

Copy-paste templates live in `config/nginx/templates/cloudsuite/`.

---

## 4. End-to-end smoke

```bash
make smoke
```

Expected: `smoke test PASSED` with checks for WebDAV PUT/PROPFIND/GET,
public link download, file versions, trashbin, ONLYOFFICE health and audit-log
growth.

Then open a document in the web UI and confirm co-editing loads from
OFFICE_DOMAIN: no mixed content in the browser console, no JWT errors in
`make logs SERVICE=onlyoffice`.

---

## 5. Backup and restore rehearsal (the important part)

```bash
make backup
ls -la backups/LATEST
(cd backups/LATEST && sha256sum -c manifest.sha256)

# destroy and rebuild from the backup
make nuke FORCE=yes
make up
make restore ARGS="--dir backups/LATEST --confirm --yes"
```

Expected:

* the backup contains db.dump, redis.rdb, vol-*.tar.gz, config.tar.gz.enc,
  meta.env and manifest.sha256;
* every manifest line is OK;
* the restore prints the RPO/RTO report and ends with `restore completed successfully`;
* `make smoke` passes again after the restore;
* a file uploaded before the backup is still downloadable afterwards.

Record the RPO and RTO from the report in the release ticket.

---

## 6. Update drill

```bash
make update ARGS="--yes"
```

Expected: backup taken, images pulled, containers recreated, `occ upgrade` reports
`Everything up to date`, the health check passes, and the rollback block is
printed with the `logs/update-<timestamp>/images.before.txt` path.

---

## 7. Migration rehearsal

Prepare an rclone `yandex` remote with a small test account (a few nested
folders, Cyrillic filenames, one ~100 MB file):

```bash
make migrate ARGS="--source yandex:disk --user testuser --dry-run"
make migrate ARGS="--source yandex:disk --user testuser --target-dir YandexDisk"
```

Expected: rclone check reports 0 differences (size mode), `occ files:scan` completes
and the files are visible in the web UI with correct timestamps.

---

## 8. Retention and log rotation

```bash
make prune-versions-dry-run    # inspect the JSON summary
make prune-versions            # apply
make audit-report ARGS="--from 2026-01-01 --action file_download"
sudo install -m 644 config/logrotate/cloudsuite /etc/logrotate.d/cloudsuite
sudo logrotate --debug /etc/logrotate.d/cloudsuite
```

Expected: the pruner deletes only versions above VERSIONS_MAX; the audit report
shows the smoke-test downloads; logrotate lists both stanzas (logs/nginx and
logs/cloudsuite) without errors. ONLYOFFICE and NPM rotate their own logs
inside their named volumes, so there is no host stanza for them.

---

## 9. Acceptance checklist

Walk `docs/12-acceptance-checklist.md` and mark every item. Attach:

1. `/tmp/drill-01-doctor.log`
2. `make status`, `make smoke` and `make healthcheck` output,
3. `backups/LATEST/meta.env` (contains no secrets) and the restore report,
4. the update rollback block,
5. the audit report for the drill user.

A release is approved only when all five are attached and the checklist is
green.

