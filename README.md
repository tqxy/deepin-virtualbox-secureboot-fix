# Deepin 25 下修复 VirtualBox 内核模块无法加载（rc=-1908）

在 Deepin 25（磐石不可变系统 + Secure Boot）环境下，VirtualBox 启动虚拟机时报错
`Kernel driver not installed (rc=-1908)` 的完整排查过程与一键修复脚本。

## 问题现象

打开 VirtualBox 启动虚拟机时弹出错误：

```
Kernel driver not installed (rc=-1908)

The VirtualBox Linux kernel driver is either not loaded or not set up correctly.
Please try setting it up again by executing '/sbin/vboxconfig' as root.

If your system has EFI Secure Boot enabled you may also need to sign the
kernel modules (vboxdrv, vboxnetflt, vboxnetadp, vboxpci) before you can load them.

where: suplibOsInit what: 3 VERR_VM_DRIVER_NOT_INSTALLED (-1908)
```

## 环境

- 系统：Deepin 25（crimson，磐石不可变系统）
- 内核：6.18.38-amd64-desktop-rolling
- VirtualBox：7.2.18（软件包名 `org.virtualbox.virtualbox`）
- Secure Boot：**已开启**

## 原因分析

这个报错涉及两层原因，缺一不可：

**1. Secure Boot 拒绝加载未签名的内核模块**

开启 Secure Boot 后，内核只允许加载带有可信签名的模块。
VirtualBox 的三个宿主驱动 `vboxdrv` / `vboxnetflt` / `vboxnetadp` 是安装时本地编译的，
没有签名，因此被内核拒绝加载，`/dev/vboxdrv` 不存在，VirtualBox 报 -1908。

**2. Deepin 25 磐石系统 /usr 只读，无法直接签名**

Deepin 25 使用 ostree + overlayfs 的不可变根设计，`/usr` 以只读 overlay 挂载
（`/lib` 是指向 `/usr/lib` 的软链）。这意味着：

- 即使拿到了签名工具，也无法直接在 `/lib/modules/.../misc/` 下写回签名后的模块；
- `mount -o remount,rw /usr` 也会失败（mount point not mounted or bad option）；
- 官方提供的 `deepin-immutable-ctl admin file-op` 在当前版本不支持 cp/copy 动作。

## 排查过程记录

```bash
# 1. 确认 Secure Boot 状态
mokutil --sb-state          # 输出: SecureBoot enabled

# 2. 确认模块已编译但未加载
find /lib/modules/$(uname -r) -name "vbox*"   # 模块文件存在
lsmod | grep vbox                              # 无输出，未加载

# 3. 检查模块签名
modinfo /lib/modules/$(uname -r)/misc/vboxdrv.ko | grep sig_key
# 无输出 → 未签名

# 4. 检查 DKMS 的 MOK 密钥是否已注册
mokutil --test-key /var/lib/dkms/mok.pub
# 输出: is not enrolled → 密钥存在但未注册进主板

# 5. 确认 /usr 为只读 overlay（磐石不可变系统）
findmnt /usr
# FSTYPE=overlay, OPTIONS=ro
```

## 修复原理

1. **签名**：系统里已有 DKMS 自动生成的 MOK 密钥对
   （`/var/lib/dkms/mok.key` 私钥 + `/var/lib/dkms/mok.pub` 证书），
   用内核头文件自带的 `scripts/sign-file` 工具给三个模块加上签名；
2. **绕过只读 /usr**：不直接改系统目录，而是把签名后的模块写入 overlay 的
   **upperdir**（`/root/persistent/overlay/data/layer-*/usr/lib/modules/...`），
   重启后 overlay 会用上层文件遮盖下层未签名的旧模块；
3. **注册 MOK 密钥**：用 `mokutil --import` 把 DKMS 公钥加入主板 MOK 列表，
   重启时在蓝色 MOK Manager 界面确认注册，之后内核就信任该密钥签名的模块。

> 为什么不直接用 `sudo /sbin/vboxconfig`？
> 它能重新编译模块，但在只读 /usr 下写不进去，且编译出来的模块依然没签名，
> Secure Boot 下依旧无法加载。

## 使用方法

```bash
sudo bash fix_vbox_secureboot.sh
```

脚本会自动完成：

1. 用 DKMS MOK 密钥签名 `vboxdrv` / `vboxnetflt` / `vboxnetadp`；
2. 把签名后的模块写入 overlay upperdir；
3. 将 DKMS MOK 公钥加入待注册队列（一次性密码默认为 `12345678`，
   可在脚本开头 `MOK_PASSWORD` 变量中修改）。

然后**重启电脑**：

1. 开机进入蓝色 MOK Manager 界面；
2. 依次选择 `Enroll MOK` → `Continue` → `Yes`；
3. 输入一次性密码 `12345678`（输入时屏幕无回显，属正常）；
4. 选择 `Reboot`。

进入系统后 VirtualBox 即可正常启动虚拟机。

## 注意事项

- 脚本需要 root 权限运行；
- upperdir 路径因机器而异，脚本会自动从 `findmnt /usr` 的输出中解析，无需手改；
- 如果重启时没有弹出蓝色 MOK Manager 界面（个别固件会跳过），
  说明密钥未注册成功，需要重新执行脚本第 3 步（mokutil --import）再重启；
- 若以后更换了 DKMS 密钥或内核大版本升级导致模块重编译，可能需要重新签名；
- 本方案理论上同样适用于其他开启 Secure Boot 的 Debian/Ubuntu 系发行版
  （非不可变系统可省略写 upperdir 步骤，直接原地签名后 `depmod -a`）。
