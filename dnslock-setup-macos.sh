#!/usr/bin/env bash
# =============================================================================
#  dnslock-setup-macos.sh — system-wide adult-content DNS lock for macOS
# =============================================================================
#  Layers:
#    1. dnscrypt-proxy on 127.0.0.1:53, upstream = CleanBrowsing Adult Filter
#       (encrypted), plus HaGeZi NSFW + DoH and StevenBlack porn blocklists
#       (auto-updated daily) and forced SafeSearch (Google, Bing, DuckDuckGo,
#       YouTube).
#    2. Every network service (Wi-Fi, Ethernet, USB, ...) pinned to DNS
#       127.0.0.1 with networksetup; iCloud Private Relay switched off through
#       its DNS canary.
#    3. pf: outbound DNS (53) / DoT (853) is rejected unless it goes to the
#       local resolver; well-known public DoH resolvers are rejected too.
#    4. Browser policies (Managed Preferences): DoH off, proxy/VPN extensions
#       blocked, proxy settings locked in Firefox / Zen / Chrome / Chromium /
#       Brave / Edge (plus Firefox's built-in VPN and Brave's VPN + Tor windows
#       off) — written even for browsers you haven't installed yet.
#    5. Guard daemon re-applies everything every 5 minutes if something drifts.
#    6. Optional lock: chflags uchg on all config; unlocking = 30-min cooldown.
#
#  Usage:   sudo bash dnslock-setup-macos.sh [--lock | --no-lock]
#           curl -fsSL <raw-url>/dnslock-setup-macos.sh | sudo bash -s -- [--lock | --no-lock]
#    --lock      lock at the end without asking
#    --no-lock   don't lock and don't ask (unattended install)
#    (no flag)   ask at the end; with no terminal to ask on, don't lock
#  Re-run safe: yes (it unlocks its own files first, if you pass the cooldown).
#  Runs on the stock /bin/bash 3.2: no mapfile, no ${var,,}, no assoc arrays.
# =============================================================================

# The whole script is one { ... } group: bash parses all of it before running
# anything, so `curl ... | sudo bash` can't have its script text eaten by a
# command that reads stdin. stdin is then detached; prompts use /dev/tty.
{
set -euo pipefail
exec </dev/null
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin

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

# Everything lives in one root-owned tree. Not /usr/local/etc or /usr/local/sbin:
# Homebrew on Intel Macs makes those user-writable, and launchd runs our
# scripts as root.
DL=/usr/local/dnslock
BIN=$DL/bin
ETC=$DL/etc
VAR=$DL/var
LINK_DIR=/usr/local/bin                        # convenience symlinks for the commands
DAEMONS=/Library/LaunchDaemons
LABEL=local.dnslock
MANAGED="/Library/Managed Preferences"
# Preference domains the browsers read policies from. Managed Preferences win
# over anything the user sets in ~/Library/Preferences.
GECKO_DOMAINS=(org.mozilla.firefox app.zen-browser.zen)
CHROMIUM_DOMAINS=(com.google.Chrome org.chromium.Chromium com.brave.Browser com.microsoft.Edge)

# ---------- helpers ----------------------------------------------------------
c_ok=$'\e[32m'; c_bad=$'\e[31m'; c_dim=$'\e[2m'; c_b=$'\e[1m'; c_0=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$c_b" "$*" "$c_0"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔%s %s\n' "$c_ok" "$c_0" "$*"; }
bad()  { printf '    %s✘%s %s\n' "$c_bad" "$c_0" "$*"; }
die()  { bad "$*"; exit 1; }
# dq SERVER NAME -> prints A records (empty if blocked/unreachable)
dq()   { dig +short +time=3 +tries=1 "@$1" "$2" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' || true; }
# sysq NAME -> succeeds if the system resolver (mDNSResponder) returns an IPv4
sysq() { dscacheutil -q host -a name "$1" 2>/dev/null | grep -q '^ip_address:'; }
flush_dns() { dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true; }
# network_services -> every network service name, disabled ones included
network_services() { networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//'; }
# load_daemon LABEL -> (re)load a daemon from $DAEMONS/LABEL.plist
load_daemon() {
  launchctl bootout "system/$1" 2>/dev/null || true
  launchctl enable "system/$1"
  for _ in 1 2 3 4 5 6 7 8 9 10; do   # bootout finishes asynchronously
    launchctl bootstrap system "$DAEMONS/$1.plist" 2>/dev/null && return 0
    sleep 1
  done
  die "launchctl could not load $1"
}
# plist_header -> start of a property list file
plist_header() {
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<!-- Managed by dnslock-setup-macos.sh -->'
}

LOCK_MODE=ask
for arg in "$@"; do
  case $arg in
    --lock)    LOCK_MODE=lock ;;
    --no-lock) LOCK_MODE=no-lock ;;
    -h|--help) sed -n '/^#  Usage:/,/^#  Re-run/p' "${BASH_SOURCE[0]:-}" 2>/dev/null \
                 || echo "Usage: sudo bash dnslock-setup-macos.sh [--lock | --no-lock]"
               exit 0 ;;
    *)         die "Unknown option: $arg (use --lock, --no-lock or --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash dnslock-setup-macos.sh"
[[ $(uname -s) == Darwin ]] || die "This script is for macOS (use dnslock-setup.sh on Arch Linux)."

# If a previous install is locked, refuse — unlocking goes through the cooldown.
if [[ -f $ETC/locked-files ]] && [[ $(stat -f %Sf "$ETC/locked-files") == *uchg* ]]; then
  die "DNS lock is active. Run 'sudo dnslock-unlock' first (${COOLDOWN_MIN}-min cooldown), then re-run."
fi

# ---------- 1. dnscrypt-proxy binary -----------------------------------------
step "Installing dnscrypt-proxy"
mkdir -p "$BIN" "$ETC/managed" "$VAR"
chown -R root:wheel "$DL"
chmod 755 "$DL" "$BIN" "$ETC" "$ETC/managed" "$VAR"

case $(uname -m) in
  arm64)  dc_arch=arm64 ;;
  x86_64) dc_arch=x86_64 ;;
  *)      die "Unsupported CPU: $(uname -m)" ;;
esac
dc_ver=$(curl -fsSI https://github.com/DNSCrypt/dnscrypt-proxy/releases/latest \
  | awk -F/ 'tolower($1) ~ /^location:/ {print $NF}' | tr -d '\r')
[[ $dc_ver =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "Could not find the latest dnscrypt-proxy release on GitHub."
if [[ -x $BIN/dnscrypt-proxy && $("$BIN/dnscrypt-proxy" -version 2>/dev/null) == "$dc_ver" ]]; then
  ok "dnscrypt-proxy $dc_ver already installed"
else
  dl_tmp=$(mktemp -d)
  trap 'rm -rf "$dl_tmp"' EXIT
  curl -fsSL --retry 3 -o "$dl_tmp/dc.zip" \
    "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${dc_ver}/dnscrypt-proxy-macos_${dc_arch}-${dc_ver}.zip" \
    || die "dnscrypt-proxy download failed."
  unzip -q -o "$dl_tmp/dc.zip" dnscrypt-proxy -d "$dl_tmp" || die "dnscrypt-proxy archive has an unexpected layout."
  [[ $("$dl_tmp/dnscrypt-proxy" -version 2>/dev/null) == "$dc_ver" ]] || die "Downloaded dnscrypt-proxy does not run."
  install -m 755 -o root -g wheel "$dl_tmp/dnscrypt-proxy" "$BIN/dnscrypt-proxy"
  ok "dnscrypt-proxy $dc_ver ($dc_arch) from the official GitHub release"
fi

# ---------- 2. dnscrypt-proxy config ----------------------------------------
step "Configuring dnscrypt-proxy"
bootstrap_list=$(printf "'%s:53', " "${CB_BOOTSTRAP[@]}"); bootstrap_list=${bootstrap_list%, }

cat > "$ETC/dnscrypt-proxy.toml" <<EOF
# Managed by dnslock-setup-macos.sh — edits are overwritten on re-run.
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

cloaking_rules = '${ETC}/cloaking-rules.txt'
cloak_ttl = 600

[blocked_names]
  blocked_names_file = '${ETC}/blocked-names.txt'

[allowed_names]
  allowed_names_file = '${ETC}/allowed-names.txt'

[sources]
  [sources.public-resolvers]
    urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
    cache_file = '${VAR}/public-resolvers.md'
    minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
    refresh_delay = 73
EOF

# Forced SafeSearch. Left side = what apps ask for, right side = what they get.
cat > "$ETC/cloaking-rules.txt" <<'EOF'
# Managed by dnslock-setup-macos.sh
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
if [[ ! -f $ETC/extra-blocked.txt ]]; then
  cat > "$ETC/extra-blocked.txt" <<'EOF'
# Extra domains to block, one per line (subdomains included automatically).
# Firefox canary domain: makes Firefox's automatic DoH switch itself off.
use-application-dns.net
# iCloud Private Relay canaries: Safari's relay (which skips local DNS)
# switches itself off when these don't resolve.
mask.icloud.com
mask-h2.icloud.com
EOF
fi

# Allow-list for false positives (kept empty by default).
[[ -f $ETC/allowed-names.txt ]] || echo "# One domain per line to un-block false positives." > "$ETC/allowed-names.txt"
ok "resolver: ${UPSTREAM} (encrypted), SafeSearch cloaking, allow/block lists"

# ---------- 3. blocklist updater --------------------------------------------
step "Installing blocklist auto-updater"
{
  echo '#!/bin/bash'
  echo '# Managed by dnslock-setup-macos.sh — downloads the blocklists into dnscrypt-proxy.'
  echo 'set -euo pipefail'
  echo 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin'
  printf 'URLS=(%s)\n' "$(printf '"%s" ' "${BLOCKLIST_URLS[@]}")"
  cat <<'EOF'
ETC=/usr/local/dnslock/etc
OUT=$ETC/blocked-names.txt
tmp=$(mktemp); raw=$(mktemp)
trap 'rm -f "$tmp" "$raw"' EXIT
for url in "${URLS[@]}"; do
  curl -fsSL --retry 3 --max-time 180 "$url" >> "$raw"
  echo >> "$raw"
done
cat "$ETC/extra-blocked.txt" >> "$raw"
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
launchctl kickstart -k system/local.dnslock.dnscrypt-proxy 2>/dev/null || true
echo "dnslock: blocklist updated ($entries entries)."
EOF
} > "$BIN/dnslock-update-blocklist"
chmod 755 "$BIN/dnslock-update-blocklist"

# Daily at a random minute past noon; launchd runs a missed slot after wake.
{
  plist_header
  cat <<EOF
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}.update</string>
  <key>ProgramArguments</key>
  <array><string>${BIN}/dnslock-update-blocklist</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>$((RANDOM % 60))</integer></dict>
  <key>StandardOutPath</key><string>${VAR}/update.log</string>
  <key>StandardErrorPath</key><string>${VAR}/update.log</string>
</dict>
</plist>
EOF
} > "$DAEMONS/${LABEL}.update.plist"

# First download happens now, while DNS still works.
if "$BIN/dnslock-update-blocklist" >/dev/null 2>&1; then
  ok "blocklist downloaded ($(grep -cvE '^[[:space:]]*(#|$)' "$ETC/blocked-names.txt") entries), daily refresh enabled"
else
  [[ -f $ETC/blocked-names.txt ]] || cp "$ETC/extra-blocked.txt" "$ETC/blocked-names.txt"
  bad "blocklist download failed — CleanBrowsing still filters; the daily job will retry"
fi

# ---------- 4. start resolver & test BEFORE switching the system ------------
step "Starting dnscrypt-proxy"
"$BIN/dnscrypt-proxy" -config "$ETC/dnscrypt-proxy.toml" -check >/dev/null 2>&1 \
  || die "dnscrypt-proxy rejected its config: $BIN/dnscrypt-proxy -config $ETC/dnscrypt-proxy.toml -check"

{
  plist_header
  cat <<EOF
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}.dnscrypt-proxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN}/dnscrypt-proxy</string>
    <string>-config</string>
    <string>${ETC}/dnscrypt-proxy.toml</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${VAR}/dnscrypt-proxy.log</string>
  <key>StandardErrorPath</key><string>${VAR}/dnscrypt-proxy.log</string>
</dict>
</plist>
EOF
} > "$DAEMONS/${LABEL}.dnscrypt-proxy.plist"

# Stop our own copy (re-run), then make sure nothing else owns port 53 —
# otherwise the test below would pass against someone else's resolver.
launchctl bootout "system/${LABEL}.dnscrypt-proxy" 2>/dev/null || true
sleep 1
port53=$( { lsof -nP -iUDP:53 2>/dev/null; lsof -nP -iTCP:53 -sTCP:LISTEN 2>/dev/null; } \
  | awk 'NR>1 && $9 !~ /->/ && $9 ~ /:53$/ {print $1}' | sort -u | tr '\n' ' ')
[[ -z $port53 ]] || die "Port 53 is already in use by: $port53 — stop it first (system DNS NOT changed)."

load_daemon "${LABEL}.dnscrypt-proxy"

resolver_up=0
for _ in $(seq 1 30); do
  if [[ -n $(dq 127.0.0.1 apple.com) ]]; then
    resolver_up=1; break
  fi
  sleep 2
done
if (( ! resolver_up )); then
  bad "dnscrypt-proxy is not answering on 127.0.0.1 — system DNS NOT changed."
  info "Check: tail -n 50 $VAR/dnscrypt-proxy.log"
  info "If it says the server '${UPSTREAM}' is unknown, list names with:"
  info "  $BIN/dnscrypt-proxy -config $ETC/dnscrypt-proxy.toml -list | grep -i cleanbrowsing"
  exit 1
fi
ok "local resolver answers on 127.0.0.1:53"

# ---------- 5. pin system DNS to 127.0.0.1 ----------------------------------
step "Pointing every network service at 127.0.0.1"
# A manual DNS server on a service overrides whatever DHCP / IPv6 RA hands out.
while IFS= read -r svc; do
  [[ -n $svc ]] || continue
  networksetup -setdnsservers "$svc" 127.0.0.1 && ok "$svc"
done < <(network_services)
flush_dns
info "${c_dim}New services (a USB adapter, iPhone hotspot) get pinned by the guard.${c_0}"

# ---------- 6. firewall -------------------------------------------------------
step "Installing firewall rules (pf)"
cb_set=$(printf '%s, ' "${CB_BOOTSTRAP[@]}"); cb_set=${cb_set%, }
cat > "$ETC/dnslock.pf" <<EOF
# Managed by dnslock-setup-macos.sh — loaded into its own pf anchor "dnslock",
# does not touch /etc/pf.conf or your other rules.

# The only plain-DNS server anything may talk to (dnscrypt-proxy bootstrap).
table <dns_ok> const { ${cb_set} }

# Well-known public DoH/DoT resolvers (browsers & apps with built-in DoH).
table <doh> const {
  1.1.1.1, 1.0.0.1, 1.1.1.2, 1.0.0.2, 1.1.1.3, 1.0.0.3,
  8.8.8.8, 8.8.4.4,
  9.9.9.9, 149.112.112.112, 9.9.9.10, 149.112.112.10, 9.9.9.11, 149.112.112.11,
  208.67.222.222, 208.67.220.220, 208.67.222.123, 208.67.220.123,
  94.140.14.14, 94.140.15.15, 94.140.14.140, 94.140.14.141,
  194.242.2.2, 194.242.2.3, 194.242.2.4, 194.242.2.9,
  76.76.2.0, 76.76.10.0,
  45.90.28.0, 45.90.30.0,
  2606:4700:4700::1111, 2606:4700:4700::1001,
  2606:4700:4700::1112, 2606:4700:4700::1002,
  2606:4700:4700::1113, 2606:4700:4700::1003,
  2001:4860:4860::8888, 2001:4860:4860::8844,
  2620:fe::fe, 2620:fe::9, 2620:fe::10, 2620:fe::11,
  2620:119:35::35, 2620:119:53::53,
  2a10:50c0::ad1:ff, 2a10:50c0::ad2:ff,
  2a07:e340::2, 2a07:e340::3, 2a07:e340::4
}

pass out quick proto { tcp, udp } to <dns_ok> port 53
block return out quick on ! lo0 proto { tcp, udp } to any port { 53, 853 }
block return out quick proto { tcp, udp } to <doh> port { 443, 853 }
EOF

pfctl -q -a dnslock -n -f "$ETC/dnslock.pf" 2>/dev/null \
  || die "pf rejected the ruleset: pfctl -a dnslock -n -f $ETC/dnslock.pf"
# The main ruleset has to reference the anchor. It's reloaded from the
# unchanged /etc/pf.conf with one line appended; the guard redoes this if
# something (a macOS update, Internet Sharing) reloads pf.conf.
if ! pfctl -s rules 2>/dev/null | grep -q '^anchor "dnslock"'; then
  { cat /etc/pf.conf; echo 'anchor "dnslock"'; } | pfctl -q -f - 2>/dev/null \
    || die "pf rejected /etc/pf.conf + our anchor line"
fi
pfctl -q -a dnslock -f "$ETC/dnslock.pf" 2>/dev/null
pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' || pfctl -E >/dev/null 2>&1
pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' || die "could not enable pf"
ok "outbound DNS/DoT locked to local resolver, public DoH IPs rejected"

# ---------- 7. browser policies ---------------------------------------------
step "Writing browser policies (DoH off, no proxy/VPN extensions)"
# apply_policy DOMAIN KEYPATH JSON [KEYPATH JSON ...]
# Merges the keys into /Library/Managed Preferences/DOMAIN.plist (keeping any
# other keys already there) and keeps a copy in $ETC/managed for the guard:
# without MDM, macOS may clear that folder at boot.
apply_policy() {
  local dom=$1 dst="$MANAGED/$1.plist" tmp kp parent
  shift
  tmp=$(mktemp)
  if [[ -s $dst ]] && plutil -lint -s "$dst" >/dev/null 2>&1; then
    [[ -f $ETC/managed/$dom.plist || -f $ETC/managed/$dom.plist.orig ]] \
      || cp -p "$dst" "$ETC/managed/$dom.plist.orig"
    plutil -convert xml1 -o "$tmp" "$dst"
  else
    { plist_header; echo '<plist version="1.0"><dict/></plist>'; } > "$tmp"
  fi
  while (( $# >= 2 )); do
    kp=$1
    # plutil won't create missing parent dictionaries — make them first.
    parent=
    while [[ $kp == *.* ]]; do
      parent=${parent:+$parent.}${kp%%.*}; kp=${kp#*.}
      plutil -extract "$parent" xml1 -o /dev/null "$tmp" 2>/dev/null \
        || plutil -insert "$parent" -json '{}' "$tmp"
    done
    plutil -replace "$1" -json "$2" "$tmp"
    shift 2
  done
  plutil -lint -s "$tmp" >/dev/null || die "invalid policy plist for $dom"
  install -m 644 -o root -g wheel "$tmp" "$ETC/managed/$dom.plist"
  install -m 644 -o root -g wheel "$tmp" "$dst"
  rm -f "$tmp"
}

mkdir -p "$MANAGED"
# Proxy/VPN extensions need the "proxy" permission; blocking it disables them
# (installed ones too) and locking proxy settings stops manual SOCKS/HTTP proxies.
for dom in "${GECKO_DOMAINS[@]}"; do
  apply_policy "$dom" \
    EnterprisePoliciesEnabled true \
    DNSOverHTTPS '{"Enabled":false,"Locked":true}' \
    'ExtensionSettings.*.blocked_permissions' '["proxy"]' \
    Proxy '{"Mode":"none","Locked":true}' \
    IPProtectionAvailable false
done
ok "Firefox, Zen"

for dom in "${CHROMIUM_DOMAINS[@]}"; do
  brave_extra=()
  [[ $dom == com.brave.Browser ]] && brave_extra=(BraveVPNDisabled true TorDisabled true)
  apply_policy "$dom" \
    DnsOverHttpsMode '"off"' \
    BuiltInDnsClientEnabled false \
    ForceGoogleSafeSearch true \
    ForceYouTubeRestrict 1 \
    'ExtensionSettings.*.blocked_permissions' '["proxy","vpnProvider"]' \
    ProxySettings '{"ProxyMode":"direct"}' \
    ${brave_extra[@]+"${brave_extra[@]}"}
done
killall cfprefsd 2>/dev/null || true   # drop cached preferences so browsers see the new ones
ok "Chrome, Chromium, Brave, Edge (also applies if installed later)"
info "proxy/VPN extensions blocked, proxy settings locked, Brave VPN + Tor windows off"
info "${c_dim}Quit and reopen any running browser for policies to load.${c_0}"

# ---------- 8. guard (self-healing) -----------------------------------------
step "Installing guard (re-applies settings every 5 min)"
cat > "$BIN/dnslock-guard" <<'EOF'
#!/bin/bash
# Managed by dnslock-setup-macos.sh — puts things back if anything drifted.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
ETC=/usr/local/dnslock/etc
MANAGED="/Library/Managed Preferences"

# Firewall: anchor referenced from the main ruleset, anchor loaded, pf on.
if ! pfctl -s rules 2>/dev/null | grep -q '^anchor "dnslock"'; then
  { cat /etc/pf.conf; echo 'anchor "dnslock"'; } | pfctl -q -f - 2>/dev/null
fi
pfctl -a dnslock -s rules 2>/dev/null | grep -q . || pfctl -q -a dnslock -f "$ETC/dnslock.pf" 2>/dev/null
pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' || pfctl -E >/dev/null 2>&1

# Resolver and blocklist updater loaded.
for label in local.dnslock.dnscrypt-proxy local.dnslock.update; do
  if ! launchctl print "system/$label" >/dev/null 2>&1; then
    launchctl enable "system/$label"
    launchctl bootstrap system "/Library/LaunchDaemons/$label.plist" 2>/dev/null
  fi
done

# Every network service (including ones added since install) on 127.0.0.1.
dns_changed=0
while IFS= read -r svc; do
  [[ -n $svc ]] || continue
  [[ $(networksetup -getdnsservers "$svc" 2>/dev/null) == 127.0.0.1 ]] && continue
  networksetup -setdnsservers "$svc" 127.0.0.1 && dns_changed=1
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//')
if (( dns_changed )); then
  dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null
fi

# Browser policies back in Managed Preferences.
mkdir -p "$MANAGED"
pol_changed=0
for src in "$ETC"/managed/*.plist; do
  [[ -f $src ]] || continue
  dst="$MANAGED/${src##*/}"
  cmp -s "$src" "$dst" && continue
  chflags nouchg "$dst" 2>/dev/null
  install -m 644 -o root -g wheel "$src" "$dst"
  [[ -f $ETC/locked ]] && chflags uchg "$dst"
  pol_changed=1
done
(( pol_changed )) && killall cfprefsd 2>/dev/null
exit 0
EOF
chmod 755 "$BIN/dnslock-guard"

{
  plist_header
  cat <<EOF
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}.guard</string>
  <key>ProgramArguments</key>
  <array><string>${BIN}/dnslock-guard</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
</dict>
</plist>
EOF
} > "$DAEMONS/${LABEL}.guard.plist"

for p in "$DAEMONS/${LABEL}".*.plist; do
  chown root:wheel "$p"; chmod 644 "$p"
  plutil -lint -s "$p" >/dev/null || die "invalid launchd plist: $p"
done
load_daemon "${LABEL}.guard"
load_daemon "${LABEL}.update"
ok "guard + daily blocklist daemons loaded (start at every boot)"

# ---------- 9. lock / unlock tools ------------------------------------------
LOCKED_FILES=(
  "$ETC/dnscrypt-proxy.toml"
  "$ETC/cloaking-rules.txt"
  "$ETC/allowed-names.txt"
  "$ETC/extra-blocked.txt"
  "$ETC/dnslock.pf"
  "$DAEMONS/${LABEL}.dnscrypt-proxy.plist"
  "$DAEMONS/${LABEL}.guard.plist"
  "$DAEMONS/${LABEL}.update.plist"
  "$BIN/dnscrypt-proxy"
  "$BIN/dnslock-guard"
  "$BIN/dnslock-update-blocklist"
  "$BIN/dnslock-lock"
  "$BIN/dnslock-unlock"
)
for dom in "${GECKO_DOMAINS[@]}" "${CHROMIUM_DOMAINS[@]}"; do
  LOCKED_FILES+=("$ETC/managed/$dom.plist" "$MANAGED/$dom.plist")
done

cat > "$BIN/dnslock-lock" <<'EOF'
#!/bin/bash
# Managed by dnslock-setup-macos.sh — make all dnslock files immutable.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
ETC=/usr/local/dnslock/etc
touch "$ETC/locked"
while IFS= read -r f; do
  [[ -z $f || $f == \#* ]] && continue
  [[ -e $f ]] && chflags uchg "$f"
done < "$ETC/locked-files"
chflags uchg "$ETC/locked" "$ETC/locked-files"
echo "dnslock: locked."
EOF

cat > "$BIN/dnslock-unlock" <<EOF
#!/bin/bash
# Managed by dnslock-setup-macos.sh — unlock only after a cooldown.
set -euo pipefail
[[ \$EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
ETC=${ETC}
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
chflags nouchg "\$ETC/locked" "\$ETC/locked-files" 2>/dev/null || true
while IFS= read -r f; do
  [[ -z \$f || \$f == \#* ]] && continue
  [[ -e \$f ]] && chflags nouchg "\$f"
done < "\$ETC/locked-files"
rm -f "\$ETC/locked"
echo "  dnslock: unlocked. Filtering is STILL ON — only the files are editable."
echo "  Re-lock with: sudo dnslock-lock"
EOF
chmod 755 "$BIN/dnslock-lock" "$BIN/dnslock-unlock"

{ echo "# files made immutable by dnslock-lock"; printf '%s\n' "${LOCKED_FILES[@]}"; } > "$ETC/locked-files"

mkdir -p "$LINK_DIR"
for cmd in dnslock-lock dnslock-unlock dnslock-update-blocklist; do
  ln -sf "$BIN/$cmd" "$LINK_DIR/$cmd"
done
ok "dnslock-lock / dnslock-unlock (${COOLDOWN_MIN}-min cooldown) installed in $LINK_DIR"

# ---------- 10. verify --------------------------------------------------------
step "Verifying"
flush_dns
pass=0; fail=0
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; pass=$((pass+1)); else bad "$1"; fail=$((fail+1)); fi; }

all_pinned() {
  local svc
  while IFS= read -r svc; do
    [[ -z $svc || $(networksetup -getdnsservers "$svc") == 127.0.0.1 ]] || return 1
  done < <(network_services)
}
check "every network service uses 127.0.0.1"        all_pinned
check "normal sites resolve (apple.com)"             "sysq apple.com"
test_domain=$(grep -m1 -vE '^[[:space:]]*(#|$)' "$ETC/blocked-names.txt" | tr -d '[:space:]')
check "a domain from the adult blocklist is blocked" "! sysq '$test_domain'"
# dnscrypt-proxy resolves the cloaking target on first use, so a query right
# after startup can come back empty; give it a few tries.
safesearch_ok() {
  local ip
  for _ in 1 2 3; do
    ip=$(dq "${CB_BOOTSTRAP[0]}" forcesafesearch.google.com | head -1)
    [[ -n $ip ]] && dq 127.0.0.1 www.google.com | grep -qx "$ip" && return 0
    sleep 2
  done
  return 1
}
check "Google SafeSearch forced"                     safesearch_ok
check "direct DNS to 8.8.8.8 is blocked"            "[[ -z \$(dq 8.8.8.8 apple.com) ]]"
check "DoH to 1.1.1.1 is blocked"                   "! curl -s --max-time 4 -o /dev/null https://1.1.1.1/dns-query"
check "Firefox canary domain returns nothing"       "! sysq use-application-dns.net"
check "iCloud Private Relay canary returns nothing" "! sysq mask.icloud.com"

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
      read -r -u 3 -p "  Lock it now (chflags uchg, unlock needs a ${COOLDOWN_MIN}-min cooldown)? [y/N] " ans || ans=n
      exec 3<&-
    else
      info "No terminal to ask on, so not locking (pass --lock to lock unattended)."
    fi ;;
esac
case $ans in
  [yY]*) "$BIN/dnslock-lock" ;;
  *)     info "Not locked. When you're happy with it: sudo dnslock-lock" ;;
esac
echo
exit
}
