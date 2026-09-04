# Automated Debian VPS Build

Unattended-ish Debian 13 (Trixie) install with hardening applied automatically at
first install. Designed for VPS providers where the only console is VNC with no
copy/paste, so the sole thing typed by hand is a short URL.

## Repo contents

| File | Purpose |
|---|---|
| `p.cfg` | Debian installer preseed. Answers the install questions and fetches `h.sh`. |
| `h.sh` | Hardening + config script. Runs at the end of the install. |
| `check.sh` | Read-only audit. Verifies what actually applied. Changes nothing. |

## How it fits together

1. You type a short URL at the installer boot prompt.
2. Cloudflare redirects `ardorkeep.com/p` to the raw `p.cfg` in this repo.
3. The installer downloads `p.cfg` and uses it to answer its own questions.
4. At the end of the install, `preseed/late_command` downloads `h.sh` and runs it
   inside the installer chroot.
5. First boot comes up hardened: key-only SSH, firewalld, fail2ban, auto security
   updates.

## Install procedure

### 1. Boot the Debian netinst ISO

At the installer menu, arrow down to **Install** (the text installer — more
reliable with preseeds than Graphical install).

Press **Tab** (BIOS mode) or **e** (UEFI mode) to edit the boot line. The existing
parameters appear at the bottom. Do not delete them. Append a space and:

```
auto=true priority=high url=ardorkeep.com/p
```

Press **Enter**.

### 2. Answer the prompts that remain

At `priority=high` the installer still shows medium-and-above questions, but the
defaults come from `p.cfg`, so most are just Enter.

- **User password** — deliberately not preseeded. Set it here.
- **Package survey / scan extra media** — answer No (already the default).
- **Partitioning** — read this one. `p.cfg` wipes the target disk.

### 3. Wait

The install runs, then `late_command` pulls `h.sh` and executes it. If it fails
you get a red "Failed to run preseeded command" screen — select Continue, the
install still finishes, and you fix it after boot (see Troubleshooting).

### 4. Verify before you close the console

Log in at the console as `david`, then from your workstation:

```
ssh david@<ip>
```

Do not close the VNC console until an SSH session works. Root login is disabled
and password auth is off, so the SSH key is the only way in.

### 5. Audit

```
curl -sL https://raw.githubusercontent.com/Urgent2030/vps/main/check.sh -o check.sh
sudo bash check.sh 2>&1 | tee check-out.txt
```

## What h.sh does

| Area | Setting |
|---|---|
| Packages | openssh-server, sudo, curl, ca-certificates, firewalld, fail2ban, unattended-upgrades, chrony, rsyslog, cockpit |
| Admin user | Creates `david`, adds to sudo, pulls pubkey from `github.com/Urgent2030.keys`. Aborts if no key is returned. |
| Root | Password locked (`passwd -l root`) |
| SSH | No root login, no password auth, `AllowUsers david`, MaxAuthTries 3, LoginGraceTime 30, no X11/agent/TCP forwarding |
| Firewall | firewalld, default zone `public`, all services removed, SSH allowed via rate-limited rich rule (10/min) |
| fail2ban | sshd jail, 5 failures in 10 min = 1 hour ban, `firewallcmd-ipset` action |
| Updates | unattended-upgrades, security origins only, no automatic reboot |
| sysctl | rp_filter, syncookies, no redirects, no source routing, dmesg_restrict, kptr_restrict, ASLR, sysrq off |
| Mounts | `/tmp` and `/dev/shm` as tmpfs with `noexec,nosuid,nodev` |
| Logging | Persistent journal, 500M cap, 1 month retention |
| Cockpit | Bound to `127.0.0.1:9090` only — tunnel to reach it |
| Misc | UTC timezone, UMASK 027, purges rpcbind/nfs-common/avahi/cups |

Everything is idempotent. Re-running is safe.

## Accessing Cockpit

Not exposed publicly by design. From your workstation:

```
ssh -L 9090:127.0.0.1:9090 david@<ip>
```

Then open `https://localhost:9090`.

## Cloudflare redirect setup

One-time, per domain.

1. Cloudflare dashboard → select domain → **Rules** → **Overview**
2. **Create rule** → **Redirect Rule**
3. Name: `preseed`
4. **Custom filter expression**:
   `(http.host eq "ardorkeep.com" and http.request.uri.path eq "/p")`
5. Target URL (static):
   `https://raw.githubusercontent.com/Urgent2030/vps/main/p.cfg`
6. Status code: 302 while testing, 301 once confirmed
7. Preserve query string: off
8. Deploy

If prompted that the rule may not apply, choose **Create a new proxied DNS
record**: type A, name the apex domain, address `192.0.2.1`. That address
discards the request — the redirect fires at Cloudflare's edge and nothing ever
reaches it. The record must be proxied (orange cloud) or the rule never sees the
traffic.

Verify:

```
curl -sL http://ardorkeep.com/p | head -3
```

Should print the preseed's locale lines. HTML means the redirect target is wrong.

## Troubleshooting

### "Failed to run preseeded command ... exit code 100"

Exit 100 is apt. Select Continue, let the install finish, log in at the console
and read the log:

```
sudo tail -40 /var/log/hardening.log
```

Then re-run on the booted system, where errors are easier to read and systemd is
actually running:

```
sudo curl -fsSL https://raw.githubusercontent.com/Urgent2030/vps/main/h.sh -o /root/h.sh
sudo bash -x /root/h.sh 2>&1 | tail -40
```

### Script stops partway with no obvious error

`set -euo pipefail` aborts on the first non-zero exit. firewalld in particular
returns non-zero for benign states like `ZONE_ALREADY_SET`. The last line in
`hardening.log` is the one that failed.

### Install media left in apt sources

Symptom: `apt-get update` fails with "does not have a Release file" pointing at
`cdrom:`. Prevented by `d-i apt-setup/cdrom/set-first boolean false` in `p.cfg`.
`h.sh` also strips it defensively at the start.

### Cannot SSH after install

Check in this order:

```
sudo firewall-cmd --list-all          # is SSH allowed?
sudo systemctl status ssh
sudo ss -tlnp | grep :22
ssh-keygen -lf /home/david/.ssh/authorized_keys
```

Then from the client, `ssh -v david@<ip>`:

- **"No authentication method available"** — client-side. Your SSH client isn't
  offering a key. Point it at the private key matching the fingerprint above.
- **"Permission denied (publickey)"** — server is up and rejecting the key.
  Fingerprint mismatch.
- **Timeout / connection refused** — firewall or sshd, not the key.

### Locked out entirely

Provider console, or boot the provider's rescue image and mount the volume.
This is why the VNC console stays open until SSH is confirmed.

## Editing the config

Change the variables at the top of `h.sh`:

```bash
ADMIN_USER="david"
GITHUB_USER="Urgent2030"
SSH_PORT="22"
TIMEZONE="Etc/UTC"
```

`raw.githubusercontent.com` caches for a few minutes. After committing, confirm
the CDN has the new version before booting an install:

```
curl -sL https://raw.githubusercontent.com/Urgent2030/vps/main/h.sh | grep -n IN_CHROOT
```

## Known gaps

- The SSH key is RSA 4096. ed25519 is the better modern default.
- No off-box log shipping. Local logs are worthless on a compromised host.
- No auditd or file integrity monitoring. Deliberate — detection you never read
  is not worth the noise on a personal box.
- If Tailscale is added later, the firewall model changes: close port 22 entirely,
  `firewall-cmd --zone=trusted --add-interface=tailscale0`, and fail2ban stops
  mattering.
