#!/usr/bin/env bash
set -euo pipefail

# ====================== НАСТРОЙКИ ======================
TIMEZONE="Europe/Helsinki"
HOSTNAME="gentoo-box"
ROOT_PASSWORD="gentoo123"       # сразу после первой загрузки ОБЯЗАТЕЛЬНО поменяй!
# ======================================================

echo "=== Gentoo FULL AUTO + XFCE (OpenRC, 2026) — ПОСЛЕДНЯЯ ВЕРСИЯ, СУКА ==="

# 1. Авто-детект диска + NVMe/SATA
echo "→ Авто-сканирование дисков..."
TARGET_DISK=$(lsblk -d -n -o NAME,SIZE,RM,TRAN | \
    awk '$3 == "0" && $2 ~ /[0-9]+G$/ {gsub("G","",$2); print "/dev/"$1 " " $2}' | \
    sort -k2 -nr | head -1 | awk '{print $1}')

if [[ -z "$TARGET_DISK" ]]; then
    echo "❌ Не нашла диск, мелкий. Запусти lsblk сам."
    exit 1
fi

if [[ $TARGET_DISK == *nvme* ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

DISK_SIZE=$(lsblk -d -o SIZE "$TARGET_DISK" | tail -1)
echo "Целевой диск: $TARGET_DISK ($DISK_SIZE) — ВСЁ СТЕРЁМ НАХУЙ"
read -p "Продолжить? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
read -p "ЕЩЁ РАЗ ПОДТВЕРДИ, СУКА (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi

# 2. Подготовка live
echo "→ Сеть, зеркала, Wi-Fi дрова..."
dhcpcd -w || true
emerge --sync --quiet || true
emerge -q app-portage/mirrorselect linux-firmware net-wireless/iwd net-wireless/wireless-tools
mirrorselect -a -o >> /etc/portage/make.conf

# 3. GPU
echo "→ Сканирую видюху..."
GPU=$(lspci | grep -E 'VGA|3D|Display' | head -1)
if echo "$GPU" | grep -qi nvidia; then VIDEO_CARDS="nvidia"
elif echo "$GPU" | grep -qiE 'amd|radeon'; then VIDEO_CARDS="amdgpu radeonsi"
elif echo "$GPU" | grep -qi intel; then VIDEO_CARDS="intel i915"
else VIDEO_CARDS="nouveau"; fi
echo "→ Видюха: $VIDEO_CARDS"

# 4. Разметка + race fix
echo "→ Размечаю $TARGET_DISK..."
wipefs -af "$TARGET_DISK"
sgdisk -Z "$TARGET_DISK"
sgdisk -n 1:0:+512M -t 1:EF00 "$TARGET_DISK"
sgdisk -n 2:0:0 -t 2:8300 "$TARGET_DISK"
partprobe "$TARGET_DISK"
udevadm settle && sleep 2

mkfs.fat -F32 "$EFI_PART" -n EFI
mkfs.ext4 -F "$ROOT_PART" -L root

mount "$ROOT_PART" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "$EFI_PART" /mnt/gentoo/boot/efi

# 5. Stage3
echo "→ Качаю свежий stage3 OpenRC..."
STAGE_URL=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | tail -1 | awk '{print "https://distfiles.gentoo.org/releases/amd64/autobuilds/"$1}')
cd /mnt/gentoo
wget -q --show-progress "$STAGE_URL"
tar xpf stage3-*.tar.xz --xattrs --numeric-owner
rm stage3-*.tar.xz

# 6. Chroot prep
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mkdir -p /mnt/gentoo/etc/portage
cp /etc/portage/make.conf /mnt/gentoo/etc/portage/make.conf
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# 7. УСТАНОВКА ВНУТРИ CHROOT
cat << EOF | chroot /mnt/gentoo /bin/bash
set -euo pipefail

echo "→ Внутри chroot: sync + OpenRC + XFCE"
emerge --sync -q
eselect profile set default/linux/amd64/23.0

cat >> /etc/portage/make.conf << INNER
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j\$(nproc) -l\$(nproc)"
EMERGE_DEFAULT_OPTS="--jobs=\$(nproc) --load-average=\$(nproc)"
VIDEO_CARDS="$VIDEO_CARDS"
ACCEPT_LICENSE="*"
USE="X gtk dbus -gnome -kde -qt -pulseaudio"
INNER

# Locale
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
echo "$TIMEZONE" > /etc/timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

# Ядро + firmware
emerge -q sys-kernel/linux-firmware sys-kernel/gentoo-sources sys-kernel/genkernel sys-apps/util-linux
genkernel --no-mount-boot all

# СЕТЬ + GRUB + XFCE
emerge -q net-misc/dhcpcd net-wireless/iwd net-wireless/wireless-tools sys-boot/grub:2 xfce-base/xfce4-meta x11-base/xorg-server x11-misc/lightdm

# GRUB EFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# LightDM автологин root
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm.conf << LIGHTDM
[Seat:*]
autologin-user=root
autologin-user-timeout=0
LIGHTDM

rc-update add lightdm default
rc-update add dhcpcd default
rc-update add iwd default

emerge -q app-admin/sudo net-misc/ntp
echo "root:$ROOT_PASSWORD" | chpasswd
echo "$HOSTNAME" > /etc/hostname

# fstab
ROOT_UUID=\$(blkid -s UUID -o value "$ROOT_PART")
EFI_UUID=\$(blkid -s UUID -o value "$EFI_PART")
cat > /etc/fstab << FSTAB
UUID=\$ROOT_UUID / ext4 defaults 0 1
UUID=\$EFI_UUID /boot/efi vfat defaults 0 2
FSTAB

echo "=== УСТАНОВКА ЗАВЕРШЕНА ==="
EOF

# 8. Финал
umount -l /mnt/gentoo/dev /mnt/gentoo/run /mnt/gentoo/sys /mnt/gentoo/proc /mnt/gentoo/boot/efi /mnt/gentoo
echo "✅ ВСЁ, СУКА! Теперь даже ты не найдёшь повод ныть."
echo "Сейчас автоматически перезагружусь в XFCE..."
sleep 3
reboot
