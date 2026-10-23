#!/usr/bin/env bash
set -euo pipefail

CONFIG="${GEMINI_CONFIG:-/etc/sing-box/config.json}"
BACKUP_DIR="${GEMINI_BACKUP_DIR:-/root/bak-singbox}"
SERVICE="${GEMINI_SERVICE:-sing-box}"
TAG="gemini-v6"
TAG4="gemini-v4"
RULESET_TAG="google"
SRS_NAME="geosite-google.srs"
SRS_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs"
PROBE="2001:4860:4860::8888"
GEMINI_DOMAINS="gemini.google.com generativelanguage.googleapis.com"
# Google Antigravity (app/CLI/IDE): web endpoint + Code Assist backends.
# All of them have AAAA records and go via the IPv6 outbound; the rest of the
# Antigravity stack (oauth2.googleapis.com, *.rep.googleapis.com, ...) is
# covered by the rule-set "google" (geosite:google).
ANTIGRAVITY_DOMAINS="antigravity.google.com cloudcode-pa.googleapis.com daily-cloudcode-pa.googleapis.com businessaicode.googleapis.com aiplatform.googleapis.com discoveryengine.googleapis.com"
# Google hosts WITHOUT an AAAA record (A-only): the IPv6 outbound resolves with
# ipv6_only and cannot connect to them, so they go via a plain direct fallback.
# Set GEMINI_IPV4_ONLY_DOMAINS="" to disable the fallback rule entirely.
IPV4_ONLY_DOMAINS="${GEMINI_IPV4_ONLY_DOMAINS-antigravity.google}"
MODE="${1:-apply}"
ARG_IPV6="${2:-}"

log() { echo "[gemini-v6-patch] $*"; }
die() { echo "[gemini-v6-patch] ERROR: $*" >&2; exit 1; }

usage() {
    echo "usage: $0 [apply|remove|status|test] [IPv6]"
    echo "  apply [IPv6] - add or refresh gemini+antigravity via IPv6 patch in ${CONFIG} (default)"
    echo "  remove       - drop outbound/rules added by this patch"
    echo "  status       - show current patch state"
    echo "  test  [IPv6] - check IPv6 connectivity to Gemini/Google Antigravity (no config changes)"
    echo
    echo "IPv6 selection (apply/test), in priority order:"
    echo "  1) argument:    $0 apply 2001:db8::1"
    echo "  2) env var:     GEMINI_IPV6=2001:db8::1 $0 apply"
    echo "  3) interactive prompt (asks for the IPv6 of this server)"
    echo "  4) auto-detection (ip -6 route get $PROBE) as a last resort"
    echo
    echo "apply runs the same connectivity tests at the end (skip: GEMINI_SKIP_TEST=1)"
    echo
    echo "Google Antigravity (antigravity.google.com, cloudcode-pa.googleapis.com, ...)"
    echo "is routed via the same IPv6 outbound. IPv4-only Google hosts (no AAAA, e.g. the"
    echo "antigravity.google docs site) go via the $TAG4 direct fallback;"
    echo "override the list with GEMINI_IPV4_ONLY_DOMAINS=\"...\" (empty = disable fallback)"
}

# Normalizes and validates an IPv6 address -> prints compressed form.
# Accepts optional /prefix or %zone suffix. Fails on non-global addresses.
normalize_ipv6() {
    python3 -c '
import ipaddress, sys
raw = sys.argv[1].strip().split("/")[0].split("%")[0]
try:
    a = ipaddress.ip_address(raw)
except ValueError:
    sys.exit("invalid IP address: %s" % raw)
if a.version != 6:
    sys.exit("not an IPv6 address: %s" % raw)
if not a.is_global:
    sys.exit("not a global IPv6: %s" % raw)
print(a.compressed)
' "$1"
}

# Auto-detected default (may be empty or wrong on multi-address hosts).
auto_detect_ipv6() {
    local ip=""
    ip="$(ip -6 route get "$PROBE" 2>/dev/null | sed -n 's/.*src \([0-9a-fA-F:]*\).*/\1/p' | head -1 || true)"
    if [[ -z "$ip" ]]; then
        ip="$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
    fi
    [[ -n "$ip" ]] || return 0
    normalize_ipv6 "$ip" 2>/dev/null || true
}

# All global IPv6 addresses of the server (deduplicated, validated).
list_ipv6_candidates() {
    {
        ip -6 route get "$PROBE" 2>/dev/null | sed -n 's/.*src \([0-9a-fA-F:]*\).*/\1/p' | head -1
        ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    } | awk 'NF && !seen[$0]++' | while read -r a; do
        normalize_ipv6 "$a" 2>/dev/null || true
    done
}

# Sets global IPV6 (and logs its source). Interactive when run from a terminal.
choose_ipv6() {
    local input="" normalized="" auto="" src=""

    if [[ -n "$ARG_IPV6" ]]; then
        input="$ARG_IPV6"
        src="command-line argument"
    elif [[ -n "${GEMINI_IPV6:-}" ]]; then
        input="$GEMINI_IPV6"
        src="GEMINI_IPV6"
    fi

    if [[ -n "$input" ]]; then
        normalized="$(normalize_ipv6 "$input")" || die "invalid IPv6 ($src): $input"
        IPV6="$normalized"
        log "IPv6 ($src): $IPV6"
        return 0
    fi

    auto="$(auto_detect_ipv6 || true)"

    if [[ -t 0 ]]; then
        local -a candidates=()
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && candidates+=("$line")
        done < <(list_ipv6_candidates)
        echo "Global IPv6 addresses found on this server:"
        local i
        for i in "${!candidates[@]}"; do
            if [[ "${candidates[$i]}" == "$auto" ]]; then
                printf '  %d) %s   <- auto-detected\n' "$((i + 1))" "${candidates[$i]}"
            else
                printf '  %d) %s\n' "$((i + 1))" "${candidates[$i]}"
            fi
        done
        [[ ${#candidates[@]} -eq 0 ]] && echo "  (none found)"
        local hint="${auto:-none}"
        while true; do
            input=""
            read -r -p "Enter the IPv6 of this server (number or full address) [default: $hint]: " input || true
            if [[ -z "$input" ]]; then
                input="$auto"
            elif [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#candidates[@]} )); then
                input="${candidates[$((input - 1))]}"
            fi
            if [[ -z "$input" ]]; then
                echo "nothing selected - type an IPv6 address (or Ctrl-C to abort)"
                continue
            fi
            if normalized="$(normalize_ipv6 "$input")"; then
                break
            fi
        done
    else
        [[ -n "$auto" ]] || die "no global IPv6 found (set GEMINI_IPV6=<ipv6> or run interactively)"
        normalized="$auto"
    fi

    IPV6="$normalized"
    log "IPv6 (${src:-manual input}): $IPV6"
}

# ---------- connectivity tests ----------

TESTS_OK=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TEST_IP=""

_ok()   { TESTS_OK=$((TESTS_OK + 1));         printf '  [OK]   %s\n' "$1"; }
_bad()  { TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  [FAIL] %s\n' "$1"; }
_skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf '  [SKIP] %s\n' "$1"; }

# Test hosts (Gemini + Google Antigravity): they must resolve to IPv6 (AAAA),
# since the outbound resolves its destinations with ipv6_only.
DNS_TEST_HOSTS="gemini.google.com antigravity.google.com cloudcode-pa.googleapis.com"

configured_ipv6() {
    python3 - <<'PY'
import json, os
try:
    cfg = json.load(open(os.environ["GEMINI_CONFIG"]))
except Exception:
    raise SystemExit(0)
for o in cfg.get("outbounds", []):
    if o.get("tag") == os.environ["GEMINI_TAG"] and o.get("inet6_bind_address"):
        print(o["inet6_bind_address"])
        break
PY
}

clash_api_info() {
    python3 - <<'PY'
import json, os
try:
    cfg = json.load(open(os.environ["GEMINI_CONFIG"]))
except Exception:
    raise SystemExit(0)
api = (cfg.get("experimental") or {}).get("clash_api") or {}
if api.get("external_controller"):
    print(api["external_controller"], api.get("secret", ""))
PY
}

# http_code <url> <source_ipv6|empty> -> prints HTTP code ("000" on failure)
http_code() {
    local url="$1" ip="${2:-}" out=""
    local args=(-6 -s -o /dev/null -w '%{http_code}' --max-time "${GEMINI_TEST_TIMEOUT:-15}")
    if [[ -n "$ip" ]]; then
        args+=(--interface "$ip")
    fi
    out="$(curl "${args[@]}" "$url" 2>/dev/null || true)"
    printf '%s' "${out:-000}"
}

# DNS: <host> must have an AAAA record (the outbound resolves with ipv6_only).
check_dns_aaaa() {
    local host="$1"
    if python3 -c 'import socket, sys; socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET6)' "$host" 2>/dev/null; then
        _ok "DNS: $host resolves to IPv6 (AAAA)"
    else
        _bad "DNS: $host has no IPv6 (AAAA) record"
    fi
}

# HTTP via the bound IPv6: <expect> is an exact code ("204") or "2xx-4xx" (reachable).
check_http() {
    local label="$1" url="$2" expect="$3" code=""
    code="$(http_code "$url" "$TEST_IP")"
    if [[ "$expect" == "2xx-4xx" ]]; then
        if [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
            _ok "$label via IPv6 -> HTTP $code (reachable)"
        else
            _bad "$label via IPv6 -> HTTP $code (unreachable)"
        fi
    elif [[ "$code" == "$expect" ]]; then
        _ok "$label via IPv6 -> HTTP $code"
    else
        _bad "$label via IPv6 -> HTTP $code (expected $expect)"
    fi
}

# True if the config has an outbound with the given tag.
has_outbound() {
    python3 -c '
import json, os, sys
try:
    cfg = json.load(open(os.environ["GEMINI_CONFIG"]))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if any(o.get("tag") == sys.argv[1] for o in cfg.get("outbounds", [])) else 1)
' "$1"
}

# End-to-end request via the sing-box outbound itself (Clash API delay test).
check_outbound_delay() {
    local outbound="$1" label="$2" url="$3"
    local url_enc="" ci="" ctrl="" secret="" resp="" delay="" msg=""
    url_enc="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$url")"
    ci="$(clash_api_info || true)"
    if [[ -z "$ci" ]]; then
        _skip "test via sing-box outbound $outbound -> $label (clash_api is not enabled in ${CONFIG})"
        return 0
    fi
    ctrl="${ci%% *}"
    secret="${ci#* }"
    [[ "$secret" == "$ctrl" ]] && secret=""
    local cargs=(-s --max-time 15)
    if [[ -n "$secret" ]]; then
        cargs+=(-H "Authorization: Bearer $secret")
    fi
    resp="$(curl "${cargs[@]}" "http://$ctrl/proxies/$outbound/delay?url=$url_enc&timeout=10000" 2>/dev/null || true)"
    delay="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(0)
print(d.get("delay") or "")
' "$resp" 2>/dev/null || true)"
    if [[ -n "$delay" ]]; then
        _ok "sing-box outbound $outbound -> $label works (delay ${delay} ms)"
    else
        msg="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("message") or d.get("error") or sys.argv[1][:150])
except Exception:
    print(sys.argv[1][:150] or "no response from clash_api")
' "$resp" 2>/dev/null || true)"
        _bad "sing-box outbound $outbound -> $label failed: $msg"
    fi
}

run_tests() {
    TEST_IP="$1"
    TESTS_OK=0
    TESTS_FAILED=0
    TESTS_SKIPPED=0

    echo "=== connectivity tests to Gemini/Google Antigravity (source IPv6: $TEST_IP) ==="

    # 1. address must be assigned on the server (inet6_bind_address binds to it)
    if ip -6 addr show 2>/dev/null | grep -Fq "$TEST_IP"; then
        _ok "IPv6 $TEST_IP is assigned on this server"
    else
        _bad "IPv6 $TEST_IP is NOT assigned on this server - outbound bind will fail"
    fi

    # 2. DNS: test hosts must have AAAA records (domain_resolver uses ipv6_only)
    local host
    for host in $DNS_TEST_HOSTS; do
        check_dns_aaaa "$host"
    done

    if ! command -v curl >/dev/null 2>&1; then
        _skip "HTTP tests (curl is not installed)"
    else
        # 3-4. Gemini and Antigravity web endpoints answer generate_204 with HTTP 204
        check_http "gemini.google.com/generate_204" "https://gemini.google.com/generate_204" "204"
        check_http "antigravity.google.com/generate_204" "https://antigravity.google.com/generate_204" "204"

        # 5. control endpoint (google.com)
        check_http "www.google.com/generate_204" "https://www.google.com/generate_204" "204"

        # 6-7. API backends (any 2xx-4xx proves reachability; 404 on / is normal)
        check_http "generativelanguage.googleapis.com" "https://generativelanguage.googleapis.com/" "2xx-4xx"
        check_http "cloudcode-pa.googleapis.com" "https://cloudcode-pa.googleapis.com/" "2xx-4xx"

        # 8. outbound source address must be exactly our IPv6 (no NAT/masquerade)
        local seen=""
        seen="$(curl -6 -s --interface "$TEST_IP" --max-time "${GEMINI_TEST_TIMEOUT:-15}" https://api6.ipify.org 2>/dev/null || true)"
        if [[ -z "$seen" ]]; then
            seen="$(curl -6 -s --interface "$TEST_IP" --max-time "${GEMINI_TEST_TIMEOUT:-15}" https://ifconfig.me 2>/dev/null || true)"
        fi
        if [[ -n "$seen" ]]; then
            local seen_n
            seen_n="$(normalize_ipv6 "$seen" 2>/dev/null || echo "$seen")"
            if [[ "$seen_n" == "$TEST_IP" ]]; then
                _ok "outbound source address is $TEST_IP (no NAT)"
            else
                _bad "outbound source is $seen_n, expected $TEST_IP (NAT/masquerade?)"
            fi
        else
            _skip "outbound source address check (no response from api6.ipify.org)"
        fi

        # 9-11. end-to-end via the sing-box outbounds themselves (Clash API delay tests)
        check_outbound_delay "$TAG" "gemini.google.com" "https://gemini.google.com/generate_204"
        check_outbound_delay "$TAG" "antigravity.google.com" "https://antigravity.google.com/generate_204"
        if has_outbound "$TAG4"; then
            check_outbound_delay "$TAG4" "antigravity.google (docs, IPv4-only host)" "https://antigravity.google/"
        fi
    fi

    echo "--- tests: OK=$TESTS_OK FAIL=$TESTS_FAILED SKIP=$TESTS_SKIPPED"
}

backup_config() {
    mkdir -p "$BACKUP_DIR"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG" "$BACKUP_DIR/config.json.bak-$ts"
    ls -1t "$BACKUP_DIR"/config.json.bak-* 2>/dev/null | tail -n +11 | xargs -r rm -f --
    log "backup: $BACKUP_DIR/config.json.bak-$ts"
}

check_and_reload() {
    if ! sing-box check -c "$CONFIG"; then
        local last
        last="$(ls -1t "$BACKUP_DIR"/config.json.bak-* 2>/dev/null | head -1 || true)"
        if [[ -n "$last" ]]; then
            cp -a "$last" "$CONFIG"
            log "restored: $last"
        fi
        die "sing-box check failed, config reverted"
    fi
    log "sing-box check: OK"
    systemctl reload "$SERVICE" 2>/dev/null || systemctl restart "$SERVICE"
    sleep 1
    systemctl is-active --quiet "$SERVICE" || die "service $SERVICE is not active after reload"
    log "service $SERVICE reloaded"
}

case "$MODE" in
    -h|--help|help) usage; exit 0 ;;
    apply|remove|status|test) ;;
    *:*) ARG_IPV6="$MODE"; MODE="apply" ;;   # first argument is an IPv6 address
    *) usage; exit 1 ;;
esac

[[ -s "$CONFIG" ]] || die "config not found: $CONFIG"

export GEMINI_MODE="$MODE" GEMINI_CONFIG="$CONFIG" GEMINI_TAG="$TAG" GEMINI_TAG4="$TAG4" \
    GEMINI_RULESET_TAG="$RULESET_TAG" GEMINI_SRS_NAME="$SRS_NAME" GEMINI_SRS_URL="$SRS_URL" \
    GEMINI_DOMAINS="$GEMINI_DOMAINS" GEMINI_ANTIGRAVITY_DOMAINS="$ANTIGRAVITY_DOMAINS" \
    GEMINI_IPV4_ONLY_DOMAINS="$IPV4_ONLY_DOMAINS"

if [[ "$MODE" == "status" ]]; then
    python3 - <<'PY'
import json, os
cfg = json.load(open(os.environ["GEMINI_CONFIG"]))
tag = os.environ["GEMINI_TAG"]
tag4 = os.environ["GEMINI_TAG4"]
tags = (tag, tag4)
obs = {o.get("tag"): o for o in cfg.get("outbounds", []) if o.get("tag") in tags}
rules = [r for r in cfg.get("route", {}).get("rules", []) if r.get("outbound") in tags]
rss = [r for r in cfg.get("route", {}).get("rule_set", []) if r.get("tag") == os.environ["GEMINI_RULESET_TAG"]]
print("outbound:", json.dumps(obs.get(tag), ensure_ascii=False) if tag in obs else "NOT SET")
print("outbound4:", json.dumps(obs.get(tag4), ensure_ascii=False) if tag4 in obs else "NOT SET")
print("rules:", len(rules))
for r in rules:
    print("  ", json.dumps(r, ensure_ascii=False))
print("rule_set:", json.dumps(rss[0], ensure_ascii=False) if rss else "NOT SET")
PY
    systemctl is-active "$SERVICE" 2>/dev/null || true
    exit 0
fi

if [[ "$MODE" == "remove" ]]; then
    backup_config
    python3 - <<'PY'
import json, os
p = os.environ["GEMINI_CONFIG"]
tag = os.environ["GEMINI_TAG"]
tag4 = os.environ["GEMINI_TAG4"]
tags = (tag, tag4)
rst = os.environ["GEMINI_RULESET_TAG"]
srs = os.environ["GEMINI_SRS_NAME"]
cfg = json.load(open(p))
cfg["outbounds"] = [o for o in cfg.get("outbounds", []) if o.get("tag") not in tags]
cfg["route"]["rules"] = [r for r in cfg["route"].get("rules", []) if r.get("outbound") not in tags]
cfg["route"]["rule_set"] = [
    r for r in cfg["route"].get("rule_set", [])
    if not (r.get("tag") == rst and os.path.basename(r.get("path", "")) == srs)
]
json.dump(cfg, open(p, "w"), indent=2, ensure_ascii=False)
print("patch removed")
PY
    check_and_reload
    exit 0
fi

if [[ "$MODE" == "test" ]]; then
    IPV6=""
    if [[ -z "$ARG_IPV6" && -z "${GEMINI_IPV6:-}" ]]; then
        CFG_IPV6="$(configured_ipv6 || true)"
        if [[ -n "$CFG_IPV6" ]]; then
            IPV6="$(normalize_ipv6 "$CFG_IPV6")" || die "invalid IPv6 in ${CONFIG}: $CFG_IPV6"
            log "IPv6 (from ${CONFIG}, outbound $TAG): $IPV6"
        fi
    fi
    if [[ -z "$IPV6" ]]; then
        choose_ipv6
    fi
    run_tests "$IPV6"
    [[ "$TESTS_FAILED" -eq 0 ]] || exit 1
    exit 0
fi

IPV6=""
choose_ipv6
backup_config

GEMINI_IPV6="$IPV6" python3 - <<'PY'
import glob, json, os, shutil, urllib.request

p = os.environ["GEMINI_CONFIG"]
tag = os.environ["GEMINI_TAG"]
tag4 = os.environ["GEMINI_TAG4"]
tags = (tag, tag4)
rst = os.environ["GEMINI_RULESET_TAG"]
srs_name = os.environ["GEMINI_SRS_NAME"]
srs_url = os.environ["GEMINI_SRS_URL"]
domains = os.environ["GEMINI_DOMAINS"].split() + os.environ["GEMINI_ANTIGRAVITY_DOMAINS"].split()
ipv4_only = os.environ["GEMINI_IPV4_ONLY_DOMAINS"].split()
ipv6 = os.environ["GEMINI_IPV6"]

cfg = json.load(open(p))
route = cfg.setdefault("route", {})
rules = route.setdefault("rules", [])
rule_sets = route.setdefault("rule_set", [])
outbounds = cfg.setdefault("outbounds", [])

dns_tag = None
for s in cfg.get("dns", {}).get("servers", []):
    if s.get("tag"):
        dns_tag = s["tag"]
        break
if not dns_tag:
    raise SystemExit("no tagged DNS server in config")

existing_rs = next((r for r in rule_sets if r.get("tag") == rst), None)
if existing_rs is None:
    ruleset_dir = None
    for r in rule_sets:
        path = r.get("path", "")
        if path.endswith(".srs") and os.path.isdir(os.path.dirname(path)):
            ruleset_dir = os.path.dirname(path)
            break
    if ruleset_dir is None:
        found = glob.glob("/var/www/*/" + srs_name)
        ruleset_dir = os.path.dirname(found[0]) if found else "/var/lib/sing-box"
    os.makedirs(ruleset_dir, exist_ok=True)
    srs_path = os.path.join(ruleset_dir, srs_name)
    if not os.path.isfile(srs_path):
        found = [f for f in glob.glob("/var/www/*/" + srs_name) + glob.glob("/var/lib/sing-box/" + srs_name) if f != srs_path]
        if found:
            shutil.copy2(found[0], srs_path)
            print("copied", srs_name, "from", found[0])
        else:
            urllib.request.urlretrieve(srs_url, srs_path)
            print("downloaded", srs_name, "from", srs_url)
    rule_sets.append({"tag": rst, "type": "local", "format": "binary", "path": srs_path})
    print("rule_set added:", rst, "->", srs_path)
else:
    print("rule_set exists:", rst, "->", existing_rs.get("path"))

outbounds[:] = [o for o in outbounds if o.get("tag") not in tags]
outbounds.append({
    "type": "direct",
    "tag": tag,
    "inet6_bind_address": ipv6,
    "domain_resolver": {"server": dns_tag, "strategy": "ipv6_only"},
})
print("outbound added:", tag, "inet6_bind_address=" + ipv6, "dns=" + dns_tag)
if ipv4_only:
    outbounds.append({"type": "direct", "tag": tag4})
    print("outbound added:", tag4, "(plain direct for hosts without AAAA)")

rules[:] = [r for r in rules if r.get("outbound") not in tags]
new_rules = []
if ipv4_only:
    # must be first: otherwise the rule_set "google" below would send these
    # hosts to the IPv6 outbound, which cannot connect to IPv4-only names
    new_rules.append({"domain_suffix": list(ipv4_only), "outbound": tag4})
new_rules += [
    {"rule_set": [rst], "outbound": tag},
    {"domain": list(domains), "outbound": tag},
]
idx = next((i for i, r in enumerate(rules) if "outbound" in r), len(rules))
rules[idx:idx] = new_rules
print("rules added at", idx, ":", json.dumps(new_rules, ensure_ascii=False))

json.dump(cfg, open(p, "w"), indent=2, ensure_ascii=False)
print("config written:", p)
PY

check_and_reload
log "done: gemini + antigravity traffic -> $TAG -> IPv6"

if [[ "${GEMINI_SKIP_TEST:-0}" == "1" ]]; then
    log "connectivity tests skipped (GEMINI_SKIP_TEST=1)"
else
    run_tests "$IPV6"
    if [[ "$TESTS_FAILED" -ne 0 ]]; then
        die "connectivity tests FAILED ($TESTS_FAILED) - patch is applied, check IPv6/DNS/routing"
    fi
    log "all connectivity tests passed"
fi
