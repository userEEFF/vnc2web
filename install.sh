#!/usr/bin/env bash
set -euo pipefail

# 1) Ввод параметров
read -rp "Домен (например your.domain.tld): " DOMAIN
read -rp "Email для Let's Encrypt: " EMAIL
read -rp "VNC-хост (IP или host.docker.internal): " VNC_HOST
read -rp "VNC-порт (обычно 5900): " VNC_PORT
read -srp "Пароль VNC-сервера: " VNC_PASS; echo
read -rp "Веб-логин (Basic Auth): " WEB_USER
read -srp "Веб-пароль (Basic Auth): " WEB_PASS; echo
read -rp "Логин для Guacamole: " GUAC_USER
read -srp "Пароль для Guacamole: " GUAC_PASS; echo

# 2) Создаём рабочую директорию
WORKDIR="guacamole_deploy"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# 3) Генерируем хэш пароля для Basic Auth
echo "► Хэшируем веб-пароль…"
HASHED_PASS=$(docker run --rm caddy:latest caddy hash-password --plaintext "${WEB_PASS}")

# 4) Пишем docker-compose.yml
cat > docker-compose.yml <<EOF
version: '3.8'
services:
  guacd:
    image: guacamole/guacd:latest
    container_name: guacd
    restart: unless-stopped
    # Увеличиваем лимиты ресурсов
    deploy:
      resources:
        limits:
          memory: 512M

  guacamole:
    image: guacamole/guacamole:latest
    container_name: guacamole
    depends_on:
      guacd:
        condition: service_healthy
    environment:
      GUACD_HOSTNAME: guacd
      GUACD_PORT: 4822
      GUACAMOLE_HOME: /etc/guacamole
      # Увеличиваем таймауты
      GUACD_CONNECT_TIMEOUT: 30000
      GUACD_RESPONSE_TIMEOUT: 30000
    volumes:
      - ./guacamole:/etc/guacamole
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 5

  caddy:
    image: caddy:latest
    container_name: caddy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      guacamole:
        condition: service_healthy
    restart: unless-stopped

volumes:
  caddy_data:
  caddy_config:
EOF

# 5) Создаем конфигурацию Guacamole
mkdir -p guacamole

# guacamole.properties
cat > guacamole/guacamole.properties <<EOF
guacd-hostname: guacd
guacd-port: 4822

# Используем файловую аутентификацию
auth-provider: net.sourceforge.guacamole.net.basic.BasicFileAuthenticationProvider
basic-user-mapping: /etc/guacamole/user-mapping.xml

# Отключаем SFTP для VNC
vnc-disable-sftp: true

# Настройки производительности
enable-websocket: true
http-session-timeout: 1440
EOF

# user-mapping.xml
cat > guacamole/user-mapping.xml <<EOF
<user-mapping>
    <authorize 
        username="${GUAC_USER}" 
        password="${GUAC_PASS}" 
        encoding="plain"
    >
        <connection name="VNC Connection">
            <protocol>vnc</protocol>
            <param name="hostname">${VNC_HOST}</param>
            <param name="port">${VNC_PORT}</param>
            <param name="password">${VNC_PASS}</param>
            <!-- Отключаем SFTP -->
            <param name="enable-sftp">false</param>
            <!-- Увеличиваем таймауты -->
            <param name="recording-exclude-output">true</param>
            <param name="recording-exclude-mouse">true</param>
            <param name="create-recording-path">true</param>
            <param name="enable-wallpaper">false</param>
        </connection>
    </authorize>
</user-mapping>
EOF

# 6) Пишем Caddyfile с улучшенной поддержкой WebSocket
cat > Caddyfile <<EOF
{
    email ${EMAIL}
    auto_https disable_redirects
}

${DOMAIN} {
    # Используем актуальный синтаксис
    basic_auth /* {
        ${WEB_USER} ${HASHED_PASS}
    }

    # WebSocket endpoint
    handle /websocket {
        reverse_proxy guacamole:8080 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            header_up Upgrade {http.request.header.Upgrade}
            header_up Connection {http.request.header.Connection}
        }
    }

    # Остальные запросы
    handle /* {
        reverse_proxy guacamole:8080 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # HTTPS
    tls ${EMAIL}
}
EOF

# 7) Запуск контейнеров
echo "► Запускаем сервисы…"
docker-compose down -v >/dev/null 2>&1 || true
docker-compose up -d

echo
echo "✅ Установка завершена!"
echo "   🔐 Доступ по адресу: https://${DOMAIN}"
echo
echo "🔒 Уровни аутентификации:"
echo "   1. Basic Auth (Caddy): ${WEB_USER}"
echo "   2. Guacamole Login: ${GUAC_USER}"
echo
echo "⚠️ Если не подключается к VNC:"
echo "   - Проверьте доступность ${VNC_HOST}:${VNC_PORT}"
echo "   - Убедитесь VNC сервер запущен"
echo "   - Проверьте брандмауэр"
echo
echo "🔄 Ожидайте 1-2 минуты пока сервисы полностью инициализируются"
echo "📋 Для просмотра логов: docker-compose logs -f"
