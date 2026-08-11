# CodeReady Containers (CRC) on Rocky Linux 10 — Full Setup Reference

Covers: install, hardware checks, CRC cluster startup, and remote console access via HAProxy.

---

## 1. Prerequisites

- Rocky Linux 10 / RHEL 9+ host (bare metal or VM with **nested virtualization enabled**, if running inside VMware/another hypervisor)
- Minimum: 4 CPU cores, 12GB RAM (CRC itself needs ≥10752 MiB for the VM, plus host overhead), 40GB free disk
- A Red Hat pull secret from https://console.redhat.com/openshift/create/local (save as `pull_secret.json`)
- Root access

---

## 2. Install script

Run the installer as root:

```bash
chmod +x install.sh
./install.sh
```

The script performs, in order:

1. **Hardware spec check** — CPU, RAM, disk, virtualization support.
2. **Dependency install** — `qemu-kvm`, `libvirt`, `virt-install`, `ebtables`, `dnsmasq`, `virt-viewer`, `iproute`, `socat`, `wget`, `curl`, `bc`, `firewalld`.
   - Note: on Rocky/RHEL the package is `iproute`, **not** `iproute2` (that's the Debian/Ubuntu name).
3. **Network bridge setup** (`crc-bridge`) via `nmcli`, with the bridge added to firewalld's `trusted` zone.
4. **CRC/oc/kubectl tool install** — downloaded from `mirror.openshift.com/pub/openshift-v4/clients/...` (GitHub no longer hosts the CRC binary as a release asset).
5. **Runtime user setup** — creates `crcuser`, adds it to `libvirt`/`qemu`/`wheel` groups, grants passwordless sudo (`/etc/sudoers.d/90-crcuser`), copies the pull secret to `/home/crcuser/.crc/pull_secret.json`.
6. **CRC setup & start** — configures `network-mode system`, runs `crc cleanup` (needed after any network-mode change), `crc setup`, then `crc start --cpus 4 --memory 12000 --disk-size 40`.

### Known gotchas fixed along the way

| Symptom | Cause | Fix |
|---|---|---|
| `No match for argument: bridge-utils` / `iproute2` | Wrong package names for RHEL/Rocky | Use `iproute`; drop `bridge-utils` (replaced by `nmcli` bridges) |
| `invalid field 'NAME'` on `nmcli device status` | `NAME` isn't a valid field for `device status` (only `connection show` supports it) | Query interface via `device status` (DEVICE,STATE) and bridge existence via `connection show` (NAME) separately |
| Duplicate `crc-bridge` connections | Detection command used the wrong nmcli subcommand, so the "already exists" check never matched | Fixed detection to use `nmcli -t -f NAME connection show \| grep -Fxq` |
| `xz: File format not recognized` downloading CRC | GitHub releases no longer attach the CRC binary as a downloadable asset | Download from `mirror.openshift.com/pub/openshift-v4/clients/crc/latest/` instead |
| `network-mode 'bridge'` invalid | Only `user` or `system` are valid CRC network modes | Use `network-mode system` |
| `Configuration property 'network-bridge-name' does not exist` | Not a real CRC config key in current versions | Removed; CRC manages its own internal libvirt network under `system` mode |
| `unable to set cap_dac_override capability ... exit status 1` | `crcuser` had no sudo rights, and no TTY was available for a password prompt under `su -c` | Added `crcuser` to `wheel` + passwordless sudo via `/etc/sudoers.d/90-crcuser` |
| `$DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined` | `su - crcuser` doesn't create a real login session / systemd user bus | `loginctl enable-linger crcuser`, start `user@<uid>.service`, export `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` explicitly for every command run as `crcuser` |
| `requires memory in MiB >= 10752` | Script originally allocated 9216 MiB, below CRC's actual minimum | Bumped to `--memory 12000` |
| VMware "unrecoverable error (vcpu-2)... debug breakpoint" | Nested virtualization edge case when the Rocky host is itself a VMware VM | Ensure "Virtualize Intel VT-x/EPT or AMD-V/RVI" is enabled in VM Settings → Processors; update VMware Workstation |

---

## 3. Day-to-day cluster commands

`crc` is installed at `/usr/local/bin/crc`. If `crcuser`'s shell doesn't have it on `PATH`, use the full path or add it to `~/.bash_profile`:

```bash
echo 'export PATH=$PATH:/usr/local/bin' >> /home/crcuser/.bash_profile
```

As `crcuser`:

```bash
sudo -i -u crcuser          # switch to crcuser
crc status                  # check cluster state
crc stop                    # stop the cluster
crc start                   # start it again (reuses prior config)
crc console                 # open the web console
crc ip                      # get the CRC VM's internal IP
eval $(crc oc-env)          # set up oc CLI
oc login -u developer https://api.crc.testing:6443
```

Default credentials (yours will differ — check your original `crc start` output for the actual `kubeadmin` password):

```
Username: kubeadmin
Password: <shown once at first `crc start`>

Username: developer
Password: developer
```

---

## 4. Remote access via HAProxy (optional)

CRC's DNS entries (`api.crc.testing`, `*.apps-crc.testing`) only resolve to `127.0.0.1` on the CRC host itself. To reach the console/API from another machine on your network, set up a TCP passthrough proxy.

### 4.1 Install and configure HAProxy

```bash
dnf install -y haproxy
```

Get the CRC VM's internal IP:

```bash
sudo -i -u crcuser
/usr/local/bin/crc ip     # e.g. 192.168.130.11
exit
```

**Remove the stock demo config block** that ships in `/etc/haproxy/haproxy.cfg` (`frontend main`, `backend static`, `backend app` with dummy `app1`-`app4` servers) — leaving it in place causes noisy but harmless `DOWN`/`ALERT` log spam for servers that don't exist. Find its line range and delete it:

```bash
grep -n "^frontend\|^backend" /etc/haproxy/haproxy.cfg
sed -i 'START,ENDd' /etc/haproxy/haproxy.cfg   # replace START,END with the demo block's line numbers
```

Then append the real passthrough config (replace `CRC_VM_IP` with the actual IP from `crc ip`):

```
frontend openshift_api
    bind *:6443
    mode tcp
    option tcplog
    default_backend openshift_api_backend

backend openshift_api_backend
    mode tcp
    server crc_api CRC_VM_IP:6443 check

frontend openshift_apps
    bind *:443
    mode tcp
    option tcplog
    default_backend openshift_apps_backend

backend openshift_apps_backend
    mode tcp
    server crc_apps CRC_VM_IP:443 check
```

Validate, open firewall ports, and start:

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg
firewall-cmd --permanent --add-port=6443/tcp --add-port=443/tcp
firewall-cmd --reload
systemctl enable --now haproxy
systemctl status haproxy
ss -tlnp | grep -E ':443|:6443'    # confirm it's listening
```

> Note: `'option forwardfor' ignored ... requires HTTP mode` warnings are expected and harmless — our frontends run in `tcp` mode (needed for TLS passthrough of OpenShift's own certs), so that HTTP-only option is simply skipped.

### 4.2 Client-side access

On the machine you're browsing from, add hosts entries pointing to the **Rocky host's real LAN IP** (not the internal `192.168.130.x` CRC VM IP):

```
<rocky-host-LAN-IP>  api.crc.testing
<rocky-host-LAN-IP>  console-openshift-console.apps-crc.testing
```

Then browse to `https://console-openshift-console.apps-crc.testing`, accept the self-signed cert warning, and log in with the `kubeadmin`/`developer` credentials above.

---

## 5. Quick troubleshooting checklist

- `crc status` shows the cluster is stopped → `crc start`
- Console unreachable remotely → check `systemctl status haproxy`, `ss -tlnp`, firewalld ports, and that client hosts file points to the *Rocky host's* IP, not the CRC VM's internal IP
- `crc start` fails on memory → confirm `free -m` shows ≥12GB, and no other VMs are competing for RAM
- Any `crc` command run as `crcuser` fails on D-Bus/session errors → confirm `loginctl enable-linger crcuser` is set and `user@<uid>.service` is running
