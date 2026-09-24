# dnslock: adult-content filter for Arch Linux

This is one script that blocks adult content at the DNS level for the **whole system**: every browser, every app with a built-in browser, and anything else that looks up a domain. You don't need any extensions.

## Run it

One line, no clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/mateuszgorecki/corn-control/main/dnslock-setup.sh | sudo bash
```

If the repo is private, `curl` gets a 404. Fetch the script through the GitHub CLI instead (`gh auth login` first). `gh` runs as your user and only `bash` runs as root, so your token never reaches the root process:

```bash
gh api repos/mateuszgorecki/corn-control/contents/dnslock-setup.sh \
  -H "Accept: application/vnd.github.raw" | sudo bash
```

Or from a clone:

```bash
git clone https://github.com/mateuszgorecki/corn-control.git
cd corn-control
sudo bash dnslock-setup.sh
```

It takes about a minute and installs everything it needs through `pacman`. Everything it sets up is a systemd service or timer, so from then on it starts by itself at every boot. You never need to run the script again unless you want to change a setting.

At the end it runs 6 self-checks and asks whether to **lock**. Say no the first time and use the machine normally for a day, then run `sudo dnslock-lock`.

To skip the question, pass a flag (after `-s --` when piping):

| Flag | Effect |
|---|---|
| *(none)* | Ask at the end. If there's no terminal to ask on, don't lock. |
| `--no-lock` | Don't ask, don't lock. For unattended installs. |
| `--lock` | Don't ask, lock right away. |

```bash
curl -fsSL https://raw.githubusercontent.com/mateuszgorecki/corn-control/main/dnslock-setup.sh | sudo bash -s -- --no-lock
```

## What it sets up

| Layer | What it does |
|---|---|
| **Resolver** | `dnscrypt-proxy` listens on `127.0.0.1:53`. It sends queries encrypted to the **CleanBrowsing Adult Filter**, the same provider you use on the router. |
| **Blocklists** | HaGeZi **NSFW** (~80k domains), HaGeZi **encrypted-DNS bypass** (~3.3k DoH servers) and **StevenBlack hosts + porn** (~150k domains, includes ads/malware). Together about 220k unique domains. Lists can be plain domains or hosts format; the updater normalizes and de-duplicates them. A timer refreshes them daily. If a download comes back broken, the old list stays. |
| **SafeSearch** | Google, Bing, DuckDuckGo and YouTube (moderate) are forced into safe mode at the DNS level. |
| **System DNS** | `/etc/resolv.conf` → `127.0.0.1`. NetworkManager gets `dns=none` and `systemd-resolved` is turned off, so DNS from Wi-Fi/DHCP gets ignored. |
| **Firewall** | nftables table `inet dnslock`. Plain DNS (53) and DoT (853) are **rejected** unless they go to the local resolver. Public DoH IPs (Cloudflare, Google, Quad9, AdGuard, NextDNS, Mullvad…) are rejected too. |
| **Browsers** | By policy in Firefox, Zen, Chromium, Chrome and Brave: DoH is off, extensions that need the `proxy` permission (browser "VPN" and proxy extensions) are blocked and disabled if already installed, and proxy settings are locked to a direct connection. Firefox's built-in VPN is turned off, and so are Brave's VPN and "Private window with Tor". These policies are written even for browsers you haven't installed yet. Firefox and Zen read `/etc/<browser>/policies/policies.json`, which *replaces* the `policies.json` shipped in the install dir, so the shipped file (e.g. Zen's `DisableAppUpdate`) is merged in. Other Firefox forks can be added to `GECKO_POLICIES` at the top of the script. Chromium-family browsers also get Google SafeSearch and YouTube Restricted forced on. |
| **Guard** | Every 5 minutes a timer checks for drift and puts things back: the firewall table, the resolver, and resolv.conf. |
| **Lock** | `chattr +i` on every config file. Unlocking means waiting through a **30-minute cooldown**. |

## Commands

```bash
sudo dnslock-lock                      # make all files immutable
sudo dnslock-unlock                    # 30-min countdown, then editable (filter stays ON)
sudo dnslock-update-blocklist          # refresh lists now
sudoedit /etc/dnscrypt-proxy/allowed-names.txt   # un-block a false positive (unlock first)
sudoedit /etc/dnslock/extra-blocked.txt           # add your own domains (unlock first)
```

After editing, run `sudo dnslock-update-blocklist` (for blocked lists) or `sudo systemctl restart dnscrypt-proxy`.

## Test it yourself

```bash
drill forcesafesearch.google.com && drill www.google.com   # same IP = SafeSearch works
drill @8.8.8.8 archlinux.org                               # should fail (firewall)
curl -m4 https://1.1.1.1/dns-query                         # should fail (DoH blocked)
sudo nft list table inet dnslock                           # counters show blocked attempts
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
- *Remove everything*: `sudo dnslock-unlock`, then disable `dnslock-guard.timer`, `dnslock-update.timer` and `dnslock-firewall.service`, run `nft delete table inet dnslock`, delete `/etc/NetworkManager/conf.d/90-dnslock.conf` and re-enable `systemd-resolved`.
