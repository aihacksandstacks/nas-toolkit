# NAS Toolkit

A CLI toolkit for macOS developers to offload storage to a NAS, keeping your local drive lean while maintaining full development capabilities.

## Overview

NAS Toolkit helps you:
- **Run Docker on your NAS** instead of locally (saves 20-100GB+)
- **Move package caches to NAS** via symlinks (npm, pip, homebrew, etc.)
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

# 3. Move caches to NAS
nas-cache setup

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

### `nas-cache`

Manages package caches - moves them to NAS and symlinks back.

```bash
nas-cache status       # Show cache status and sizes
nas-cache setup        # Interactive setup of all caches
nas-cache move npm     # Move specific cache to NAS
nas-cache restore pip  # Bring cache back to local
nas-cache list         # List supported cache types
nas-cache verify       # Verify symlinks are working
```

**Supported caches:**
- npm, yarn, pnpm (Node.js)
- pip, pypoetry, uv (Python)
- cargo (Rust)
- homebrew
- go modules
- gradle, maven (Java)
- cocoapods (iOS)
- playwright

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

Archives inactive projects to NAS cold storage.

```bash
dev-archive /path/to/project    # Archive specific project
dev-archive --list              # List archived projects
dev-archive --suggest           # Get archival recommendations
dev-archive --stale 90          # Find 90-day inactive projects
dev-archive --stale 60 --all    # Archive all 60-day inactive projects
```

**Archive process:**
1. Project is cleaned (artifacts removed)
2. Compressed with tar/gzip
3. Transferred to NAS
4. Metadata saved for restoration
5. Optionally removes local copy

### `dev-restore`

Restores archived projects from NAS.

```bash
dev-restore project-name        # Restore to ~/dev/
dev-restore project --to /tmp   # Restore to specific location
dev-restore --list              # List available archives
```

### `space-audit`

Comprehensive disk usage analysis with recommendations.

```bash
space-audit            # Full analysis
space-audit --quick    # Quick overview
space-audit --dev      # Focus on ~/dev
space-audit --caches   # Focus on caches
space-audit --docker   # Focus on Docker
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
NAS_STORAGE_BASE="/volume1/mac-offload"
NAS_CACHE_DIR="${NAS_STORAGE_BASE}/caches"
NAS_ARCHIVE_DIR="${NAS_STORAGE_BASE}/archives"
```

## Architecture

```
~/dev/nas-toolkit/
├── bin/                # CLI commands
│   ├── nas-setup       # NAS connection setup
│   ├── nas-cache       # Cache management
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

Created on your NAS at `/volume1/mac-offload/`:

```
mac-offload/
├── caches/
│   ├── npm/
│   ├── pip/
│   ├── pypoetry/
│   ├── homebrew/
│   ├── cargo/
│   └── ...
└── archives/
    └── repos/
        ├── old-project.tar.gz
        ├── old-project.json
        └── ...
```

## How Symlinks Work

When you run `nas-cache move npm`, the toolkit:

1. **Syncs** `~/.npm` to NAS via rsync
2. **Removes** local `~/.npm` directory
3. **Creates symlink** `~/.npm` → `/volume1/mac-offload/caches/npm`

npm continues to work exactly the same - it just reads/writes over the network.

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

### Symlink not working
```bash
# Verify symlink
ls -la ~/.npm

# Check if NAS is mounted/accessible
nas-cache verify
```

## Typical Space Savings

| Item | Typical Size | Action |
|------|--------------|--------|
| Docker Desktop | 20-100 GB | `nas-setup --uninstall-docker-desktop` |
| npm cache | 5-20 GB | `nas-cache move npm` |
| pip cache | 2-10 GB | `nas-cache move pip` |
| node_modules (all) | 5-30 GB | `dev-clean` |
| Inactive projects | varies | `dev-archive` |

## Tips

1. **Run `space-audit` weekly** to catch space creep
2. **Use `dev-clean --stale 30`** to auto-clean inactive projects
3. **Archive projects** you're not actively working on
4. **Keep Docker on NAS** - there's no good reason to run it locally
5. **Symlink ALL package caches** - they're fully regenerable

## License

MIT - Use freely.
