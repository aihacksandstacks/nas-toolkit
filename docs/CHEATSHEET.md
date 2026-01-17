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

# 4. Move caches to NAS
nas-cache setup

# 5. Remove Docker Desktop (biggest win!)
nas-setup --uninstall-docker-desktop
```

## Daily Commands

```bash
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
nas-cache status          # See what's where
nas-cache move npm        # Move npm to NAS
nas-cache move pip        # Move pip to NAS
nas-cache restore npm     # Bring back local
nas-cache verify          # Check symlinks work
```

## Project Management

```bash
# Clean all projects
dev-clean --all

# Clean stale projects only
dev-clean --stale 30

# Archive inactive project
dev-archive ~/dev/old-project

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

# Verify cache symlinks
nas-cache verify
```

## Quick Wins

| Command | Typical Savings |
|---------|-----------------|
| `nas-setup --uninstall-docker-desktop` | 20-100 GB |
| `nas-cache move npm` | 5-20 GB |
| `nas-cache move pip` | 2-10 GB |
| `dev-clean --all` | 5-30 GB |
| `dev-archive --stale 90 --all` | varies |
