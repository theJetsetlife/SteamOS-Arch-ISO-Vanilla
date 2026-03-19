#!/usr/bin/env bash
# =============================================================================
#  build-archiso.sh  —  SteamOS Arch Linux ISO Builder
#
#  Builds a custom Arch Linux ISO with:
#    - KDE Plasma + Wayland
#    - Gaming Mode via Gamescope (Steam Deck-like)
#    - Calamares graphical installer
#    - Limine bootloader (UEFI + BIOS)
#    - All critical dependencies included
#    - Steam pre-installed + Gaming optimizations
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

PROFILE_NAME="steamos-archiso"
DEFAULT_SESSION="plasmawayland"
ISO_LABEL="STEAMOS_LIVE"
ISO_NAME="steamos"
ISO_APP="SteamOS Live/Rescue CD"
PRODUCT_NAME="SteamOS"

PROFILE_DIR="$HOME/$PROFILE_NAME"
LOCAL_REPO_DIR="$PROFILE_DIR/local-repo"
AIROOTFS="$PROFILE_DIR/airootfs"
OUT_DIR="$HOME/iso-output"
WORK_DIR="$HOME/archiso-work"
LOG_FILE="$HOME/build-debug.log"

# ─────────────────────────────────────────────────────────────────────────────
# COLORS & LOGGING
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; exit 1; }
step()    { echo -e "\n${BOLD}${YELLOW}══════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
            echo -e "${BOLD}${YELLOW}  $*${RESET}" | tee -a "$LOG_FILE"
            echo -e "${BOLD}${YELLOW}══════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"; }

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: ENVIRONMENT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

step "Environment Checks"

[[ "$EUID" -eq 0 ]] && error "Do NOT run as root — sudo is called internally."
command -v pacman &>/dev/null || error "Must run on Arch Linux"
command -v python3 &>/dev/null || sudo pacman -S --noconfirm python
python3 -c "import sys; assert sys.version_info >= (3,6)" 2>/dev/null || \
    error "Python 3.6+ required"
command -v git &>/dev/null || sudo pacman -S --noconfirm git
command -v curl &>/dev/null || sudo pacman -S --noconfirm curl
command -v sudo &>/dev/null || error "sudo not found"

FREE_HOME=$(df "$HOME" --output=avail -BG | tail -1 | tr -d 'G ')
[[ "$FREE_HOME" -lt 25 ]] && error "Need 25GB free in \$HOME"
curl -s --max-time 5 https://archlinux.org > /dev/null 2>&1 || \
    error "No internet connection"

success "All environment checks passed"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: HOST DEPENDENCIES
# ─────────────────────────────────────────────────────────────────────────────

step "Installing host dependencies"

HOST_DEPS=(
    archiso limine git base-devel squashfs-tools dosfstools
    edk2-ovmf mkinitcpio-archiso xorriso python
)

MISSING=()
for pkg in "${HOST_DEPS[@]}"; do
    pacman -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
done

[[ ${#MISSING[@]} -gt 0 ]] && {
    info "Installing: ${MISSING[*]}"
    sudo pacman -S --needed --noconfirm "${MISSING[@]}"
}

# Install yay if no AUR helper present
if ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
    info "Installing yay (AUR helper)..."
    sudo pacman -S --needed --noconfirm go git base-devel
    TMP_YAY=$(mktemp -d)
    git clone https://aur.archlinux.org/yay.git "$TMP_YAY/yay"
    (cd "$TMP_YAY/yay" && makepkg -si --noconfirm)
    rm -rf "$TMP_YAY"
fi

AUR_CMD=$(command -v yay || command -v paru)
success "Host dependencies ready. AUR helper: $AUR_CMD"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: SET UP ARCHISO PROFILE
# ─────────────────────────────────────────────────────────────────────────────

step "Setting up archiso profile"

if [[ -d "$PROFILE_DIR" ]]; then
    warn "Profile $PROFILE_DIR already exists."
    read -rp "  Delete and recreate? [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || error "Aborted."
    rm -rf "$PROFILE_DIR"
fi

cp -r /usr/share/archiso/configs/releng/ "$PROFILE_DIR"

# Patch profiledef.sh with bootmodes AND file_permissions (only for files that exist)
cat > /tmp/fix_profiledef.py << 'PYEOF'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
label, name, app, bootmodes_val = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
content = p.read_text()
content = re.sub(
    r"bootmodes=\([^)]*\)",
    "bootmodes=(" + bootmodes_val + ")",
    content,
    flags=re.DOTALL
)
lines = content.splitlines()
out = []
for l in lines:
    if l.startswith('iso_label='):
        out.append(f'iso_label="{label}"')
    elif l.startswith('iso_name='):
        out.append(f'iso_name="{name}"')
    elif l.startswith('iso_application='):
        out.append(f'iso_application="{app}"')
    else:
        out.append(l)
out.append('')
out.append('file_permissions=(')
out.append('  ["/etc/shadow"]="0:0:400"')
out.append('  ["/etc/gshadow"]="0:0:400"')
out.append('  ["/root"]="0:0:750"')
out.append('  ["/root/.automated_script.sh"]="0:0:755"')
out.append('  ["/usr/local/bin/install-limine.sh"]="0:0:755"')
out.append('  ["/usr/bin/gamescope-session"]="0:0:755"')
out.append(')')
p.write_text('\n'.join(out) + '\n')
print('profiledef.sh patched with bootmodes and file_permissions.')
PYEOF

python3 /tmp/fix_profiledef.py \
    "$PROFILE_DIR/profiledef.sh" \
    "$ISO_LABEL" \
    "$ISO_NAME" \
    "$ISO_APP" \
    "'uefi-x64.systemd-boot.esp' 'uefi-x64.systemd-boot.eltorito'"
rm /tmp/fix_profiledef.py
bash -n "$PROFILE_DIR/profiledef.sh" || error "profiledef.sh syntax broken"

# Create directory structure
mkdir -p "$AIROOTFS"/{etc,opt,root,usr/local/bin,usr/share/plymouth/themes,usr/bin}
mkdir -p "$AIROOTFS/etc/skel/Desktop"
mkdir -p "$AIROOTFS/usr/share/applications"
mkdir -p "$AIROOTFS/usr/share/wayland-sessions"
mkdir -p "$AIROOTFS/etc/systemd/system"{,/multi-user.target.wants,/network-online.target.wants,/bluetooth.target.wants}
mkdir -p "$AIROOTFS/etc/calamares/"{modules,branding,scripts}
mkdir -p "$AIROOTFS/etc/polkit-1/rules.d"
mkdir -p "$AIROOTFS/etc/mangohud"
mkdir -p "$AIROOTFS/etc/mkinitcpio.d"
mkdir -p "$AIROOTFS/usr/lib/tmpfiles.d"
mkdir -p "$LOCAL_REPO_DIR"

# Remove PXE hooks
ARCHISO_MKINIT="$AIROOTFS/etc/mkinitcpio.conf.d/archiso.conf"
if [[ -f "$ARCHISO_MKINIT" ]]; then
    sed -i 's/ memdisk\| archiso_loop_mnt\| archiso_pxe_common//g' "$ARCHISO_MKINIT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3.5: CREATE BASE SYSTEM FILES
# ─────────────────────────────────────────────────────────────────────────────

step "Creating base system files"

# passwd
cat > "$AIROOTFS/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/bash
liveuser:x:1000:1000:liveuser:/home/liveuser:/bin/bash
EOF

# shadow
cat > "$AIROOTFS/etc/shadow" << 'EOF'
root::14871::::::
liveuser::14871::::::
EOF

# group
cat > "$AIROOTFS/etc/group" << 'EOF'
root:x:0:root
wheel:x:10:root,liveuser
video:x:91:liveuser
audio:x:92:liveuser
storage:x:93:liveuser
gamemode:x:1000:liveuser
input:x:1001:liveuser
autologin:x:1002:liveuser
liveuser:x:1000:
EOF

# gshadow
cat > "$AIROOTFS/etc/gshadow" << 'EOF'
root:!::root
wheel:!::root,liveuser
video:!::liveuser
audio:!::liveuser
storage:!::liveuser
gamemode:!::liveuser
input:!::liveuser
autologin:!::liveuser
liveuser:!:::
EOF

# kernel preset (no fallback)
cat > "$AIROOTFS/etc/mkinitcpio.d/linux-lts.preset" << 'EOF'
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux-lts'
ALL_config='/etc/mkinitcpio.conf'
archiso_image='/boot/initramfs-linux-lts.img'
EOF

success "Base system files created"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: FIX PACMAN.CONF (with local repo)
# ─────────────────────────────────────────────────────────────────────────────

step "Configuring pacman.conf"

PACMAN_CONF="$PROFILE_DIR/pacman.conf"
sed -i '/^HookDir/d' "$PACMAN_CONF"
sed -i '/^\[options\]/a HookDir = /usr/lib/libalpm/hooks/' "$PACMAN_CONF"
sed -i '/^\[options\]/a CacheDir = /var/cache/pacman/pkg/' "$PACMAN_CONF"
echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" >> "$PACMAN_CONF"

# Add local repository (CRITICAL for AUR packages)
cat >> "$PACMAN_CONF" << EOF

[local-repo]
SigLevel = Never
Server = file://$LOCAL_REPO_DIR
EOF

sed -i 's/^SigLevel.*/SigLevel = Never/' "$PACMAN_CONF"
success "pacman.conf configured with local repository"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: WRITE PACKAGES.X86_64
# ─────────────────────────────────────────────────────────────────────────────

step "Writing packages.x86_64"

cat > "$PROFILE_DIR/packages.x86_64" << 'EOF'
# Base system
base
base-devel
linux-lts
linux-lts-headers
linux-firmware
amd-ucode
intel-ucode
mkinitcpio
mkinitcpio-archiso

# Essential tools
sudo
nano
vim
git
wget
curl
htop
bash-completion
man-db
man-pages
reflector
pacman-contrib

# Filesystem support
dosfstools
exfatprogs
ntfs-3g
btrfs-progs
xfsprogs
f2fs-tools

# Bootloader
limine
efibootmgr
os-prober

# Calamares runtime dependencies
kpmcore
extra-cmake-modules
yaml-cpp
boost-libs
pybind11
qt5-svg
qt5-tools
solid

# AUR packages (will be installed from local repo)
calamares
gamescope-session-git
gamescope-session-steam-git

# Networking
networkmanager
network-manager-applet
nm-connection-editor
plasma-nm
wireless_tools
wpa_supplicant
dhcpcd
avahi
nss-mdns

# KDE Plasma
plasma-meta
plasma-workspace
kde-applications-meta
sddm
sddm-kcm
xorg-server
xorg-xinit
qt5-wayland
qt6-wayland
plasma5-integration
wayland
wayland-protocols
xdg-desktop-portal
xdg-desktop-portal-kde
xdg-user-dirs
konsole
dolphin
ark
kate
gwenview
spectacle

# Multimedia
pipewire
pipewire-alsa
pipewire-pulse
pipewire-jack
wireplumber
pavucontrol
vlc
ffmpeg
gst-plugins-good
gst-plugins-bad
gst-plugins-ugly
gst-libav

# Fonts
noto-fonts
noto-fonts-emoji
noto-fonts-cjk
ttf-liberation
ttf-dejavu
ttf-roboto
ttf-jetbrains-mono

# Bluetooth
bluez
bluez-utils
blueman

# Printing
cups
system-config-printer
print-manager

# Gaming
steam
gamescope
mangohud
lib32-mangohud
gamemode
lib32-gamemode
lutris
wine
wine-mono
wine-gecko
winetricks
protontricks
vulkan-radeon
lib32-vulkan-radeon
vulkan-intel
lib32-vulkan-intel
vulkan-mesa-layers
lib32-vulkan-mesa-layers
mesa-utils
mesa
lib32-mesa
xf86-video-amdgpu
xf86-video-intel
xf86-video-nouveau

# Plymouth
plymouth
plymouth-kcm

# Security
ufw
gufw

# Installation tools
rsync
gptfdisk
parted
arch-install-scripts

# User applications
firefox
keepassxc
gparted
kcalc
kfind
EOF
success "packages.x86_64 written"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5.5: BUILD AUR PACKAGES AND CREATE LOCAL REPO (CRITICAL FIX)
# ─────────────────────────────────────────────────────────────────────────────

step "Building AUR packages and creating local repository"

# Create directories for AUR builds
AUR_BUILD_DIR=$(mktemp -d)
mkdir -p "$LOCAL_REPO_DIR"

# Function to build AUR package
build_aur_pkg() {
    local pkg="$1"
    info "Building $pkg from AUR..."
    
    cd "$AUR_BUILD_DIR"
    
    # Clone the AUR package
    if ! git clone "https://aur.archlinux.org/${pkg}.git"; then
        error "Failed to clone $pkg from AUR"
    fi
    
    cd "$pkg"
    
    # Build the package
    if ! sudo -u "$USER" makepkg -s --noconfirm; then
        error "Failed to build $pkg"
    fi
    
    # Find and copy the built package to local repo
    local pkg_file=$(ls *.pkg.tar.zst | head -1)
    if [[ -n "$pkg_file" ]]; then
        cp "$pkg_file" "$LOCAL_REPO_DIR/"
        success "  ✓ Built and copied $pkg_file"
    else
        error "No package file found for $pkg"
    fi
    
    cd "$AUR_BUILD_DIR"
}

# Install base-devel if not present (required for makepkg)
sudo pacman -S --needed --noconfirm base-devel

# Build required AUR packages in correct order
build_aur_pkg "gamescope-session-git"        # Required first - dependency
build_aur_pkg "gamescope-session-steam-git"  # Depends on gamescope-session-git
build_aur_pkg "calamares"                    # Calamares installer

# Create repository database
cd "$LOCAL_REPO_DIR"
repo-add local-repo.db.tar.gz *.pkg.tar.zst

# Create symlinks for pacman
ln -sf local-repo.db.tar.gz local-repo.db
ln -sf local-repo.files.tar.gz local-repo.files

# Copy packages to pacman cache (optional, speeds up future builds)
sudo cp *.pkg.tar.zst /var/cache/pacman/pkg/ 2>/dev/null || true

rm -rf "$AUR_BUILD_DIR"
success "AUR packages built and local repository created"


# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: CREATE GAMING MODE SESSION FILES (UPDATED)
# ─────────────────────────────────────────────────────────────────────────────

step "Creating Gaming Mode session files"

# REMOVED: gamescope-session.desktop and gamescope-session-steam.desktop
# These are provided by the AUR packages

# Create wrapper script with SteamOS environment variables
cat > "$AIROOTFS/usr/bin/gamescope-session" << 'EOF'
#!/bin/bash
# SteamOS environment variables
export STEAM_GAMESCOPE_VRR=1
export STEAM_GAMESCOPE_ADAPTIVE_SYNC=1
export STEAM_USE_MANGOAPP=1
export STEAM_DISABLE_MANGOAPP_ATOM_WORKAROUND=1
export STEAM_GAMESCOPE_HAS_TEARING_SUPPORT=1
export STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER=1
export STEAM_GAMESCOPE_COLOR_TOYS=1
export STEAM_GAMESCOPE_NIS_SUPPORTED=1
export STEAM_MULTIPLE_XWAYLANDS=1
export STEAM_ENABLE_VOLUME_HANDLER=1
export QT_IM_MODULE=steam
export GTK_IM_MODULE=Steam
export STEAM_ALLOW_DRIVE_UNMOUNT=1
export STEAMOS_STEAM_REBOOT_SENTINEL="/tmp/steamos-reboot-sentinel"
export STEAMOS_STEAM_SHUTDOWN_SENTINEL="/tmp/steamos-shutdown-sentinel"
export STEAM_DISABLE_AUDIO_DEVICE_SWITCHING=1
ulimit -n 524288

exec /usr/bin/gamescope -e --xwayland-count 2 \
    --default-touch-mode 4 \
    --hide-cursor-delay 3000 \
    --fade-out-duration 200 \
    --mangoapp \
    -- \
    steam -steamos3 -steampal -steamdeck -gamepadui -pipewire-dmabuf
EOF
chmod +x "$AIROOTFS/usr/bin/gamescope-session"

# Create symlink (the AUR package might expect this)
ln -sf /usr/bin/gamescope-session "$AIROOTFS/usr/bin/gamescope-session-steam"

# Create MangoHud config (this doesn't conflict)
cat > "$AIROOTFS/etc/mangohud/mangohud.conf" << 'EOF'
no_display=0
fps_limit=0
cpu_stats=1
gpu_stats=1
vram=1
ram=1
fps=1
frame_timing=1
position=top-left
toggle_hud=F2
EOF

success "Gaming Mode session files created"

# Create MangoHud config
cat > "$AIROOTFS/etc/mangohud/mangohud.conf" << 'EOF'
no_display=0
fps_limit=0
cpu_stats=1
gpu_stats=1
vram=1
ram=1
fps=1
frame_timing=1
position=top-left
toggle_hud=F2
EOF

success "Gaming Mode session files created"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: PLYMOUTH THEMES
# ─────────────────────────────────────────────────────────────────────────────

step "Setting up Plymouth themes"

if command -v git &>/dev/null; then
    TMP_DL=$(mktemp -d)
    if git clone --depth=1 https://github.com/bootcrew/steamos-bootc.git "$TMP_DL/bootcrew" 2>/dev/null; then
        if [[ -d "$TMP_DL/bootcrew/files/usr/share/plymouth/themes" ]]; then
            cp -r "$TMP_DL/bootcrew/files/usr/share/plymouth/themes/"* \
                "$AIROOTFS/usr/share/plymouth/themes/" 2>/dev/null || true
        fi
    fi
    rm -rf "$TMP_DL"
fi

# Plymouth installer
cat > "$AIROOTFS/root/install-plymouth-themes.sh" << 'EOF'
#!/bin/bash
THEME="steamos"
[[ ! -d "/usr/share/plymouth/themes/$THEME" ]] && THEME="steamdeck"
[[ ! -d "/usr/share/plymouth/themes/$THEME" ]] && THEME="bgrt"
mkdir -p /etc/plymouth
cat > /etc/plymouth/plymouthd.conf << CONF
[Daemon]
Theme=$THEME
ShowDelay=0
DeviceTimeout=8
CONF
echo "Plymouth theme set to: $THEME"
EOF
chmod +x "$AIROOTFS/root/install-plymouth-themes.sh"
success "Plymouth theme installer created"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: CREATE POST-INSTALL LIMINE SCRIPT
# ─────────────────────────────────────────────────────────────────────────────

step "Creating post-install Limine script"

cat > "$AIROOTFS/usr/local/bin/install-limine.sh" << 'EOF'
#!/bin/bash
# Post-install script for Limine bootloader

set -e

ESP_MOUNT="/boot/efi"
if [[ ! -d "$ESP_MOUNT" ]]; then
    echo "ERROR: ESP not mounted at $ESP_MOUNT"
    exit 1
fi

ESP_DEVICE=$(lsblk -o MOUNTPOINT,PKNAME -nr | grep "$ESP_MOUNT" | awk '{print $2}')
if [[ -z "$ESP_DEVICE" ]]; then
    echo "ERROR: Could not detect disk device"
    exit 1
fi

ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/root 2>/dev/null || \
            blkid -s UUID -o value "$(df / | tail -1 | awk '{print $1}')")
if [[ -z "$ROOT_UUID" ]]; then
    echo "ERROR: Could not detect root UUID"
    exit 1
fi

mkdir -p "$ESP_MOUNT/EFI/limine"
cp /usr/share/limine/BOOTX64.EFI "$ESP_MOUNT/EFI/limine/"

efibootmgr --create \
    --disk "/dev/$ESP_DEVICE" \
    --part 1 \
    --label "SteamOS" \
    --loader "\\EFI\\limine\\BOOTX64.EFI" 2>/dev/null || true

mkdir -p /boot/limine
cat > /boot/limine/limine.conf << LIMEOF
TIMEOUT: 5

:SteamOS
    PROTOCOL: linux
    KERNEL_PATH: boot():/vmlinuz-linux-lts
    MODULE_PATH: boot():/initramfs-linux-lts.img
    CMDLINE: root=UUID=$ROOT_UUID rw quiet splash plymouth.enable=1

:SteamOS (fallback)
    PROTOCOL: linux
    KERNEL_PATH: boot():/vmlinuz-linux-lts
    MODULE_PATH: boot():/initramfs-linux-lts-fallback.img
    CMDLINE: root=UUID=$ROOT_UUID rw
LIMEOF

cp /boot/limine/limine.conf "$ESP_MOUNT/EFI/limine/"
cp /usr/share/limine/limine-bios.sys "$ESP_MOUNT/EFI/limine/"
limine bios-install "/dev/$ESP_DEVICE" 2>/dev/null || true

echo "Limine installation complete"
EOF
chmod +x "$AIROOTFS/usr/local/bin/install-limine.sh"
success "Post-install Limine script created"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9: CREATE SYSTEMD SERVICES (COMPLETE)
# ─────────────────────────────────────────────────────────────────────────────

step "Creating systemd services"

# Create all necessary directories
mkdir -p "$AIROOTFS/etc/systemd/system/getty@tty1.service.d"
mkdir -p "$AIROOTFS/etc/systemd/journald.conf.d"
mkdir -p "$AIROOTFS/etc/systemd/logind.conf.d"

# SDDM config
cat > "$AIROOTFS/etc/sddm.conf" << 'EOF'
[Autologin]
Relogin=true
Session=plasmawayland
User=liveuser

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot

[Theme]
Current=breeze
EOF

# Getty autologin
cat > "$AIROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin liveuser --noclear %I 38400 linux
EOF

# Performance mode service
cat > "$AIROOTFS/etc/systemd/system/performance-mode.service" << 'EOF'
[Unit]
Description=Set performance mode on boot
After=local-fs.target
Before=graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null || true'
ExecStart=/bin/bash -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true'

[Install]
WantedBy=graphical.target
EOF

# Pacman-init service
cat > "$AIROOTFS/etc/systemd/system/pacman-init.service" << 'EOF'
[Unit]
Description=Initialize pacman keyring
Before=multi-user.target
Requires=etc-pacman.d-gnupg.mount
After=etc-pacman.d-gnupg.mount
After=time-sync.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash -c 'pacman-key --init && pacman-key --populate'

[Install]
WantedBy=multi-user.target
EOF

# Temporary GPG directory mount
cat > "$AIROOTFS/etc/systemd/system/etc-pacman.d-gnupg.mount" << 'EOF'
[Unit]
Description=Temporary Pacman GNUPG directory
Before=pacman-init.service
ConditionPathExists=/etc/pacman.d/gnupg

[Mount]
What=tmpfs
Where=/etc/pacman.d/gnupg
Type=tmpfs
Options=mode=0755,size=64M

[Install]
WantedBy=multi-user.target
EOF

# Volatile journal storage
cat > "$AIROOTFS/etc/systemd/journald.conf.d/volatile-storage.conf" << 'EOF'
[Journal]
Storage=volatile
EOF

# Power management (ignore suspend)
cat > "$AIROOTFS/etc/systemd/logind.conf.d/do-not-suspend.conf" << 'EOF'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
EOF

# Hostname
echo "steamos-live" > "$AIROOTFS/etc/hostname"

# Default locale
echo "LANG=C.UTF-8" > "$AIROOTFS/etc/locale.conf"

# Locale.gen
cat > "$AIROOTFS/etc/locale.gen" << 'EOF'
en_US.UTF-8 UTF-8
en_US ISO-8859-1
EOF

# Display manager symlink
ln -sf /usr/lib/systemd/system/sddm.service \
    "$AIROOTFS/etc/systemd/system/display-manager.service"

# Enable services with correct symlinks
ln -sf /usr/lib/systemd/system/NetworkManager.service \
    "$AIROOTFS/etc/systemd/system/multi-user.target.wants/NetworkManager.service"

ln -sf /usr/lib/systemd/system/NetworkManager-wait-online.service \
    "$AIROOTFS/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service"

ln -sf /usr/lib/systemd/system/bluetooth.service \
    "$AIROOTFS/etc/systemd/system/bluetooth.target.wants/bluetooth.service"

ln -sf /usr/lib/systemd/system/pacman-init.service \
    "$AIROOTFS/etc/systemd/system/multi-user.target.wants/pacman-init.service"

ln -sf /usr/lib/systemd/system/etc-pacman.d-gnupg.mount \
    "$AIROOTFS/etc/systemd/system/multi-user.target.wants/etc-pacman.d-gnupg.mount"

# tmpfiles.d configuration
cat > "$AIROOTFS/usr/lib/tmpfiles.d/steamos.conf" << 'EOF'
d /run/steamos 0755 root root -
d /run/gamescope 0755 liveuser liveuser -
EOF

success "Systemd services created"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10: CREATE CALAMARES CONFIGS
# ─────────────────────────────────────────────────────────────────────────────

step "Creating Calamares configuration"

# PolKit rules
cat > "$AIROOTFS/etc/polkit-1/rules.d/49-calamares.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") === "/usr/bin/calamares" &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF

# Main settings
cat > "$AIROOTFS/etc/calamares/settings.conf" << 'EOF'
---
modules-search: [ local, /usr/lib/calamares/modules ]
sequence:
  - show:
    - welcome
    - locale
    - keyboard
    - partition
    - users
    - summary
  - exec:
    - partition
    - mount
    - unpackfs
    - machineid
    - fstab
    - locale
    - keyboard
    - localecfg
    - users
    - networkcfg
    - hwclock
    - initcpiocfg
    - initcpio
    - shellprocess@post
    - packages
    - removeuser
    - umount
  - show:
    - finished
branding: $ISO_NAME
prompt-install: true
dont-chroot: false
EOF

# Partition module (enforce FAT32 ESP)
cat > "$AIROOTFS/etc/calamares/modules/partition.conf" << 'EOF'
---
efi:
  mountPoint: "/boot/efi"
  fs: "fat32"
  recommendedSize: 512MiB
  minimumSize: 256MiB
userSwapChoices: [ none, small, suspend, file ]
initialPartitioningChoice: erase
initialSwapChoice: small
defaultFileSystemType: "ext4"
availableFileSystemTypes: ["ext4", "btrfs", "xfs", "f2fs"]
requiredStorage: 25.0
EOF

# Bootloader module (handled by shellpost)
cat > "$AIROOTFS/etc/calamares/modules/bootloader.conf" << 'EOF'
---
efiBootLoader: "none"
EOF

# Shellprocess post-install (arch-deckify fully automated)
cat > "$AIROOTFS/etc/calamares/modules/shellprocess@post.conf" << 'EOF'
---
dontChroot: false
timeout: 600
script:
  - "-": |
      # Install Limine bootloader
      /usr/local/bin/install-limine.sh

      # Enable core services
      systemctl enable NetworkManager sddm bluetooth fstrim.timer performance-mode.service

      # Set Plymouth theme
      /root/install-plymouth-themes.sh

      # Install AUR helper for the new user
      INSTALLED_USER=$(getent passwd 1000 | cut -d: -f1 || echo "user")
      USER_HOME=$(getent passwd 1000 | cut -d: -f6 || echo "/home/$INSTALLED_USER")
      mkdir -p "$USER_HOME/.yay-build"
      chown "$INSTALLED_USER:$INSTALLED_USER" "$USER_HOME/.yay-build"
      git clone https://aur.archlinux.org/yay.git "$USER_HOME/.yay-build/yay"
      (cd "$USER_HOME/.yay-build/yay" && sudo -u "$INSTALLED_USER" makepkg -si --noconfirm)

      # ===== ARCH-DECKIFY FULL INSTALLATION (NO CHOICES) =====

      # 1. Install Flatpak (containerized apps)
      pacman -S --noconfirm flatpak
      flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
      echo "flatpak installed" > /etc/flatpak-installed

      # 2. Install Decky Loader (plugin system for Steam)
      curl -sSL https://raw.githubusercontent.com/unlbslk/arch-deckify/refs/heads/main/setup_deckyloader.sh > /tmp/setup_deckyloader.sh
      bash /tmp/setup_deckyloader.sh
      echo "decky-installed" > /etc/decky-installed

      # 3. Create arch-deckify directory structure
      mkdir -p "/home/$INSTALLED_USER/arch-deckify"

      # 4. Download system update script
      cat > "/home/$INSTALLED_USER/arch-deckify/system_update.sh" << 'UEOF'
#!/bin/bash
# System update script for SteamOS-like environment
AUR_CMD=$(command -v yay || command -v paru || echo "sudo pacman")
TERMINAL_CMD=""
for term in konsole gnome-terminal kgx kitty alacritty; do
    if command -v "$term" &>/dev/null; then
        TERMINAL_CMD="$term"
        break
    fi
done
if [ -n "$TERMINAL_CMD" ]; then
    $TERMINAL_CMD -e bash -c "sudo rm -rf /var/lib/pacman/db.lck; $AUR_CMD -Syu --noconfirm; flatpak update -y 2>/dev/null; echo 'Update complete'; sleep 3" &
else
    echo "No supported terminal found. Please run manually: $AUR_CMD -Syu"
fi
UEOF
      chmod +x "/home/$INSTALLED_USER/arch-deckify/system_update.sh"
      chown "$INSTALLED_USER:$INSTALLED_USER" "/home/$INSTALLED_USER/arch-deckify/system_update.sh"

      # 5. Create system update desktop shortcut
      mkdir -p "/home/$INSTALLED_USER/Desktop"
      cat > "/home/$INSTALLED_USER/Desktop/System_Update.desktop" << 'DEOF'
[Desktop Entry]
Name=System Update
Comment=Update system packages
Exec=/home/INSTALLED_USER/arch-deckify/system_update.sh
Icon=system-software-update
Terminal=false
Type=Application
Categories=System;
DEOF
      sed -i "s|INSTALLED_USER|$INSTALLED_USER|g" "/home/$INSTALLED_USER/Desktop/System_Update.desktop"
      chmod +x "/home/$INSTALLED_USER/Desktop/System_Update.desktop"
      chown "$INSTALLED_USER:$INSTALLED_USER" "/home/$INSTALLED_USER/Desktop/System_Update.desktop"

      # 6. Create Decky Loader shortcut (if installed)
      cat > "/home/$INSTALLED_USER/Desktop/Decky_Loader.desktop" << 'DEOF2'
[Desktop Entry]
Name=Decky Loader
Comment=Plugin system for Steam
Exec=deckyloader
Icon=applications-games
Terminal=false
Type=Application
Categories=Game;
DEOF2
      chmod +x "/home/$INSTALLED_USER/Desktop/Decky_Loader.desktop"
      chown "$INSTALLED_USER:$INSTALLED_USER" "/home/$INSTALLED_USER/Desktop/Decky_Loader.desktop"

      # 7. Create arch-deckify helper in applications menu
      cat > "/usr/share/applications/arch-deckify-helper.desktop" << 'HEOF'
[Desktop Entry]
Name=Deckify Tools
Comment=Additional SteamOS tools
Exec=/home/$INSTALLED_USER/arch-deckify/system_update.sh
Icon=preferences-system
Terminal=true
Type=Application
Categories=System;
HEOF

      # 8. Copy arch-deckify icons if available
      if [[ -d "/opt/arch-deckify/icons" ]]; then
        cp -r /opt/arch-deckify/icons "/home/$INSTALLED_USER/arch-deckify/"
        chown -R "$INSTALLED_USER:$INSTALLED_USER" "/home/$INSTALLED_USER/arch-deckify/icons"
      fi

      # 9. Add udev rule for backlight (Steam Deck compatibility)
      echo 'ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video $sys$devpath/brightness", RUN+="/bin/chmod g+w $sys$devpath/brightness"' >> /etc/udev/rules.d/99-backlight.rules

      # 10. Ensure user is in video group (for backlight)
      usermod -a -G video "$INSTALLED_USER"

      echo "arch-deckify fully installed (no choices)"
EOF

# Unpackfs config
cat > "$AIROOTFS/etc/calamares/modules/unpackfs.conf" << 'EOF'
---
unpack:
  - source: "/"
    sourcefs: "squashfs"
    destination: ""
    exclude:
      - "airootfs.sfs"
      - "airootfs.sha512"
      - "proc"
      - "sys"
      - "dev"
      - "run"
      - "tmp"
      - "mnt"
      - "lost+found"
EOF

# Users config
cat > "$AIROOTFS/etc/calamares/modules/users.conf" << 'EOF'
---
userShell: /bin/bash
rootPassReq: [ minLength: 6, maxLength: 128, allowEmpty: false ]
userPassReq: [ minLength: 6, maxLength: 128, allowEmpty: false ]
allowWeakPasswords: false
autologinGroup: autologin
sudoersGroup: wheel
setRootPassword: true
doAutologin: false
userList: [ wheel, video, audio, storage, optical, gamemode ]
EOF

success "Calamares configuration created"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 11: CREATE CUSTOMIZE_AIROOTFS.SH (with permission fixes)
# ─────────────────────────────────────────────────────────────────────────────

step "Writing customize_airootfs.sh"

cat > "$AIROOTFS/root/customize_airootfs.sh" << 'EOF'
#!/usr/bin/env bash
set -e

echo "[customize] Starting live environment customization..."
chmod +x /root/install-plymouth-themes.sh 2>/dev/null || true
# Create live user if missing
if ! id liveuser &>/dev/null; then
    useradd -m -G wheel,video,audio,storage,gamemode,input,autologin -s /bin/bash liveuser
    echo "liveuser:liveuser" | chpasswd
fi

# Sudoers
echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
echo "liveuser ALL=(ALL) NOPASSWD: /usr/bin/calamares" > /etc/sudoers.d/calamares-live

# Create steamos-session sudoers file (for session switching)
echo "liveuser ALL=(ALL) NOPASSWD: /usr/bin/steamos-session-select" > /etc/sudoers.d/steamos-session
chmod 440 /etc/sudoers.d/calamares-live
chmod 440 /etc/sudoers.d/steamos-session

# Install Plymouth theme
/root/install-plymouth-themes.sh

# Desktop shortcuts
cat > /home/liveuser/Desktop/Install_SteamOS.desktop << 'DEOF'
[Desktop Entry]
Name=Install SteamOS
Exec=calamares
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;
DEOF

cat > /home/liveuser/Desktop/Gaming_Mode.desktop << 'GEOF'
[Desktop Entry]
Name=Gaming Mode
Exec=steamos-session-select gamescope
Icon=steam
Terminal=false
Type=Application
GEOF

chmod +x /home/liveuser/Desktop/*.desktop
chown -R liveuser:liveuser /home/liveuser

# Session switcher
cat > /usr/bin/steamos-session-select << 'SEOF'
#!/bin/bash
if [ "$1" = "plasma" ] || [ "$1" = "desktop" ]; then
    sudo sed -i 's/^Session=.*/Session=plasmawayland/' /etc/sddm.conf
    notify-send "Switching to Desktop Mode on next login"
elif [ "$1" = "gamescope" ]; then
    sudo sed -i 's/^Session=.*/Session=gamescope-session-steam/' /etc/sddm.conf
    notify-send "Switching to Gaming Mode..."
    sleep 2
    loginctl terminate-session "$XDG_SESSION_ID"
else
    echo "Usage: steamos-session-select [plasma|gamescope]"
    exit 1
fi
SEOF
chmod 755 /usr/bin/steamos-session-select

# Enable services
systemctl enable sddm NetworkManager bluetooth
systemctl enable performance-mode.service 2>/dev/null || true

echo "[customize] Live environment ready"
EOF

chmod +x "$AIROOTFS/root/customize_airootfs.sh"
success "customize_airootfs.sh written"

# STEP 12: CREATE LIVE ISO LIMINE CONFIG
step "Creating live ISO Limine config"

mkdir -p "$AIROOTFS/boot/limine"
mkdir -p "$AIROOTFS/EFI/BOOT"

# Create the config
cat > "$AIROOTFS/boot/limine/limine.conf" << EOF
TIMEOUT: 5

:SteamOS Live
    PROTOCOL: linux
    KERNEL_PATH: boot():/arch/boot/x86_64/vmlinuz-linux-lts
    MODULE_PATH: boot():/arch/boot/x86_64/initramfs-linux-lts.img
    CMDLINE: archisobasedir=arch archisolabel=$ISO_LABEL rw quiet splash plymouth.enable=1

:SteamOS Live (verbose)
    PROTOCOL: linux
    KERNEL_PATH: boot():/arch/boot/x86_64/vmlinuz-linux-lts
    MODULE_PATH: boot():/arch/boot/x86_64/initramfs-linux-lts.img
    CMDLINE: archisobasedir=arch archisolabel=$ISO_LABEL rw
EOF

# COPY TO MULTIPLE LOCATIONS (CRITICAL FIX)
cp "$AIROOTFS/boot/limine/limine.conf" "$AIROOTFS/EFI/BOOT/"
cp "$AIROOTFS/boot/limine/limine.conf" "$AIROOTFS/"
cp "$AIROOTFS/boot/limine/limine.conf" "$AIROOTFS/boot/"

# Copy Limine files
cp /usr/share/limine/BOOTX64.EFI "$AIROOTFS/EFI/BOOT/"
cp /usr/share/limine/limine-bios.sys "$AIROOTFS/boot/limine/"
cp /usr/share/limine/limine-bios-cd.bin "$AIROOTFS/boot/limine/"
touch "$AIROOTFS/boot/limine/boot.cat"

success "Live ISO Limine config created (copied to multiple locations)"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 13: BUILD THE ISO
# ─────────────────────────────────────────────────────────────────────────────

step "Building ISO (this will take a while...)"

mkdir -p "$OUT_DIR"
if [[ -d "$WORK_DIR" ]]; then
    for mp in proc sys dev run; do
        sudo umount -l "$WORK_DIR/x86_64/airootfs/$mp" 2>/dev/null || true
    done
    sudo rm -rf "$WORK_DIR"
fi

info "Running mkarchiso..."
sudo mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR" 2>&1 | tee -a "$LOG_FILE"

ISO_FILE=$(ls "$OUT_DIR"/${ISO_NAME}-*.iso 2>/dev/null | head -1)
[[ -z "$ISO_FILE" ]] && error "ISO build failed!"
success "ISO built: $ISO_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 14: VERIFY ISO
# ─────────────────────────────────────────────────────────────────────────────

step "Verifying ISO"

TMP_VERIFY=$(mktemp -d)
xorriso -osirrox on -indev "$ISO_FILE" -extract / "$TMP_VERIFY" >/dev/null 2>&1

errors=0
echo "Checking critical files:"
for file in "EFI/BOOT/BOOTX64.EFI" "boot/limine/limine.conf" \
            "usr/share/wayland-sessions/gamescope-session.desktop" \
            "usr/bin/gamescope-session" "etc/calamares/settings.conf"; do
    if [[ -f "$TMP_VERIFY/$file" ]]; then
        success "  ✓ $file"
    else
        warn "  ✗ $file missing"
        errors=$((errors+1))
    fi
done

rm -rf "$TMP_VERIFY"

if [[ $errors -eq 0 ]]; then
    success "ISO verification passed"
else
    warn "ISO verification found $errors missing files"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 15: INSTALL LIMINE TO ISO
# ─────────────────────────────────────────────────────────────────────────────

step "Installing Limine to ISO"

if command -v limine &>/dev/null; then
    limine bios-install "$ISO_FILE" && success "Limine BIOS support installed" || \
        warn "Limine bios-install failed (UEFI boot still works)"
else
    warn "limine command not found - skipping BIOS install"
fi

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  BUILD COMPLETE!${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ISO:  ${CYAN}$ISO_FILE${RESET}"
echo -e "  Size: ${CYAN}$(du -sh "$ISO_FILE" | cut -f1)${RESET}"
echo -e "  Logs: ${CYAN}$LOG_FILE${RESET}"
echo ""
echo -e "${YELLOW}Test with QEMU (UEFI):${RESET}"
echo -e "  ${CYAN}qemu-system-x86_64 -enable-kvm -m 4G -cpu host -smp 4 \\"
echo -e "    -bios /usr/share/edk2/x64/OVMF.4m.fd \\"
echo -e "    -cdrom \"$ISO_FILE\"${RESET}"
echo ""
echo -e "${YELLOW}Flash to USB:${RESET}"
echo -e "  ${CYAN}sudo dd if=\"$ISO_FILE\" of=/dev/sdX bs=4M status=progress oflag=sync${RESET}"
echo ""
