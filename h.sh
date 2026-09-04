#!/usr/bin/env bash
# Debian 12/13 VPS hardening + config
# Runs from preseed late_command (inside installer chroot) or standalone as root.
# Idempotent - safe to re-run.

set -euo pipefail

########## SETTINGS ##########
ADMIN_USER="david"
GITHUB_USER="Urgent2030"
SSH_PORT="22"
TIMEZONE="Etc/UTC"
##############################

LOG=/var/log/hardening.log
exec > >(tee -a "$LOG") 2>&1
echo "=== hardening start $(date -Is) ==="

[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

# Detect installer chroot: systemd not running as PID 1
IN_CHROOT=0
[[ -d /run/systemd/system ]] || IN_CHROOT=1
echo "chroot mode: $IN_CHROOT"

export DEBIAN_FRONTEND=noninteractive
APT_INSTALL="apt-get install -y --no-install-recommends"

##### packages #####
# The netinst media stays in sources.list during install and breaks apt-get update
sed -i '/cdrom:/d' /etc/apt/sources.list 2>/dev/null || true
sed -i '/cdrom:/d' /etc/apt/sources.list.d/*.list 2>/dev/null || true
[[ -f /etc/apt/sources.list.d/debian.sources ]] && \
  sed -i '/^URIs: cdrom/,+3d' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true

apt-get update
$APT_INSTALL \
  openssh-server sudo curl ca-certificates \
  firewalld fail2ban unattended-upgrades apt-listchanges \
  chrony rsyslog cockpit

##### admin user + ssh key #####
id "$ADMIN_USER" &>/dev/null || useradd -m -s /bin/bash "$ADMIN_USER"
usermod -aG sudo "$ADMIN_USER"

HOME_DIR=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$HOME_DIR/.ssh"
curl -fsSL "https://github.com/${GITHUB_USER}.keys" -o "$HOME_DIR/.ssh/authorized_keys"
[[ -s "$HOME_DIR/.ssh/authorized_keys" ]] || { echo "FATAL: no keys fetched"; exit 1; }
chown "$ADMIN_USER:$ADMIN_USER" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
echo "keys installed:"
ssh-keygen -lf "$HOME_DIR/.ssh/authorized_keys"

# lock root password login entirely
passwd -l root || true

##### sshd #####
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AllowUsers ${ADMIN_USER}
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
chmod 644 /etc/ssh/sshd_config.d/99-hardening.conf
sshd -t && echo "sshd config OK"

##### firewall (firewalld) #####
# In the installer chroot the daemon isn't running, so use the offline tool.
# On a live system use firewall-cmd --permanent and reload at the end.
# Every call is tolerant: firewalld returns non-zero for "already set".
if [[ $IN_CHROOT -eq 1 ]]; then
  fw() { firewall-offline-cmd "$@" || echo "  [skip] $*"; }
else
  fw() { firewall-cmd --permanent "$@" || echo "  [skip] $*"; }
fi

fw --set-default-zone=public
fw --zone=public --remove-service=ssh
fw --zone=public --remove-service=dhcpv6-client
fw --zone=public --remove-service=cockpit
# rate-limited ssh instead of a plain accept
fw --zone=public --add-rich-rule='rule service name="ssh" accept limit value="10/m"'

[[ $IN_CHROOT -eq 0 ]] && { firewall-cmd --reload || true; }
echo "--- firewall result ---"
firewall-cmd --list-all 2>/dev/null || firewall-offline-cmd --list-all 2>/dev/null || true

##### fail2ban #####
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend   = systemd
banaction = firewallcmd-ipset
bantime   = 1h
findtime  = 10m
maxretry  = 5

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF

##### unattended upgrades #####
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/51unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

##### sysctl #####
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# network
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0

# kernel
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.randomize_va_space = 2
kernel.sysrq = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
EOF
[[ $IN_CHROOT -eq 0 ]] && sysctl --system >/dev/null || true

##### /tmp and /dev/shm hardening (works with single-partition layout) #####
if ! grep -q '^tmpfs /tmp' /etc/fstab; then
  echo 'tmpfs /tmp tmpfs defaults,rw,nosuid,nodev,noexec,relatime,size=512M 0 0' >> /etc/fstab
fi
if ! grep -q '^tmpfs /dev/shm' /etc/fstab; then
  echo 'tmpfs /dev/shm tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0' >> /etc/fstab
fi

##### logging #####
install -d -m 2755 /var/log/journal
install -d -m 755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-local.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
MaxRetentionSec=1month
EOF

##### misc #####
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
# Trixie's login.defs has no UMASK line, so append rather than substitute
grep -q '^UMASK' /etc/login.defs || printf 'UMASK\t\t027\n' >> /etc/login.defs

# Cockpit: bind to localhost only, reach it via ssh -L 9090:127.0.0.1:9090
install -d -m 755 /etc/systemd/system/cockpit.socket.d
cat > /etc/systemd/system/cockpit.socket.d/listen.conf <<'EOF'
[Socket]
ListenStream=
ListenStream=127.0.0.1:9090
EOF

# strip services a VPS doesn't need
apt-get purge -y rpcbind nfs-common avahi-daemon cups 2>/dev/null || true
apt-get autoremove -y

##### enable units (start happens at boot) #####
systemctl enable ssh firewalld fail2ban chrony unattended-upgrades 2>/dev/null || true
# cockpit is socket-activated and stays bound to localhost
systemctl enable cockpit.socket 2>/dev/null || true

# On a live box, apply now instead of waiting for a reboot
if [[ $IN_CHROOT -eq 0 ]]; then
  systemctl daemon-reload || true
  systemctl restart fail2ban || true
  systemctl restart systemd-journald || true
  systemctl restart cockpit.socket || true
  mount -o remount /tmp 2>/dev/null || true
  mount -o remount /dev/shm 2>/dev/null || true
  systemctl restart ssh || true
fi

echo "=== hardening complete $(date -Is) ==="
echo "Reboot, then: ssh ${ADMIN_USER}@<ip>"
