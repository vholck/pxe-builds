# Bug report draft: authselect replaces /etc/nsswitch.conf non-atomically, chronyd fails at boot

Not posted yet. For [authselect](https://github.com/authselect/authselect/issues), with a short note to [fedora-coreos-tracker](https://github.com/coreos/fedora-coreos-tracker/issues) pointing to it. Facts checked 2026-11-22.

---

**Title:** `authselect apply-changes` replaces its symlinks with unlink() + symlink(): services starting at that moment see no /etc/nsswitch.conf

**Summary.** At boot, `authselect-apply-changes.service` runs `authselect apply-changes --upgrade`. To write `/etc/nsswitch.conf` (a symlink to `/etc/authselect/nsswitch.conf`), `authselect_symlinks_write()` first unlinks the old link and then creates the new one. For that moment the file does not exist, and glibc falls back to its built-in defaults, which do not include `altfiles`. On Fedora CoreOS the system users (`chrony`, among others) are only in `/usr/lib/passwd`, read through `nss-altfiles`. A service that looks up its user in that window fails. Seen with `chronyd`: `Fatal error : Could not get user/group ID of chrony`, unit failed, system `degraded`.

**Where.** `src/lib/files/symlinks.c`, `authselect_symlinks_write()` (tag 1.8.0, lines 44 and 52): `unlink(symlinks[i].name)` followed by `symlink(symlinks[i].dest, symlinks[i].name)`.

**Seen with.** Fedora CoreOS stable 45.20261030.3.1 (aarch64, live PXE on a Raspberry Pi 5), authselect 1.8.0-1.fc45, chrony 4.9-1.fc45, systemd 262-3.fc45, nss-altfiles 2.23.0-10.fc45. `/etc/nsswitch.conf` has `passwd: files altfiles systemd`; `chrony` is in `/usr/lib/passwd`, not in `/etc/passwd`.

Timeline from the journal (monotonic seconds) of the failing boot:

| Time | Event |
|---|---|
| 32.80 | `systemd-sysusers.service` finished |
| 34.68 | `authselect-apply-changes.service` started |
| 34.77 | `chronyd.service` started |
| 34.830 | chronyd: `Fatal error : Could not get user/group ID of chrony` |
| 34.832 | authselect: `Changes were successfully applied.` |

The symlink's mtime (`/etc/nsswitch.conf` and the files in `/etc/authselect/`) is the same moment, 00:00:33.287 wall clock, which matches 34.83 on the monotonic clock. After boot, `getent passwd chrony` works and `systemctl restart chronyd` succeeds. The failure is intermittent: an earlier boot of the same image on the same board came up `running`.

**Why the ordering does not prevent it.** `authselect-apply-changes.service` has `After=local-fs.target`, `Before=systemd-user-sessions.service nss-user-lookup.target` and `WantedBy=multi-user.target`. `chronyd.service` is not ordered after `nss-user-lookup.target` (or after authselect), so both start in parallel after `sysinit.target`.

**Proposed fix (authselect).** Replace each symlink atomically: create it under a temporary name in the same directory, then `rename()` it over the old one. Readers then always see either the old or the new link, never none. (The file contents are already written through a temporary file; only the symlinks are not.)

**Possible fix (distribution side).** Order services that look up users at start after `nss-user-lookup.target`, or order `authselect-apply-changes.service` before `sysinit.target` like `authselect-first-boot.service`. Either narrows the window but does not close it for every reader; the atomic rename does.

**Workaround.** A drop-in for chronyd, e.g. in Butane:

```yaml
systemd:
  units:
    - name: chronyd.service
      dropins:
        - name: 10-after-authselect.conf
          contents: |
            [Unit]
            After=authselect-apply-changes.service
```

---

Note for fedora-coreos-tracker: "chronyd intermittently fails at boot ('Could not get user/group ID of chrony') because authselect-apply-changes replaces /etc/nsswitch.conf non-atomically while chronyd starts (authselect issue #…); system users live only in /usr/lib/passwd, so the fallback without altfiles misses them. Workaround: order chronyd after authselect-apply-changes.service."
