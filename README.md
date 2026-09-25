# corn-control: adult-content filter for Arch Linux and macOS

corn-control blocks adult content at the DNS level for the **whole system**: every browser, every app with a built-in browser, and anything else that looks up a domain. You don't need any extensions.

There are two installers with the same layers and the same commands: `corn-control-arch.sh` for **Arch Linux** (described first) and `corn-control-macos.sh` for **macOS** (see [macOS](#macos) below).

## Run it

One line, no clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/mateuszgorecki/corn-control/main/corn-control-arch.sh | sudo bash
```

Or from a clone:

```bash
git clone https://github.com/mateuszgorecki/corn-control.git
cd corn-control
sudo bash corn-control-arch.sh
```

It takes about a minute and installs everything it needs through `pacman`. Everything it sets up is a systemd service or timer, so from then on it starts by itself at every boot. You never need to run the script again unless you want to change a setting.

At the end it runs 6 self-checks and asks whether to **lock**. Say no the first time and use the machine normally for a day, then run `sudo corn-control-lock`.

To skip the question, pass a flag (after `-s --` when piping):

| Flag | Effect |
|---|---|
| *(none)* | Ask at the end. If there's no terminal to ask on, don't lock. |
| `--no-lock` | Don't ask, don't lock. For unattended installs. |
| `--lock` | Don't ask, lock right away. |

```bash
curl -fsSL https://raw.githubusercontent.com/mateuszgorecki/corn-control/main/corn-control-arch.sh | sudo bash -s -- --no-lock
```

## What it sets up

| Layer | What it does |
|---|---|
| **Resolver** | `dnscrypt-proxy` listens on `127.0.0.1:53`. It sends queries encrypted to the **CleanBrowsing Adult Filter**, a free filtering resolver. |
| **Blocklists** | HaGeZi **NSFW** (~80k domains), HaGeZi **encrypted-DNS bypass** (~3.3k DoH servers) and **StevenBlack hosts + porn** (~150k domains, includes ads/malware). Together about 220k unique domains. Lists can be plain domains or hosts format; the updater normalizes and de-duplicates them. A timer refreshes them daily. If a download comes back broken, the old list stays. |
| **SafeSearch** | Google, Bing, DuckDuckGo and YouTube (moderate) are forced into safe mode at the DNS level. |
| **System DNS** | `/etc/resolv.conf` → `127.0.0.1`. NetworkManager gets `dns=none` and `systemd-resolved` is turned off, so DNS from Wi-Fi/DHCP gets ignored. |
| **Firewall** | nftables table `inet corn_control`. Plain DNS (53) and DoT (853) are **rejected** unless they go to the local resolver. Public DoH IPs (Cloudflare, Google, Quad9, AdGuard, NextDNS, Mullvad…) are rejected too. |
| **Browsers** | By policy in Firefox, Zen, Chromium, Chrome and Brave: DoH is off, extensions that need the `proxy` permission (browser "VPN" and proxy extensions) are blocked and disabled if already installed, and proxy settings are locked to a direct connection. Firefox's built-in VPN is turned off, and so are Brave's VPN and "Private window with Tor". These policies are written even for browsers you haven't installed yet. Firefox and Zen read `/etc/<browser>/policies/policies.json`, which *replaces* the `policies.json` shipped in the install dir, so the shipped file (e.g. Zen's `DisableAppUpdate`) is merged in. Other Firefox forks can be added to `GECKO_POLICIES` at the top of the script. Chromium-family browsers also get Google SafeSearch and YouTube Restricted forced on. |
| **Guard** | Every 5 minutes a timer checks for drift and puts things back: the firewall table, the resolver, and resolv.conf. |
| **Lock** | `chattr +i` on every config file. Unlocking means waiting through a **30-minute cooldown**. |

## Commands

```bash
sudo corn-control-lock                           # make all files immutable
sudo corn-control-unlock                         # 30-min countdown, then editable (filter stays ON)
sudo corn-control-update-blocklist               # refresh lists now
sudoedit /etc/dnscrypt-proxy/allowed-names.txt   # un-block a false positive (unlock first)
sudoedit /etc/corn-control/extra-blocked.txt     # add your own domains (unlock first)
```

After editing, run `sudo corn-control-update-blocklist` (for blocked lists) or `sudo systemctl restart dnscrypt-proxy`.

## Test it yourself

```bash
drill forcesafesearch.google.com && drill www.google.com   # same IP = SafeSearch works
drill @8.8.8.8 archlinux.org                               # should fail (firewall)
curl -m4 https://1.1.1.1/dns-query                         # should fail (DoH blocked)
sudo nft list table inet corn_control                      # counters show blocked attempts
```

## Things to know

- **VPN (ProtonVPN):** a system VPN doesn't bypass the filter. dnscrypt-proxy's encrypted queries simply travel through the tunnel, and the firewall rejects plain DNS to the VPN's own resolver on the tunnel interface too. But WireGuard/OpenVPN clients often push their own DNS or rewrite resolv.conf, and that breaks name resolution until the guard restores it (within 5 minutes). Set the Proton app to use **custom DNS = 127.0.0.1** to avoid that.
- **Browser VPN/proxy extensions** are blocked through the `proxy` permission. Firefox needs version 153 or newer for this. Legitimate extensions that ask for that permission (e.g. FoxyProxy) are blocked as well. The locked proxy settings also block a corporate proxy, so if you need one, change `ProxySettings` / `Proxy` in the policies.
- **Proxies and VPNs aren't blocked** by the CleanBrowsing *Adult* filter itself. The *Family* filter blocks them. To make it stricter, change `UPSTREAM="cleanbrowsing-family"` and `CB_BOOTSTRAP=("185.228.168.168" "185.228.169.168")` at the top of the script and re-run it.
- **Docker** containers use their own DNS config. That's usually fine, but they get the firewall rules too.
- **Tor Browser** bypasses DNS entirely (Brave's built-in Tor windows are disabled by policy, the standalone Tor Browser isn't). If you want to close that door as well, don't install it, or add Tor directory hosts to the extra-blocked list.
- **Root can undo anything.** The lock and cooldown don't make it impossible, they just make it slow and deliberate. That's the point: stopping an impulse, not an admin.
- **Restart open browsers** after the first run so they load the policies. Check that they loaded under `about:policies` (Firefox) or `chrome://policy` / `brave://policy`.

## Troubleshooting

- *"dnscrypt-proxy is not answering"*: run `journalctl -u dnscrypt-proxy -n 50`. The script stops **before** touching system DNS, so the machine keeps working.
- *A normal site won't load*: it's probably a false positive. Put it in `allowed-names.txt`, then restart dnscrypt-proxy.
- *Remove everything*: `sudo corn-control-unlock`, then disable `corn-control-guard.timer`, `corn-control-update.timer` and `corn-control-firewall.service`, run `nft delete table inet corn_control`, delete `/etc/NetworkManager/conf.d/90-corn-control.conf` and re-enable `systemd-resolved`.

## macOS

`corn-control-macos.sh` does the same thing on macOS with the native tools: launchd instead of systemd, pf instead of nftables, `networksetup` instead of resolv.conf, Managed Preferences instead of `policies.json`, and `chflags uchg` instead of `chattr +i`. It runs on the stock `/bin/bash` 3.2 and needs nothing installed first (no Homebrew).

```bash
curl -fsSL https://raw.githubusercontent.com/mateuszgorecki/corn-control/main/corn-control-macos.sh | sudo bash
```

Or from a clone: `sudo bash corn-control-macos.sh`.

The `--lock` / `--no-lock` flags work the same way. At the end it runs 8 self-checks.

### What's different on macOS

| Layer | macOS version |
|---|---|
| **Install location** | Everything lives in `/usr/local/corn-control` (`bin/`, `etc/`, `var/` for logs). It's root-owned on purpose: Homebrew on Intel Macs makes `/usr/local/etc` and `/usr/local/sbin` user-writable, and these scripts run as root. `corn-control-lock`, `corn-control-unlock` and `corn-control-update-blocklist` are symlinked into `/usr/local/bin`. |
| **Resolver** | `dnscrypt-proxy` is downloaded from its official GitHub release (latest version, arm64 or x86_64) and runs as the launchd daemon `local.corn-control.dnscrypt-proxy`. Re-run the script to upgrade it. |
| **System DNS** | Every network service (Wi-Fi, Ethernet, Thunderbolt, USB adapters, disabled ones too) gets the manual DNS server `127.0.0.1`, which overrides DHCP and IPv6 router advertisements. Services added later (a new adapter, iPhone hotspot) are pinned by the guard. |
| **iCloud Private Relay** | Safari's Private Relay sends DNS past the local resolver. `mask.icloud.com` and `mask-h2.icloud.com` are blocked, which is Apple's documented signal for Private Relay to switch itself off on this network. |
| **Firewall** | pf anchor `corn_control` with the same rules as the nftables table. `/etc/pf.conf` isn't edited: the main ruleset is loaded from it with one extra `anchor "corn_control"` line, and pf is enabled with `pfctl -E`. |
| **Browsers** | Policies go to `/Library/Managed Preferences/<domain>.plist` for Firefox, Zen, Chrome, Chromium, Brave and Edge. Managed Preferences take priority over anything set in `~/Library/Preferences`. Existing keys in those files are kept (an existing file is backed up once to `/usr/local/corn-control/etc/managed/<domain>.plist.orig`). Without MDM, macOS may empty that folder at boot, so the guard puts the files back. Safari has no DoH setting and uses system DNS. |
| **Guard** | The launchd daemon `local.corn-control.guard` runs at boot and every 5 minutes. It restores the pf anchor, the resolver and updater daemons, DNS on every network service, and the browser policies. |
| **Blocklist refresh** | The launchd daemon `local.corn-control.update` runs daily around noon (after wake if the Mac was asleep). Same 20000-entry safety check. |
| **Lock** | `chflags uchg` on the configs, launchd plists, scripts, the dnscrypt-proxy binary and the policy files, including `allowed-names.txt`. Unlocking has the same 30-minute cooldown. |

### Commands on macOS

```bash
sudo corn-control-lock
sudo corn-control-unlock
sudo corn-control-update-blocklist
sudo nano /usr/local/corn-control/etc/allowed-names.txt                # un-block a false positive (unlock first)
sudo nano /usr/local/corn-control/etc/extra-blocked.txt                # add your own domains (unlock first)
sudo launchctl kickstart -k system/local.corn-control.dnscrypt-proxy   # restart the resolver
```

### Test it yourself on macOS

```bash
dig +short forcesafesearch.google.com && dig +short www.google.com   # same IP = SafeSearch works
dig @8.8.8.8 apple.com                                               # should fail (firewall)
curl -m4 https://1.1.1.1/dns-query                                   # should fail (DoH blocked)
networksetup -getdnsservers Wi-Fi                                    # 127.0.0.1
sudo pfctl -a corn_control -s rules -v                               # counters show blocked attempts
```

### Things to know on macOS

- **Hotel / airport Wi-Fi with a login page** may not open the portal, because the portal's DNS is ignored. The same is true on Arch.
- **VPN apps and "Encrypted DNS" profiles.** A VPN that pushes its own DNS doesn't bypass the filter (pf rejects plain DNS to it), but it can break name resolution while it's connected. In the VPN app, set custom DNS to `127.0.0.1`. Configuration profiles with DNS settings and apps that install a DNS proxy (System Settings → General → VPN & Filters / Device Management) can override system DNS. corn-control can't block those, so treat installing one as a warning sign.
- **Chrome policies** are checked at `chrome://policy`. Chrome, Brave and Edge apply these policies on unmanaged Macs, but a few other Chrome policies (not the ones used here) only work under MDM.
- **Root can undo anything** here too: `sudo launchctl bootout` stops any daemon. The lock slows you down, it doesn't make it impossible.

### Troubleshooting on macOS

- *"dnscrypt-proxy is not answering"*: run `tail -n 50 /usr/local/corn-control/var/dnscrypt-proxy.log`. System DNS is left untouched in that case.
- *"Port 53 is already in use"*: another local DNS server (dnsmasq, a Docker DNS proxy, AdGuard) is running. Stop it and re-run.
- *Remove everything*: `sudo corn-control-unlock`, then:

  ```bash
  for l in guard update dnscrypt-proxy; do
    sudo launchctl bootout system/local.corn-control.$l
    sudo rm /Library/LaunchDaemons/local.corn-control.$l.plist
  done
  sudo pfctl -a corn_control -F all && sudo pfctl -f /etc/pf.conf
  networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' |
    while IFS= read -r s; do sudo networksetup -setdnsservers "$s" empty; done
  cd "/Library/Managed Preferences" && sudo rm -f org.mozilla.firefox.plist app.zen-browser.zen.plist \
    com.google.Chrome.plist org.chromium.Chromium.plist com.brave.Browser.plist com.microsoft.Edge.plist
  sudo rm -rf /usr/local/corn-control /usr/local/bin/corn-control-*
  ```

  If `/usr/local/corn-control/etc/managed/` has `.plist.orig` backups, copy them back into `/Library/Managed Preferences` before deleting the folder.

## License

[MIT](LICENSE)
