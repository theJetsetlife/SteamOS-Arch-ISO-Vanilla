#!/usr/bin/env bash
# =============================================================================
#  build-archiso.sh  —  SteamOS Arch Linux ISO Builder
#
#  Builds a custom Arch Linux ISO with:
#    - KDE Plasma (plasma-meta) + Wayland
#    - Calamares graphical installer
#    - Limine bootloader (installed to target disk via Calamares)
#    - arch-deckify (SteamOS-like Gaming Mode via Gamescope)
#    - Vapor/SteamOS KDE theme + Plymouth Steam Deck boot splash
#    - Steam Deck icons and wallpaper
#    - Steam game client pre-installed
#
#  REQUIREMENTS:
#    - Arch Linux host (any user with sudo)
#    - 20GB+ free disk space in $HOME
#    - Internet connection
#
#  USAGE:
#    bash build-archiso.sh
#
#  NO pre-built packages needed. Script builds everything from scratch.
# =============================================================================

set -euo pipefail

# ── CONFIG (safe to edit) ─────────────────────────────────────────────────────
PROFILE_NAME="steamos-archiso"
DEFAULT_SESSION="plasmawayland"
ISO_LABEL="STEAMOS_LIVE"
ISO_NAME="steamos"
ISO_APP="SteamOS Live/Rescue CD"
PRODUCT_NAME="SteamOS"

# Derived paths — do not edit
PROFILE_DIR="$HOME/$PROFILE_NAME"
LOCAL_REPO_DIR="$PROFILE_DIR/local-repo"
AIROOTFS="$PROFILE_DIR/airootfs"
OUT_DIR="$HOME/iso-output"
WORK_DIR="$HOME/archiso-work"

# ── COLORS ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${YELLOW}══════════════════════════════════════${RESET}"
            echo -e "${BOLD}${YELLOW}  $*${RESET}"
            echo -e "${BOLD}${YELLOW}══════════════════════════════════════${RESET}"; }

# ── ENVIRONMENT CHECKS ────────────────────────────────────────────────────────
step "Environment Checks"

# Must not be root
[[ "$EUID" -eq 0 ]] && error "Do NOT run as root — sudo is called internally."

# Must be Arch Linux
command -v pacman &>/dev/null || error "pacman not found. Must run on Arch Linux."
success "Running on Arch Linux as $(whoami)"

# Python check — required for profiledef.sh patching
if command -v python3 &>/dev/null; then
    success "Python found: $(python3 --version)"
else
    warn "Python 3 is not installed. It is required for this script."
    echo -e "${CYAN}  Running: sudo pacman -S --needed --noconfirm python${RESET}"
    sudo pacman -S --needed --noconfirm python
    command -v python3 &>/dev/null || error "Python 3 install failed. Run: sudo pacman -S python"
    success "Python 3 installed: $(python3 --version)"
fi
python3 -c "import re, pathlib, sys; assert sys.version_info >= (3,6)" 2>/dev/null || \
    error "Python 3.6+ with re and pathlib required."
success "Python modules OK."

# git check
if command -v git &>/dev/null; then
    success "git found: $(git --version)"
else
    warn "git not installed. Installing..."
    sudo pacman -S --needed --noconfirm git
    command -v git &>/dev/null || error "git install failed."
    success "git installed."
fi

# curl check
if command -v curl &>/dev/null; then
    success "curl found."
else
    warn "curl not installed. Installing..."
    sudo pacman -S --needed --noconfirm curl
    command -v curl &>/dev/null || error "curl install failed."
    success "curl installed."
fi

# sudo check
command -v sudo &>/dev/null || error "sudo not found. Install it: pacman -S sudo"
success "sudo found."

# awk check
if ! command -v awk &>/dev/null; then
    warn "awk not found. Installing gawk..."
    sudo pacman -S --needed --noconfirm gawk
fi
success "awk found."

# Disk space check
FREE_HOME=$(df "$HOME" --output=avail -BG | tail -1 | tr -d 'G ')
[[ "$FREE_HOME" -lt 20 ]] && \
    error "Need 20GB free in \$HOME (have ${FREE_HOME}GB). Free up space and retry."
success "Disk space OK — ${FREE_HOME}GB free."

# Internet check
curl -s --max-time 5 https://archlinux.org > /dev/null 2>&1 || \
    error "No internet connection. This script requires internet access."
success "Internet connection OK."

success "All environment checks passed."

# ── STEP 1: Host dependencies ─────────────────────────────────────────────────
step "Step 1/9 — Installing host dependencies"
DEPS=(archiso limine git base-devel squashfs-tools dosfstools edk2-ovmf mkinitcpio-archiso syslinux go librsvg)
MISSING=()
for pkg in "${DEPS[@]}"; do
    pacman -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
done
[[ ${#MISSING[@]} -gt 0 ]] && {
    info "Installing: ${MISSING[*]}"
    sudo pacman -S --needed --noconfirm "${MISSING[@]}"
}

# Install yay if no AUR helper present
if ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
    info "Installing yay (AUR helper)..."
    # go is required to build yay — install it first
    sudo pacman -S --needed --noconfirm go git base-devel
    TMP_YAY="$HOME/.yay-build"
    mkdir -p "$TMP_YAY"
    git clone https://aur.archlinux.org/yay.git "$TMP_YAY/yay"
    (cd "$TMP_YAY/yay" && makepkg -si --noconfirm)
    rm -rf "$TMP_YAY"
    success "yay installed."
fi
AUR_CMD=$(command -v yay || command -v paru)
success "Host dependencies ready. AUR helper: $AUR_CMD"

# ── STEP 2: Set up archiso profile ────────────────────────────────────────────
step "Step 2/9 — Setting up archiso profile"
if [[ -d "$PROFILE_DIR" ]]; then
    warn "Profile $PROFILE_DIR already exists."
    read -rp "  Delete and recreate? [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || error "Aborted."
    rm -rf "$PROFILE_DIR"
fi

cp -r /usr/share/archiso/configs/releng/ "$PROFILE_DIR"

# Patch profiledef.sh via Python tempfile.
# Passes values as argv so no shell quoting issues at all.
# Uses re.DOTALL to handle multi-line bootmodes=(...) arrays.
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
p.write_text('\n'.join(out) + '\n')
print('profiledef.sh patched OK.')
PYEOF

python3 /tmp/fix_profiledef.py \
    "$PROFILE_DIR/profiledef.sh" \
    "$ISO_LABEL" \
    "$ISO_NAME" \
    "$ISO_APP" \
    "'uefi-x64.systemd-boot.esp' 'uefi-x64.systemd-boot.eltorito'"
rm /tmp/fix_profiledef.py
bash -n "$PROFILE_DIR/profiledef.sh" || error "profiledef.sh syntax broken after patch"
success "profiledef.sh patched (UEFI only, no syslinux)."

mkdir -p "$AIROOTFS"/{etc,opt,root}
mkdir -p "$AIROOTFS/etc/systemd/system"
mkdir -p "$AIROOTFS/etc/calamares/modules"
mkdir -p "$AIROOTFS/etc/calamares/branding/$ISO_NAME"

mkdir -p "$AIROOTFS/etc/calamares/branding/$ISO_NAME"

# Generate a guaranteed valid PNG for Calamares branding using Python
# Calamares is strict — it requires actual PNG files, not SVGs renamed as .png
python3 << PYEOF
import struct, zlib, pathlib

def make_png(width, height, r, g, b):
    """Generate a minimal valid PNG file."""
    def chunk(name, data):
        c = name + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    
    raw = b''
    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            # Draw Steam Deck-style circle logo
            cx, cy = width//2, height//2
            d = ((x-cx)**2 + (y-cy)**2) ** 0.5
            outer = min(cx, cy) * 0.9
            inner = min(cx, cy) * 0.45
            if d <= inner:
                raw += bytes([26, 159, 255])   # Steam blue inner circle
            elif d <= outer:
                raw += bytes([r, g, b])         # Logo ring color
            else:
                raw += bytes([26, 26, 46])      # Dark background
    
    idat = chunk(b'IDAT', zlib.compress(raw))
    iend = chunk(b'IEND', b'')
    return sig + ihdr + idat + iend

out = pathlib.Path('$AIROOTFS/etc/calamares/branding/$ISO_NAME')
png = make_png(256, 256, 255, 255, 255)
(out / 'logo.png').write_bytes(png)
(out / 'languages.png').write_bytes(png)
print('Calamares branding PNG files generated.')
PYEOF

info "Calamares branding images created."
mkdir -p "$AIROOTFS/etc/xdg/autostart"
mkdir -p "$AIROOTFS/etc/skel/Desktop"
mkdir -p "$AIROOTFS/usr/share/applications"
mkdir -p "$LOCAL_REPO_DIR"

# Remove memdisk and all PXE hooks from archiso mkinitcpio config.
# We only boot from USB/ISO — PXE/network booting is not needed.
# memdisk requires syslinux, PXE hooks require network boot infrastructure.
# Removing them makes the initramfs smaller and faster to build.
ARCHISO_MKINIT="$AIROOTFS/etc/mkinitcpio.conf.d/archiso.conf"
if [[ -f "$ARCHISO_MKINIT" ]]; then
    sed -i 's/ memdisk//' "$ARCHISO_MKINIT"
    sed -i 's/ archiso_loop_mnt//' "$ARCHISO_MKINIT"
    sed -i 's/ archiso_pxe_common//' "$ARCHISO_MKINIT"
    sed -i 's/ archiso_pxe_nbd//' "$ARCHISO_MKINIT"
    sed -i 's/ archiso_pxe_http//' "$ARCHISO_MKINIT"
    sed -i 's/ archiso_pxe_nfs//' "$ARCHISO_MKINIT"
    info "Removed memdisk and PXE hooks from archiso mkinitcpio config."
    info "Resulting hooks: $(grep ^HOOKS "$ARCHISO_MKINIT")"
fi
success "Profile structure created."

# ── STEP 3: Build AUR packages ────────────────────────────────────────────────
step "Step 3/9 — Building AUR packages"
AUR_BUILD_DIR=$(mktemp -d -p "$HOME" tmp.aur.XXXXXX)

# Tell makepkg to build in HOME not /tmp — avoids tmpfs size limit errors
export BUILDDIR="$HOME/.makepkg-build"
export PKGDEST="$HOME/.pkg-cache"
mkdir -p "$BUILDDIR" "$PKGDEST"

build_aur_pkg() {
    local pkg="$1"
    info "Building $pkg..."
    (
        cd "$AUR_BUILD_DIR"
        $AUR_CMD -G "$pkg" --noconfirm 2>/dev/null || \
            git clone "https://aur.archlinux.org/${pkg}.git"
        cd "$pkg"
        makepkg -s --noconfirm --skippgpcheck
    )
    # makepkg puts packages in BUILDDIR/<pkg>/ when BUILDDIR is set
    # Search all likely locations
    local found=0
    for search_dir in \
        "$BUILDDIR/$pkg" \
        "$AUR_BUILD_DIR/$pkg" \
        "$PKGDEST" \
        "$HOME/.makepkg-build/$pkg"; do
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            info "Found package: $f"
            cp "$f" "$LOCAL_REPO_DIR/"
            found=1
        done < <(find "$search_dir" -maxdepth 1 -name "*.pkg.tar.zst" 2>/dev/null)
    done
    [[ $found -eq 1 ]] || error "No package found for $pkg — build may have failed"
    success "$pkg built."
}

purge_cached_pkg() {
    local pattern="$1"
    for f in /var/cache/pacman/pkg/${pattern}*.pkg.tar.zst; do
        [[ -f "$f" ]] || continue
        tar -taf "$f" &>/dev/null || {
            warn "Removing corrupted cached package: $f"
            sudo rm -f "$f"
        }
    done
}

info "Checking for corrupted cached packages..."
purge_cached_pkg "calamares"
purge_cached_pkg "gamescope-session-git"
purge_cached_pkg "gamescope-session-steam-git"

build_aur_pkg "gamescope-session-git"
build_aur_pkg "gamescope-session-steam-git"
build_aur_pkg "calamares"

# DB name MUST match [local-repo] section name
repo-add "$LOCAL_REPO_DIR/local-repo.db.tar.gz" "$LOCAL_REPO_DIR"/*.pkg.tar.zst
ln -sf local-repo.db.tar.gz "$LOCAL_REPO_DIR/local-repo.db"
ln -sf local-repo.files.tar.gz "$LOCAL_REPO_DIR/local-repo.files"
sudo cp "$LOCAL_REPO_DIR"/*.pkg.tar.zst /var/cache/pacman/pkg/
success "Local AUR repo built and packages cached."
rm -rf "$AUR_BUILD_DIR"

# ── STEP 4: Write packages.x86_64 ────────────────────────────────────────────
step "Step 4/9 — Writing packages.x86_64"
cat > "$PROFILE_DIR/packages.x86_64" << 'EOF'
# ── Base ──────────────────────────────────────────────────────────────────────
base
base-devel
linux
linux-firmware
linux-headers
mkinitcpio
mkinitcpio-archiso
go
sudo
nano
vim
git
wget
curl
htop
unzip
zip
p7zip
bash-completion
man-db
man-pages
# ── Boot ──────────────────────────────────────────────────────────────────────
limine
efibootmgr
os-prober
# ── Networking ────────────────────────────────────────────────────────────────
networkmanager
network-manager-applet
nm-connection-editor
plasma-nm
wireless_tools
wpa_supplicant
dhcpcd
# ── KDE Plasma ────────────────────────────────────────────────────────────────
plasma-meta
kde-applications-meta
sddm
sddm-kcm
xorg-server
xorg-xinit
qt5-wayland
qt6-wayland
wayland
wayland-protocols
xdg-desktop-portal
xdg-desktop-portal-kde
xdg-user-dirs
konsole
# ── Fonts ─────────────────────────────────────────────────────────────────────
noto-fonts
noto-fonts-emoji
noto-fonts-cjk
ttf-liberation
ttf-dejavu
# ── Calamares (from local-repo) ───────────────────────────────────────────────
calamares
# ── Audio ─────────────────────────────────────────────────────────────────────
pipewire
pipewire-alsa
pipewire-pulse
pipewire-jack
wireplumber
pavucontrol
# ── Bluetooth ─────────────────────────────────────────────────────────────────
bluez
bluez-utils
# ── Gaming / arch-deckify (from local-repo) ───────────────────────────────────
steam
gamescope
mangohud
lib32-mangohud
gamemode
lib32-gamemode
ntfs-3g
zenity
gamescope-session-git
gamescope-session-steam-git
# ── Optional gaming utilities ─────────────────────────────────────────────────
protontricks
wine
winetricks
lutris
# ── GPU drivers ───────────────────────────────────────────────────────────────
mesa
lib32-mesa
vulkan-radeon
lib32-vulkan-radeon
vulkan-intel
lib32-vulkan-intel
xf86-video-amdgpu
xf86-video-intel
# ── Plymouth ──────────────────────────────────────────────────────────────────
plymouth
plymouth-kcm
# ── Misc ──────────────────────────────────────────────────────────────────────
flatpak
gparted
dolphin
ark
syslinux
EOF
success "packages.x86_64 written."

# ── STEP 5: Configure pacman.conf ─────────────────────────────────────────────
step "Step 5/9 — Configuring pacman.conf"
PACMAN_CONF="$PROFILE_DIR/pacman.conf"

grep -q '^\[multilib\]' "$PACMAN_CONF" || \
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$PACMAN_CONF"

if ! grep -q '^\[local-repo\]' "$PACMAN_CONF"; then
    awk -v dir="$LOCAL_REPO_DIR" '
        /^\[core\]/ && !done {
            print "[local-repo]"
            print "SigLevel = Never"
            print "Server = file://" dir
            print ""
            done=1
        }
        { print }
    ' "$PACMAN_CONF" > "${PACMAN_CONF}.tmp" && mv "${PACMAN_CONF}.tmp" "$PACMAN_CONF"
fi

sed -i 's/^SigLevel.*/SigLevel = Never/' "$PACMAN_CONF"
grep -q '^CacheDir' "$PACMAN_CONF" || \
    sed -i '/^\[options\]/a CacheDir = /var/cache/pacman/pkg/' "$PACMAN_CONF"
success "pacman.conf configured."

# ── STEP 6: Bundle arch-deckify ───────────────────────────────────────────────
step "Step 6/9 — Bundling arch-deckify"
git clone https://github.com/unlbslk/arch-deckify.git "$AIROOTFS/opt/arch-deckify"
DECKIFY_SCRIPT="$AIROOTFS/opt/arch-deckify/install.sh"

awk -v session="$DEFAULT_SESSION" '
    /^while true; do/ { in_loop=1 }
    in_loop && /^done/ {
        print "selected_de=\"" session "\""
        in_loop=0
        next
    }
    in_loop { next }
    { print }
' "$DECKIFY_SCRIPT" > "${DECKIFY_SCRIPT}.tmp" && mv "${DECKIFY_SCRIPT}.tmp" "$DECKIFY_SCRIPT"

if ! grep -q "^selected_de=" "$DECKIFY_SCRIPT"; then
    sed -i "2i selected_de=\"$DEFAULT_SESSION\"" "$DECKIFY_SCRIPT"
    info "selected_de injected via fallback."
fi

chmod +x "$DECKIFY_SCRIPT"
grep -q "^selected_de=" "$DECKIFY_SCRIPT" || error "arch-deckify patch failed"
success "arch-deckify patched (session=$DEFAULT_SESSION)."

# ── STEP 6.5: Fetch steamdeck-kde-presets ────────────────────────────────────
step "Step 6.5/9 — Fetching steamdeck-kde-presets (Vapor theme)"
KDE_PRESETS_URL="https://steamdeck-packages.steamos.cloud/archlinux-mirror/jupiter-main/os/x86_64/"
KDE_PRESETS_TMP=$(mktemp -d)
LATEST_PKG=$(curl -s "$KDE_PRESETS_URL" \
    | grep -oP 'steamdeck-kde-presets-[\d\.]+-[\d]+-any\.pkg\.tar\.zst(?=")' \
    | sort -V | tail -n1)
if [[ -n "$LATEST_PKG" ]]; then
    curl -L --fail -o "$KDE_PRESETS_TMP/$LATEST_PKG" "${KDE_PRESETS_URL}${LATEST_PKG}" && {
        tar -I zstd -xf "$KDE_PRESETS_TMP/$LATEST_PKG" -C "$AIROOTFS" \
            --exclude='.PKGINFO' --exclude='.MTREE' \
            --exclude='.BUILDINFO' --exclude='.INSTALL' 2>/dev/null || true
        success "steamdeck-kde-presets extracted."
    } || warn "steamdeck-kde-presets download failed — skipping."
else
    warn "Could not find steamdeck-kde-presets — skipping."
fi
rm -rf "$KDE_PRESETS_TMP"

# ── STEP 7: Write airootfs config files ───────────────────────────────────────
step "Step 7/9 — Writing airootfs configuration"

# SDDM — arch-deckify hardcodes /etc/sddm.conf
cat > "$AIROOTFS/etc/sddm.conf" << EOF
[Autologin]
Relogin=true
Session=$DEFAULT_SESSION
User=liveuser

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot

[Theme]
Current=

[Users]
MaximumUid=60513
MinimumUid=1000
EOF
info "Written: sddm.conf"

# arch-deckify first-boot service
cat > "$AIROOTFS/etc/systemd/system/arch-deckify-setup.service" << 'EOF'
[Unit]
Description=Arch-Deckify First Boot Setup
After=graphical.target plasma-plasmashell.service
ConditionPathExists=!/etc/arch-deckify-installed

[Service]
Type=oneshot
User=1000
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-0
ExecStart=/usr/bin/konsole -e /opt/arch-deckify/install.sh
ExecStartPost=/usr/bin/touch /etc/arch-deckify-installed
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF
info "Written: arch-deckify-setup.service"

# Calamares settings.conf
cat > "$AIROOTFS/etc/calamares/settings.conf" << EOF
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
    - bootloader
    - packages
    - removeuser
    - umount
  - show:
    - finished
branding: $ISO_NAME
prompt-install: true
dont-chroot: false
EOF

# Calamares branding
cat > "$AIROOTFS/etc/calamares/branding/$ISO_NAME/branding.desc" << EOF
---
componentName: $ISO_NAME
welcomeStyleCalamares: true
welcomeExpandingLogo:  true
strings:
  productName:         $PRODUCT_NAME
  shortProductName:    $ISO_NAME
  version:             Rolling
  shortVersion:        Rolling
  versionedName:       $PRODUCT_NAME (Rolling)
  bootloaderEntryName: $PRODUCT_NAME
  productUrl:          https://archlinux.org
  supportUrl:          https://wiki.archlinux.org
images:
  productLogo:    "logo.png"
  productIcon:    "logo.png"
  productWelcome: "languages.png"
slideshow: show.qml
slideshowAPI: 2
style:
  sidebarBackground:    "#1a1a2e"
  sidebarText:          "#FFFFFF"
  sidebarTextSelect:    "#1a1a2e"
  sidebarTextHighlight: "#1a9fff"
EOF

cat > "$AIROOTFS/etc/calamares/branding/$ISO_NAME/show.qml" << 'EOF'
import QtQuick 2.0;
import calamares.slideshow 1.0;
Presentation {
    id: presentation
    Timer {
        interval: 4000; running: presentation.activatedInCalamares
        repeat: true; onTriggered: presentation.goToNextSlide()
    }
    Slide {
        Image {
            source: "logo.png"; width: 800; height: 500
            fillMode: Image.PreserveAspectFit
            anchors.centerIn: parent
        }
    }
}
EOF

# Calamares module configs
cat > "$AIROOTFS/etc/calamares/modules/welcome.conf" << 'EOF'
---
showSupportUrl:      true
showKnownIssuesUrl:  true
showReleaseNotesUrl: false
requirements:
  checker: all
  required:    [ storage, ram ]
  recommended: [ power, internet ]
storageMinSize: 20000
ramMinSize:      4000
EOF

cat > "$AIROOTFS/etc/calamares/modules/locale.conf" << 'EOF'
---
region:        "America"
zone:          "New_York"
localeGenPath: "/etc/locale.gen"
geoipUrl:      "https://ipapi.co/json"
geoipStyle:    "json"
EOF

cat > "$AIROOTFS/etc/calamares/modules/keyboard.conf" << 'EOF'
---
xorgConfPath:        "/etc/X11/xorg.conf.d/00-keyboard.conf"
convertedKeymapPath: "/lib/kbd/keymaps/xkb"
EOF

cat > "$AIROOTFS/etc/calamares/modules/users.conf" << 'EOF'
---
userShell: /bin/bash
rootPassReq:
  - minLength: 6
  - maxLength: 128
  - allowEmpty: false
userPassReq:
  - minLength: 6
  - maxLength: 128
  - allowEmpty: false
allowWeakPasswords:        false
allowWeakPasswordsDefault: false
autologinGroup:  autologin
sudoersGroup:    wheel
setRootPassword: true
doAutologin:     false
userList:
  - sudo
  - wheel
  - video
  - audio
  - storage
  - optical
  - network
  - bluetooth
EOF

cat > "$AIROOTFS/etc/calamares/modules/partition.conf" << 'EOF'
---
efi:
  mountPoint:      "/boot/efi"
  recommendedSize: 512MiB
  minimumSize:     128MiB
userSwapChoices:           [ none, small, suspend, file ]
initialPartitioningChoice: erase
initialSwapChoice:         small
defaultFileSystemType:     "ext4"
availableFileSystemTypes:  ["ext4", "btrfs", "xfs", "f2fs"]
requiredStorage: 20.0
EOF

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

cat > "$AIROOTFS/etc/calamares/modules/fstab.conf" << 'EOF'
---
mountOptions:
  default: defaults,noatime
  btrfs:   defaults,noatime,compress=zstd
  efi:     defaults,fmask=0137,dmask=0027
ssdExtraMountOptions:
  default: discard=async
  btrfs:   discard=async,compress=zstd
EOF

cat > "$AIROOTFS/etc/calamares/modules/networkcfg.conf" << 'EOF'
---
backend: NetworkManager
EOF

cat > "$AIROOTFS/etc/calamares/modules/hwclock.conf" << 'EOF'
---
setHardwareClock: true
EOF

cat > "$AIROOTFS/etc/calamares/modules/initcpiocfg.conf" << 'EOF'
---
kernel: linux
hooksDir: /etc/mkinitcpio.conf.d
hooks:
  - base
  - udev
  - plymouth
  - autodetect
  - modconf
  - kms
  - keyboard
  - keymap
  - consolefont
  - block
  - filesystems
  - fsck
EOF

cat > "$AIROOTFS/etc/calamares/modules/initcpio.conf" << 'EOF'
---
kernel: linux
EOF

cat > "$AIROOTFS/etc/calamares/modules/packages.conf" << 'EOF'
---
backend: pacman
update_db:     false
update_system: false
operations:
  - remove:
    - calamares
EOF

cat > "$AIROOTFS/etc/calamares/modules/removeuser.conf" << 'EOF'
---
username: liveuser
EOF

cat > "$AIROOTFS/etc/calamares/modules/finished.conf" << 'EOF'
---
restartNowEnabled: true
restartNowChecked: true
restartNowCommand: "systemctl reboot"
notifyOnFinished:  false
EOF

# shellprocess@post — runs ONLY on the INSTALLED system after unpackfs
# NOT the live ISO. This is where mkinitcpio runs safely.
cat > "$AIROOTFS/etc/calamares/modules/shellprocess@post.conf" << 'EOF'
---
dontChroot: false
timeout:    600
script:
  - "-": |
      grep -q '^\[multilib\]' /etc/pacman.conf || \
          printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
      pacman -Sy --noconfirm

  - "-": |
      pacman -S --needed --noconfirm git base-devel
      INSTALLED_USER=$(getent passwd 1000 | cut -d: -f1 || echo "user")
      USER_HOME=$(getent passwd 1000 | cut -d: -f6 || echo "/home/$INSTALLED_USER")
      YAY_BUILD="$USER_HOME/.yay-build"
      mkdir -p "$YAY_BUILD"
      chown "$INSTALLED_USER:$INSTALLED_USER" "$YAY_BUILD"
      git clone https://aur.archlinux.org/yay.git "$YAY_BUILD/yay"
      chown -R "$INSTALLED_USER:$INSTALLED_USER" "$YAY_BUILD"
      (cd "$YAY_BUILD/yay" && sudo -u "$INSTALLED_USER" makepkg -si --noconfirm)
      rm -rf "$YAY_BUILD"

  - "-": |
      systemctl enable NetworkManager sddm bluetooth fstrim.timer

  - "-": |
      INSTALLED_USER=$(getent passwd 1000 | cut -d: -f1 || echo "user")
      cat > /etc/sddm.conf << SDDMEOF
[Autologin]
Relogin=false
Session=plasmawayland
User=${INSTALLED_USER}

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot

[Theme]
Current=breeze
SDDMEOF

  - "-": |
      for t in steamdeck steamos bgrt; do
          [ -d "/usr/share/plymouth/themes/$t" ] && \
              plymouth-set-default-theme "$t" && break
      done 2>/dev/null || true
      grep -q '\bplymouth\b' /etc/mkinitcpio.conf || \
          sed -i 's/\(HOOKS=([^)]*\budev\b\)/\1 plymouth/' /etc/mkinitcpio.conf

  - "-": |
      INSTALLED_USER=$(getent passwd 1000 | cut -d: -f1 || echo "user")
      cat > /etc/systemd/system/arch-deckify-setup.service << SVCEOF
[Unit]
Description=Arch-Deckify First Boot Setup
After=graphical.target
ConditionPathExists=!/etc/arch-deckify-installed

[Service]
Type=oneshot
User=1000
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-0
ExecStart=/usr/bin/konsole -e /opt/arch-deckify/install.sh
ExecStartPost=/usr/bin/touch /etc/arch-deckify-installed
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
SVCEOF
      systemctl enable arch-deckify-setup

  - "-": |
      pacman -S --needed --noconfirm steam 2>/dev/null || true
      flatpak remote-add --if-not-exists flathub \
          https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
EOF
info "Written: all Calamares module configs"

# Calamares bootloader
cat > "$AIROOTFS/etc/calamares/modules/bootloader.conf" << 'EOF'
---
efiBootLoader:      "systemd-boot"
kernel:             "/boot/vmlinuz-linux"
initramfs:          "/boot/initramfs-linux.img"
initramfsBackup:    "/boot/initramfs-linux-fallback.img"
kernelLine:         " quiet splash plymouth.enable=1"
fallbackKernelLine: " verbose plymouth.enable=0"
timeout:            5
pmbr_install:       false
EOF

# Calamares autostart
cat > "$AIROOTFS/etc/xdg/autostart/calamares.desktop" << 'EOF'
[Desktop Entry]
Name=Install System
Exec=sh -c "pkexec calamares || sudo -E calamares"
Icon=calamares
Terminal=false
Type=Application
X-KDE-autostart-phase=2
EOF

cat > "$AIROOTFS/etc/skel/Desktop/Install_System.desktop" << EOF
[Desktop Entry]
Version=1.0
Name=Install $PRODUCT_NAME
Exec=sh -c "pkexec calamares || sudo -E calamares"
Icon=calamares
Terminal=false
Type=Application
Categories=System;
EOF
info "Written: Calamares launcher"

# Limine live ISO boot menu
mkdir -p "$AIROOTFS/boot/limine"
cat > "$AIROOTFS/boot/limine/limine.cfg" << EOF
timeout: 5
default_entry: 1

/$PRODUCT_NAME
    protocol: linux
    kernel_path: boot:///arch/boot/x86_64/vmlinuz-linux
    cmdline: archisobasedir=arch archisolabel=$ISO_LABEL rw quiet splash plymouth.enable=1
    module_path: boot:///arch/boot/x86_64/initramfs-linux.img

/$PRODUCT_NAME (verbose)
    protocol: linux
    kernel_path: boot:///arch/boot/x86_64/vmlinuz-linux
    cmdline: archisobasedir=arch archisolabel=$ISO_LABEL rw plymouth.enable=0
    module_path: boot:///arch/boot/x86_64/initramfs-linux.img
EOF
info "Written: limine.cfg"

# ── customize_airootfs.sh ─────────────────────────────────────────────────────
# IMPORTANT: This runs in the LIVE ISO chroot during mkarchiso.
# Do NOT add mkinitcpio or HOOKS modifications here — the live ISO uses
# archiso-specific hooks that don't exist at runtime and will break boot.
# Plymouth mkinitcpio injection happens ONLY in shellprocess@post (installed system).
cat > "$AIROOTFS/root/customize_airootfs.sh" << CEOF
#!/usr/bin/env bash
set -e

echo "[customize] Enabling services..."
systemctl enable sddm NetworkManager bluetooth
systemctl enable arch-deckify-setup || true

echo "[customize] Creating live user..."
mkdir -p /home/liveuser/{Desktop,arch-deckify,.config,.local/share/color-schemes}
mkdir -p /home/liveuser/.local/share/plasma/plasmoids/org.kde.plasma.kickoff/contents/config
mkdir -p /home/liveuser/.local/share/applications

if ! id liveuser &>/dev/null; then
    useradd -M -G wheel,video,audio,storage,optical -s /bin/bash liveuser
fi
echo "liveuser:liveuser" | chpasswd
echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
echo "liveuser ALL=(ALL) NOPASSWD: /usr/bin/calamares" > /etc/sudoers.d/calamares-live
chmod 440 /etc/sudoers.d/calamares-live

# Polkit rule so pkexec can launch calamares without password prompt
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-calamares.rules << 'PEOF'
polkit.addRule(function(action, subject) {
    if (action.id === "org.freedesktop.policykit.exec" &&
        action.lookup("program") === "/usr/bin/calamares" &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
PEOF

# Steam environment — helps with VM/software rendering fallback
mkdir -p /etc/environment.d
cat > /etc/environment.d/steam.conf << 'EEOF'
STEAM_RUNTIME_PREFER_HOST_LIBRARIES=0
DXVK_CONFIG_FILE=/dev/null
__GL_SHADER_DISK_CACHE=0
EEOF

# Gaming mode fallback — if gamescope fails (VM/no GPU) drop back to desktop
# instead of SDDM login screen
cat > /usr/bin/steamos-session-select << 'SEOF'
#!/usr/bin/bash
CONFIG_FILE="/etc/sddm.conf"
if [ \$# -eq 0 ]; then echo "Valid arguments: plasma, gamescope"; exit 0; fi
if [ "\$1" == "plasma" ] || [ "\$1" == "desktop" ]; then
    [ ! -f "\$CONFIG_FILE" ] && echo "SDDM config not found." && exit 1
    NEW_SESSION="$DEFAULT_SESSION"
    sudo sed -i "s/^Session=.*/Session=\${NEW_SESSION}/" "\$CONFIG_FILE"
    steam -shutdown 2>/dev/null || true
elif [ "\$1" == "gamescope" ]; then
    [ ! -f "\$CONFIG_FILE" ] && echo "SDDM config not found." && exit 1
    # Check if gamescope is actually available and GPU supports it
    if ! command -v gamescope &>/dev/null; then
        notify-send "Gaming Mode" "Gamescope not found — staying in desktop mode." 2>/dev/null || true
        exit 1
    fi
    NEW_SESSION="gamescope-session-steam"
    sudo sed -i "s/^Session=.*/Session=\${NEW_SESSION}/" "\$CONFIG_FILE"
    dbus-send --session --type=method_call --print-reply \
        --dest=org.kde.Shutdown /Shutdown org.kde.Shutdown.logout \
        || gnome-session-quit --logout --no-prompt \
        || loginctl terminate-session \$XDG_SESSION_ID
else
    echo "Valid arguments: plasma, gamescope."; exit 1
fi
SEOF
chmod +x /usr/bin/steamos-session-select

echo "[customize] Writing sudoers for session switching..."
echo "ALL ALL=(ALL) NOPASSWD: /usr/bin/sed -i s/^Session=*/Session=*/ /etc/sddm.conf" \
    > /etc/sudoers.d/sddm_config_edit
chmod 440 /etc/sudoers.d/sddm_config_edit

echo "[customize] Adding backlight udev rule..."
usermod -a -G video liveuser 2>/dev/null || true
echo 'ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video \$sys\$devpath/brightness", RUN+="/bin/chmod g+w \$sys\$devpath/brightness"' \
    >> /etc/udev/rules.d/backlight.rules

echo "[customize] Downloading Steam Deck icons..."
ICON_BASE="https://gitlab.com/evlaV"
HICOLOR_DIR="/usr/share/icons/hicolor/scalable"
mkdir -p "\$HICOLOR_DIR/actions" "\$HICOLOR_DIR/apps"
curl -L --fail --max-time 20 \
    "\$ICON_BASE/steamdeck-kde-presets/-/raw/master/usr/share/icons/hicolor/scalable/actions/steamdeck-gaming-return.svg" \
    -o "\$HICOLOR_DIR/actions/steamdeck-gaming-return.svg" 2>/dev/null || true
curl -L --fail --max-time 20 \
    "\$ICON_BASE/jupiter-PKGBUILD/-/raw/master/images/steam-deck-logo.svg" \
    -o "\$HICOLOR_DIR/apps/steam-deck-logo.svg" 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

# Set Kickoff launcher icon via Plasma autostart script
# Uses qdbus to set the icon at runtime after Plasma loads
mkdir -p /home/liveuser/.config/autostart
mkdir -p /home/liveuser/.local/bin

# Bundle the steam-deck-logo SVG directly into the icon theme
# so it's available by name without path
mkdir -p /usr/share/icons/hicolor/scalable/apps
# Copy uploaded SVG if it was placed in airootfs, otherwise use curl fallback
if [[ -f /usr/share/icons/hicolor/scalable/apps/steam-deck-logo.svg ]]; then
    echo "  steam-deck-logo.svg already in icon theme"
fi

cat > /home/liveuser/.config/autostart/set-kickoff-icon.desktop << 'KAEOF'
[Desktop Entry]
Name=Set Kickoff Icon
Exec=/home/liveuser/.local/bin/set-kickoff-icon.sh
Type=Application
X-KDE-autostart-phase=2
OnlyShowIn=KDE;
KAEOF

cat > /home/liveuser/.local/bin/set-kickoff-icon.sh << 'KEOF'
#!/usr/bin/bash
sleep 5

# Plasma 6 API — use qdbus6 or qdbus
QDBUS_BIN=\$(command -v qdbus6 2>/dev/null || command -v qdbus 2>/dev/null || echo "")
[ -z "\$QDBUS_BIN" ] && exit 0

\$QDBUS_BIN org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
var allPanels = panels();
for (var i = 0; i < allPanels.length; i++) {
    var ws = allPanels[i].widgets();
    for (var j = 0; j < ws.length; j++) {
        if (ws[j].type === 'org.kde.plasma.kickoff' ||
            ws[j].type === 'org.kde.plasma.kicker' ||
            ws[j].type === 'org.kde.plasma.kickerdash') {
            ws[j].currentConfigGroup = ['General'];
            ws[j].writeConfig('icon', 'steam-deck-logo');
            ws[j].reloadConfig();
        }
    }
}
" 2>/dev/null

# Self-destruct after running once
rm -f ~/.config/autostart/set-kickoff-icon.desktop
rm -f ~/.local/bin/set-kickoff-icon.sh
KEOF
chmod +x /home/liveuser/.local/bin/set-kickoff-icon.sh

echo "[customize] Setting Steam Deck wallpaper..."
mkdir -p /usr/share/wallpapers/SteamDeck/contents/images
curl -L --fail --max-time 30 \
    "https://gitlab.com/evlaV/jupiter-PKGBUILD/-/raw/master/images/steam-deck-logo.svg" \
    -o /usr/share/wallpapers/SteamDeck/contents/images/steam-deck-logo.svg 2>/dev/null || true
printf '{"KPlugin":{"Id":"SteamDeck","Name":"Steam Deck","Description":"Steam Deck Logo Default"}}\n' \
    > /usr/share/wallpapers/SteamDeck/metadata.json
WALLPAPER_PATH=""
for wp in \
    /usr/share/wallpapers/SteamDeck/contents/images/steam-deck-logo.svg \
    /usr/share/wallpapers/Vapor/contents/images/1920x1080.png; do
    [ -f "\$wp" ] && WALLPAPER_PATH="\$wp" && break
done

echo "[customize] Creating desktop shortcuts..."
if [ -f "\$HICOLOR_DIR/actions/steamdeck-gaming-return.svg" ]; then
    GAMING_ICON="steamdeck-gaming-return"
else
    GAMING_ICON="/home/liveuser/arch-deckify/steam-gaming-return.png"
fi
cat > /home/liveuser/Desktop/Return_to_Gaming_Mode.desktop << DEOF
[Desktop Entry]
Name=Gaming Mode
Exec=steamos-session-select gamescope
Icon=\$GAMING_ICON
Terminal=false
Type=Application
StartupNotify=false
DEOF
chmod +x /home/liveuser/Desktop/Return_to_Gaming_Mode.desktop
cp /home/liveuser/Desktop/Return_to_Gaming_Mode.desktop /usr/share/applications/ 2>/dev/null || true
cp /etc/skel/Desktop/Install_System.desktop /home/liveuser/Desktop/ 2>/dev/null || true
chmod +x /home/liveuser/Desktop/Install_System.desktop 2>/dev/null || true

# ── Deckify Helper — full setup ───────────────────────────────────────────────
echo "[customize] Setting up Deckify Helper..."

# Create arch-deckify home directory
mkdir -p /home/liveuser/arch-deckify

# Copy everything from bundled /opt/arch-deckify
cp -r /opt/arch-deckify/. /home/liveuser/arch-deckify/ 2>/dev/null || true

# Download icons (gui_helper looks for these in ~/arch-deckify/)
for icon in helper.png steam-gaming-return.png; do
    [ -f /home/liveuser/arch-deckify/icons/\$icon ] && \
        cp /home/liveuser/arch-deckify/icons/\$icon \
           /home/liveuser/arch-deckify/\$icon 2>/dev/null || true
    [ ! -f /home/liveuser/arch-deckify/\$icon ] && \
        curl -L --fail --max-time 20 \
            "https://raw.githubusercontent.com/unlbslk/arch-deckify/refs/heads/main/icons/\$icon" \
            -o /home/liveuser/arch-deckify/\$icon 2>/dev/null || true
done

# Make all scripts executable
chmod +x /home/liveuser/arch-deckify/*.sh 2>/dev/null || true

# Pre-install all gui_helper dependencies
# zenity  — GUI dialogs
# jq      — required by Decky Loader installer
# curl    — downloads Decky Loader
pacman -S --needed --noconfirm zenity jq curl 2>/dev/null || true

# Add flathub so "Install Flathub" option is hidden in the helper menu
flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

# Sudoers — gui_helper uses 'ask_sudo' (zenity --password | sudo -S)
# liveuser is already in wheel with NOPASSWD so sudo -S works without a password
# This is correct behavior — the password prompt is skipped on the live session
cat > /etc/sudoers.d/deckify-helper << 'SEOF'
liveuser ALL=(ALL) NOPASSWD: ALL
SEOF
chmod 440 /etc/sudoers.d/deckify-helper

# Deckify Helper desktop shortcut
HELPER_ICON="/home/liveuser/arch-deckify/helper.png"
[ ! -f "\$HELPER_ICON" ] && HELPER_ICON="system-run"

cat > /home/liveuser/Desktop/Deckify_Tools.desktop << HEOF
[Desktop Entry]
Name=Deckify Helper
Exec=bash /home/liveuser/arch-deckify/gui_helper.sh
Icon=\$HELPER_ICON
Terminal=false
Type=Application
Categories=System;
StartupNotify=false
HEOF
chmod +x /home/liveuser/Desktop/Deckify_Tools.desktop

# System-wide app menu entry
cat > /usr/share/applications/Deckify_Tools.desktop << HEOF2
[Desktop Entry]
Name=Deckify Helper
Exec=bash /home/liveuser/arch-deckify/gui_helper.sh
Icon=\$HELPER_ICON
Terminal=false
Type=Application
Categories=System;
StartupNotify=false
HEOF2

echo "  Deckify Helper configured."

echo "[customize] Writing system_update.sh..."
cat > /home/liveuser/arch-deckify/system_update.sh << 'UEOF'
#!/bin/bash
AUR_CMD=\$(command -v yay || command -v paru || echo "")
[ -z "\$AUR_CMD" ] && echo "No AUR helper." && exit 1
konsole -e bash -c "sudo rm -rf /var/lib/pacman/db.lck; \$AUR_CMD -Syu --noconfirm; \
    flatpak update -y 2>/dev/null; echo Done; sleep 5" || true
UEOF
chmod +x /home/liveuser/arch-deckify/system_update.sh

echo "[customize] Applying Vapor/SteamOS theme..."
KWC=\$(command -v kwriteconfig6 2>/dev/null || command -v kwriteconfig5 2>/dev/null || echo "")
write_kde_cfg() {
    local file="\$1" group="\$2" key="\$3" value="\$4"
    [ -n "\$KWC" ] || return 0
    \$KWC --file "/etc/xdg/\$file"               --group "\$group" --key "\$key" "\$value"
    \$KWC --file "/home/liveuser/.config/\$file" --group "\$group" --key "\$key" "\$value"
}

# Layer 1: Plymouth — install theme files + write plymouthd.conf ONLY
# DO NOT run mkinitcpio or modify HOOKS here — this is the live ISO chroot
# and archiso-specific hooks (memdisk etc.) would break the boot initramfs.
# Plymouth initramfs injection happens post-install via shellprocess@post.
PLYMOUTH_TMP="\$(mktemp -d)"
PLYMOUTH_THEME="bgrt"
if git clone --depth=1 https://github.com/bootcrew/steamos-bootc.git "\$PLYMOUTH_TMP/bootc" 2>/dev/null; then
    while IFS= read -r m; do
        t="\$(basename "\$m" .plymouth)"; d="\$(dirname "\$m")"
        [ "\$t" != "default" ] && [ -d "\$d" ] && \
            mkdir -p "/usr/share/plymouth/themes/\$t" && \
            cp -r "\$d/." "/usr/share/plymouth/themes/\$t/" && \
            PLYMOUTH_THEME="\$t"
    done < <(find "\$PLYMOUTH_TMP/bootc" -name "*.plymouth" ! -name "default.plymouth" 2>/dev/null)
fi
if [ "\$PLYMOUTH_THEME" = "bgrt" ]; then
    if git clone --depth=1 https://github.com/vovamod/Plymouth-SteamDeck.git "\$PLYMOUTH_TMP/sd" 2>/dev/null; then
        mkdir -p /usr/share/plymouth/themes/steamdeck
        cp -r "\$PLYMOUTH_TMP/sd/images" /usr/share/plymouth/themes/steamdeck/ 2>/dev/null || true
        cp "\$PLYMOUTH_TMP/sd/steamdeck.plymouth" /usr/share/plymouth/themes/steamdeck/
        cp "\$PLYMOUTH_TMP/sd/steamdeck.script"   /usr/share/plymouth/themes/steamdeck/
        PLYMOUTH_THEME="steamdeck"
    fi
fi
rm -rf "\$PLYMOUTH_TMP"
mkdir -p /etc/plymouth
printf '[Daemon]\nTheme=%s\nShowDelay=0\nDeviceTimeout=8\n' "\$PLYMOUTH_THEME" \
    > /etc/plymouth/plymouthd.conf
echo "  Plymouth theme staged: \$PLYMOUTH_THEME (initramfs built post-install)"

# Layer 2: SDDM theme
SDDM_THEME=""
for t in vapor-deck breeze; do
    [ -d "/usr/share/sddm/themes/\$t" ] && SDDM_THEME="\$t" && break
done
if [ -n "\$SDDM_THEME" ]; then
    grep -q '^\[Theme\]' /etc/sddm.conf && \
        sed -i "s/^Current=.*/Current=\$SDDM_THEME/" /etc/sddm.conf || \
        printf '\n[Theme]\nCurrent=%s\n' "\$SDDM_THEME" >> /etc/sddm.conf
    echo "  SDDM: \$SDDM_THEME"
fi

# Layer 3: KSplash
KSPLASH="org.kde.breeze.desktop"
[ -d /usr/share/plasma/look-and-feel/com.valve.vapor.desktop ] && \
    KSPLASH="com.valve.vapor.desktop"
write_kde_cfg ksplashrc KSplash Theme  "\$KSPLASH"
write_kde_cfg ksplashrc KSplash Engine "KSplashQML"
echo "  KSplash: \$KSPLASH"

# Layer 4: KDE Plasma theme
[ -d /usr/share/plasma/look-and-feel/com.valve.vapor.desktop ] && \
    write_kde_cfg kdeglobals KDE LookAndFeelPackage "com.valve.vapor.desktop"
write_kde_cfg kdeglobals General  ColorScheme "Vapor"
write_kde_cfg kdeglobals General  widgetStyle "Breeze"
write_kde_cfg plasmarc   Theme    name        "vapor"
[ -d /usr/share/icons/steam-deck ] && \
    write_kde_cfg kdeglobals Icons Theme "steam-deck"
write_kde_cfg kcminputrc Mouse cursorTheme "Breeze_Light"
write_kde_cfg kcminputrc Mouse cursorSize  "24"
write_kde_cfg kwinrc "org.kde.kdecoration2" library "org.kde.breeze"
write_kde_cfg kwinrc "org.kde.kdecoration2" theme   "__aurorae__svg__Vapor"
[ -n "\$WALLPAPER_PATH" ] && write_kde_cfg \
    plasma-org.kde.plasma.desktop-appletsrc \
    "Containments][1][Wallpaper][org.kde.image][General" Image "\$WALLPAPER_PATH"
[ -f /usr/share/color-schemes/Vapor.colors ] && \
    cp /usr/share/color-schemes/Vapor.colors /home/liveuser/.local/share/color-schemes/
echo "  Plasma: Vapor"

echo "[customize] Enabling multilib..."
grep -q '^\[multilib\]' /etc/pacman.conf || \
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf

chown -R liveuser:liveuser /home/liveuser 2>/dev/null || true

# Run arch-deckify install.sh in the live environment as liveuser
# Since we've pre-installed all dependencies, most steps will be skipped
# This ensures Gaming Mode is fully configured on the live session
echo "[customize] Running arch-deckify install.sh for live session..."
if [[ -f /opt/arch-deckify/install.sh ]]; then
    # Run as liveuser since the script refuses to run as root
    sudo -u liveuser bash /opt/arch-deckify/install.sh || \
        echo "[customize] arch-deckify install completed (some steps may have been skipped)"
fi

echo "[customize] Done."
CEOF

chmod +x "$AIROOTFS/root/customize_airootfs.sh"
success "Written: customize_airootfs.sh (no mkinitcpio — safe for live ISO chroot)"

# ── STEP 8: Build the ISO ─────────────────────────────────────────────────────
step "Step 8/9 — Building ISO (this will take a while...)"
mkdir -p "$OUT_DIR"

if [[ -d "$WORK_DIR" ]]; then
    for mp in proc sys dev run; do
        sudo umount -l "$WORK_DIR/x86_64/airootfs/$mp" 2>/dev/null || true
    done
    sudo rm -rf "$WORK_DIR"
fi

info "Running mkarchiso..."
sudo mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

ISO_FILE=$(ls "$OUT_DIR"/${ISO_NAME}-*.iso 2>/dev/null | head -1)
[[ -z "$ISO_FILE" ]] && error "mkarchiso produced no ISO. Check output above."
success "ISO built: $ISO_FILE"

# ── STEP 9: Embed Limine BIOS support ────────────────────────────────────────
step "Step 9/9 — Embedding Limine BIOS boot support"
LIMINE_BIN=$(find /usr/share/limine /usr/lib/limine 2>/dev/null -name "limine" -type f | head -1)
if [[ -n "$LIMINE_BIN" ]]; then
    "$LIMINE_BIN" bios-install "$ISO_FILE" && success "Limine BIOS support embedded." \
        || warn "Limine bios-install failed — UEFI boot still works."
else
    warn "Limine binary not found — run manually: limine bios-install $ISO_FILE"
fi

# ── DONE ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  BUILD COMPLETE!${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ISO:   ${CYAN}$ISO_FILE${RESET}"
echo -e "  Size:  ${CYAN}$(du -sh "$ISO_FILE" | cut -f1)${RESET}"
echo ""
echo -e "${YELLOW}  Test in VirtualBox:${RESET}"
echo -e "  1. Create VM → Arch Linux 64-bit"
echo -e "  2. System → Motherboard → Enable EFI"
echo -e "  3. RAM 4GB+, Disk 40GB+"
echo -e "  4. Attach ISO and boot"
echo ""
echo -e "${YELLOW}  Test with QEMU (EFI):${RESET}"
echo -e "  ${CYAN}qemu-system-x86_64 -enable-kvm -m 4G -cpu host -smp 4 \\"
echo -e "    -bios /usr/share/ovmf/x64/OVMF.fd \\"
echo -e "    -cdrom \"$ISO_FILE\" -boot d${RESET}"
echo ""
echo -e "${YELLOW}  Flash to USB:${RESET}"
echo -e "  ${CYAN}sudo dd if=\"$ISO_FILE\" of=/dev/sdX bs=4M status=progress oflag=sync${RESET}"
echo ""
