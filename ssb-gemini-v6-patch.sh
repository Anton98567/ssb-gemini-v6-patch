#!/usr/bin/env bash
set -euo pipefail

CONFIG="${GEMINI_CONFIG:-/etc/sing-box/config.json}"
BACKUP_DIR="${GEMINI_BACKUP_DIR:-/root/bak-singbox}"
SERVICE="${GEMINI_SERVICE:-sing-box}"
TAG="gemini-v6"
RULESET_TAG="google"
SRS_NAME="geosite-google.srs"
SRS_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs"
PROBE="2001:4860:4860::8888"
GEMINI_DOMAINS="gemini.google.com generativelanguage.googleapis.com"
MODE="${1:-apply}"

log() { echo "[gemini-v6-patch] $*"; }
die() { echo "[gemini-v6-patch] ERROR: $*" >&2; exit 1; }

usage() {
    echo "usage: $0 [apply|remove|status]"
    echo "  apply  - add or refresh gemini-via-IPv6 patch in ${CONFIG} (default)"
    echo "  remove - drop outbound/rules added by this patch"
    echo "  status - show current patch state"
}

detect_ipv6() {
    local ip=""
    if [[ -n "${GEMINI_IPV6:-}" ]]; then
        ip="$GEMINI_IPV6"
    else
        ip="$(ip -6 route get "$PROBE" 2>/dev/null | sed -n 's/.*src \([0-9a-fA-F:]*\).*/\1/p' | head -1 || true)"
        if [[ -z "$ip" ]]; then
            ip="$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
        fi
    fi
    [[ -n "$ip" ]] || die "global IPv6 not found (override: GEMINI_IPV6=x.x.x.x)"
    python3 -c '
import ipaddress, sys
a = ipaddress.ip_address(sys.argv[1].strip())
assert a.version == 6 and a.is_global, f"not a global IPv6: {a}"
print(a.compressed)
' "$ip"
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
    apply|remove|status) ;;
    *) usage; exit 1 ;;
esac

[[ -s "$CONFIG" ]] || die "config not found: $CONFIG"

export GEMINI_MODE="$MODE" GEMINI_CONFIG="$CONFIG" GEMINI_TAG="$TAG" \
    GEMINI_RULESET_TAG="$RULESET_TAG" GEMINI_SRS_NAME="$SRS_NAME" GEMINI_SRS_URL="$SRS_URL" \
    GEMINI_DOMAINS="$GEMINI_DOMAINS"

if [[ "$MODE" == "status" ]]; then
    python3 - <<'PY'
import json, os
cfg = json.load(open(os.environ["GEMINI_CONFIG"]))
tag = os.environ["GEMINI_TAG"]
obs = [o for o in cfg.get("outbounds", []) if o.get("tag") == tag]
rules = [r for r in cfg.get("route", {}).get("rules", []) if r.get("outbound") == tag]
rss = [r for r in cfg.get("route", {}).get("rule_set", []) if r.get("tag") == os.environ["GEMINI_RULESET_TAG"]]
print("outbound:", json.dumps(obs[0], ensure_ascii=False) if obs else "NOT SET")
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
rst = os.environ["GEMINI_RULESET_TAG"]
srs = os.environ["GEMINI_SRS_NAME"]
cfg = json.load(open(p))
cfg["outbounds"] = [o for o in cfg.get("outbounds", []) if o.get("tag") != tag]
cfg["route"]["rules"] = [r for r in cfg["route"].get("rules", []) if r.get("outbound") != tag]
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

IPV6="$(detect_ipv6)"
log "detected IPv6: $IPV6"
backup_config

GEMINI_IPV6="$IPV6" python3 - <<'PY'
import glob, json, os, shutil, urllib.request

p = os.environ["GEMINI_CONFIG"]
tag = os.environ["GEMINI_TAG"]
rst = os.environ["GEMINI_RULESET_TAG"]
srs_name = os.environ["GEMINI_SRS_NAME"]
srs_url = os.environ["GEMINI_SRS_URL"]
domains = os.environ["GEMINI_DOMAINS"].split()
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

outbounds[:] = [o for o in outbounds if o.get("tag") != tag]
outbounds.append({
    "type": "direct",
    "tag": tag,
    "inet6_bind_address": ipv6,
    "domain_resolver": {"server": dns_tag, "strategy": "ipv6_only"},
})
print("outbound added:", tag, "inet6_bind_address=" + ipv6, "dns=" + dns_tag)

rules[:] = [r for r in rules if r.get("outbound") != tag]
new_rules = [
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
log "done: gemini traffic -> $TAG -> IPv6"
