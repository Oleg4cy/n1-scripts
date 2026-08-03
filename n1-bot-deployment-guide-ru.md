# Развёртывание Telegram-бота N1 с нуля

## 1. Итоговая схема

Этот документ описывает развёртывание Telegram-бота N1 на Debian 13 без Docker.

После выполнения всех шагов:

- репозиторий находится в `/srv/n1/bot`;
- бот запускается от системного пользователя `n1`;
- production-конфигурация хранится в `/srv/n1/bot/.env`;
- SQLite, сессии, логи и временные файлы вынесены в `/srv/n1/persistent/bot`;
- TypeScript компилируется в `/srv/n1/bot/dist`;
- бот работает через `systemd`;
- сервис автоматически запускается после перезагрузки;
- обновления доставляются через `git pull`, Yarn, сборку и перезапуск сервиса.

Используемые значения:

| Параметр | Значение |
|---|---|
| ОС | Debian 13 |
| Пользователь приложения | `n1` |
| Каталог проекта | `/srv/n1/bot` |
| Постоянные данные | `/srv/n1/persistent/bot` |
| Репозиторий | `git@github.com:Oleg4cy/n1_bot.git` |
| Node.js | `22.22.3` |
| Yarn | `1.22.22` |
| systemd unit | `n1-bot.service` |
| Entry point | `/srv/n1/bot/dist/app.js` |

Все административные команды выполняются от `root`. Команды приложения выполняются от пользователя `n1` через `runuser`.

---

## 2. Подключение и первичная проверка

Подключиться к серверу:

```bash
ssh root@SERVER_IP
```

- `ssh` открывает защищённую SSH-сессию.
- `root` — административный пользователь.
- `SERVER_IP` нужно заменить на IP сервера.

Проверить ОС, архитектуру и ресурсы:

```bash
cat /etc/os-release
uname -m
nproc
free -h
df -hT
```

- `cat /etc/os-release` показывает дистрибутив и версию ОС.
- `uname -m` показывает архитектуру; на текущем сервере использовалась `x86_64`.
- `nproc` показывает количество CPU.
- `free -h` показывает RAM и swap в читаемом формате.
- `df -hT` показывает свободное место и тип файловых систем.
- `-h` означает human-readable.
- `-T` добавляет тип файловой системы.

---

## 3. Установка системных пакетов

Обновить индекс пакетов:

```bash
apt-get update
```

- `apt-get` — пакетный менеджер Debian.
- `update` загружает актуальный индекс пакетов.

Установить необходимые инструменты:

```bash
DEBIAN_FRONTEND=noninteractive apt-get install \
    --yes \
    --no-install-recommends \
    ca-certificates \
    curl \
    git \
    openssh-client \
    xz-utils \
    build-essential \
    python3 \
    pkg-config
```

- `DEBIAN_FRONTEND=noninteractive` отключает интерактивные диалоги установщика.
- `--yes` автоматически подтверждает установку.
- `--no-install-recommends` не ставит необязательные рекомендуемые пакеты.
- `ca-certificates` нужен для HTTPS.
- `curl` нужен для загрузки Node.js.
- `git` и `openssh-client` нужны для GitHub.
- `xz-utils` нужен для `.tar.xz`.
- `build-essential`, `python3` и `pkg-config` нужны при сборке native Node.js-модулей.

---

## 4. Создание пользователя `n1`

Проверить наличие пользователя:

```bash
id n1
```

Если пользователь отсутствует:

```bash
adduser \
    --disabled-password \
    --gecos "" \
    n1
```

- `--disabled-password` запрещает парольный вход.
- `--gecos ""` отключает дополнительные вопросы.

Проверить результат:

```bash
id n1
getent passwd n1
```

- `id n1` показывает UID, GID и группы.
- `getent passwd n1` показывает домашний каталог и shell.

---

## 5. Создание каталогов

Создать общий каталог проекта:

```bash
install \
    -d \
    -m 0755 \
    -o root \
    -g root \
    /srv/n1
```

- `install -d` создаёт каталог.
- `-m 0755` задаёт права.
- `-o root` и `-g root` задают владельца и группу.

Создать persistent-каталоги бота:

```bash
install \
    -d \
    -m 0750 \
    -o n1 \
    -g n1 \
    /srv/n1/persistent/bot \
    /srv/n1/persistent/bot/logs \
    /srv/n1/persistent/bot/temp \
    /srv/n1/persistent/bot/temp/voices
```

Эти каталоги не входят в Git checkout и сохраняются при обновлениях.

---

## 6. Установка Node.js 22.22.3

Для `x86_64`:

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

- `mktemp -d` создаёт уникальный временный каталог.
- Путь сохраняется в `NODE_TMP`.

Загрузить архив и checksum-файл:

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

- `--fail` возвращает ошибку при HTTP 4xx/5xx.
- `--location` следует redirect.
- `--silent --show-error` скрывает progress bar, но показывает ошибки.
- `--output` задаёт файл назначения.

Получить checksum нужного архива:

```bash
grep -E "  ${NODE_ARCHIVE}$" \
    "${NODE_TMP}/SHASUMS256.txt" \
    > "${NODE_TMP}/CHECKSUM"
```

Проверить архив:

```bash
(
    cd "${NODE_TMP}"
    sha256sum --check CHECKSUM
)
```

- Круглые скобки создают subshell.
- `sha256sum --check` сверяет архив с официальной контрольной суммой.

Распаковать:

```bash
tar \
    -xJf "${NODE_TMP}/${NODE_ARCHIVE}" \
    -C /opt
```

- `-x` распаковывает.
- `-J` использует XZ.
- `-f` указывает архив.
- `-C /opt` задаёт каталог назначения.

Назначить владельца:

```bash
chown -R root:root "${NODE_DIR}"
```

Создать стабильные ссылки:

```bash
ln -sfn "${NODE_DIR}/bin/node" /usr/local/bin/node
ln -sfn "${NODE_DIR}/bin/npm" /usr/local/bin/npm
ln -sfn "${NODE_DIR}/bin/npx" /usr/local/bin/npx
ln -sfn "${NODE_DIR}/bin/corepack" /usr/local/bin/corepack
```

- `ln -s` создаёт символическую ссылку.
- `-f` заменяет существующую.
- `-n` не разыменовывает существующую ссылку-каталог.

Удалить временные файлы:

```bash
rm -rf "${NODE_TMP}"
```

Проверить:

```bash
node --version
npm --version
corepack --version
```

Ожидаемая версия Node.js: `v22.22.3`.

---

## 7. Установка Yarn Classic

```bash
corepack prepare yarn@1.22.22 --activate
```

- `prepare` загружает указанную версию Yarn.
- `--activate` делает её активной.

Проверить:

```bash
yarn --version
```

Ожидаемый результат: `1.22.22`.

---

## 8. SSH-доступ пользователя `n1` к GitHub

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

- `runuser -u n1 --` запускает последующую команду от `n1`.
- `-t ed25519` выбирает тип ключа.
- `-C` добавляет комментарий.
- `-f` задаёт путь.
- `-N ""` создаёт ключ без passphrase.

Показать публичный ключ:

```bash
cat /home/n1/.ssh/id_ed25519.pub
```

Добавить его в GitHub как SSH key или deploy key.

Записать host key GitHub:

```bash
runuser \
    -u n1 \
    -- \
    ssh-keyscan \
    -H github.com \
    >> /home/n1/.ssh/known_hosts
```

- `-H` хеширует hostname.
- `>>` дописывает в файл.

Исправить права:

```bash
chown n1:n1 /home/n1/.ssh/known_hosts
chmod 0600 /home/n1/.ssh/known_hosts
```

Проверить соединение:

```bash
runuser \
    -u n1 \
    -- \
    ssh \
    -T \
    git@github.com
```

- `-T` запрещает интерактивный терминал.

---

## 9. Клонирование репозитория

```bash
runuser \
    -u n1 \
    -- \
    git \
    clone \
    git@github.com:Oleg4cy/n1_bot.git \
    /srv/n1/bot
```

Не использовать `--single-branch`, если может понадобиться переключение между ветками.

Проверить remote:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/bot \
    remote \
    -v
```

Получить все remote-ветки:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/bot \
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
    -C /srv/n1/bot \
    branch \
    --all
```

Если локальной `dev` нет:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/bot \
    switch \
    --create dev \
    --track origin/dev
```

Если локальная `dev` существует:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/bot \
    switch dev
```

Выбор ветки контролируется вручную.

Проверить состояние:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/bot \
    status \
    --short \
    --branch
```

---

## 10. Исключение production `.env` из Git

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'grep -qxF "/.env" /srv/n1/bot/.git/info/exclude || printf "\n# Production-local files\n/.env\n" >> /srv/n1/bot/.git/info/exclude'
```

- `grep -q` не выводит совпадение.
- `-x` требует полного совпадения строки.
- `-F` ищет буквальный текст.
- `||` выполняет правую часть только при отсутствии правила.
- `.git/info/exclude` не меняет tracked-файлы репозитория.

Проверить:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/bot \
    check-ignore \
    -v \
    .env
```

---

## 11. Production `.env`

Создать файл:

```bash
install \
    -m 0600 \
    -o n1 \
    -g n1 \
    /dev/null \
    /srv/n1/bot/.env
```

Открыть:

```bash
vim /srv/n1/bot/.env
```

Шаблон:

```dotenv
TOKEN_TELEGRAM=TELEGRAM_BOT_TOKEN
TOKEN_DEEPSEEK=DEEPSEEK_API_TOKEN
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=MODEL_NAME

TELEGRAM_PROXY_URL=

OPERATOR_GROUP_ID=-1000000000000
OPERATOR_CHAT_ID=123456789

LOG_DIR=/srv/n1/persistent/bot/logs
LOG_DEFAULT=/srv/n1/persistent/bot/logs/log.txt
LOG_ERRORS=/srv/n1/persistent/bot/logs/log_errors.txt

DB_NAME=/srv/n1/persistent/bot/BOT.db

TEMP_DIR=/srv/n1/persistent/bot/temp
TEMP_VOICES=/srv/n1/persistent/bot/temp/voices
```

Правила:

- реальные токены не коммитить и не отправлять в чат;
- `OPERATOR_GROUP_ID` у supergroup обычно отрицательный;
- `OPERATOR_CHAT_ID` — личный Telegram User ID оператора;
- пустой `TELEGRAM_PROXY_URL` означает прямое соединение;
- постоянные пути должны находиться вне Git checkout.

Закрепить права:

```bash
chown n1:n1 /srv/n1/bot/.env
chmod 0600 /srv/n1/bot/.env
```

Показать только имена переменных:

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'cut -d= -f1 /srv/n1/bot/.env | sed "/^[[:space:]]*$/d"'
```

---

## 12. Постоянные данные

Создать начальный файл сессий:

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'umask 077; printf "{\n  \"sessions\": []\n}\n" > /srv/n1/persistent/bot/sessions.json'
```

Закрепить права:

```bash
chown n1:n1 /srv/n1/persistent/bot/sessions.json
chmod 0600 /srv/n1/persistent/bot/sessions.json
```

Текущий код ожидает `sessions.json` в рабочем каталоге. Создать ссылку:

```bash
ln \
    -sfn \
    /srv/n1/persistent/bot/sessions.json \
    /srv/n1/bot/sessions.json
```

Назначить владельца самой ссылки:

```bash
chown \
    -h \
    n1:n1 \
    /srv/n1/bot/sessions.json
```

- `-h` изменяет владельца ссылки, а не целевого файла.

Проверить:

```bash
ls -l /srv/n1/bot/sessions.json
stat /srv/n1/persistent/bot/sessions.json
```

SQLite-файл `BOT.db` будет создан приложением при первом запуске. После появления:

```bash
chown n1:n1 /srv/n1/persistent/bot/BOT.db
chmod 0600 /srv/n1/persistent/bot/BOT.db
```

---

## 13. Установка зависимостей

Удалить старые зависимости, если они есть:

```bash
rm -rf /srv/n1/bot/node_modules
```

Установить строго по `yarn.lock`:

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'cd /srv/n1/bot && exec yarn install --frozen-lockfile'
```

- `cd` переходит в каталог проекта.
- `exec` корректно передаёт код завершения Yarn.
- `--frozen-lockfile` запрещает изменять `yarn.lock`.

Peer dependency warnings допустимы. Критерий успеха — код завершения `0` и строка `Done`.

---

## 14. Сборка и тесты

Удалить старую сборку:

```bash
rm -rf /srv/n1/bot/dist
```

Собрать TypeScript:

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'cd /srv/n1/bot && exec yarn build'
```

Проверить entry point:

```bash
stat \
    -c '%A %U:%G %s bytes %y %n' \
    /srv/n1/bot/dist/app.js
```

- `%A` — права.
- `%U:%G` — владелец и группа.
- `%s` — размер.
- `%y` — время изменения.
- `%n` — путь.

Запустить тесты, если они присутствуют в ветке:

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'cd /srv/n1/bot && exec yarn test'
```

---

## 15. Ручной функциональный тест

Остановить systemd-сервис, если он уже существует:

```bash
systemctl stop n1-bot.service 2>/dev/null || true
```

- `2>/dev/null` скрывает stderr при отсутствии unit.
- `|| true` не прерывает выполнение.

Запустить вручную:

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'cd /srv/n1/bot && exec yarn start'
```

`yarn start` выполняет `yarn build && node ./dist/app.js`.

Проверить:

1. обычный пользовательский запрос;
2. ответ ИИ;
3. переход к оператору;
4. появление сообщения в операторской группе;
5. ответ оператора;
6. сохранение SQLite и сессий.

Учитывать: при активном операторском диалоге сообщения и ответы могут находиться в операторской теме. Это может выглядеть как отсутствие ответа в другом наблюдаемом чате.

Для остановки нажать `Ctrl+C`.

Нельзя одновременно запускать ручной `yarn start` и `n1-bot.service` с одним Telegram token.

Проверить persistent-файлы:

```bash
stat \
    -c '%A %U:%G %s bytes %n' \
    /srv/n1/persistent/bot/BOT.db \
    /srv/n1/persistent/bot/sessions.json
```

Закрепить права:

```bash
chown n1:n1 \
    /srv/n1/persistent/bot/BOT.db \
    /srv/n1/persistent/bot/sessions.json

chmod 0600 \
    /srv/n1/persistent/bot/BOT.db \
    /srv/n1/persistent/bot/sessions.json
```

---

## 16. systemd unit

Открыть файл:

```bash
vim /etc/systemd/system/n1-bot.service
```

Содержимое:

```ini
[Unit]
Description=N1 Telegram Bot
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=n1
Group=n1
WorkingDirectory=/srv/n1/bot
Environment=NODE_ENV=production
ExecStart=/usr/local/bin/node /srv/n1/bot/dist/app.js

Restart=on-failure
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=30

UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

Назначение основных директив:

- `WorkingDirectory` нужен для относительного `sessions.json`.
- `ExecStart` запускает уже собранный JavaScript напрямую.
- `Restart=on-failure` перезапускает после ошибки.
- `KillSignal=SIGINT` позволяет Telegraf корректно завершиться.
- `UMask=0077` создаёт новые файлы без прав для группы и остальных.
- `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem`, `ProtectHome` ограничивают сервис.
- Не использовать `yarn start` в `ExecStart`, потому что он пересобирает проект при каждом рестарте.

Установить права:

```bash
chown root:root /etc/systemd/system/n1-bot.service
chmod 0644 /etc/systemd/system/n1-bot.service
```

Проверить unit:

```bash
systemd-analyze verify /etc/systemd/system/n1-bot.service
```

Перечитать конфигурацию:

```bash
systemctl daemon-reload
```

Включить автозапуск:

```bash
systemctl enable n1-bot.service
```

Запустить:

```bash
systemctl start n1-bot.service
```

Проверить:

```bash
systemctl is-enabled n1-bot.service
systemctl is-active n1-bot.service
```

Ожидается:

```text
enabled
active
```

Полный статус:

```bash
systemctl \
    --no-pager \
    --full \
    status \
    n1-bot.service
```

- `--no-pager` выводит результат сразу.
- `--full` не обрезает строки.

Последние логи:

```bash
journalctl \
    --unit=n1-bot.service \
    --lines=100 \
    --no-pager
```

Логи в реальном времени:

```bash
journalctl \
    --unit=n1-bot.service \
    --follow
```

`Ctrl+C` закрывает просмотр и не останавливает сервис.

---

## 17. Управление сервисом

Статус:

```bash
systemctl status n1-bot.service
```

Перезапуск:

```bash
systemctl restart n1-bot.service
```

Остановка:

```bash
systemctl stop n1-bot.service
```

Запуск:

```bash
systemctl start n1-bot.service
```

Это альтернативные команды. Не следует копировать `restart` и `stop` одним блоком, если бот должен остаться запущенным.

---

## 18. Доставка обновлений

### На локальном компьютере

```bash
git status
git add PATHS
git commit -m "commit message"
git push origin CURRENT_BRANCH
```

Заменить `PATHS` и `CURRENT_BRANCH` реальными значениями.

### На сервере

Получить обновления:

```bash
runuser \
    -u n1 \
    -- \
    git \
    -C /srv/n1/bot \
    pull \
    --ff-only
```

- `--ff-only` запрещает неожиданный merge commit на production-сервере.

Установить зависимости:

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'cd /srv/n1/bot && exec yarn install --frozen-lockfile'
```

Собрать:

```bash
runuser \
    -u n1 \
    -- \
    bash \
    -c 'cd /srv/n1/bot && exec yarn build'
```

Перезапустить только после успешной сборки:

```bash
systemctl restart n1-bot.service
```

Проверить:

```bash
systemctl is-active n1-bot.service
systemctl --no-pager --full status n1-bot.service
journalctl --unit=n1-bot.service --lines=50 --no-pager
```

Провести один Telegram-тест.

Обновление не должно затрагивать:

```text
/srv/n1/bot/.env
/srv/n1/persistent/bot/BOT.db
/srv/n1/persistent/bot/sessions.json
/srv/n1/persistent/bot/logs
/srv/n1/persistent/bot/temp
```

---

## 19. Проверка после перезагрузки

```bash
reboot
```

После повторного входа:

```bash
systemctl is-enabled n1-bot.service
systemctl is-active n1-bot.service
systemctl --no-pager --full status n1-bot.service
```

Проверить один Telegram-сценарий.

---

## 20. Проблемы и решения

### 20.1. Ветка `dev` не была видна

Симптом:

```text
pathspec 'dev' did not match any file(s) known to git
```

Причина: clone был выполнен с `--single-branch --branch main`, а refspec получал только `main`.

Исправление существующего checkout:

```bash
runuser -u n1 -- git -C /srv/n1/bot config \
    --replace-all \
    remote.origin.fetch \
    '+refs/heads/*:refs/remotes/origin/*'

runuser -u n1 -- git -C /srv/n1/bot fetch --prune origin
runuser -u n1 -- git -C /srv/n1/bot switch --create dev --track origin/dev
```

Решение для новых серверов: не использовать `--single-branch`.

### 20.2. `npm ci` завершался с `ERESOLVE`

Причина: конфликт peer dependencies между TypeScript и `@typescript-eslint`.

Локально проект работал через Yarn и существующий lock-файл.

Решение:

```bash
rm -rf /srv/n1/bot/node_modules
runuser -u n1 -- git -C /srv/n1/bot restore yarn.lock
runuser -u n1 -- bash -c 'cd /srv/n1/bot && exec yarn install --frozen-lockfile'
runuser -u n1 -- bash -c 'cd /srv/n1/bot && exec yarn build'
```

Итоговое правило: этот проект разворачивается через Yarn Classic и закоммиченный `yarn.lock`, а не через `npm ci`.

### 20.3. Yarn создал новый `yarn.lock`

Симптом: `No lockfile found`.

Решение: восстановить tracked-файл и переустановить зависимости:

```bash
runuser -u n1 -- git -C /srv/n1/bot restore yarn.lock
rm -rf /srv/n1/bot/node_modules
runuser -u n1 -- bash -c 'cd /srv/n1/bot && exec yarn install --frozen-lockfile'
```

Production-сервер не должен генерировать или коммитить lock-файлы.

### 20.4. `sessions.json` находился внутри checkout

Решение: вынести его в persistent-каталог и создать ссылку:

```bash
ln -sfn /srv/n1/persistent/bot/sessions.json /srv/n1/bot/sessions.json
```

SQLite, логи и temp также вынесены через `.env`.

### 20.5. Исправный сервис был случайно остановлен

Команды `status`, `restart`, `stop` и `journalctl` были запущены подряд. `systemctl stop` штатно остановил сервис.

Решение: выполнять управляющие команды отдельно.

### 20.6. Казалось, что бот не отвечает

Фактическая причина: тестировался операторский сценарий, а сообщения и ответы находились в операторской теме. Это не было ошибкой systemd, Telegram token или polling.

Решение: проверять текущий статус операторского диалога и нужную тему в операторской группе.

### 20.7. `yarn start` показывал только `exit code 1`

Текущий `src/app.ts` подавляет исходную ошибку:

```ts
void bot.start().catch(() => {
    process.exitCode = 1;
});
```

Рекомендуемое изменение:

```ts
void bot.start().catch((error: unknown) => {
    console.error('Bot startup failed:', error);
    process.exitCode = 1;
});
```

Изменение нужно сделать локально, проверить, закоммитить и доставить обычным deploy-процессом.

### 20.8. Возможен конфликт двух polling-процессов

Перед ручным запуском:

```bash
systemctl stop n1-bot.service
```

После теста:

```bash
systemctl start n1-bot.service
```

Не запускать `yarn start` параллельно с systemd-сервисом.

### 20.9. Ошибка диагностического shell-кода с `${token}`

JavaScript template literal оказался внутри двойной строки Bash. Bash попытался раскрыть `${token}`, что вызвало `unbound variable` и повредило JavaScript.

Для сложного embedded JavaScript использовать quoted heredoc:

```bash
cat > /tmp/check.js <<'NODE'
const token = process.env.TOKEN_TELEGRAM;
console.log(token);
NODE
```

Quoted delimiter `'NODE'` запрещает shell-подстановки.

---

## 21. Контрольный список

- [ ] Пользователь `n1` создан.
- [ ] Node.js 22.22.3 установлен.
- [ ] Yarn Classic 1.22.22 установлен.
- [ ] SSH-доступ к GitHub работает.
- [ ] Репозиторий клонирован без `--single-branch`.
- [ ] Ветка выбрана вручную.
- [ ] `.env` создан с правами `0600`.
- [ ] Persistent-каталоги созданы.
- [ ] `sessions.json` подключён ссылкой.
- [ ] `yarn install --frozen-lockfile` проходит.
- [ ] `yarn build` проходит.
- [ ] Ручной Telegram-тест пройден.
- [ ] `n1-bot.service` установлен.
- [ ] Сервис имеет состояния `enabled` и `active`.
- [ ] После перезагрузки сервис запускается автоматически.
- [ ] Процедура обновления проверена.
