# 3x-ui Reverse Proxy Setup

Автоматическая настройка nginx как reverse proxy для [3x-ui](https://github.com/MHSanaei/3x-ui) с поддержкой VLESS транспортов и SSL.

## Поддерживаемые протоколы

| Протокол | Транспорт | Через Nginx |
|----------|-----------|-------------|
| VLESS + WebSocket | WS | ✅ |
| VLESS + gRPC | gRPC | ✅ |
| VLESS + XHTTP (SplitHTTP) | XHTTP | ✅ |
| VLESS + Reality | XTLS-Vision | ❌ (прямое подключение) |

## Поддерживаемые ОС

- Ubuntu 22.04 / 24.04
- Debian 12 / 13

## Что делает скрипт

- Устанавливает и настраивает **nginx** как reverse proxy
- Получает SSL сертификат через **acme.sh** (Let's Encrypt)
- Настраивает **fail2ban** (защита от сканеров и брутфорса панели)
- Включает **TCP BBR** (оптимизация congestion control)
- Отключает **UFW**
- Генерирует случайные пути для панели и inbound'ов
- Показывает инструкции для настройки inbound'ов в 3x-ui

## Использование

```bash
bash <(curl -Ls https://raw.githubusercontent.com/drno88/reverse-proxy-3x-ui/main/setup.sh)
```

Или скачать и запустить:

```bash
curl -Lo setup.sh https://raw.githubusercontent.com/drno88/reverse-proxy-3x-ui/main/setup.sh
bash setup.sh
```

> Запускать от root.

## Что спросит скрипт

1. **Домен** — должен иметь A-запись на IP сервера (нужен для SSL)
2. **Путь к панели** — случайный по умолчанию (5–12 символов)
3. **Порт панели** — по умолчанию 2053
4. **Путь и порт** для каждого транспорта (WS / gRPC / XHTTP)
5. **Порт** для Reality (прямое подключение, без nginx)

## Архитектура

```
Клиент → 443 (HTTPS) → Nginx → localhost:порт → Xray inbound
                                                  ├── WS       :10001
                                                  ├── gRPC     :10002
                                                  └── XHTTP    :10003

Клиент → Reality порт (прямое) → Xray inbound (Reality)
```

> Reality требует прямого TLS соединения — nginx в цепочке не нужен.

## После установки

В **3x-ui панели** создать inbound'ы с настройками из финальных инструкций скрипта:

- Порт = тот что выбрали при настройке
- TLS = **None** (TLS снимает nginx)
- Transport path / serviceName = тот что выбрали

Панель доступна по HTTPS через nginx — нужно установить `URI Path` в настройках панели.

## fail2ban

Два jail'а из коробки:

| Jail | Условие | Бан |
|------|---------|-----|
| `nginx-4xx` | >20 ошибок 4xx за 5 мин | 30 мин |
| `nginx-panel-auth` | >10 ошибок 401/403 на панели за 5 мин | 2 ч |
