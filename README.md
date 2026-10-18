# ssb-gemini-v6-patch — Gemini и Google через IPv6 для Secret-Sing-Box

Патч-скрипт для серверов [Secret-Sing-Box (ssb)](https://github.com/A-Zuro/Secret-Sing-Box):
направляет трафик **Google / Gemini** через **глобальный IPv6** сервера.

Аналог решения для Xray / 3X-UI (outbound `freedom` + `sendThrough` + routing rule)
из статьи «Gemini — решение для РФ через ipv6» (checkvpn.net), адаптированный под
sing-box 1.12+ и конфиги, которые генерирует ssb.

## Зачем это нужно

Google-сервисы (в том числе Gemini) могут блокироваться, отвечать капчей или
отказывать при выходе с IPv4 адресов дата-центров, тогда как с IPv6 того же
сервера всё работает. Скрипт добавляет в серверный конфиг sing-box отдельный
outbound, который соединяется с Google с исходным адресом вашего IPv6, и
маршрутизирует на него Google-домены.

Схема клиента не меняется (клиент → прокси → сервер), меняется только выход
сервера для Google-доменов. **Клиентские конфиги ssb трогать не нужно.**

## Соответствие Xray → sing-box

| Xray / 3X-UI (статья) | sing-box (этот патч) |
|---|---|
| outbound `freedom` | outbound `direct` |
| `sendThrough: <IPv6>` | `inet6_bind_address: <IPv6>` |
| `settings.domainStrategy: "UseIPv6"` | `domain_resolver: { server, strategy: "ipv6_only" }` |
| rule `geosite:google` | `rule_set: ["google"]` (geosite-google.srs) |
| rule `domain:gemini.google.com` + `domain:generativelanguage.googleapis.com` | `domain: [...]` |

## Что делает скрипт

1. **Определяет глобальный IPv6** сервера автоматически:
   `ip -6 route get 2001:4860:4860::8888` → `src` (при нескольких адресах берётся
   тот, которым сервер ходит в интернет). Можно задать вручную: `GEMINI_IPV6=...`.
2. **Делает бэкап** `/etc/sing-box/config.json` в `/root/bak-singbox/config.json.bak-<дата>`
   (хранит последние 10 копий).
3. **Вносит три изменения в конфиг** (идемпотентно — повторный запуск не плодит дубликаты):
   * rule-set `google` → `geosite-google.srs` (копирует из webroot ssb или докачивает с SagerNet);
   * outbound `gemini-v6`: `direct` + `inet6_bind_address` + `domain_resolver`
     со стратегией `ipv6_only` (аналог `UseIPv6`);
   * два routing-правила (перед остальными outbound-правилами):
     * `rule_set: ["google"]` → `gemini-v6`
     * `domain: ["gemini.google.com", "generativelanguage.googleapis.com"]` → `gemini-v6`
4. **Проверяет конфиг** через `sing-box check` — при ошибке автоматически
   откатывает бэкап.
5. **Перезагружает sing-box** (`systemctl reload`, fallback `systemctl restart`).

## Требования

* сервер с установленным [Secret-Sing-Box](https://github.com/A-Zuro/Secret-Sing-Box)
  (стандартный `/etc/sing-box/config.json`);
* **глобальный** IPv6 (не ULA/link-local) — без него скрипт завершится с ошибкой
  **до** каких-либо правок конфига;
* sing-box **1.12+** (в ssb по умолчанию новее), python3, iproute2, systemd.

## Установка

```bash
curl -fsSL -o /usr/local/sbin/ssb-gemini-v6-patch.sh \
  https://raw.githubusercontent.com/Anton98567/ssb-gemini-v6-patch/main/ssb-gemini-v6-patch.sh
chmod 700 /usr/local/sbin/ssb-gemini-v6-patch.sh
```

## Применение

```bash
ssb-gemini-v6-patch.sh apply    # добавить или обновить патч (режим по умолчанию)
ssb-gemini-v6-patch.sh status   # показать текущее состояние патча
ssb-gemini-v6-patch.sh remove   # убрать outbound и правила, добавленные патчем
```

Пример вывода `apply` (адреса условные):

```text
[gemini-v6-patch] detected IPv6: 2001:db8:1::10
[gemini-v6-patch] backup: /root/bak-singbox/config.json.bak-20261018-120000
rule_set added: google -> /var/www/<RULESET_DIR>/geosite-google.srs
outbound added: gemini-v6 inet6_bind_address=2001:db8:1::10 dns=dns-main
rules added at 3 : [{"rule_set": ["google"], "outbound": "gemini-v6"}, {"domain": ["gemini.google.com", "generativelanguage.googleapis.com"], "outbound": "gemini-v6"}]
config written: /etc/sing-box/config.json
[gemini-v6-patch] sing-box check: OK
[gemini-v6-patch] service sing-box reloaded
[gemini-v6-patch] done: gemini traffic -> gemini-v6 -> IPv6
```

### Переменные окружения

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `GEMINI_IPV6` | исходный IPv6, если не определять автоматически | автоопределение |
| `GEMINI_CONFIG` | путь к конфигу sing-box | `/etc/sing-box/config.json` |
| `GEMINI_BACKUP_DIR` | каталог бэкапов | `/root/bak-singbox` |
| `GEMINI_SERVICE` | имя systemd-юнита | `sing-box` |

Пример: `GEMINI_IPV6=2001:db8:1::10 ssb-gemini-v6-patch.sh apply`

## Итоговый фрагмент конфига

```json
"outbounds": [
  {
    "type": "direct",
    "tag": "gemini-v6",
    "inet6_bind_address": "2001:db8:1::10",
    "domain_resolver": { "server": "dns-main", "strategy": "ipv6_only" }
  }
],
"route": {
  "rules": [
    { "rule_set": ["google"], "outbound": "gemini-v6" },
    { "domain": ["gemini.google.com", "generativelanguage.googleapis.com"], "outbound": "gemini-v6" }
  ],
  "rule_set": [
    { "tag": "google", "type": "local", "format": "binary",
      "path": "/var/www/<RULESET_DIR>/geosite-google.srs" }
  ]
}
```

Правила ставятся до остальных outbound-правил конфига ssb (например, до правила,
отправляющего часть трафика в WARP), поэтому Gemini-соединения гарантированно
попадают в `gemini-v6`.

## Проверка работы

**1. Лог sing-box** (`/var/lib/sing-box/box.log` или `journalctl -u sing-box`):

```text
INFO inbound/trojan[trojan-in]: [user] inbound connection to gemini.google.com:443
INFO outbound/direct[gemini-v6]: outbound connection to gemini.google.com:443
```

Для не-Google доменов вместо `gemini-v6` будет обычный `direct`.

**2. Clash API** (включён в конфигах ssb по умолчанию):

```bash
SECRET=$(jq -r '.experimental.clash_api.secret' /etc/sing-box/config.json)
curl -s -H "Authorization: Bearer $SECRET" http://127.0.0.1:9090/proxies \
  | jq -r '.proxies | keys[]'
curl -s -H "Authorization: Bearer $SECRET" \
  "http://127.0.0.1:9090/proxies/gemini-v6/delay?url=https://gemini.google.com/generate_204&timeout=8000"
```

В первом ответе должен появиться `gemini-v6`, во втором — `{"delay": ...}`.

**3. Исходный адрес соединений:**

```bash
ss -tnp | grep sing-box
```

TCP-соединения к Google должны идти с локального адреса вашего глобального IPv6.

## Восстановление

```bash
ls -1t /root/bak-singbox/
cp -a /root/bak-singbox/config.json.bak-<дата> /etc/sing-box/config.json
systemctl reload sing-box
```

Либо `ssb-gemini-v6-patch.sh remove` — уберёт только элементы, добавленные патчем.

## Совместимость и нюансы

* **После полной переустановки ssb** конфиг генерируется заново — просто повторите
  `ssb-gemini-v6-patch.sh apply`. Управление пользователями через `ssb`/`sbmanager`
  конфиг не перетирает (правки точечные), патч сохраняется.
* Поле `domain_resolver.strategy` в sing-box 1.14 помечено как deprecated
  (план удаления — 1.16). На sing-box 1.12–1.15 работает; при переходе на 1.16+
  поле `strategy` в скрипте нужно будет убрать или заменить на новую механику
  выбора семейства адресов.
* Если глобальных IPv6 несколько, берётся адрес исходящего маршрута
  (`ip -6 route get`) — обычно основной адрес интерфейса.
* Скрипт идемпотентен: повторный `apply` сначала удаляет свои элементы
  (outbound с тегом `gemini-v6`, его правила, свой rule-set) и добавляет заново.
* Патч работает на стороне **сервера**: клиентские конфиги ssb уже отправляют
  Google (`rule_set: google`) в прокси, а сервер выбирает для него IPv6-выход.

## Что именно проверялось

* `sing-box check` на sing-box 1.14.x;
* сквозной тест через реальный trojan-inbound ssb: `gemini.google.com` →
  outbound `gemini-v6` (HTTP 204), контрольный домен → outbound `direct`;
* исходный адрес TCP-соединений к Google равен глобальному IPv6 сервера;
* идемпотентность повторного запуска (без дубликатов правил и outbounds).
