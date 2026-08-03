# Простой деплой Laravel API N1 с нуля

Этот гайд описывает только рабочую последовательность действий:

1. зайти на сервер;
2. установить пакеты;
3. создать пользователя и базу;
4. склонировать проект;
5. заполнить `.env`;
6. установить зависимости;
7. выполнить миграции;
8. настроить PHP-FPM;
9. запустить очередь;
10. настроить Nginx;
11. подключить HTTPS;
12. проверить сайт.

Используемые пути:

```text
Laravel:  /srv/n1/api
Frontend: /srv/n1/front/dist
Домен:    virtual-privat-n1.ru
```

Все команды выполняются от `root`, если отдельно не указано другое.

---

## 1. Зайти на сервер

```bash
ssh root@IP_СЕРВЕРА
```

---

## 2. Установить необходимые пакеты

```bash
apt-get update
```

```bash
apt-get install -y \
    git \
    nginx \
    postgresql \
    composer \
    php8.4-cli \
    php8.4-fpm \
    php8.4-pgsql \
    php8.4-curl \
    php8.4-mbstring \
    php8.4-xml \
    php8.4-zip \
    php8.4-bcmath \
    php8.4-intl
```

Запустить сервисы:

```bash
systemctl enable --now nginx
systemctl enable --now php8.4-fpm
systemctl enable --now postgresql
```

---

## 3. Создать пользователя приложения

Если пользователь `n1` уже существует, этот шаг пропустить.

```bash
adduser --disabled-password --gecos "" n1
```

Создать основной каталог:

```bash
mkdir -p /srv/n1
```

---

## 4. Настроить доступ к GitHub

Создать SSH-ключ от пользователя `n1`:

```bash
sudo -u n1 ssh-keygen \
    -t ed25519 \
    -f /home/n1/.ssh/id_ed25519 \
    -N ""
```

Показать публичный ключ:

```bash
cat /home/n1/.ssh/id_ed25519.pub
```

Добавить этот ключ в GitHub.

Проверить подключение:

```bash
sudo -u n1 ssh -T git@github.com
```

---

## 5. Склонировать Laravel

```bash
sudo -u n1 git clone \
    git@github.com:Oleg4cy/n1-api.git \
    /srv/n1/api
```

Перейти в проект:

```bash
cd /srv/n1/api
```

При необходимости самостоятельно переключить ветку:

```bash
sudo -u n1 git switch dev
```

Ветка в этом гайде автоматически не выбирается.

---

## 6. Создать базу PostgreSQL

Открыть PostgreSQL:

```bash
sudo -u postgres psql
```

Выполнить:

```sql
CREATE USER n1_api WITH PASSWORD 'ЗАДАЙ_СЛОЖНЫЙ_ПАРОЛЬ';
CREATE DATABASE n1_api OWNER n1_api;
ALTER DATABASE n1_api SET timezone TO 'UTC';
\q
```

Проверить подключение:

```bash
PGPASSWORD='ЗАДАННЫЙ_ПАРОЛЬ' psql \
    -h 127.0.0.1 \
    -U n1_api \
    -d n1_api
```

Выйти:

```sql
\q
```

---

## 7. Создать Laravel `.env`

```bash
cd /srv/n1/api
```

```bash
cp .env.example .env
```

Открыть:

```bash
vim .env
```

Заполнить основные параметры:

```dotenv
APP_NAME=N1
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=https://virtual-privat-n1.ru

FRONTEND_ORIGINS=https://virtual-privat-n1.ru
SANCTUM_STATEFUL_DOMAINS=virtual-privat-n1.ru

DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=n1_api
DB_USERNAME=n1_api
DB_PASSWORD=ПАРОЛЬ_БАЗЫ

SESSION_DRIVER=database
CACHE_STORE=database
QUEUE_CONNECTION=database

MAIL_MAILER=log
LOGIN_CODE_DELIVERY=mail

PAYMENT_PROVIDER_DRIVER=stub

REMNAWAVE_BASE_URL=https://panel.virtual-privat-n1.ru
REMNAWAVE_API_TOKEN=ТОКЕН_REMNAWAVE
REMNAWAVE_ACTIVE_INTERNAL_SQUAD_UUIDS=UUID_ВНУТРЕННЕГО_SQUAD
```

Сохранить файл и назначить права:

```bash
chown n1:n1 /srv/n1/api/.env
chmod 600 /srv/n1/api/.env
```

Важно:

- `.env` не коммитить;
- `MAIL_MAILER=log` не отправляет реальные письма, а пишет их в Laravel log;
- `PAYMENT_PROVIDER_DRIVER=stub` — тестовая оплата, не YooKassa.

---

## 8. Установить Composer-зависимости

```bash
cd /srv/n1/api
```

```bash
sudo -u n1 composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction
```

Сгенерировать ключ приложения:

```bash
sudo -u n1 php artisan key:generate --force
```

---

## 9. Настроить права Laravel

```bash
chown -R n1:n1 \
    /srv/n1/api/storage \
    /srv/n1/api/bootstrap/cache
```

```bash
chmod -R 770 \
    /srv/n1/api/storage \
    /srv/n1/api/bootstrap/cache
```

---

## 10. Выполнить миграции

```bash
cd /srv/n1/api
```

```bash
sudo -u n1 php artisan migrate --force
```

Заполнить тарифы:

```bash
sudo -u n1 php artisan db:seed \
    --class=TariffCatalogSeeder \
    --force
```

Не запускать обычный:

```text
php artisan db:seed
```

В текущем проекте общий `DatabaseSeeder` может создать тестового пользователя.

---

## 11. Создать Laravel cache

```bash
sudo -u n1 php artisan optimize:clear
```

```bash
sudo -u n1 php artisan config:cache
```

```bash
sudo -u n1 php artisan event:cache
```

```bash
sudo -u n1 php artisan view:cache
```

Проверить Laravel:

```bash
sudo -u n1 php artisan about
```

Проверить Remnawave:

```bash
sudo -u n1 php artisan remnawave:check
```

---

## 12. Настроить PHP-FPM

Создать отдельный pool:

```bash
vim /etc/php/8.4/fpm/pool.d/n1-api.conf
```

Добавить:

```ini
[n1-api]

user = n1
group = n1

listen = /run/php/php8.4-fpm-n1-api.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 10s

chdir = /srv/n1/api
```

Проверить конфигурацию:

```bash
php-fpm8.4 --test
```

Перезапустить:

```bash
systemctl restart php8.4-fpm
```

Проверить:

```bash
systemctl status php8.4-fpm
```

---

## 13. Запустить Laravel queue

Создать сервис:

```bash
vim /etc/systemd/system/n1-queue.service
```

Добавить:

```ini
[Unit]
Description=N1 Laravel Queue
After=network.target postgresql.service

[Service]
User=n1
Group=n1
WorkingDirectory=/srv/n1/api

ExecStart=/usr/bin/php /srv/n1/api/artisan queue:work database --queue=remnawave,default --sleep=3 --tries=3 --timeout=90

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Применить:

```bash
systemctl daemon-reload
```

```bash
systemctl enable --now n1-queue.service
```

Проверить:

```bash
systemctl status n1-queue.service
```

---

## 14. Настроить Nginx

Frontend должен быть уже собран в:

```text
/srv/n1/front/dist
```

Создать конфигурацию:

```bash
vim /etc/nginx/sites-available/n1
```

Добавить:

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name virtual-privat-n1.ru;

    root /srv/n1/front/dist;
    index index.html;

    location ^~ /api/ {
        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME /srv/n1/api/public/index.php;
        fastcgi_param SCRIPT_NAME /index.php;

        fastcgi_pass unix:/run/php/php8.4-fpm-n1-api.sock;
    }

    location = /sanctum/csrf-cookie {
        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME /srv/n1/api/public/index.php;
        fastcgi_param SCRIPT_NAME /index.php;

        fastcgi_pass unix:/run/php/php8.4-fpm-n1-api.sock;
    }

    location ^~ /payments/stub/ {
        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME /srv/n1/api/public/index.php;
        fastcgi_param SCRIPT_NAME /index.php;

        fastcgi_pass unix:/run/php/php8.4-fpm-n1-api.sock;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

Включить сайт:

```bash
ln -s /etc/nginx/sites-available/n1 /etc/nginx/sites-enabled/n1
```

Удалить стандартный сайт:

```bash
rm -f /etc/nginx/sites-enabled/default
```

Проверить:

```bash
nginx -t
```

Применить:

```bash
systemctl reload nginx
```

---

## 15. Проверить сайт по HTTP

Проверить frontend:

```bash
curl -I http://virtual-privat-n1.ru
```

Проверить Laravel health:

```bash
curl http://virtual-privat-n1.ru/api/v1/health
```

Проверить каталог тарифов:

```bash
curl http://virtual-privat-n1.ru/api/v1/pricing/catalog
```

---

## 16. Подключить HTTPS

Установить Certbot:

```bash
apt-get install -y certbot python3-certbot-nginx
```

Получить сертификат:

```bash
certbot \
    --nginx \
    -d virtual-privat-n1.ru
```

Certbot задаст несколько вопросов и сам добавит HTTPS в Nginx.

Проверить:

```bash
curl https://virtual-privat-n1.ru/api/v1/health
```

---

## 17. Проверить вход по email

Сейчас в `.env` указано:

```dotenv
MAIL_MAILER=log
```

Поэтому код входа будет записываться в:

```text
/srv/n1/api/storage/logs/laravel.log
```

Посмотреть log:

```bash
tail -f /srv/n1/api/storage/logs/laravel.log
```

После запроса кода на сайте он появится в этом файле.

Для реального запуска позже нужно настроить SMTP.

---

## 18. Как доставлять обновления

На локальном компьютере:

```bash
git add .
git commit -m "commit message"
git push
```

На сервере:

```bash
cd /srv/n1/api
```

```bash
sudo -u n1 git pull --ff-only
```

```bash
sudo -u n1 composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction
```

```bash
sudo -u n1 php artisan migrate --force
```

```bash
sudo -u n1 php artisan db:seed \
    --class=TariffCatalogSeeder \
    --force
```

```bash
sudo -u n1 php artisan optimize:clear
sudo -u n1 php artisan config:cache
sudo -u n1 php artisan event:cache
sudo -u n1 php artisan view:cache
```

```bash
systemctl reload php8.4-fpm
systemctl restart n1-queue.service
```

Проверить:

```bash
curl https://virtual-privat-n1.ru/api/v1/health
```

---

## 19. Основные команды управления

Проверить PHP-FPM:

```bash
systemctl status php8.4-fpm
```

Проверить очередь:

```bash
systemctl status n1-queue.service
```

Перезапустить очередь:

```bash
systemctl restart n1-queue.service
```

Посмотреть Laravel log:

```bash
tail -f /srv/n1/api/storage/logs/laravel.log
```

Посмотреть queue log:

```bash
journalctl -u n1-queue.service -f
```

Посмотреть Nginx errors:

```bash
tail -f /var/log/nginx/error.log
```

---

## 20. Проблемы, которые уже встречались

### Не было ветки `dev`

Причина: репозиторий клонировался с `--single-branch`.

Правильно:

```bash
git clone git@github.com:Oleg4cy/n1-api.git /srv/n1/api
```

Без `--single-branch`.

### Не найден `TariffCatalogSeeder`

Ошибка:

```text
Target class [Database\Seeders\TariffCatalogSeeder] does not exist
```

Причина: на сервере был старый код.

Решение:

```bash
cd /srv/n1/api
sudo -u n1 git pull --ff-only
```

После этого проверить:

```bash
ls database/seeders
```

### Письма не приходят

При:

```dotenv
MAIL_MAILER=log
```

письма не отправляются, а записываются в:

```text
storage/logs/laravel.log
```

### Изменения `.env` не применились

После изменения `.env`:

```bash
sudo -u n1 php artisan config:cache
```

### Queue использует старый код

После обновления:

```bash
systemctl restart n1-queue.service
```

### API возвращает страницу frontend

Значит Nginx отправил `/api/*` в SPA.

Проверить, что `location ^~ /api/` находится отдельно от:

```nginx
location / {
    try_files $uri $uri/ /index.html;
}
```

---

## 21. Итоговая схема

```text
Пользователь открывает сайт
        ↓
Nginx
        ├── /, /cabinet, /documents → React frontend
        ├── /assets/*               → статические файлы
        ├── /api/*                  → Laravel
        ├── /sanctum/*              → Laravel
        └── /payments/stub/*        → Laravel

Laravel
        ├── PostgreSQL
        ├── Remnawave API
        ├── database queue
        └── Laravel log
```
