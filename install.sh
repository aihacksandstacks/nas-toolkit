#!/bin/bash
#
# NAS Toolkit Installer
#
# Installs the nas-toolkit CLI commands, configures launchd for auto-mount,
# and adds commands to your PATH.
#
set -e

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_BIN="$TOOLKIT_DIR/bin"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.nas-toolkit.health.plist"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

echo ""
echo -e "${BOLD}NAS Toolkit Installer${NC}"
echo "====================="
echo ""

# Step 1: Make all scripts executable
echo -e "${BLUE}[1/5]${NC} Making scripts executable..."
chmod +x "$TOOLKIT_BIN"/*
chmod +x "$TOOLKIT_DIR/lib"/*.sh 2>/dev/null || true
echo -e "${GREEN}Done${NC}"

# Step 2: Check/create config.sh
echo -e "${BLUE}[2/5]${NC} Checking configuration..."
if [ ! -f "$TOOLKIT_DIR/config.sh" ]; then
    if [ -f "$TOOLKIT_DIR/config.sh.example" ]; then
        echo -e "${YELLOW}config.sh not found. Creating from template...${NC}"
        cp "$TOOLKIT_DIR/config.sh.example" "$TOOLKIT_DIR/config.sh"
        echo -e "${YELLOW}IMPORTANT: Edit $TOOLKIT_DIR/config.sh with your NAS settings${NC}"
    else
        echo -e "${RED}Error: Neither config.sh nor config.sh.example found${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}config.sh exists${NC}"
fi

# Step 3: Detect shell and add to PATH
echo -e "${BLUE}[3/5]${NC} Configuring shell PATH..."

SHELL_NAME=$(basename "$SHELL")
SHELL_RC=""

case "$SHELL_NAME" in
    zsh)
        SHELL_RC="$HOME/.zshrc"
        ;;
    bash)
        if [ -f "$HOME/.bash_profile" ]; then
            SHELL_RC="$HOME/.bash_profile"
        else
            SHELL_RC="$HOME/.bashrc"
        fi
        ;;
    *)
        echo -e "${YELLOW}Warning: Unknown shell ($SHELL_NAME). Add to PATH manually:${NC}"
        echo "  export PATH=\"\$PATH:$TOOLKIT_BIN\""
        ;;
esac

if [ -n "$SHELL_RC" ]; then
    if grep -q "nas-toolkit" "$SHELL_RC" 2>/dev/null; then
        echo -e "${GREEN}PATH entry already exists in $SHELL_RC${NC}"
    else
        cat >> "$SHELL_RC" << EOF

# NAS Toolkit - added by installer
export PATH="\$PATH:$TOOLKIT_BIN"
EOF
        echo -e "${GREEN}Added to $SHELL_RC${NC}"
    fi
fi

# Step 4: Install launchd plist for auto-mount health checks
echo -e "${BLUE}[4/5]${NC} Setting up auto-mount service..."

mkdir -p "$LAUNCHD_DIR"

# Generate plist from template with correct path
if [ -f "$TOOLKIT_DIR/com.nas-toolkit.health.plist.template" ]; then
    sed "s|__TOOLKIT_DIR__|$TOOLKIT_DIR|g" \
        "$TOOLKIT_DIR/com.nas-toolkit.health.plist.template" \
        > "$LAUNCHD_DIR/$PLIST_NAME"

    # Unload if already loaded, then reload
    launchctl unload "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true
    launchctl load "$LAUNCHD_DIR/$PLIST_NAME"

    echo -e "${GREEN}Auto-mount service installed (runs every 5 minutes)${NC}"
else
    echo -e "${YELLOW}Warning: plist template not found, skipping auto-mount setup${NC}"
fi

# Step 5: Create mount point if needed
echo -e "${BLUE}[5/5]${NC} Checking mount point..."
source "$TOOLKIT_DIR/config.sh" 2>/dev/null || true

if [ -n "$NAS_MOUNT_POINT" ]; then
    if [ ! -d "$NAS_MOUNT_POINT" ]; then
        echo "Mount point $NAS_MOUNT_POINT doesn't exist."
        echo "Creating it requires sudo. You can run manually:"
        echo "  sudo mkdir -p $NAS_MOUNT_POINT"
    else
        echo -e "${GREEN}Mount point exists: $NAS_MOUNT_POINT${NC}"
    fi
fi

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "To start using the tools, either:"
echo "  1. Open a new terminal window"
echo "  2. Run: source $SHELL_RC"
echo ""
echo -e "${BOLD}Available commands:${NC}"
echo "  nas-setup      - Configure NAS connection and Docker"
echo "  nas-cache      - Move package caches to NAS"
echo "  nas-mount      - Mount NAS share manually"
echo "  dev-clean      - Clean project build artifacts"
echo "  dev-archive    - Archive projects to NAS"
echo "  dev-restore    - Restore archived projects"
echo "  space-audit    - Analyze disk usage"
echo ""
echo -e "${BOLD}Quick start:${NC}"
echo "  1. Edit config.sh with your NAS settings"
echo "  2. Run: nas-setup --check"
echo "  3. Run: space-audit"
echo ""
echo -e "${BOLD}Auto-mount:${NC}"
echo "  - NAS will be checked every 5 minutes and remounted if dropped"
echo "  - Logs at: /tmp/nas-health.log"
echo "  - To disable: launchctl unload ~/Library/LaunchAgents/$PLIST_NAME"
echo ""
