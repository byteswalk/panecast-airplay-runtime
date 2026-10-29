# UxPlay 1.73.6 Windows 构建约定

Panecast 只使用上游 UxPlay 1.73.6 的 Windows UCRT64 构建，不使用来源不明的预编译程序。

## 与上游的差异

`patches/uxplay-1.73.6-windows-dnssd-runtime.patch` 只调整 Windows DNS-SD 接入：

- 编译时不再要求 Apple Bonjour SDK；
- 运行时仍按 UxPlay 原有方式动态加载 `dnssd.dll`；
- `dnssd.dll` 由本仓库 `dnssd-compat` crate 构建，使用 Rust mDNS（`mdns-sd`）发布
  `_raop._tcp` 与 `_airplay._tcp` 服务；
- 不安装系统服务，不写系统目录，不要求管理员权限。

协议协商、解密和 RTP 输出仍由未复制进主程序的 UxPlay 独立进程完成。

## 可复现环境

- MSYS2 UCRT64（`bootstrap-toolchain.sh` 固定到 2026-06-11 左右的环境）；
- UxPlay：1.73.6；
- GStreamer UCRT64：1.28.5-1；
- libplist UCRT64：2.7.0-4；
- Rust 工具链：构建本仓库的 `dnssd.dll`。

## 构建步骤

1. 安装 MSYS2 并运行：
   ```bash
   scripts/bootstrap-toolchain.sh
   ```
2. 准备 UxPlay 1.73.6 源码（例如克隆 `FDH2/UxPlay` 并检出 v1.73.6）到
   `work/source/FDH2-UxPlay-21eef8d`。
3. 构建并暂存运行时：
   ```powershell
   scripts/build-runtime.ps1
   ```
4. 生成物料清单与发行包：
   ```powershell
   scripts/package-release.ps1
   ```

构建脚本会验证工具链、补丁、UxPlay RTP 参数和 GStreamer 元件，不会自动安装或修改
系统级 Bonjour 服务。`package-release.ps1` 会用 `pacman -Qo` 把每个 DLL 映射到发行包，
复制对应许可证文本，并生成带 SHA256 的发行归档。
