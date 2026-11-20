# NAS Toolkit Cheat Sheet

## First Time Setup

```bash
# 1. Install toolkit
cd ~/dev/nas-toolkit && ./install.sh
source ~/.zshrc

# 2. Check current space usage
space-audit

# 3. Configure NAS
nas-setup

# 4. Prune package caches
cache-prune

# 5. Remove Docker Desktop (biggest win!)
nas-setup --uninstall-docker-desktop
```

## Daily Commands

```bash
# Check Time Machine + the NAS share it backs up to
tm-health

# Free space pinned by Time Machine local snapshots
snapshot-reap            # list
snapshot-reap --reap     # delete (sudo)

# Check disk status
space-audit --quick

# Clean project artifacts
dev-clean

# Use Docker (always on NAS)
docker ps
docker compose up -d
```

## Cache Management

```bash
cache-prune --dry-run     # Sizes and what would run
cache-prune               # Prune npm/npx/uv/pnpm/pip/brew/conda caches
```

## Project Management

```bash
# Clean all projects
dev-clean --all

# Clean stale projects only
dev-clean --stale 30

# Find idle projects, then archive one (verifies before deleting)
dev-archive --suggest 90
dev-archive ~/dev/old-project --clean

# See what's archived
dev-archive --list

# Restore from archive
dev-restore old-project
```

## Docker on NAS

```bash
# Check current context
docker context show

# Switch to NAS
docker context use nas

# Switch to local (if needed)
docker context use default

# Build on NAS
DOCKER_CONTEXT=nas docker compose build

# Deploy to NAS
DOCKER_CONTEXT=nas docker compose up -d
```

## Troubleshooting

```bash
# Check NAS connection
nas-setup --check

# Test SSH to NAS
ssh nas "echo ok"

# Check Docker on NAS
docker --context nas info

```

## Quick Wins

| Command | Typical Savings |
|---------|-----------------|
| `nas-setup --uninstall-docker-desktop` | 20-100 GB |
| `cache-prune` | 5-20 GB |
| `dev-clean --all` | 5-30 GB |
| `dev-archive --suggest`, then `--clean` per project | varies |
