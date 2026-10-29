# Nginx Proxy Manager — wiring notes / заметки по подключению

> EDGE tier artifact. Everything here is applied **in the NPM GUI** (no NPM
> container files are edited). Step-by-step walkthrough: [npm-gui-setup.md](npm-gui-setup.md).
> Protecting admin UIs: [access-list-minio.md](access-list-minio.md).
>
> Все настройки вносятся **в веб-интерфейсе NPM** (файлы контейнера NPM не
> правятся). Пошаговая инструкция: [npm-gui-setup.md](npm-gui-setup.md).
> Защита админ-панелей: [access-list-minio.md](access-list-minio.md).

## 1. Host → upstream map

| Public host (from `.env`) | NPM proxy host → upstream | Scheme | Websockets | Purpose |
|---|---|---|---|---|
| `${CLOUD_DOMAIN}` (e.g. `cloud.example.com`) | `web:8080` | http | ON | Nextcloud UI, WebDAV, public share links |
| `${OFFICE_DOMAIN}` (e.g. `office.example.com`) | `onlyoffice:80` | http | ON | ONLYOFFICE Docs 8.3.3 editor + co-editing |
| — | *not proxied* | — | — | SeaweedFS filer/master/S3 console: loopback only |

`proxy` is pinned to `172.28.10.10` on the `edge` network. `web`,
`app`, `cron` and `onlyoffice` have
`extra_hosts: "${CLOUD_DOMAIN}:172.28.10.10"` so server-side callbacks
(ONLYOFFICE → Nextcloud, Nextcloud → ONLYOFFICE) never leave the host or depend
on the public DNS/Hairpin-NAT.

**Where each setting lives / где что настраивается**

| Setting | NPM tab | Value |
|---|---|---|
| Domain names, forward host/port, **Websockets Support**, Block Common Exploits | Details | see table above |
| SSL certificate (Let's Encrypt HTTP-01), **Force SSL**, **HTTP/2**, **HSTS** (+ Subdomains), Access List | SSL | cert for each host, Force SSL ON, HSTS ON |
| `client_max_body_size`, timeouts, buffering | Advanced | [nextcloud-advanced.conf](nextcloud-advanced.conf), [onlyoffice-advanced.conf](onlyoffice-advanced.conf) |
| IP allow-list / basic auth for admin UIs | Access Lists | [access-list-minio.md](access-list-minio.md) |

**What NPM already emits** (NPM 2.16.0, so it must not be duplicated):

* http level: `client_max_body_size 2000m`, `proxy_*_timeout 90s`,
  `proxy_http_version 1.1`, `server_tokens off`, `gzip on`;
* `location /`: `Host $host`, `X-Forwarded-Scheme $scheme`,
  `X-Forwarded-Proto $scheme`, `X-Forwarded-For $proxy_add_x_forwarded_for`,
  `X-Real-IP $remote_addr`;
* SSL tab: `add_header Strict-Transport-Security $hsts_header always`
  (max-age 63072000, optional `includeSubDomains`, optional `preload`) and the
  301 Force-SSL redirect.

Consequence / следствие: **HSTS is added by NPM only** — the `web` tier
deliberately does not send it (see `config/nginx/snippets/security-headers.conf`),
otherwise every response would carry two `Strict-Transport-Security` headers.

## 2. Why the Advanced tab cannot contain `proxy_set_header`

NPM renders the Advanced text at **server level**, while its own
`location /` includes `conf.d/include/proxy.conf`, which already contains
`proxy_set_header` directives. In nginx, a directive is inherited from the
previous level **only if** the current level defines none — so any
`proxy_set_header` written in Advanced is silently ignored by `location /`.

Therefore:

* websocket upgrades are switched on with the Details toggle
  **Websockets Support** (NPM then emits `Upgrade`/`Connection` both at server
  level and inside `location /`);
* extra headers are only needed if you replace `location /` with a
  **Custom Location** — ready-to-paste blocks are at the bottom of both
  `*-advanced.conf` files.

## 3. Request flow / путь запроса

```
client --443/TLS--> proxy (NPM, 172.28.10.10)
                      |  Host: cloud.example.com, X-Forwarded-Proto: https,
                      |  X-Forwarded-For: <client ip>
                      v
                    web:8080 (nginx front controller, no TLS)
                      |  realip -> $remote_addr = client ip
                      |  security headers, deny /data /config /lib /db_storage, dotfiles
                      |  static /core /apps /dist /build -> immutable cache
                      v
                    app:9000 (php-fpm, Nextcloud 35)  --S3--> s3:8333 (SeaweedFS)
```

```
browser --443/TLS--> proxy (NPM) --http--> onlyoffice:80 (Docs 8.3.3, JWT)
   ^                                          |
   |  editor iframe + websocket (/doc/)        |  server-side: download document
   |                                           v  https://${CLOUD_DOMAIN} (172.28.10.10)
   +---------------------------------- Nextcloud /remote.php/dav + WOPI callbacks
```

ONLYOFFICE resolves `cloud.example.com` (i.e. `${CLOUD_DOMAIN}`) to the **private** NPM address via
`extra_hosts`, so the DS server must be allowed to call private IPs
(`request-filtering-agent.allowPrivateIPAddress: true` in
`config/onlyoffice/local.json`, or `ALLOW_PRIVATE_IP_ADDRESS=true` on the
`onlyoffice` service). Without it, the editor opens but the document never
loads (`download error` in `/var/log/onlyoffice`).

## 4. Health & troubleshooting

| Check | Command |
|---|---|
| NPM API up | `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8181/api/` (200/401 = alive) |
| Generated NPM config is valid | `docker compose exec proxy nginx -t` |
| Which config was generated | `docker compose exec proxy cat /data/nginx/proxy_host/1.conf` |
| TLS certificate | `docker compose exec proxy sh -c 'ls -l /etc/letsencrypt/live'` |
| Web tier (behind NPM) | `docker compose exec web wget -qO- http://127.0.0.1:8080/healthz`, `.../status` |
| Editor reachability | `curl -fsS https://office.example.com/healthcheck` |

Typical symptoms:

* **413 Request Entity Too Large** on upload → `client_max_body_size` in
  `nextcloud-advanced.conf` (and `PHP_UPLOAD_LIMIT`) too small;
* **editor opens, document does not load** → DS cannot reach
  `https://cloud.example.com`: check `extra_hosts`, JWT secret equality
  (`ONLYOFFICE_JWT_SECRET` must be the same in `.env`, the `onlyoffice`
  service and the Nextcloud ONLYOFFICE connector), and private-IP permission;
* **502 Bad Gateway from NPM** → `web` or `onlyoffice` container is not
  running/healthy (`docker compose ps`);
* **redirects to `:8080`** → the `web` tier must keep
  `absolute_redirect off` (already set in `config/nginx/conf.d/10-nextcloud.conf`).
