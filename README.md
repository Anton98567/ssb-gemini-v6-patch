# ssb-gemini-v6-patch — Gemini, Antigravity и Google через IPv6 для Secret-Sing-Box

Патч-скрипт для серверов [Secret-Sing-Box (ssb)](https://github.com/A-Zuro/Secret-Sing-Box):
направляет трафик **Google / Gemini / Google Antigravity** через **глобальный IPv6** сервера.

Аналог решения для Xray / 3X-UI (outbound `freedom` + `sendThrough` + routing rule)
из статьи «Gemini — решение для РФ через ipv6» (checkvpn.net), адаптированный под
sing-box 1.12+ и конфиги, которые генерирует ssb.

## Зачем это нужно

Google-сервисы (в том числе Gemini и Google Antigravity) могут блокироваться, отвечать капчей
или отказывать при выходе с IPv4 адресов дата-центров, тогда как с IPv6 того же сервера всё
работает. Скрипт добавляет в серверный конфиг sing-box отдельный outbound, который соединяется
с Google с исходным адресом вашего IPv6, и маршрутизирует на него Google-домены.

Схема клиента не меняется (клиент → прокси → сервер), меняется только выход
сервера для Google-доменов. **Клиентские конфиги ssb трогать не нужно.**

## Соответствие Xray → sing-box

| Xray / 3X-UI (статья) | sing-box (этот патч) |
|---|---|
| outbound `freedom` | outbound `direct` |
| `sendThrough: <IPv6>` | `inet6_bind_address: <IPv6>` |
| `settings.domainStrategy: "UseIPv6"` | `domain_resolver: { server, strategy: "ipv6_only" }` |
| rule `geosite:google` | `rule_set: ["google"]` (geosite-google.srs) |
| rule `domain:gemini.google.com` + `domain:generativelanguage.googleapis.com` | `domain: [...]` (Gemini + Antigravity) |
| — (нет аналога) | outbound `gemini-v4`: обычный `direct` для Google-хостов без AAAA |

## Что делает скрипт

1. **Берёт глобальный IPv6 сервера** (приоритет — от ручного ввода к автоопределению):
   1. аргумент командной строки: `ssb-gemini-v6-patch.sh apply 2001:db8:1::10`;
   2. переменная окружения `GEMINI_IPV6=...`;
   3. **интерактивный запрос** — скрипт показывает все глобальные IPv6 сервера
      и просит ввести нужный (номер из списка или полный адрес);
   4. автоопределение `ip -6 route get 2001:4860:4860::8888` → `src`
      — только если запуск не из терминала (cron/ansible) или как значение по умолчанию в запросе.

   Автоопределение при нескольких адресах может выбрать не тот, поэтому
   **рекомендуется вводить IPv6 вручную**. Любой введённый адрес валидируется
   (только глобальный IPv6, допускается суффикс `/64` или `%zone` — они отбрасываются),
   неверный адрес отклоняется с повторным запросом.
2. **Делает бэкап** `/etc/sing-box/config.json` в `/root/bak-singbox/config.json.bak-<дата>`
   (хранит последние 10 копий).
3. **Вносит изменения в конфиг** (идемпотентно — повторный запуск не плодит дубликаты):
   * rule-set `google` → `geosite-google.srs` (копирует из webroot ssb или докачивает с SagerNet);
   * outbound `gemini-v6`: `direct` + `inet6_bind_address` + `domain_resolver`
     со стратегией `ipv6_only` (аналог `UseIPv6`);
   * outbound `gemini-v4`: обычный `direct` без bind — для Google-хостов без AAAA
     (см. раздел «Google Antigravity»);
   * три routing-правила (перед остальными outbound-правилами):
     * `domain_suffix: ["antigravity.google"]` → `gemini-v4`
     * `rule_set: ["google"]` → `gemini-v6`
     * `domain: [...]` → `gemini-v6` (Gemini + Antigravity, полный список — ниже)
4. **Проверяет конфиг** через `sing-box check` — при ошибке автоматически
   откатывает бэкап.
5. **Перезагружает sing-box** (`systemctl reload`, fallback `systemctl restart`).
6. **Прогоняет тесты связи с Gemini и Antigravity по IPv6** (13 проверок, см. ниже) — чтобы
   убедиться, что всё работает на 100%. Отдельный запуск без правок конфига:
   `ssb-gemini-v6-patch.sh test`.

## Что покрывается: Gemini, AI Studio и другие сервисы Google

Домены Google берутся **не вручную**, а из rule-set `google` (`geosite-google.srs`,
сборка [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite) из
[domain-list-community](https://github.com/v2fly/domain-list-community)) —
категория `google` содержит суффиксы `google.com`, `googleapis.com`, `gstatic.com`,
`googleusercontent.com` и сотни других, то есть покрывает **все поддомены**, включая AI Studio.

| Сервис / домен | Как покрывается |
|---|---|
| `aistudio.google.com` (Google AI Studio) | суффикс `google.com` в rule-set `google` |
| `makersuite.google.com` (старый URL AI Studio) | суффикс `google.com` |
| `gemini.google.com`, `deepmind.google` | суффикс `google.com` |
| `accounts.google.com` (логин Google) | суффикс `google.com` |
| `alkalimakersuite-pa.googleapis.com` (API-бэкенд AI Studio) | суффикс `googleapis.com` |
| `generativelanguage.googleapis.com` (Gemini API) | суффикс `googleapis.com` + явное правило патча |
| `gstatic.com`, `googleusercontent.com` (ресурсы UI) | свои суффиксы в rule-set `google` |

Проверено на живом сервере (реальный прогон):

```text
https://aistudio.google.com/        -> HTTP 302 (reachable via IPv6)
https://aistudio.google.com/app     -> HTTP 302 (reachable via IPv6)
aistudio.google.com через outbound gemini-v6 -> {"delay": 231} ms
gemini.google.com  через outbound gemini-v6 -> {"delay": 49} ms
```

То есть весь стек AI Studio — веб-интерфейс, API-бэкенд, логин и статика —
уходит через глобальный IPv6 без дополнительных правок. **Важно:** правило
работает для трафика, который приходит на сервер через прокси-клиент ssb;
в клиентских конфигах Google должен быть направлен в прокси (в ssb это
правило `rule_set: google` уже есть — как и в этом патче).

## Google Antigravity

[Google Antigravity](https://antigravity.google.com/) — агентная IDE и CLI (`agy`) от Google
на моделях Gemini (развитие идей Gemini CLI / Firebase Studio). Весь его бэкенд —
Google-инфраструктура, поэтому Antigravity покрывается теми же правилами, что и Gemini:
как rule-set `google`, так и явным списком доменов в патче.

Домены Antigravity (по [официальной странице network allowlist](https://antigravity.google/docs/enterprise)):

| Сервис / домен | Назначение | Как покрывается |
|---|---|---|
| `antigravity.google.com` | веб-интерфейс / Remote Control | суффикс `google.com` + явное правило патча |
| `cloudcode-pa.googleapis.com` | Code Assist backend (основной) | суффикс `googleapis.com` + явное правило |
| `daily-cloudcode-pa.googleapis.com` | canary-бэкенд Code Assist | суффикс `googleapis.com` + явное правило |
| `businessaicode.googleapis.com` (+ `*.us/eu.rep`, `*.mtls`) | AI Developer Tools: sign-in, каталог моделей | суффикс `googleapis.com` + явное правило |
| `aiplatform.googleapis.com` (+ `*.us/eu.rep`, `*.mtls`) | Gemini Enterprise API (Vertex AI) | суффикс `googleapis.com` + явное правило |
| `discoveryengine.googleapis.com` (us/eu, mtls) | Discovery Engine | суффикс `googleapis.com` + явное правило |
| `oauth2.googleapis.com`, `accounts.google.com` | логин Google | суффиксы `googleapis.com` / `google.com` |

Явный список доменов Antigravity в правиле патча:

```text
antigravity.google.com cloudcode-pa.googleapis.com daily-cloudcode-pa.googleapis.com
businessaicode.googleapis.com aiplatform.googleapis.com discoveryengine.googleapis.com
```

### Особый случай: antigravity.google (документация) — хост без IPv6

Сайт документации `antigravity.google` (и `www.antigravity.google`) имеет **только A-запись**
(IPv6/AAAA нет). При этом rule-set `google` (geosite:google) включает весь TLD `.google`,
то есть этот домен попадал бы в outbound `gemini-v6` с `domain_resolver: ipv6_only` —
такое соединение не установится (резолвится только AAAA). Поэтому патч добавляет
**fallback-outbound `gemini-v4`** (обычный `direct` без bind) и правило

```json
{ "domain_suffix": ["antigravity.google"], "outbound": "gemini-v4" }
```

**перед** правилом `rule_set: google`. Список хостов без AAAA задаётся переменной
`GEMINI_IPV4_ONLY_DOMAINS` (по умолчанию `antigravity.google`; пустая строка — fallback отключён).

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
ssb-gemini-v6-patch.sh test     # проверить связь с Gemini по IPv6 (без правок конфига)
```

### Как указать IPv6

```bash
ssb-gemini-v6-patch.sh apply 2001:db8:1::10      # аргументом (самый простой способ)
GEMINI_IPV6=2001:db8:1::10 ssb-gemini-v6-patch.sh apply
ssb-gemini-v6-patch.sh apply                     # интерактивный запрос адреса
```

Интерактивный запрос (когда `apply` запущен из терминала):

```text
Global IPv6 addresses found on this server:
  1) 2001:db8:1::10   <- auto-detected
  2) 2001:db8:2::20
Enter the IPv6 of this server (number or full address) [default: 2001:db8:1::10]: 2
[gemini-v6-patch] IPv6 (manual input): 2001:db8:2::20
```

В поле можно ввести **номер** адреса из списка или **полный адрес** (например
`2001:db8:2::20` или `2001:db8:2::20/64`). Enter берёт значение по умолчанию
(автоопределённый адрес). Невалидный ввод (например, `fe80::…` или ULA `fd00::…`)
отклоняется, и запрос повторяется.

### Тесты связи с Gemini и Antigravity по IPv6

`ssb-gemini-v6-patch.sh test` (и автоматически в конце `apply`) прогоняет 13 проверок —
они показывают, что Gemini и Antigravity доступны именно через ваш IPv6, «на 100%»:

1. IPv6 назначен на интерфейсе сервера (иначе `inet6_bind_address` не сможет bind);
2. у `gemini.google.com` есть AAAA-запись (в `domain_resolver` стоит `ipv6_only`);
3. у `antigravity.google.com` есть AAAA-запись;
4. у `cloudcode-pa.googleapis.com` (Code Assist Antigravity) есть AAAA-запись;
5. `https://gemini.google.com/generate_204` через IPv6 → **HTTP 204**;
6. `https://antigravity.google.com/generate_204` через IPv6 → **HTTP 204**;
7. `https://www.google.com/generate_204` через IPv6 → **HTTP 204** (контрольная точка);
8. `https://generativelanguage.googleapis.com/` через IPv6 отвечает (2xx–4xx;
   404 на корне — норма, важна сама доступность API Gemini);
9. `https://cloudcode-pa.googleapis.com/` через IPv6 отвечает (2xx–4xx; 404 на корне — норма);
10. исходящий адрес соединения равен вашему IPv6 (нет NAT/маскарада) —
    проверяется по `api6.ipify.org` / `ifconfig.me`;
11. **сквозной тест через сам outbound `gemini-v6`** sing-box: запрос к
    `gemini.google.com/generate_204` через Clash API (`experimental.clash_api`)
    и замер задержки;
12. сквозной тест через outbound `gemini-v6` → `antigravity.google.com/generate_204`;
13. сквозной тест через outbound `gemini-v4` → `antigravity.google`
    (docs, IPv4-only хост, fallback). Если fallback отключён или outbound
    `gemini-v4` в конфиге отсутствует — проверка пропускается.

Если `clash_api` в конфиге не включён — проверки 11–13 помечаются `[SKIP]`.

Пример вывода (реальный прогон на рабочем сервере, IPv6 замаскирован):

```text
=== connectivity tests to Gemini/Google Antigravity (source IPv6: 2001:db8:1::10) ===
  [OK]   IPv6 2001:db8:1::10 is assigned on this server
  [OK]   DNS: gemini.google.com resolves to IPv6 (AAAA)
  [OK]   DNS: antigravity.google.com resolves to IPv6 (AAAA)
  [OK]   DNS: cloudcode-pa.googleapis.com resolves to IPv6 (AAAA)
  [OK]   gemini.google.com/generate_204 via IPv6 -> HTTP 204
  [OK]   antigravity.google.com/generate_204 via IPv6 -> HTTP 204
  [OK]   www.google.com/generate_204 via IPv6 -> HTTP 204
  [OK]   generativelanguage.googleapis.com via IPv6 -> HTTP 404 (reachable)
  [OK]   cloudcode-pa.googleapis.com via IPv6 -> HTTP 404 (reachable)
  [OK]   outbound source address is 2001:db8:1::10 (no NAT)
  [OK]   sing-box outbound gemini-v6 -> gemini.google.com works (delay 71 ms)
  [OK]   sing-box outbound gemini-v6 -> antigravity.google.com works (delay 48 ms)
  [OK]   sing-box outbound gemini-v4 -> antigravity.google (docs, IPv4-only host) works (delay 51 ms)
--- tests: OK=13 FAIL=0 SKIP=0
```

* Итог `OK=13 FAIL=0` = всё работает; при любом `[FAIL]` скрипт завершается
  с кодом 1 и пишет, какая именно проверка не прошла.
* `test` сам берёт IPv6 из настроенного outbound `gemini-v6` (правки конфига
  не делает); можно передать адрес и вручную: `ssb-gemini-v6-patch.sh test 2001:db8:1::10`.
* Автотест в конце `apply` отключается переменной `GEMINI_SKIP_TEST=1`
  (например, в cron/ansible, где доступ в интернет ограничен).
* Таймаут HTTP-проверок — `GEMINI_TEST_TIMEOUT` (по умолчанию 15 секунд).

Пример вывода `apply` (реальный прогон, IPv6 замаскирован):

```text
[gemini-v6-patch] IPv6 (command-line argument): 2001:db8:1::10
[gemini-v6-patch] backup: /root/bak-singbox/config.json.bak-20261023-091605
rule_set exists: google -> /var/www/<RULESET_DIR>/geosite-google.srs
outbound added: gemini-v6 inet6_bind_address=2001:db8:1::10 dns=dns-main
outbound added: gemini-v4 (plain direct for hosts without AAAA)
rules added at 3 : [{"domain_suffix": ["antigravity.google"], "outbound": "gemini-v4"}, {"rule_set": ["google"], "outbound": "gemini-v6"}, {"domain": ["gemini.google.com", "generativelanguage.googleapis.com", "antigravity.google.com", "cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com", "businessaicode.googleapis.com", "aiplatform.googleapis.com", "discoveryengine.googleapis.com"], "outbound": "gemini-v6"}]
config written: /etc/sing-box/config.json
[gemini-v6-patch] sing-box check: OK
[gemini-v6-patch] service sing-box reloaded
[gemini-v6-patch] done: gemini + antigravity traffic -> gemini-v6 -> IPv6
```

### Переменные окружения

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `GEMINI_IPV6` | исходный IPv6 (имеет приоритет над запросом и автоопределением) | интерактивный запрос |
| `GEMINI_CONFIG` | путь к конфигу sing-box | `/etc/sing-box/config.json` |
| `GEMINI_BACKUP_DIR` | каталог бэкапов | `/root/bak-singbox` |
| `GEMINI_SERVICE` | имя systemd-юнита | `sing-box` |
| `GEMINI_IPV4_ONLY_DOMAINS` | Google-хосты без AAAA, идущие через `gemini-v4` | `antigravity.google` (пустая строка — отключить fallback) |

Пример: `GEMINI_IPV6=2001:db8:1::10 ssb-gemini-v6-patch.sh apply`

## Итоговый фрагмент конфига

```json
"outbounds": [
  {
    "type": "direct",
    "tag": "gemini-v6",
    "inet6_bind_address": "2001:db8:1::10",
    "domain_resolver": { "server": "dns-main", "strategy": "ipv6_only" }
  },
  { "type": "direct", "tag": "gemini-v4" }
],
"route": {
  "rules": [
    { "domain_suffix": ["antigravity.google"], "outbound": "gemini-v4" },
    { "rule_set": ["google"], "outbound": "gemini-v6" },
    { "domain": ["gemini.google.com", "generativelanguage.googleapis.com",
                 "antigravity.google.com", "cloudcode-pa.googleapis.com",
                 "daily-cloudcode-pa.googleapis.com", "businessaicode.googleapis.com",
                 "aiplatform.googleapis.com", "discoveryengine.googleapis.com"],
      "outbound": "gemini-v6" }
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
* Если глобальных IPv6 несколько — **не полагайтесь на автоопределение**: скрипт
  покажет список адресов и попросит выбрать нужный вручную (либо задайте его
  аргументом/`GEMINI_IPV6`). В режиме без терминала (cron) берётся адрес
  исходящего маршрута (`ip -6 route get`).
* Скрипт идемпотентен: повторный `apply` сначала удаляет свои элементы
  (outbounds `gemini-v6` и `gemini-v4`, их правила, свой rule-set) и добавляет заново.
* Патч работает на стороне **сервера**: клиентские конфиги ssb уже отправляют
  Google (`rule_set: google`) в прокси, а сервер выбирает для него IPv6-выход.

## Что именно проверялось

* `sing-box check` на sing-box 1.14.x (Ubuntu 24.04, bash 5.2);
* сквозной тест через реальный trojan-inbound ssb: `gemini.google.com` →
  outbound `gemini-v6` (HTTP 204), контрольный домен → outbound `direct`;
* исходный адрес TCP-соединений к Google равен глобальному IPv6 сервера;
* идемпотентность повторного запуска (без дубликатов правил и outbounds);
* ручной ввод IPv6: выбор номера из списка, ввод полного адреса и адреса с `/64`,
  отклонение невалидного ввода (`fe80::…`, ULA) с повторным запросом,
  режимы `apply <IPv6>` и `GEMINI_IPV6=...`, а также `remove` → повторный `apply`;
* режим `test` и автотест в конце `apply`: 13 проверок связи с Gemini и Antigravity
  по IPv6 (назначение адреса, AAAA, `generate_204` → 204, доступность API Gemini
  и Code Assist Antigravity, исходящий адрес без NAT, сквозные тесты через outbound
  `gemini-v6` и fallback `gemini-v4` с замером задержки) — `OK=13 FAIL=0 SKIP=0`
  на рабочем сервере (реальный прогон 23.10.2026, sing-box 1.14.3, Ubuntu 24.04);
* Google Antigravity: `antigravity.google.com/generate_204` через глобальный IPv6
  → HTTP 204, `cloudcode-pa.googleapis.com` → HTTP 404 (reachable), сквозные тесты
  через outbound `gemini-v6` (48 ms) и `gemini-v4` для docs-сайта (51 ms);
* хосты без AAAA (`antigravity.google`): правило `domain_suffix → gemini-v4`
  стоит **до** `rule_set: google` — соединение к docs-сайту устанавливается,
  проверено сквозным тестом через outbound `gemini-v4`;
* Google AI Studio: `aistudio.google.com` доступен через глобальный IPv6
  (HTTP 302) и проходит через outbound `gemini-v6` (сквозной тест с замером
  задержки) — домен покрывается rule-set `google` (geosite:google).
