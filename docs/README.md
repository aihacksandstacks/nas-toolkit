# NAS Toolkit

A CLI toolkit for macOS developers to offload storage to a NAS, keeping your local drive lean while maintaining full development capabilities.

## Overview

NAS Toolkit helps you:
- **Run Docker on your NAS** instead of locally (saves 20-100GB+)
- **Prune package caches** in place (npm, uv, pnpm, pip, Homebrew, conda)
- **Clean development artifacts** (node_modules, venvs, build outputs)
- **Archive inactive projects** to NAS cold storage
- **Audit disk usage** with actionable recommendations

## Requirements

- macOS
- NAS with SSH access (tested with UGREEN UGOS, Synology, TrueNAS)
- Tailscale (or other VPN) for secure NAS access
- Docker installed on NAS

## Installation

```bash
cd ~/dev/nas-toolkit
./install.sh
```

This adds the toolkit to your PATH. Open a new terminal or run `source ~/.zshrc`.

## Quick Start

```bash
# 1. See what's eating your disk space
space-audit

# 2. Configure NAS connection
nas-setup

# 3. Prune package caches
cache-prune

# 4. Clean development projects
dev-clean
```

## Commands

### `nas-setup`

Configures your Mac to use the NAS for Docker and storage.

```bash
nas-setup              # Full interactive setup
nas-setup --check      # Check current configuration
nas-setup --docker     # Setup Docker context only
nas-setup --uninstall-docker-desktop  # Remove Docker Desktop
```

**What it does:**
1. Sets up SSH config for Tailscale access
2. Creates Docker context pointing to NAS
3. Creates NAS directory structure
4. Optionally removes Docker Desktop

### `cache-prune`

Prunes package-manager caches in place: npm, npx installs not in use and idle 30+ days, uv, pnpm, pip, Homebrew, conda, and simulators with no runtime. Every one of these is a cache the tool downloads again on demand. space-guard runs it once when free space drops below its threshold.

```bash
cache-prune            # Prune everything, report MB freed per cache
cache-prune --dry-run  # Show sizes and the commands it would run
```

It replaces `nas-cache`, which symlinked caches onto the NAS share. Over SMB through Tailscale (about 20 MB/s) that made installs slow, and it broke the tools whenever the share was not mounted. cache-prune warns if a cache directory is still a symlink from those days.

### `dev-clean`

Removes regenerable artifacts from development projects.

```bash
dev-clean              # Scan ~/dev and clean interactively
dev-clean --dry-run    # Preview what would be removed
dev-clean --all        # Clean all without prompting
dev-clean --stale 30   # Only clean projects inactive 30+ days
dev-clean /path/to/project  # Clean specific project
```

**What gets cleaned:**
- `node_modules` - npm/yarn/pnpm dependencies
- `.venv`, `venv` - Python virtual environments
- `__pycache__`, `.pytest_cache` - Python bytecode/cache
- `dist`, `build` - Build outputs
- `.next`, `.nuxt`, `.turbo` - Framework caches
- `target` - Rust/Java outputs

**What's preserved:**
- `.git` - Version control
- Lock files (package-lock.json, yarn.lock, etc.)
- `.env` files

### `dev-archive`

Archives an inactive project to `mac-offload/archives/repos/` on the NAS share, reads the archive back to verify it, and only then deletes the local copy (with `--clean`).

```bash
dev-archive --suggest [DAYS]      # Projects idle DAYS+ days (default 90), with git state
dev-archive ~/dev/old-project     # Archive and verify, keep local copy
dev-archive ~/dev/old-project --clean   # ...then delete the local copy
dev-archive --list                # Archives on the NAS
```

- The archive keeps `.git` (stashes, unpushed branches), `.env` and other untracked files. It leaves out directories a package manager rebuilds: `node_modules`, `.venv`, `Pods`, `.next`, `DerivedData` and similar, plus `target` in Rust projects.
- It writes through the SMB mount, so it needs no ssh or rsync on the NAS.
- It refuses a linked worktree, and a repo that still has linked worktrees, since archiving would orphan them.
- A `<name>.json` manifest records the remote, branch, HEAD, dirty, unpushed and stash counts, and the archive's sha256.
- Re-archiving keeps the previous archive under a timestamped name.

### `dev-restore`

```bash
dev-restore old-project               # Restore to ~/dev/old-project
dev-restore old-project --to /tmp     # Restore to /tmp/old-project
dev-restore old-project --delete-archive
dev-restore --list
```

It checks the sha256 against the manifest before extracting and never overwrites an existing directory. Reinstall dependencies afterwards; it prints the commands for the lockfiles it finds.

### `space-audit`

Comprehensive disk usage analysis with recommendations.

```bash
space-audit            # Full analysis
space-audit --quick    # Quick overview
space-audit --dev      # Focus on ~/dev
space-audit --caches   # Focus on caches
space-audit --docker   # Focus on Docker
```

### `snapshot-reap`
List and delete Time Machine local snapshots, which pin deleted blocks and make
other cleanup free nothing. Deletes through `diskutil apfs deleteSnapshot`,
which still works when `tmutil deletelocalsnapshots` fails with
`Stale NFS file handle` against a network destination.
```bash
snapshot-reap                        # Dry run: list local snapshots
snapshot-reap --older-than 2 --reap  # Delete snapshots older than 2 days (sudo)
snapshot-reap --json                 # Machine-readable list
```

### `space-guard`
Watchdog installed as a launchd job (every 6 hours). Sends one notification
when free space drops below 20 GB or local snapshots pile up, and one when it
clears. Thresholds are environment variables in the plist template.
```bash
space-guard status   # Current readings and last state
```

### `tm-health`
Check Time Machine from both ends: the Mac's last backup result and local
snapshots, and the NAS share it backs up to (quota-aware free space, recycle
bin size, sparsebundle bloat). Installed as a launchd job that runs every 6
hours and sends a notification when something needs attention.
```bash
tm-health            # Report, exit 1 if anything is in WARN state
tm-health --notify   # Same, plus a macOS notification on state change
```
Thresholds live in `config.sh` (`TM_MIN_FREE_GB`, `TM_RECYCLE_WARN_GB`,
`TM_MAX_LOCAL_SNAPSHOTS`, `TM_MAX_BACKUP_AGE_HOURS`).

```bash
tm-health install-purge   # Hourly root cron on the NAS that empties the share's #recycle
tm-health remove-purge    # Remove it again
```

## Configuration

Edit `~/dev/nas-toolkit/config.sh` to customize:

```bash
# NAS Connection
NAS_HOSTNAME="black-betty"
NAS_IP="100.127.182.121"
NAS_USER="root"
NAS_SSH_HOST="nas"

# NAS Paths
NAS_SMB_SHARE="personal_folder"            # your home share: only you can read it
NAS_MOUNT_POINT="/Volumes/personal_folder"
NAS_SHARE_ROOT="/home/your-username"       # what the share exposes
NAS_STORAGE_BASE="${NAS_SHARE_ROOT}/mac-offload"
NAS_CACHE_DIR="${NAS_STORAGE_BASE}/caches"
NAS_ARCHIVE_DIR="${NAS_STORAGE_BASE}/archives"
```

## Architecture

```
~/dev/nas-toolkit/
├── bin/                # CLI commands
│   ├── nas-setup       # NAS connection setup
│   ├── cache-prune     # Package cache pruning
│   ├── dev-clean       # Project cleanup
│   ├── dev-archive     # Project archival
│   ├── dev-restore     # Project restoration
│   └── space-audit     # Disk analysis
├── lib/
│   └── common.sh       # Shared functions
├── docs/
│   └── README.md       # This file
├── config.sh           # Configuration
└── install.sh          # Installer
```

## NAS Directory Structure

Created on your NAS inside your home share, at `/home/<user>/mac-offload/`. Using the home share instead of a shared folder keeps the data readable by your account only.

```
mac-offload/
├── models/             # AI model files (the Mac links here)
└── archives/
    └── repos/
        ├── old-project.tar.gz
        ├── old-project.json
        └── ...
```

## Docker on NAS

Instead of running Docker Desktop locally (20-100GB), you use Docker on your NAS:

```bash
# Set NAS as default Docker context
docker context use nas

# All docker commands now run on NAS
docker ps
docker compose up -d
```

Your Mac just sends commands over SSH. Images, containers, and volumes all live on the NAS.

## Troubleshooting

### Time Machine: "not enough space on the backup disk even after older backups were deleted"
The Mac's `hdiutil info` shows the sparsebundle as a 16 TB image and the NAS
volume has terabytes free, so the message looks wrong. It isn't. Time Machine
sees the share's quota, and two things eat that quota silently:

1. **The share's SMB recycle bin.** Time Machine thins old backups by deleting
   sparsebundle band files. With the recycle bin on, every deleted band moves
   to `#recycle` and still counts against the quota. On 2026-09-24 that folder
   held 304 GB of dead bands.
2. **Sparsebundle slack.** Bands never shrink on their own. The image sat at
   1.1 TB on disk for 655 GB of actual backup data.

Diagnose (this is what `tm-health` automates):
```bash
ssh nas 'repquota -P /volume1; df -h /volume1/TimeMachine; du -sh "/volume1/TimeMachine/#recycle"'
```

Fix, in order:
```bash
# 1. Empty the recycle bin (only ever holds deleted band files on this share)
ssh nas 'rm -rf "/volume1/TimeMachine/#recycle"/* "/volume1/TimeMachine/#recycle"/.[!.]*'

# 2. Stop the bin from refilling. UGOS does not expose a recycle bin toggle
#    for the Time Machine share, so install an hourly purge cron on the NAS
#    instead (idempotent; remove with `tm-health remove-purge`). It skips
#    files younger than 2 hours, and silly-renamed ".smbdelete*" files younger
#    than a day, because deleting a file the Mac still has open aborts the
#    running backup.
tm-health install-purge

# 3. Optional: raise the share quota in the same screen if the volume has room.

# 4. Kick a backup and watch it
tmutil startbackup
tmutil status
```

Freed space not showing up while a backup runs? Time Machine takes a local
APFS snapshot when a backup starts, and anything deleted after that stays
pinned until the snapshot goes. `tmutil stopbackup`, then
`tmutil deletelocalsnapshots <date>` (works without sudo once the backup is
idle), then `tmutil startbackup`. On 2026-10-02 that released 105 GB.

Leftovers worth cleaning once backups work again:

- **Orphaned `.previous` / `.interrupted` backups inside the image.** backupd
  logs `fBsyErr: File is busy (delete)` for these and never finishes removing
  them. Needs a Terminal with Full Disk Access, while the backup volume is
  mounted and no backup is running:
  ```bash
  sudo tmutil disable
  ls -d "/Volumes/Backups of <your Mac>/"*.previous "/Volumes/Backups of <your Mac>/"*.interrupted
  sudo rm -rf "/Volumes/Backups of <your Mac>/"*.previous "/Volumes/Backups of <your Mac>/"*.interrupted
  sudo tmutil enable
  ```
- **Sparsebundle slack.** Reclaim it with `hdiutil compact`. Do this only after
  the recycle bin is off, or the freed bands go straight back into it.
  ```bash
  sudo tmutil disable                      # backupd unmounts the image
  open "smb://$NAS_IP/TimeMachine"        # mount the share in Finder
  hdiutil compact "/Volumes/TimeMachine/<your Mac>.sparsebundle"  # prompts for the image password
  sudo tmutil enable
  ```
  Expect it to take a while over Tailscale; it rewrites band metadata for the
  whole image.

### NAS not reachable
```bash
# Check Tailscale connection
tailscale status

# Test SSH
ssh nas "echo ok"
```

### Docker context not working
```bash
# Check context exists
docker context ls

# Test context
docker --context nas info
```

## Typical Space Savings

| Item | Typical Size | Action |
|------|--------------|--------|
| Docker Desktop | 20-100 GB | `nas-setup --uninstall-docker-desktop` |
| Package caches | 5-20 GB | `cache-prune` |
| node_modules (all) | 5-30 GB | `dev-clean` |
| Inactive projects | varies | `dev-archive --suggest`, then `dev-archive <path> --clean` |

## Tips

1. **Run `space-audit` weekly** to catch space creep
2. **Use `dev-clean --stale 30`** to auto-clean inactive projects
3. **Archive projects** you're not actively working on
4. **Keep Docker on NAS** - there's no good reason to run it locally
5. **Prune package caches, don't move them** - `cache-prune` is safe any time

## License

MIT - Use freely.
