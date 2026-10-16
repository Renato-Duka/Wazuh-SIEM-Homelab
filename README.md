# Wazuh SIEM & Suricata IPS Home Lab

## Overview

This is a self-built Security Information and Event Management (SIEM) lab, running [Wazuh](https://wazuh.com) on a local VirtualBox VM, put together to learn how a SIEM actually works end to end rather than just reading about it. That meant standing up the platform itself, enrolling a real endpoint, working through File Integrity Monitoring and real vulnerability data, building a custom log source integration for GitHub from scratch after discovering Wazuh's built-in GitHub module is gated behind a paid GitHub plan I don't have, and later adding Suricata as an inline intrusion prevention system (IPS) whose alerts and blocks feed into the same SIEM.

Everything below is documented as it actually happened, including the parts that didn't fully work (see [File Integrity Monitoring](#file-integrity-monitoring)), because the troubleshooting is as much the point of a lab like this as the finished result.

**What's inside:**

- A working Wazuh manager and dashboard, reachable from the host machine via VirtualBox port forwarding
- A macOS Wazuh agent, enrolled and actively reporting
- File Integrity Monitoring, configured and investigated end to end (partially inconclusive, documented honestly rather than glossed over)
- Vulnerability Detection, explored against real flagged CVEs on the lab agent
- A from-scratch GitHub integration: an org webhook, an ngrok tunnel, a small Python listener, a Wazuh `localfile` block, and a custom alerting rule, replacing the native module that GitHub's Enterprise Cloud requirement blocks
- Suricata 8 running inline via netfilter NFQUEUE, with ~22,000 Emerging Threats malware and exploit signatures set to drop, fail-open bypass, and EVE JSON alerts forwarded into Wazuh
- A hardened macOS endpoint: stealth-mode firewall, outbound app filtering with LuLu, unneeded sharing services closed, and lab ports bound to localhost only

The GitHub integration and the Suricata IPS are scripted and reproducible (see [`scripts/`](scripts)). The VM and dashboard setup below is a walkthrough of what was done, since it's mostly point-and-click through VirtualBox and the Wazuh dashboard rather than something you'd script.

## Contents

- [Lab environment](#lab-environment)
- [Agent deployment](#agent-deployment)
- [File Integrity Monitoring](#file-integrity-monitoring)
- [Vulnerability Detection](#vulnerability-detection)
- [GitHub integration](#github-integration)
- [Suricata IPS](#suricata-ips)
- [Endpoint hardening](#endpoint-hardening)
- [Repo structure](#repo-structure)
- [Setup (GitHub integration)](#setup-github-integration)
- [Setup (Suricata IPS)](#setup-suricata-ips)
- [Troubleshooting notes](#troubleshooting-notes)
- [Security notes](#security-notes)

## Lab environment

The manager runs in a VirtualBox VM: Ubuntu Server (ARM64, since the host is an Apple Silicon Mac and Wazuh's OVA appliance is x86-only), with the indexer, manager, and dashboard all installed in one guest using Wazuh's installation assistant. VirtualBox's default networking is NAT, which means nothing outside the VM can reach it by default, so the first real piece of infrastructure work was port forwarding on the VM's Network settings:

| Host IP | Host port | Guest port | Purpose |
|---|---|---|---|
| 127.0.0.1 | 8443 | 443 | Dashboard (HTTPS) |
| 127.0.0.1 | 1515 | 1515 | Agent enrollment |
| 127.0.0.1 | 1514 | 1514 | Agent event traffic |

Each rule is bound to `127.0.0.1`. Leaving Host IP blank makes VirtualBox listen on every interface, which exposes the dashboard and agent ports to anyone on the same Wi-Fi.

With that in place, the dashboard becomes reachable at `https://localhost:8443` from the host machine, and agents on the host (or elsewhere on the LAN) can enroll and ship data to `127.0.0.1` on the mapped ports.

Wazuh's own architecture, for reference: the **indexer** (OpenSearch under the hood) stores and searches everything, the **manager** runs `analysisd` (the rule engine) and receives agent traffic, **Filebeat** ships parsed data from the manager into the indexer, and the **dashboard** (OpenSearch Dashboards) is the web UI on top of it all.

## Agent deployment

Deployed the Wazuh agent onto a macOS host and pointed it at the manager:

```bash
curl -so wazuh-agent.pkg https://packages.wazuh.com/4.x/macos/wazuh-agent-4.14.7-1.arm64.pkg
echo "WAZUH_MANAGER='127.0.0.1'" > /tmp/wazuh_envs
sudo installer -pkg ./wazuh-agent.pkg -target /
```

`WAZUH_MANAGER` tells the installer where to enroll. It's `127.0.0.1` because of the port forwarding above. The agent's traffic on 1514/1515 gets forwarded straight into the VM from there. After install, confirmed all five agent-side daemons came up (`wazuh-modulesd`, `wazuh-logcollector`, `wazuh-syscheckd`, `wazuh-agentd`, `wazuh-execd`) and the agent showed **Active** in the dashboard's Agents view.

Once enrolled, spent time in the dashboard's **Threat Hunting** view getting familiar with what a healthy agent's baseline activity actually looks like, and learning the practical distinction between a SIEM (aggregates and correlates security data across many sources, which is what Wazuh is), an XDR (extends that with active cross-tool response), and an EDR (endpoint-only detection and response), useful vocabulary for understanding where Wazuh sits relative to other security tooling.

## File Integrity Monitoring

Tried to get a live FIM alert end to end: added a custom watched directory under `<syscheck>` in the agent's `ossec.conf` with `realtime="yes" report_changes="yes"`, dropped the scan `<frequency>` down to 60s for faster iteration, granted the agent binary Full Disk Access in macOS's Privacy settings (required for realtime FSEvents-based monitoring), and confirmed rule descriptions like "Integrity checksum changed" genuinely exist in the manager's ruleset (`ruleset/rules/0015-ossec_rules.xml`).

Despite all of that lining up, no syscheck alert ever appeared in `alerts.log`, only in the newer **Inventory** tab, which is backed by a different, database-synchronization-based FIM pipeline in current Wazuh versions, separate from the classic rule/decoder path those alert rules expect. Ruled out the usual suspects along the way, including clock skew throwing off the dashboard's search window, checking the wrong log file (`ossec.log` vs `alerts.log`), and missing ruleset files, before landing on that architecture-mismatch theory. Didn't chase it further into `analysisd` debug logging. Documenting it here as an open thread rather than a solved one, and moved on deliberately rather than burning more time on it.

## Vulnerability Detection

Spent time in the **Vulnerability Detection** module going through real flagged CVEs on the lab agent: learning to read a CVSS vector string (e.g. `CVSS:3.1/AV:L/AC:L/PR:N/UI:R/S:U/C:H/I:N/A:N`) and what each field means (attack vector, attack complexity, privileges required, user interaction, scope, and the confidentiality/integrity/availability impact triad), and working through the CWE (Common Weakness Enumeration) categories that showed up across the flagged packages, things like integer/buffer overflow, out-of-bounds read/write, use-after-free, type confusion, race conditions, memory corruption, information disclosure, authorization/permissions issues, path traversal, injection, parsing issues, and inconsistent-state issues, and why each one gets classified as a genuine vulnerability by weighing it against the CIA triad (does it threaten confidentiality, integrity, or availability).

## GitHub integration

This is the piece with actual scripts and a reproducible setup, detailed below.

### The blocker

Wazuh ships a native `<wodle name="github">` module that polls GitHub's organization audit-log REST API (`GET /orgs/{org}/audit-log`). That endpoint is restricted to orgs on **GitHub Enterprise Cloud**. On a free/Team org it returns a 404, even with a correctly scoped token:

```json
{"message":"Not Found","documentation_url":"https://docs.github.com/rest/orgs/orgs#get-the-audit-log-for-an-organization","status":"404"}
```

![Native module blocked with a 404](screenshots/01-native-module-blocked-404.png)

The manager-side "Cloud Security → GitHub" dashboard confirms it: the wiring is correct, but there's nothing to show, since the underlying API call never succeeds.

![Cloud Security GitHub panel, empty](screenshots/02-cloud-security-dashboard-empty.png)

### The fix: push instead of poll

Webhooks are available on every GitHub plan. So instead of Wazuh polling an API it doesn't have access to, GitHub pushes events out directly:

```mermaid
flowchart LR
    GH[GitHub org webhook] -->|HTTPS POST| NG[ngrok tunnel]
    NG --> L[Python listener\nlocalhost:8000]
    L -->|appends JSON line| F[github_events.log]
    F -->|localfile, log_format=json| A[Wazuh agent]
    A -->|encrypted agent channel| M[Wazuh manager]
    M -->|custom rule 100100| AL[alerts.log]
    AL --> D[Dashboard: Discover]
```

Since the machine running the listener sits behind NAT with no public IP, [ngrok](https://ngrok.com) provides the public URL, tunneling straight back to a local port. Every event a GitHub webhook can fire (member invited, repo created, settings changed, and so on) travels this exact path, and nothing about it requires a paid GitHub plan.

## Suricata IPS

Wazuh watches what happens *on* hosts. Suricata adds visibility into the traffic *between* them, and in inline mode it can block that traffic, not just log it. It runs on the same Ubuntu VM as the Wazuh manager, so its alerts are local files Wazuh can read directly.

### IDS first, then IPS

Suricata 8.0.3 came from Ubuntu's repos, with the free [Emerging Threats Open](https://rules.emergingthreats.net/) ruleset pulled by `suricata-update` (69,153 rules loaded, 53,195 enabled by default). The first pass ran it as a passive IDS with `af-packet` capture on the VM's NIC, which only watches copies of packets, so a broken config can't take the network down. Validating the config before every start:

![Config test passes](screenshots/14-suricata-config-test-pass.png)
![Suricata running in IDS mode](screenshots/15-suricata-service-running.png)

To prove detection worked, a custom signature alerts on any ICMP (`sid:1000001` in [`config/suricata/local.rules`](config/suricata/local.rules)). One `ping` later, `fast.log` showed it, alongside real ET alerts for the `apt` traffic from the install itself:

![First alerts in fast.log](screenshots/16-first-alerts-in-fast-log.png)

### Forwarding alerts into Wazuh

Suricata writes structured alerts to `eve.json`. A single `<localfile>` block with `log_format=json` on the manager ([`config/suricata_localfile_snippet.xml`](config/suricata_localfile_snippet.xml)) is enough, since Wazuh ships decoders and rules for EVE JSON already. Searching `rule.groups:suricata` in Threat Hunting showed the test alerts arriving:

![Suricata alerts in Wazuh](screenshots/17-suricata-alerts-in-wazuh.png)

### Going inline with NFQUEUE

An IPS has to sit *in* the traffic path so it can decide whether each packet continues. On Linux that's netfilter's NFQUEUE: iptables hands packets to a queue, Suricata reads the queue, and returns a verdict (accept or drop) for each one.

- A systemd drop-in ([`config/suricata/override.conf`](config/suricata/override.conf)) replaces the packaged `--af-packet` start command with `-q 0`, so Suricata reads from queue 0.
- Two iptables rules send the VM's `INPUT` and `OUTPUT` traffic to that queue with `--queue-bypass`. That flag makes it **fail open**: if Suricata stops or crashes, traffic keeps flowing instead of the VM going offline.
- `iptables-persistent` saves the rules so they survive reboots.

The test was a `drop` signature for ICMP to `8.8.8.8` only (`sid:1000002`). Pinging `8.8.8.8` got 100% packet loss, pinging `1.1.1.1` still worked, and `fast.log` recorded the block with a `[Drop]` tag:

![IPS drop confirmed](screenshots/18-ips-drop-confirmed.png)

### Blocking real threats

ET rules ship as `alert`. [`config/suricata/drop.conf`](config/suricata/drop.conf) tells `suricata-update` to rewrite three high-confidence groups (malware, exploit, mobile malware) to `drop`. It converted 30,259 rules, 22,063 of them enabled and actively blocking. Everything else stays alert-only, so noisier categories can't break normal traffic. The plan is to watch alerts in Wazuh and widen `drop.conf` gradually, disabling any false-positive rule by SID in `disable.conf`.

![Drop rules applied](screenshots/19-drop-rules-applied.png)

### Limits

- **It protects the VM, not the Mac.** Inline mode only sees traffic to and from the VM itself. Routing the Mac through it (a WireGuard tunnel into the VM) needs bridged networking, which hung VirtualBox on this Apple Silicon host, so that's an open item.
- **Most traffic is HTTPS.** Suricata still sees DNS lookups, TLS server names, certificates, and destination IPs, but not encrypted page content.
- **Memory.** With the full ruleset loaded, Suricata uses about 1.3 GB, so the VM went from 4 GB to 6 GB alongside the Wazuh indexer.

## Endpoint hardening

Monitoring a laptop that's wide open defeats the point, so the macOS agent host got tightened up too. A `sudo lsof -i -P -n` review of every listening socket and outbound connection drove most of these:

- **macOS firewall** on, with **stealth mode** (no replies to pings or probes) and "automatically allow downloaded signed software" turned off, so new apps have to ask before accepting connections.
- **Remote Login (SSH) and File Sharing (SMB) turned off.** Port 22 was listening on all interfaces.
- **[LuLu](https://objective-see.org/products/lulu.html)**, a free open-source outbound firewall, blocks unknown apps from phoning home. Wazuh and the VirtualBox port forwards keep working because localhost traffic is allowed.
- **Background items reviewed.** One surprise in Login Items was the Wazuh agent itself, which turned out to be this lab's own agent pointed at `127.0.0.1`, a good reminder to verify where an agent reports (`grep -A3 "<server>" /Library/Ossec/etc/ossec.conf`) before trusting it.
- **Agent re-enrolled** with `agent-auth` after the duplicate stale registration was deleted from the dashboard.

## Repo structure

```
.
├── scripts/
│   ├── mac/
│   │   ├── install_ngrok.sh      # installs ngrok without Homebrew
│   │   ├── webhook_listener.py   # receives + logs webhook deliveries
│   │   ├── start_listener.sh     # runs listener + ngrok, prints the public URL
│   │   └── configure_agent.sh    # adds the <localfile> block, restarts agent
│   ├── manager/
│   │   ├── add_custom_rule.sh    # adds rule 100100, restarts manager
│   │   ├── enable_archiving.sh   # optional: turns on logall for debugging
│   │   └── setup_suricata_ips.sh # Suricata inline IPS + Wazuh forwarding
│   └── github/
│       └── create_org_webhook.sh # registers the org webhook via GitHub's API
├── config/
│   ├── localfile_snippet.xml     # the exact agent config block, for manual use
│   ├── local_rules_snippet.xml   # the exact manager rule, for manual use
│   ├── suricata_localfile_snippet.xml  # eve.json block for the manager
│   └── suricata/
│       ├── override.conf         # systemd drop-in: run Suricata on NFQUEUE 0
│       ├── drop.conf             # ET groups converted from alert to drop
│       ├── local.rules           # alert + drop test signatures
│       └── suricata.yaml.changes # the only lines changed in suricata.yaml
└── screenshots/                  # this lab's actual run, in order
```

## Setup (GitHub integration)

**Prerequisites:** a Wazuh manager (built against 4.14.7) with at least one enrolled agent, a GitHub organization you own or admin, a free [ngrok](https://ngrok.com) account, and `python3` on the machine running the listener (stdlib only, no third-party packages).

**1. Install and authorize ngrok** (on the machine that will run the listener):

```bash
./scripts/mac/install_ngrok.sh
ngrok config add-authtoken <your-authtoken>   # from https://dashboard.ngrok.com
```

![ngrok setup](screenshots/03-ngrok-product-picker.png)

**2. Start the listener + tunnel:**

```bash
./scripts/mac/start_listener.sh
```

Backgrounds both the Python listener and `ngrok http 8000`, then reads ngrok's local API to print the public URL automatically:

![Live ngrok tunnel](screenshots/04-ngrok-tunnel-live.png)

**3. Register the webhook.** Either let the script do it:

```bash
export GITHUB_TOKEN=ghp_xxx        # needs admin:org (classic) or the org "Webhooks" permission
export GITHUB_ORG=your-org-login
export WEBHOOK_URL=https://xxxx.ngrok-free.dev   # printed by start_listener.sh
./scripts/github/create_org_webhook.sh
```

or create it by hand under **Org Settings → Webhooks → Add webhook**, content type `application/json`, events set to "Send me everything."

![Webhook created in GitHub](screenshots/05-github-webhook-created.png)

GitHub fires an automatic `ping` event the moment the webhook is saved. It shows up on both ends. The listener catches it locally, and GitHub's own delivery log confirms it went out successfully:

![Listener receives the ping event](screenshots/06-listener-receives-ping.png)
![GitHub confirms the delivery](screenshots/07-github-confirms-delivery.png)

**4. Point the Wazuh agent at the log file:**

```bash
sudo ./scripts/mac/configure_agent.sh
```

**5. Add the alerting rule on the manager:**

```bash
sudo ./scripts/manager/add_custom_rule.sh
```

![Custom rule added to local_rules.xml](screenshots/10-custom-rule-added.png)
![Manager restarts clean](screenshots/11-manager-clean-restart.png)

**6. Verify.** Trigger any activity in the org (or click "Redeliver" on the ping event from GitHub's webhook delivery log), then check the manager:

```bash
sudo grep -i github /var/ossec/logs/alerts/alerts.log
```

![Alert 100100 fires](screenshots/12-alert-fires-in-alerts-log.png)

...and in the dashboard, **Explore → Discover**, search `rule.id:100100`:

![Discover shows the alert](screenshots/13-discover-shows-alert.png)

## Setup (Suricata IPS)

**Prerequisites:** the Wazuh manager VM (Ubuntu), at least 6 GB of RAM for the VM, and a VM snapshot taken first, because a mistake in the NFQUEUE step can cut the VM's network.

**1. Run the setup script** on the manager, from the repo root:

```bash
sudo ./scripts/manager/setup_suricata_ips.sh
```

It installs Suricata, applies `drop.conf`, installs the NFQUEUE drop-in, adds the fail-open iptables rules and persists them, and adds the `eve.json` block to `ossec.conf`. `local.rules` is installed empty on purpose.

**2. Test detection and blocking** by copying the two test signatures from [`config/suricata/local.rules`](config/suricata/local.rules) into `/etc/suricata/rules/local.rules`, then:

```bash
sudo systemctl restart suricata
ping -c 3 8.8.8.8      # should fail: dropped by sid 1000002
ping -c 3 1.1.1.1      # should work
sudo tail -3 /var/log/suricata/fast.log
```

**3. Check Wazuh.** In the dashboard, search `rule.groups:suricata`.

**4. Remove the test signatures** so normal pings work and alerts don't flood:

```bash
echo '' | sudo tee /etc/suricata/rules/local.rules
sudo systemctl restart suricata
```

**Weekly:** `sudo suricata-update && sudo systemctl restart suricata` to pull new signatures.

## Troubleshooting notes

**"wazuh-modulesd: ERROR: Unknown module 'github'"** shows up if you try the native module's *old* XML syntax (`<wodle name="github">`). Current Wazuh versions use a dedicated top-level `<github>` block with `<enabled>` instead of `<disabled>`. Moot here since the module still hits the Enterprise Cloud wall regardless of syntax, but worth knowing if you go looking at the built-in module first.

**Events arriving but no alert showing up.** By default, Wazuh only writes to `alerts.log` for events that match a rule at severity level 3 or higher. A JSON localfile with no matching custom rule gets silently processed and dropped, no alert, no error. To confirm data is actually reaching the manager while still debugging a new log source (before a rule exists for it), run `scripts/manager/enable_archiving.sh` and watch `archives.log`, which records everything, alerted or not. Before enabling it, the check comes back empty:

![archives.log empty before enabling](screenshots/08-archives-log-empty-before.png)

After enabling it and resending an event, the same check confirms delivery:

![archives.log confirms delivery](screenshots/09-archives-log-confirmed-after.png)

That's what proved the pipeline was working end to end before rule 100100 existed.

**ngrok URLs are ephemeral.** A free ngrok account without a reserved static domain gets a new random URL every time the tunnel restarts. Update the webhook's payload URL (via the GitHub UI or by re-running `create_org_webhook.sh`) whenever the tunnel changes. A reserved static domain (free accounts get one) avoids this.

**Suricata won't load its config.** `suricata.yaml` is YAML, so one extra space after a dash (`-  interface:`) breaks it. Run `sudo suricata -T -c /etc/suricata/suricata.yaml` after every edit.

**`systemctl edit` silently discards the override.** Lines must go *between* the two `###` comment markers at the top, with no leading `#`. Anything below "Edits below this comment will be discarded" is ignored, as is anything commented out. Writing the file directly to `/etc/systemd/system/suricata.service.d/override.conf` avoids the editor entirely. Check the result with `systemctl cat suricata | grep ExecStart`.

**The standard IDS test site didn't resolve.** `curl http://testmynids.org/uid/index.html` failed with a DNS error even though the VM had internet. A custom ICMP signature made a more reliable test anyway, since it doesn't depend on a third-party site.

**Dashboard health check failures after rotating the admin password.** After changing the `admin` password with `wazuh-passwords-tool.sh` and rebooting, the dashboard showed "Network Error" and "Index pattern `wazuh-alerts-*` found: no", even though `curl -k -u admin:'...' https://localhost:9200/_cluster/health` returned green and `filebeat test output` passed. The indexer just takes several minutes to start on a memory-constrained VM, and the browser held a stale session. Restarting `wazuh-dashboard`, logging in from a fresh browser session, and retrying the health check fixed it. The password tool also warns to restart the services afterward, which matters.

## Security notes

- No tokens are hardcoded anywhere in these scripts. `GITHUB_TOKEN` and the ngrok authtoken are always supplied by the environment or ngrok's own local config, never committed.
- The webhook has no secret configured in this lab setup (kept simple on purpose). For anything beyond a personal lab, set a webhook secret and verify the `X-Hub-Signature-256` header in the listener before trusting a payload.
- The listener binds to `127.0.0.1` only. It's never directly exposed; ngrok is the only thing that can reach it from outside.
- VirtualBox port forwards are bound to `127.0.0.1`, so the dashboard and agent ports are reachable only from the host, not the local network.
- No passwords are committed. Wazuh generates its credentials in `wazuh-install-files.tar` on the manager; those, `client.keys`, certificates, and shell history stay out of this repo.

## What this is / isn't

A personal home-lab project built to learn Wazuh's log-collection and rule-writing model hands-on, using GitHub as a real, non-trivial log source, on top of a broader from-scratch SIEM build (VM networking, agent deployment, FIM, vulnerability data) and a Suricata inline IPS feeding the same SIEM. Not production-hardened: no delivery retries beyond what GitHub's webhook redelivery gives you, and the tunnel is a single point of failure. For real production use, this same pattern (webhook → listener → localfile → rule) would move to a proper always-on ingress instead of a personal ngrok tunnel.
