# Защита админ-панелей (SeaweedFS S3-консоль / filer / master)

Имя файла историческое (`minio`): в этом стенде роль S3 играет **SeaweedFS**.
Документ описывает, как закрыть административные интерфейсы объектного
хранилища паролем (NPM **Access List**) и/или списком IP, если их нужно открыть
не только через SSH-туннель.

## 1. Что вообще торчит наружу

| Интерфейс | Порт | В compose | Публикация |
|---|---|---|---|
| SeaweedFS master (cluster status) | 9333 | `s3` | `127.0.0.1:9333` — только loopback |
| SeaweedFS filer UI (файловый менеджер) | 8888 | `s3` | `127.0.0.1:${SEAWEEDFS_FILER_PORT:-8888}` — только loopback |
| SeaweedFS volume server | 8080 (внутри контейнера!) | `s3` | не публикуется |
| SeaweedFS S3 API | 8333 | `s3` | не публикуется (только сеть `backend`) |
| NPM GUI | 81 → `127.0.0.1:8181` | `proxy` | только loopback |

**По умолчанию ни одна админ-панель в интернет не выходит** — доступ через
SSH-туннель:

```bash
ssh -L 8888:127.0.0.1:8888 -L 9333:127.0.0.1:9333 -L 8181:127.0.0.1:8181 root@server
# filer UI:      http://127.0.0.1:8888/
# master status: http://127.0.0.1:9333/cluster/status
# NPM GUI:       http://127.0.0.1:8181/
```

Это рекомендуемый режим: ничего настраивать в NPM не нужно.

## 2. Когда нужен Access List

Если по регламенту админ-панель должна открываться из браузера без SSH
(например, для дежурной смены), публикуйте её **только** через NPM с
HTTPS + Access List. Прямую публикацию портов (`ports:` в compose) не
используйте: SeaweedFS filer не имеет собственной аутентификации.

Подготовка:

1. Заведите DNS-имя, например `admin.example.com` (A-запись на этот сервер).
2. Убедитесь, что порты 80/443 уже заняты NPM (они заняты сервисом `proxy`).
3. В `.env` ничего менять не нужно; имя админки в контракт не входит.

## 3. Создание Access List (GUI)

*Access Lists → Add Access List.*

### Вкладка Details

| Поле | Значение |
|---|---|
| Name | `admins-only` |
| Satisfy Any | **выключено** (нужно выполнить И пароль, И IP-правило, если IP заданы) |
| Pass Auth to Upstream | **выключено** (NPM отправит `proxy_set_header Authorization ""` — логин/пароль basic-auth не утечёт в SeaweedFS) |

### Вкладка Authorization

*Add User*:

| Поле | Значение |
|---|---|
| Username | `admin` (или ваша учётка) |
| Password | длинный пароль из менеджера секретов (**не** `NPM_ADMIN_PASSWORD`) |

NPM хранит файл `/data/access/<id>` и подключает его как
`auth_basic_user_file`; пароль хранится в bcrypt-хеше.

### Вкладка Access (необязательно, но рекомендуется)

*Add Rule* → `allow`, значение — офисная подсеть или статический IP
(например `203.0.113.0/24`). В конце NPM автоматически добавляет `deny all;`.
Если заданы и пользователи, и IP-правила, при выключенном *Satisfy Any*
действуют оба условия.

## 4. Proxy Host для админки filer

*Hosts → Proxy Hosts → Add Proxy Host.*

| Поле | Значение |
|---|---|
| Domain Names | `admin.example.com` |
| Scheme | `http` |
| Forward Hostname / IP | `s3` |
| Forward Port | `8888` |
| Block Common Exploits | включено |
| Websockets Support | включено (filer UI использует websocket для live-обновлений) |
| **Access List** | `admins-only` |

*SSL*: Let's Encrypt, **Force SSL** включить, **HTTP/2**, **HSTS** — включить.
Пароль поверх HTTP без шифрования передавать нельзя, поэтому Force SSL
обязателен.

*Advanced*: достаточно

```nginx
client_max_body_size 100m;
proxy_read_timeout 300s;
proxy_send_timeout 300s;
```

Для master (только `/cluster/status`) сделайте отдельный хост с
`Forward Port 9333`, если он действительно нужен снаружи.

## 5. Проверка

```bash
# без учётных данных — 401
curl -s -o /dev/null -w '%{http_code}\n' https://admin.example.com/
# с учётными данными — 200
curl -s -o /dev/null -w '%{http_code}\n' -u admin:'<пароль>' https://admin.example.com/
# http должен редиректить на https
curl -sI http://admin.example.com/ | head -n 3
# HSTS присутствует ровно один раз
curl -sI https://admin.example.com/ -u admin:'<пароль>' | grep -ci strict-transport-security
```

## 6. Что не делать

* не публиковать `8888`/`9333` через `ports:` в `docker-compose.yml` —
  это обходит NPM и весь контроль доступа;
* не включать на админке *Cache Assets*;
* не переиспользовать пароль администратора NPM;
* не оставлять `Access List` пустым у прокси-хоста, если он смотрит в интернет.

## 7. Опциональный «админский» compose

В репозитории есть `docker-compose.admin.yml` (профиль для временного
раскрытия админ-портов на loopback/для отладки). Он не нужен для штатной
работы: штатный доступ — SSH-туннель из раздела 1.
