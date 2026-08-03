# Развёртывание React frontend N1 с нуля

## 1. Область документа

Этот документ описывает подготовку production checkout и production build React frontend N1 на Debian 13.

После выполнения:

- репозиторий находится в `/srv/n1/front`;
- сборка выполняется от пользователя `n1`;
- production-переменная `VITE_API_BASE_URL` хранится в `/srv/n1/front/.env`;
- зависимости устанавливаются строго по `package-lock.json`;
- выполняются lint и Vite production build;
- статические файлы находятся в `/srv/n1/front/dist`;
- файлы имеют права, позволяющие Nginx читать их;
- обновления доставляются через `git pull`, `npm ci` и `npm run build`.

Важно: на момент составления документа Nginx-конфигурация для публикации frontend ещё не была выполнена. Этот гайд заканчивается готовым production build в `/srv/n1/front/dist`. Чтобы сайт стал доступен по домену, необходимо отдельно настроить Nginx, DNS и TLS.

Используемые значения:

| Параметр | Значение |
|---|---|
| ОС | Debian 13 |
| Пользователь приложения | `n1` |
| Каталог проекта | `/srv/n1/front` |
| Репозиторий | `git@github.com:Oleg4cy/n1-pub-front.git` |
| Node.js | `22.22.3` |
| Package manager | npm |
| Production API URL | `https://virtual-privat-n1.ru` |
| Результат сборки | `/srv/n1/front/dist` |

Все административные команды выполняются от `root`. Команды npm и Git выполняются от пользователя `n1`.

---

## 2. Подключение и проверка сервера

Подключиться:

```bash
ssh root@SERVER_IP
```

Проверить ОС и ресурсы:

```bash
cat /etc/os-release
uname -m
nproc
free -h
df -hT
```

- `cat /etc/os-release` показывает версию Debian.
- `uname -m` показывает архитектуру.
- `nproc` показывает CPU.
- `free -h` показывает RAM и swap.
- `df -hT` показывает место и типы файловых систем.

---

## 3. Установка системных пакетов

Обновить индекс:

```bash
apt-get update
```

Установить инструменты:

```bash
DEBIAN_FRONTEND=noninteractive apt-get install \
    --yes \
    --no-install-recommends \
    ca-certificates \
    curl \
    git \
    openssh-client \
    xz-utils
```

- `--yes` подтверждает установку.
- `--no-install-recommends` исключает необязательные пакеты.
- `curl` нужен для Node.js.
- `git` и `openssh-client` нужны для GitHub.
- `xz-utils` нужен для архива Node.js.

---

## 4. Создание пользователя `n1`

Проверить:

```bash
id n1
```

Создать при отсутствии:

```bash
adduser \
    --disabled-password \
    --gecos "" \
    n1
```

- `--disabled-password` запрещает парольный вход.
- `--gecos ""` отключает дополнительные вопросы.

Проверить:

```bash
id n1
getent passwd n1
```

---

## 5. Создание каталога приложения

```bash
install \
    -d \
    -m 0755 \
    -o root \
    -g root \
    /srv/n1
```

- `install -d` создаёт каталог.
- `0755` позволяет сервисам проходить по каталогу.
- Репозиторий после клонирования будет принадлежать `n1`.

---

## 6. Установка Node.js 22.22.3

Задать переменные для x86_64:

```bash
NODE_VERSION="22.22.3"
NODE_ARCH="x64"
NODE_ARCHIVE="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}"
NODE_DIR="/opt/node-v${NODE_VERSION}-linux-${NODE_ARCH}"
```

Для ARM64 заменить `NODE_ARCH="x64"` на `NODE_ARCH="arm64"`.

Создать временный каталог:

```bash
NODE_TMP="$(mktemp -d /tmp/n1-node-install.XXXXXX)"
```

Загрузить checksum и архив:

```bash
curl \
    --fail \
    --location \
    --silent \
    --show-error \
    "${NODE_URL}/SHASUMS256.txt" \
    --output "${NODE_TMP}/SHASUMS256.txt"

curl \
    --fail \
    --location \
    --silent \
    --show-error \
    "${NODE_URL}/${NODE_ARCHIVE}" \
    --output "${NODE_TMP}/${NODE_ARCHIVE}"
```

- `--fail` считает HTTP 4xx/5xx ошибкой.
- `--location` следует redirect.
- `--silent --show-error` скрывает progress bar, но сохраняет ошибки.
- `--output` задаёт файл назначения.

Получить checksum нужного архива:

```bash
grep -E "  ${NODE_ARCHIVE}$" \
    "${NODE_TMP}/SHASUMS256.txt" \
    > "${NODE_TMP}/CHECKSUM"
```

Проверить:

```bash
(
    cd "${NODE_TMP}"
    sha256sum --check CHECKSUM
)
```

Распаковать:

```bash
tar \
    -xJf "${NODE_TMP}/${NODE_ARCHIVE}" \
    -C /opt
```

- `-x` распаковывает.
- `-J` включает XZ.
- `-f` задаёт архив.
- `-C /opt` задаёт каталог назначения.

Назначить владельца:

```bash
chown -R root:root "${NODE_DIR}"
```

Создать ссылки:

```bash
ln -sfn "${NODE_DIR}/bin/node" /usr/local/bin/node
ln -sfn "${NODE_DIR}/bin/npm" /usr/local/bin/npm
ln -sfn "${NODE_DIR}/bin/npx" /usr/local/bin/npx
ln -sfn "${NODE_DIR}/bin/corepack" /usr/local/bin/corepack
```

Удалить временный каталог:

```bash
rm -rf "${NODE_TMP}"
```

Проверить:

```bash
node --version
npm --version
```

Ожидаемый Node.js: `v22.22.3`.

---

## 7. SSH-доступ пользователя `n1` к GitHub

Создать `.ssh`:

```bash
install \
    -d \
    -m 0700 \
    -o n1 \
    -g n1 \
    /home/n1/.ssh
```

Создать ключ:

```bash
runuser \
    -u n1 \
    -- \
    ssh-keygen \
    -t ed25519 \
    -C "n1@fr1" \
    -f /home/n1/.ssh/id_ed25519 \
    -N ""
```

Показать публичный ключ:

```bash
cat /home/n1/.ssh/id_ed25519.pub
```

Добавить его в GitHub.

Записать host key:

```bash
runuser \
    -u n1 \
    -- \
    ssh-keyscan \
    -H github.com \
    >> /home/n1/.ssh/known_hosts
```

Исправить права:

```bash
chown n1:n1 /home/n1/.ssh/known_hosts
chmod 0600 /home/n1/.ssh/known_hosts
```

Проверить:

```bash
runuser \
    -u n1 \
    -- \
    ssh \
    -T \
    git@github.com
```

---

## 8. Клонирование frontend

```bash
runuser \
    -u n1 \
    -- \
    git \
    clone \
    git@github.com:Oleg4cy/n1-pub-front.git \
    /srv/n1/front
```

Не добавлять `--single-branch`, чтобы checkout видел remote-ветки.

Проверить remote:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/front \
    remote \
    -v
```

Получить ветки:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/front \
    fetch \
    --prune \
    origin
```

Показать ветки:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/front \
    branch \
    --all
```

Если локальной `dev` нет:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/front \
    switch \
    --create dev \
    --track origin/dev
```

Если она есть:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/front \
    switch dev
```

Выбор ветки выполняется вручную.

Проверить:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/front \
    status \
    --short \
    --branch
```

---

## 9. Проверка структуры проекта

```bash
stat \
    /srv/n1/front/package.json \
    /srv/n1/front/package-lock.json \
    /srv/n1/front/vite.config.js \
    /srv/n1/front/src/main.jsx
```

Проверить scripts:

```bash
node \
    -e "const p=require('/srv/n1/front/package.json'); console.log(p.scripts)"
```

- `node -e` выполняет JavaScript из аргумента.
- `require` читает `package.json`.

Для текущего проекта нужны scripts `lint` и `build`.

---

## 10. Production `.env`

Добавить `.env` в локальный exclude:

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'grep -qxF "/.env" /srv/n1/front/.git/info/exclude || printf "\n# N1 production-local files\n/.env\n" >> /srv/n1/front/.git/info/exclude'
```

- `.git/info/exclude` действует только на сервере.
- Tracked `.gitignore` не изменяется.

Создать `.env`:

```bash
install \
    -m 0640 \
    -o n1 \
    -g n1 \
    /dev/null \
    /srv/n1/front/.env
```

Записать API URL:

```bash
printf '%s\n' \
    'VITE_API_BASE_URL=https://virtual-privat-n1.ru' \
    > /srv/n1/front/.env
```

Поскольку redirect выполнялся от `root`, повторно назначить владельца:

```bash
chown n1:n1 /srv/n1/front/.env
chmod 0640 /srv/n1/front/.env
```

Проверить:

```bash
grep -E '^VITE_API_BASE_URL=' /srv/n1/front/.env

runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/front \
    check-ignore \
    -v \
    .env
```

Важно: frontend `.env` не должен содержать секреты. Любые `VITE_*` значения могут попасть в bundle браузера.

Vite подставляет переменные во время сборки. После изменения `.env` нужно повторно запускать `npm run build`.

---

## 11. Чистая установка зависимостей

Удалить существующий `node_modules`, если checkout уже использовался:

```bash
rm -rf /srv/n1/front/node_modules
```

Установить строго по `package-lock.json`:

```bash
runuser \
    -u n1 \
    -- \
    env \
    PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix /srv/n1/front \
    ci \
    --no-audit \
    --no-fund
```

- `runuser -u n1 --` запускает npm от пользователя приложения.
- `env PATH=...` задаёт предсказуемый Node.js.
- `npm --prefix` задаёт каталог проекта.
- `ci` делает чистую воспроизводимую установку по lock-файлу.
- `--no-audit` отключает audit во время deploy.
- `--no-fund` скрывает сообщения о финансировании.

`npm ci` не должен изменять `package-lock.json`.

---

## 12. Lint

```bash
runuser \
    -u n1 \
    -- \
    env \
    PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix /srv/n1/front \
    run \
    lint
```

Проектный script запускает `oxlint`. При ошибке deploy нужно остановить.

---

## 13. Production build

Удалить старый результат:

```bash
rm -rf /srv/n1/front/dist
```

Собрать:

```bash
runuser \
    -u n1 \
    -- \
    env \
    PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix /srv/n1/front \
    run \
    build
```

Проектный script выполняет `vite build`.

Ожидаемые пути:

```text
/srv/n1/front/dist/index.html
/srv/n1/front/dist/assets/
```

---

## 14. Права production build

Назначить владельца:

```bash
chown \
    -R \
    n1:n1 \
    /srv/n1/front/dist
```

Назначить права каталогам:

```bash
find \
    /srv/n1/front/dist \
    -type d \
    -exec chmod 0755 {} +
```

- `find` обходит дерево.
- `-type d` выбирает каталоги.
- `-exec ... {} +` передаёт найденные пути группами.
- `0755` позволяет Nginx проходить по каталогам.

Назначить права файлам:

```bash
find \
    /srv/n1/front/dist \
    -type f \
    -exec chmod 0644 {} +
```

- `0644` позволяет владельцу изменять файлы, а Nginx — читать.

Проверить:

```bash
stat \
    -c '%A %U:%G %n' \
    /srv/n1/front/dist \
    /srv/n1/front/dist/index.html \
    /srv/n1/front/dist/assets
```

---

## 15. Проверка сборки

Проверить обязательные пути:

```bash
test -f /srv/n1/front/dist/index.html
test -d /srv/n1/front/dist/assets
```

- `test -f` проверяет обычный файл.
- `test -d` проверяет каталог.
- При успехе команды ничего не выводят.

Посчитать файлы:

```bash
find /srv/n1/front/dist -type f | wc -l
```

Показать размер:

```bash
du -sh /srv/n1/front/dist
```

- `-s` выводит итог.
- `-h` использует читаемые единицы.

Показать references assets из `index.html`:

```bash
grep \
    -oE '/assets/[^"[:space:]]+' \
    /srv/n1/front/dist/index.html
```

- `-o` выводит только совпадение.
- `-E` включает расширенный regex.

Проверить production API URL в bundle:

```bash
grep \
    -RsaqF \
    'https://virtual-privat-n1.ru' \
    /srv/n1/front/dist/assets
```

- `-R` ищет рекурсивно.
- `-s` скрывает ошибки чтения.
- `-a` рассматривает файлы как текст.
- `-q` возвращает только код результата.
- `-F` ищет буквальную строку.

Показать известные API-пути:

```bash
grep \
    -RsaEo \
    '/api/v1/[A-Za-z0-9_./?-]+|/sanctum/csrf-cookie' \
    /srv/n1/front/dist/assets \
    | sort \
    -u
```

- `sort -u` сортирует и удаляет дубликаты.

Проверить Git status:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/front \
    status \
    --short \
    --branch
```

`.env` не должен отображаться как untracked.

---

## 16. Публикация через Nginx

Этот этап ещё не выполнялся в текущем развёртывании, поэтому точный production Nginx config в документ намеренно не добавлен.

Для полной публикации потребуется отдельно:

1. установить или проверить Nginx;
2. указать `root /srv/n1/front/dist`;
3. настроить SPA fallback на `/index.html`;
4. проксировать `/api/*`, `/sanctum/*` и backend-маршруты в Laravel;
5. настроить DNS;
6. получить TLS-сертификат;
7. провести браузерный end-to-end тест.

До этого этапа production build готов, но сам по себе не доступен по публичному домену.

---

## 17. Доставка обновлений frontend

### На локальном компьютере

```bash
git status
git add PATHS
git commit -m "commit message"
git push origin CURRENT_BRANCH
```

Заменить `PATHS` и `CURRENT_BRANCH` реальными значениями.

### На сервере

Получить изменения:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/front \
    pull \
    --ff-only
```

- `--ff-only` не позволяет создать неожиданный merge commit на сервере.

Установить зависимости:

```bash
runuser \
    -u n1 \
    -- \
    env \
    PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix /srv/n1/front \
    ci \
    --no-audit \
    --no-fund
```

Запустить lint:

```bash
runuser \
    -u n1 \
    -- \
    env \
    PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix /srv/n1/front \
    run \
    lint
```

Собрать:

```bash
runuser \
    -u n1 \
    -- \
    env \
    PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix /srv/n1/front \
    run \
    build
```

Обновить права:

```bash
chown -R n1:n1 /srv/n1/front/dist

find /srv/n1/front/dist \
    -type d \
    -exec chmod 0755 {} +

find /srv/n1/front/dist \
    -type f \
    -exec chmod 0644 {} +
```

Проверить:

```bash
test -f /srv/n1/front/dist/index.html
test -d /srv/n1/front/dist/assets
du -sh /srv/n1/front/dist
```

После настройки Nginx его не нужно перезапускать при обычном изменении статических файлов. `systemctl reload nginx` потребуется только после изменения Nginx-конфигурации.

---

## 18. Изменение API URL

Открыть:

```bash
vim /srv/n1/front/.env
```

Изменить:

```dotenv
VITE_API_BASE_URL=https://NEW_DOMAIN
```

Обязательно пересобрать:

```bash
runuser \
    -u n1 \
    -- \
    env \
    PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix /srv/n1/front \
    run \
    build
```

Восстановить права:

```bash
chown -R n1:n1 /srv/n1/front/dist

find /srv/n1/front/dist \
    -type d \
    -exec chmod 0755 {} +

find /srv/n1/front/dist \
    -type f \
    -exec chmod 0644 {} +
```

Простого изменения `.env` недостаточно: Vite не читает этот файл в браузере во время выполнения.

---

## 19. Проблемы и решения

### 19.1. Remote-ветка `dev` не была доступна

Причина: первоначальный clone был выполнен с `--single-branch --branch main`.

Исправление существующего checkout:

```bash
runuser -u n1 -- git -C /srv/n1/front config \
    --replace-all \
    remote.origin.fetch \
    '+refs/heads/*:refs/remotes/origin/*'

runuser -u n1 -- git -C /srv/n1/front fetch --prune origin
runuser -u n1 -- git -C /srv/n1/front switch --create dev --track origin/dev
```

Для нового deploy клонировать без `--single-branch`.

### 19.2. Неподходящая версия Node.js

Современный Vite требует актуальный Node.js. Системная версия могла быть старее необходимой.

Решение: официальная Node.js 22.22.3 установлена в `/opt`, а ссылки созданы в `/usr/local/bin`.

Проверка:

```bash
/usr/local/bin/node --version
/usr/local/bin/npm --version
```

### 19.3. Production `.env` не был исключён tracked `.gitignore`

Не нужно изменять `.gitignore` на production-сервере только ради локальной конфигурации.

Решение: добавить `/.env` в:

```text
/srv/n1/front/.git/info/exclude
```

Это сохраняет чистый checkout и не требует server-side commit.

### 19.4. После изменения `.env` оставался старый API URL

Причина: Vite внедряет `VITE_API_BASE_URL` в bundle во время build.

Решение: после каждого изменения `VITE_*` запускать:

```bash
npm run build
```

### 19.5. `grep` мог не найти API URL в bundle

Bundler может минифицировать или преобразовать строки. Отсутствие простого совпадения не всегда означает ошибку.

Дополнительная проверка:

```bash
find /srv/n1/front/dist/assets \
    -type f \
    -exec strings {} + \
    | grep -F 'https://virtual-privat-n1.ru'
```

Окончательная проверка выполняется в DevTools браузера после настройки Nginx.

### 19.6. Права `dist`

Nginx должен читать `index.html` и assets. После build права могли зависеть от пользователя и umask.

Решение:

```bash
chown -R n1:n1 /srv/n1/front/dist
find /srv/n1/front/dist -type d -exec chmod 0755 {} +
find /srv/n1/front/dist -type f -exec chmod 0644 {} +
```

### 19.7. Build ещё не означает публичный deploy

`npm run build` создаёт статические файлы, но не публикует их в интернете.

Нужны Nginx, DNS и TLS. Эти этапы на момент написания оставались следующей частью общего deploy.

---

## 20. Контрольный список

- [ ] Пользователь `n1` создан.
- [ ] Node.js 22.22.3 установлен.
- [ ] SSH-доступ к GitHub работает.
- [ ] Репозиторий клонирован без `--single-branch`.
- [ ] Ветка выбрана вручную.
- [ ] `.env` создан.
- [ ] `VITE_API_BASE_URL` настроен.
- [ ] `.env` исключён через `.git/info/exclude`.
- [ ] `npm ci` проходит.
- [ ] `npm run lint` проходит.
- [ ] `npm run build` проходит.
- [ ] `dist/index.html` существует.
- [ ] `dist/assets` существует.
- [ ] Права каталогов — `0755`.
- [ ] Права файлов — `0644`.
- [ ] Git checkout остаётся чистым.
- [ ] Nginx, DNS и TLS будут настроены отдельным этапом.
