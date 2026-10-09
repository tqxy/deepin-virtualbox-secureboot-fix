#!/bin/bash
#
# fix_vbox_secureboot.sh
# 修复 Deepin 25（Secure Boot + 磐石不可变系统）下 VirtualBox 内核模块
# 无法加载的问题（rc=-1908）。
#
# 原理：
#   1. 用 DKMS 的 MOK 密钥给 vboxdrv/vboxnetflt/vboxnetadp 签名
#   2. 签名后的模块写入 /usr overlay 的 upperdir（重启后生效）
#   3. mokutil --import 注册公钥，重启时在 MOK Manager 中确认
#
# 用法：sudo bash fix_vbox_secureboot.sh
#
set -e

# MOK 注册时的一次性密码（重启后 Enroll MOK 时需要输入）
MOK_PASSWORD="12345678"

KVER=$(uname -r)
SIGNFILE="/usr/src/linux-headers-$KVER/scripts/sign-file"
MOK_KEY="/var/lib/dkms/mok.key"
MOK_PUB="/var/lib/dkms/mok.pub"
MODDIR="/usr/lib/modules/$KVER/misc"
MODULES="vboxdrv vboxnetflt vboxnetadp"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

echo "==> 内核版本: $KVER"

# --- 前置检查 ---
[ -f "$SIGNFILE" ] || { echo "!! 未找到 sign-file，请先安装 linux-headers-$KVER"; exit 1; }
[ -f "$MOK_KEY" ] && [ -f "$MOK_PUB" ] || { echo "!! 未找到 DKMS MOK 密钥"; exit 1; }

for m in $MODULES; do
    [ -f "$MODDIR/$m.ko" ] || { echo "!! 未找到 $MODDIR/$m.ko"; exit 1; }
done

# --- 1. 在临时目录签名 ---
for m in $MODULES; do
    echo "==> 签名 $m.ko"
    cp "$MODDIR/$m.ko" "$TMPD/$m.ko"
    "$SIGNFILE" sha256 "$MOK_KEY" "$MOK_PUB" "$TMPD/$m.ko"
    modinfo "$TMPD/$m.ko" | grep -q "^sig_key" || { echo "[FAIL] $m 签名失败"; exit 1; }
    echo "[OK] $m 已签名"
done

# --- 2. 写入 overlay upperdir（不可变系统；普通系统可直接原地签名 + depmod） ---
echo
echo "==> 解析 /usr overlay upperdir"
UPPER_USR=$(findmnt -n -o OPTIONS /usr | tr ',' '\n' | grep '^upperdir=' | cut -d= -f2)
[ -n "$UPPER_USR" ] || { echo "!! 未能解析 upperdir，/usr 可能不是 overlay"; exit 1; }
UPPER_MODDIR="$UPPER_USR/lib/modules/$KVER/misc"
echo "    upperdir: $UPPER_MODDIR"

mkdir -p "$UPPER_MODDIR"
for m in $MODULES; do
    install -m 644 "$TMPD/$m.ko" "$UPPER_MODDIR/$m.ko"
    modinfo "$UPPER_MODDIR/$m.ko" | grep -q "^sig_key" && echo "[OK] upperdir 中 $m 已就位"
done

# --- 3. 注册 MOK 公钥 ---
echo
echo "==> 导入 MOK 公钥（一次性密码: $MOK_PASSWORD）"
printf "%s\n%s\n" "$MOK_PASSWORD" "$MOK_PASSWORD" | mokutil --import "$MOK_PUB"

echo
echo "==> 待注册密钥:"
mokutil --list-new || true

cat <<EOF

===================================================
 完成！请重启电脑，并在开机蓝色 MOK Manager 界面：
   1. 选择 Enroll MOK -> Continue -> Yes
   2. 输入一次性密码: $MOK_PASSWORD
   3. 选择 Reboot
 重启后 VirtualBox 即可正常使用。
===================================================
EOF
