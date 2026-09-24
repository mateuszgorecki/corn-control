#!/usr/bin/env bash
# =============================================================================
#  dnslock-setup.sh — system-wide adult-content DNS lock for Arch Linux
# =============================================================================
#  Layers:
#    1. dnscrypt-proxy on 127.0.0.1:53, upstream = CleanBrowsing Adult Filter
#       (encrypted), plus HaGeZi NSFW + DoH and StevenBlack porn blocklists
#       (auto-updated daily) and forced SafeSearch (Google, Bing, DuckDuckGo,
#       YouTube).
#    2. System DNS pinned to 127.0.0.1 (NetworkManager told to keep hands off,
#       systemd-resolved disabled).
#    3. nftables: outbound DNS (53) / DoT (853) is rejected unless it goes to
#       the local resolver; well-known public DoH resolvers are rejected too.
#    4. Browser policies: DoH off, proxy/VPN extensions blocked, proxy settings
#       locked in Firefox / Chromium / Chrome / Brave (plus Firefox's built-in
#       VPN and Brave's VPN + Tor windows off) — written even for browsers you
#       haven't installed yet.
#    5. Guard timer re-applies everything every 5 minutes if something drifts.
#    6. Optional lock: chattr +i on all config; unlocking = 30-min cooldown.
#
#  Usage:   sudo bash dnslock-setup.sh [--lock | --no-lock]
#           curl -fsSL <raw-url>/dnslock-setup.sh | sudo bash -s -- [--lock | --no-lock]
#    --lock      lock at the end without asking
#    --no-lock   don't lock and don't ask (unattended install)
#    (no flag)   ask at the end; with no terminal to ask on, don't lock
#  Re-run safe: yes (it unlocks its own files first, if you pass the cooldown).
# =============================================================================

# The whole script is one { ... } group: bash parses all of it before running
# anything, so `curl ... | sudo bash` can't have its script text eaten by a
# command that reads stdin. stdin is then detached; prompts use /dev/tty.
{
set -euo pipefail
exec </dev/null

# ---------- settings ---------------------------------------------------------
UPSTREAM="cleanbrowsing-adult"                 # dnscrypt-proxy resolver name
CB_BOOTSTRAP=("185.228.168.10" "185.228.169.11")  # CleanBrowsing Adult, plain DNS (bootstrap only)
BLOCKLIST_URLS=(
  "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/nsfw-onlydomains.txt"
  "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/doh-onlydomains.txt"
  "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn/hosts"
)
# Lists can be plain domains or hosts format (0.0.0.0 domain); the updater
# normalizes both.
COOLDOWN_MIN=30

DC_DIR=/etc/dnscrypt-proxy
LOCK_DIR=/etc/dnslock
SBIN=/usr/local/sbin
UNITS=/etc/systemd/system
NM_CONF=/etc/NetworkManager/conf.d/90-dnslock.conf
FF_POLICY=/etc/firefox/policies/policies.json
CHROMIUM_POLICY_DIRS=(
  /etc/chromium/policies/managed
  /etc/opt/chrome/policies/managed
  /etc/brave/policies/managed
)

# ---------- helpers ----------------------------------------------------------
c_ok=$'\e[32m'; c_bad=$'\e[31m'; c_dim=$'\e[2m'; c_b=$'\e[1m'; c_0=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$c_b" "$*" "$c_0"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔%s %s\n' "$c_ok" "$c_0" "$*"; }
bad()  { printf '    %s✘%s %s\n' "$c_bad" "$c_0" "$*"; }
die()  { bad "$*"; exit 1; }
# dq SERVER NAME -> prints A records (empty if blocked/unreachable)
dq()   { timeout 6 drill "@$1" "$2" A 2>/dev/null | awk '$3=="IN" && $4=="A"{print $5}'; }

LOCK_MODE=ask
for arg in "$@"; do
  case $arg in
    --lock)    LOCK_MODE=lock ;;
    --no-lock) LOCK_MODE=no-lock ;;
    -h|--help) sed -n '/^#  Usage:/,/^#  Re-run/p' "${BASH_SOURCE[0]:-}" 2>/dev/null \
                 || echo "Usage: sudo bash dnslock-setup.sh [--lock | --no-lock]"
               exit 0 ;;
    *)         die "Unknown option: $arg (use --lock, --no-lock or --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash dnslock-setup.sh"
command -v pacman >/dev/null || die "This script is for Arch Linux (pacman not found)."

# If a previous install is locked, refuse — unlocking goes through the cooldown.
if [[ -f $LOCK_DIR/locked-files ]] && lsattr -d "$LOCK_DIR/locked-files" 2>/dev/null | awk '{print $1}' | grep -q i; then
  die "DNS lock is active. Run 'sudo dnslock-unlock' first (${COOLDOWN_MIN}-min cooldown), then re-run."
fi

for fw in firewalld ufw; do
  if systemctl is-active --quiet "$fw" 2>/dev/null; then
    info "${c_bad}Note:${c_0} $fw is active. Our rules live in their own nftables table and"
    info "should coexist, but if $fw reloads with 'flush ruleset' the guard timer re-adds them."
  fi
done

# ---------- 1. packages ------------------------------------------------------
step "Installing packages"
pacman -S --needed --noconfirm dnscrypt-proxy nftables curl ldns jq e2fsprogs >/dev/null
ok "dnscrypt-proxy, nftables, curl, ldns (drill), jq"

mkdir -p "$LOCK_DIR"

# ---------- 2. dnscrypt-proxy config ----------------------------------------
step "Configuring dnscrypt-proxy"
if [[ -f $DC_DIR/dnscrypt-proxy.toml && ! -f $DC_DIR/dnscrypt-proxy.toml.orig ]]; then
  cp -a "$DC_DIR/dnscrypt-proxy.toml" "$DC_DIR/dnscrypt-proxy.toml.orig"
  info "original config backed up to dnscrypt-proxy.toml.orig"
fi

bootstrap_list=$(printf "'%s:53', " "${CB_BOOTSTRAP[@]}"); bootstrap_list=${bootstrap_list%, }

cat > "$DC_DIR/dnscrypt-proxy.toml" <<EOF
# Managed by dnslock-setup.sh — edits are overwritten on re-run.
listen_addresses = ['127.0.0.1:53']
max_clients = 250

server_names = ['${UPSTREAM}']
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true

# CleanBrowsing is a *filtering* resolver, so these must be relaxed.
require_dnssec = false
require_nolog = false
require_nofilter = false

# Bootstrap + connectivity probe go only to CleanBrowsing (the only plain-DNS
# destination the firewall allows).
bootstrap_resolvers = [${bootstrap_list}]
ignore_system_dns = true
netprobe_address = '${CB_BOOTSTRAP[0]}:53'
netprobe_timeout = 60

block_ipv6 = false
block_unqualified = true
block_undelegated = true
cache = true

cloaking_rules = '${DC_DIR}/cloaking-rules.txt'
cloak_ttl = 600

[blocked_names]
  blocked_names_file = '${DC_DIR}/blocked-names.txt'

[allowed_names]
  allowed_names_file = '${DC_DIR}/allowed-names.txt'

[sources]
  [sources.public-resolvers]
    urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
    cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
    minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
    refresh_delay = 73
EOF

# Forced SafeSearch. Left side = what apps ask for, right side = what they get.
cat > "$DC_DIR/cloaking-rules.txt" <<'EOF'
# Managed by dnslock-setup.sh
www.google.*              forcesafesearch.google.com
=google.com               forcesafesearch.google.com
www.bing.com              strict.bing.com
=bing.com                 strict.bing.com
=duckduckgo.com           safe.duckduckgo.com
=www.duckduckgo.com       safe.duckduckgo.com
=start.duckduckgo.com     safe.duckduckgo.com
=www.youtube.com          restrictmoderate.youtube.com
=m.youtube.com            restrictmoderate.youtube.com
=youtubei.googleapis.com  restrictmoderate.youtube.com
=youtube.googleapis.com   restrictmoderate.youtube.com
=www.youtube-nocookie.com restrictmoderate.youtube.com
EOF

# Your own extra blocks (merged into the list on every update).
if [[ ! -f $LOCK_DIR/extra-blocked.txt ]]; then
  cat > "$LOCK_DIR/extra-blocked.txt" <<'EOF'
# Extra domains to block, one per line (subdomains included automatically).
# Firefox canary domain: makes Firefox's automatic DoH switch itself off.
use-application-dns.net
EOF
fi

# Allow-list for false positives (kept empty by default).
[[ -f $DC_DIR/allowed-names.txt ]] || echo "# One domain per line to un-block false positives." > "$DC_DIR/allowed-names.txt"
ok "resolver: ${UPSTREAM} (encrypted), SafeSearch cloaking, allow/block lists"

# ---------- 3. blocklist updater --------------------------------------------
step "Installing blocklist auto-updater"
{
  echo '#!/usr/bin/env bash'
  echo '# Managed by dnslock-setup.sh — downloads the blocklists into dnscrypt-proxy.'
  echo 'set -euo pipefail'
  printf 'URLS=(%s)\n' "$(printf '"%s" ' "${BLOCKLIST_URLS[@]}")"
  cat <<'EOF'
OUT=/etc/dnscrypt-proxy/blocked-names.txt
tmp=$(mktemp); raw=$(mktemp)
trap 'rm -f "$tmp" "$raw"' EXIT
for url in "${URLS[@]}"; do
  curl -fsSL --retry 3 --max-time 180 "$url" >> "$raw"
  echo >> "$raw"
done
cat /etc/dnslock/extra-blocked.txt >> "$raw"
# Plain domains pass through; hosts lines (0.0.0.0/127.0.0.1 domain) keep the
# domain; other IPs (::1, fe80::…) and localhost-style names are dropped.
awk '
  { sub(/#.*/, "") }
  NF == 0 { next }
  NF == 1 { d = $1 }
  NF >= 2 { if ($1 != "0.0.0.0" && $1 != "127.0.0.1") next; d = $2 }
  d ~ /^(localhost|localhost\.localdomain|local|broadcasthost|0\.0\.0\.0)$/ { next }
  !seen[d]++ { print d }
' "$raw" > "$tmp"
entries=$(grep -cvE '^[[:space:]]*(#|$)' "$tmp" || true)
if (( entries < 20000 )); then
  echo "dnslock: download looks incomplete ($entries entries) — keeping the old list." >&2
  exit 1
fi
install -m 644 "$tmp" "$OUT.new" && mv -f "$OUT.new" "$OUT"
systemctl try-restart dnscrypt-proxy.service
echo "dnslock: blocklist updated ($entries entries)."
EOF
} > "$SBIN/dnslock-update-blocklist"
chmod 755 "$SBIN/dnslock-update-blocklist"

cat > "$UNITS/dnslock-update.service" <<EOF
[Unit]
Description=dnslock: refresh adult-content blocklist
Wants=network-online.target
After=network-online.target dnscrypt-proxy.service

[Service]
Type=oneshot
ExecStart=$SBIN/dnslock-update-blocklist
EOF

cat > "$UNITS/dnslock-update.timer" <<'EOF'
[Unit]
Description=dnslock: refresh blocklist daily

[Timer]
OnBootSec=10min
OnUnitActiveSec=1d
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# First download happens now, while normal DNS still works.
if "$SBIN/dnslock-update-blocklist" >/dev/null 2>&1; then
  ok "blocklist downloaded ($(grep -cvE '^[[:space:]]*(#|$)' "$DC_DIR/blocked-names.txt") entries), daily refresh enabled"
else
  [[ -f $DC_DIR/blocked-names.txt ]] || cp "$LOCK_DIR/extra-blocked.txt" "$DC_DIR/blocked-names.txt"
  bad "blocklist download failed — CleanBrowsing still filters; the timer will retry"
fi

# ---------- 4. start resolver & test BEFORE switching the system ------------
step "Starting dnscrypt-proxy"
systemctl disable --now dnscrypt-proxy.socket >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable dnscrypt-proxy.service >/dev/null 2>&1
systemctl restart dnscrypt-proxy.service

resolver_up=0
for _ in $(seq 1 30); do
  if [[ -n $(dq 127.0.0.1 archlinux.org) ]]; then
    resolver_up=1; break
  fi
  sleep 2
done
if (( ! resolver_up )); then
  bad "dnscrypt-proxy is not answering on 127.0.0.1 — system DNS NOT changed."
  info "Check: journalctl -u dnscrypt-proxy -n 50"
  info "If it says the server '${UPSTREAM}' is unknown, list names with:"
  info "  dnscrypt-proxy -config $DC_DIR/dnscrypt-proxy.toml -list | grep -i cleanbrowsing"
  exit 1
fi
ok "local resolver answers on 127.0.0.1:53"

# ---------- 5. pin system DNS to 127.0.0.1 ----------------------------------
step "Pointing the whole system at 127.0.0.1"
if command -v NetworkManager >/dev/null 2>&1; then
  mkdir -p "$(dirname "$NM_CONF")"
  cat > "$NM_CONF" <<'EOF'
# Managed by dnslock-setup.sh — NetworkManager must not touch DNS.
[main]
dns=none
rc-manager=unmanaged
EOF
  systemctl reload NetworkManager.service >/dev/null 2>&1 || true
  ok "NetworkManager: dns=none"
fi

if systemctl is-enabled --quiet systemd-resolved.service 2>/dev/null || systemctl is-active --quiet systemd-resolved.service 2>/dev/null; then
  systemctl disable --now systemd-resolved.service >/dev/null 2>&1 || true
  ok "systemd-resolved disabled"
fi

cat > "$LOCK_DIR/resolv.conf" <<'EOF'
# Managed by dnslock-setup.sh
nameserver 127.0.0.1
options edns0 trust-ad
EOF
chattr -i /etc/resolv.conf 2>/dev/null || true
[[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
install -m 644 "$LOCK_DIR/resolv.conf" /etc/resolv.conf
ok "/etc/resolv.conf -> 127.0.0.1"

# ---------- 6. firewall -------------------------------------------------------
step "Installing firewall rules (nftables)"
cb_set=$(printf '%s, ' "${CB_BOOTSTRAP[@]}"); cb_set=${cb_set%, }
cat > "$LOCK_DIR/dnslock.nft" <<EOF
#!/usr/sbin/nft -f
# Managed by dnslock-setup.sh — own table, does not touch your other rules.
table inet dnslock
delete table inet dnslock

table inet dnslock {
  # The only plain-DNS server anything may talk to (dnscrypt-proxy bootstrap).
  set dns_ok4 {
    type ipv4_addr
    elements = { ${cb_set} }
  }

  # Well-known public DoH/DoT resolvers (browsers & apps with built-in DoH).
  set doh4 {
    type ipv4_addr
    elements = {
      1.1.1.1, 1.0.0.1, 1.1.1.2, 1.0.0.2, 1.1.1.3, 1.0.0.3,
      8.8.8.8, 8.8.4.4,
      9.9.9.9, 149.112.112.112, 9.9.9.10, 149.112.112.10, 9.9.9.11, 149.112.112.11,
      208.67.222.222, 208.67.220.220, 208.67.222.123, 208.67.220.123,
      94.140.14.14, 94.140.15.15, 94.140.14.140, 94.140.14.141,
      194.242.2.2, 194.242.2.3, 194.242.2.4, 194.242.2.9,
      76.76.2.0, 76.76.10.0,
      45.90.28.0, 45.90.30.0
    }
  }
  set doh6 {
    type ipv6_addr
    elements = {
      2606:4700:4700::1111, 2606:4700:4700::1001,
      2606:4700:4700::1112, 2606:4700:4700::1002,
      2606:4700:4700::1113, 2606:4700:4700::1003,
      2001:4860:4860::8888, 2001:4860:4860::8844,
      2620:fe::fe, 2620:fe::9, 2620:fe::10, 2620:fe::11,
      2620:119:35::35, 2620:119:53::53,
      2a10:50c0::ad1:ff, 2a10:50c0::ad2:ff,
      2a07:e340::2, 2a07:e340::3, 2a07:e340::4
    }
  }

  chain output {
    type filter hook output priority filter; policy accept;
    oifname "lo" accept
    ip daddr @dns_ok4 meta l4proto { tcp, udp } th dport 53 accept
    meta l4proto { tcp, udp } th dport { 53, 853 } counter reject
    ip  daddr @doh4 meta l4proto { tcp, udp } th dport { 443, 853 } counter reject
    ip6 daddr @doh6 meta l4proto { tcp, udp } th dport { 443, 853 } counter reject
  }
}
EOF

cat > "$UNITS/dnslock-firewall.service" <<'EOF'
[Unit]
Description=dnslock: block DNS/DoH bypass
Wants=network-pre.target
Before=network-pre.target
After=nftables.service
PartOf=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nft -f /etc/dnslock/dnslock.nft
ExecReload=/usr/bin/nft -f /etc/dnslock/dnslock.nft

[Install]
WantedBy=multi-user.target
EOF

nft -c -f "$LOCK_DIR/dnslock.nft" || die "nftables rejected the ruleset (see error above)"
systemctl daemon-reload
systemctl enable dnslock-firewall.service >/dev/null 2>&1
systemctl restart dnslock-firewall.service
ok "outbound DNS/DoT locked to local resolver, public DoH IPs rejected"

# ---------- 7. browser policies ---------------------------------------------
step "Writing browser policies (DoH off, no proxy/VPN extensions)"
# Proxy/VPN extensions need the "proxy" permission; blocking it disables them
# (installed ones too) and locking proxy settings stops manual SOCKS/HTTP proxies.
ff_ours='{"policies":{
  "DNSOverHTTPS":{"Enabled":false,"Locked":true},
  "ExtensionSettings":{"*":{"blocked_permissions":["proxy"]}},
  "Proxy":{"Mode":"none","Locked":true},
  "IPProtectionAvailable":false
}}'
mkdir -p "$(dirname "$FF_POLICY")"
if [[ -s $FF_POLICY ]] && jq -e . "$FF_POLICY" >/dev/null 2>&1; then
  [[ -f $FF_POLICY.dnslock-bak ]] || cp -a "$FF_POLICY" "$FF_POLICY.dnslock-bak"
  jq -s '.[0] * .[1]' "$FF_POLICY" <(echo "$ff_ours") > "$FF_POLICY.new" && mv -f "$FF_POLICY.new" "$FF_POLICY"
  ok "Firefox: merged into existing policies.json"
else
  echo "$ff_ours" | jq . > "$FF_POLICY"
  ok "Firefox (+ forks reading /etc/firefox/policies)"
fi

for d in "${CHROMIUM_POLICY_DIRS[@]}"; do
  mkdir -p "$d"
  brave_extra=''
  [[ $d == /etc/brave/* ]] && brave_extra=$',\n  "BraveVPNDisabled": true,\n  "TorDisabled": true'
  cat > "$d/dnslock.json" <<EOF
{
  "DnsOverHttpsMode": "off",
  "BuiltInDnsClientEnabled": false,
  "ForceGoogleSafeSearch": true,
  "ForceYouTubeRestrict": 1,
  "ExtensionSettings": { "*": { "blocked_permissions": ["proxy", "vpnProvider"] } },
  "ProxySettings": { "ProxyMode": "direct" }${brave_extra}
}
EOF
  jq -e . "$d/dnslock.json" >/dev/null || die "invalid policy JSON in $d/dnslock.json"
done
ok "Chromium, Google Chrome, Brave (also applies if installed later)"
info "proxy/VPN extensions blocked, proxy settings locked, Brave VPN + Tor windows off"
info "${c_dim}Restart any open browser for policies to load.${c_0}"

# ---------- 8. guard (self-healing) -----------------------------------------
step "Installing guard (re-applies settings every 5 min)"
cat > "$SBIN/dnslock-guard" <<'EOF'
#!/usr/bin/env bash
# Managed by dnslock-setup.sh — puts things back if anything drifted.
nft list table inet dnslock >/dev/null 2>&1 || nft -f /etc/dnslock/dnslock.nft
systemctl is-active --quiet dnscrypt-proxy.service || systemctl restart dnscrypt-proxy.service
if ! cmp -s /etc/resolv.conf /etc/dnslock/resolv.conf; then
  chattr -i /etc/resolv.conf 2>/dev/null; rm -f /etc/resolv.conf
  install -m 644 /etc/dnslock/resolv.conf /etc/resolv.conf
  [[ -f /etc/dnslock/locked ]] && chattr +i /etc/resolv.conf
fi
exit 0
EOF
chmod 755 "$SBIN/dnslock-guard"

cat > "$UNITS/dnslock-guard.service" <<EOF
[Unit]
Description=dnslock: re-apply DNS lock if it drifted

[Service]
Type=oneshot
ExecStart=$SBIN/dnslock-guard
EOF

cat > "$UNITS/dnslock-guard.timer" <<'EOF'
[Unit]
Description=dnslock: guard every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now dnslock-guard.timer dnslock-update.timer >/dev/null 2>&1
ok "guard + daily blocklist timers enabled"

# ---------- 9. lock / unlock tools ------------------------------------------
LOCKED_FILES=(
  /etc/resolv.conf
  "$DC_DIR/dnscrypt-proxy.toml"
  "$DC_DIR/cloaking-rules.txt"
  "$LOCK_DIR/dnslock.nft"
  "$LOCK_DIR/resolv.conf"
  "$LOCK_DIR/extra-blocked.txt"
  "$FF_POLICY"
  "$UNITS/dnslock-firewall.service"
  "$UNITS/dnslock-guard.service"
  "$UNITS/dnslock-guard.timer"
  "$UNITS/dnslock-update.service"
  "$UNITS/dnslock-update.timer"
  "$SBIN/dnslock-guard"
  "$SBIN/dnslock-update-blocklist"
  "$SBIN/dnslock-lock"
  "$SBIN/dnslock-unlock"
)
[[ -f $NM_CONF ]] && LOCKED_FILES+=("$NM_CONF")
for d in "${CHROMIUM_POLICY_DIRS[@]}"; do LOCKED_FILES+=("$d/dnslock.json"); done

cat > "$SBIN/dnslock-lock" <<'EOF'
#!/usr/bin/env bash
# Managed by dnslock-setup.sh — make all dnslock files immutable.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
touch /etc/dnslock/locked
mapfile -t files < <(grep -v '^#' /etc/dnslock/locked-files)
for f in "${files[@]}" /etc/dnslock/locked /etc/dnslock/locked-files; do
  [[ -e $f ]] && chattr +i "$f"
done
echo "dnslock: locked."
EOF

cat > "$SBIN/dnslock-unlock" <<EOF
#!/usr/bin/env bash
# Managed by dnslock-setup.sh — unlock only after a cooldown.
set -euo pipefail
[[ \$EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
MIN=${COOLDOWN_MIN}
echo
echo "  Unlocking in \$MIN minutes. Ctrl+C cancels at any time."
echo "  While you wait: what do you actually need right now?"
echo
for ((m=MIN; m>0; m--)); do
  printf '\r  %2d min left ' "\$m"
  sleep 60
done
echo
mapfile -t files < <(grep -v '^#' /etc/dnslock/locked-files)
for f in /etc/dnslock/locked /etc/dnslock/locked-files "\${files[@]}"; do
  [[ -e \$f ]] && chattr -i "\$f"
done
rm -f /etc/dnslock/locked
echo "  dnslock: unlocked. Filtering is STILL ON — only the files are editable."
echo "  Re-lock with: sudo dnslock-lock"
EOF
chmod 755 "$SBIN/dnslock-lock" "$SBIN/dnslock-unlock"

{ echo "# files made immutable by dnslock-lock"; printf '%s\n' "${LOCKED_FILES[@]}"; } > "$LOCK_DIR/locked-files"
ok "dnslock-lock / dnslock-unlock (${COOLDOWN_MIN}-min cooldown) installed"

# ---------- 10. verify --------------------------------------------------------
step "Verifying"
pass=0; fail=0
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; pass=$((pass+1)); else bad "$1"; fail=$((fail+1)); fi; }

check "normal sites resolve (archlinux.org)"         "getent ahostsv4 archlinux.org"
test_domain=$(grep -m1 -vE '^[[:space:]]*(#|$)' "$DC_DIR/blocked-names.txt" | tr -d '[:space:]')
check "a domain from the adult blocklist is blocked" "! getent ahostsv4 '$test_domain'"
ss_ip=$(dq "${CB_BOOTSTRAP[0]}" forcesafesearch.google.com | head -1)
check "Google SafeSearch forced" \
  "[[ -n '$ss_ip' ]] && dq 127.0.0.1 www.google.com | grep -qx '$ss_ip'"
check "direct DNS to 8.8.8.8 is blocked"            "[[ -z \$(dq 8.8.8.8 archlinux.org) ]]"
check "DoH to 1.1.1.1 is blocked"                   "! curl -s --max-time 4 -o /dev/null https://1.1.1.1/dns-query"
check "Firefox canary domain returns nothing"       "! getent ahostsv4 use-application-dns.net"

echo
if (( fail == 0 )); then
  printf '%s  All %d checks passed.%s\n' "$c_ok" "$pass" "$c_0"
else
  printf '%s  %d passed, %d failed — see README “Troubleshooting”.%s\n' "$c_bad" "$pass" "$fail" "$c_0"
fi

# ---------- 11. lock? --------------------------------------------------------
echo
ans=n
case $LOCK_MODE in
  lock) ans=y ;;
  ask)
    if { exec 3</dev/tty; } 2>/dev/null; then
      read -r -u 3 -p "  Lock it now (chattr +i, unlock needs a ${COOLDOWN_MIN}-min cooldown)? [y/N] " ans || ans=n
      exec 3<&-
    else
      info "No terminal to ask on, so not locking (pass --lock to lock unattended)."
    fi ;;
esac
if [[ ${ans,,} == y* ]]; then
  "$SBIN/dnslock-lock"
else
  info "Not locked. When you're happy with it: sudo dnslock-lock"
fi
echo
exit
}
