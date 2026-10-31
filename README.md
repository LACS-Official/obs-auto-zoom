<p align="center">
  <img src="logo.svg" width="460" alt="obs-auto-zoom logo"/>
</p>

# obs-auto-zoom

[简体中文](#obs-auto-zoom) | [English](#english)

---

## 简体中文

适用于 OBS Studio 的鼠标跟随缩放脚本。在录制教程、演示操作或教学直播时，可通过快捷键平滑放大画面并聚焦到光标所在区域。

### 功能特性

- **平滑鼠标跟随**：基于阻尼弹簧算法实现平滑移动与缓冲，也可将弹性强度设为 0 使用常规平滑跟随。
- **按键与鼠标操作可视化 (Keystroke OSD)**：在画面上实时显示键盘按键组合（如 `Ctrl + C`）及鼠标点击状态，支持自定义显示位置、像素偏移与停留时长。
- **空闲自动复原**：光标静止达到设定时长后，镜头自动平滑拉远回 1x 全屏。
- **快捷键动态变焦与锁定**：支持通过快捷键步进放大/缩小画面（步长可调），或一键锁定镜头当前视口焦点。
- **配置导入导出与 WebDAV 同步**：支持将所有参数及快捷键导出为本地 JSON 文件，支持通过 WebDAV 协议（坚果云、Nextcloud、群晖 NAS、ALiST 等）一键上传至 `obsautozoom` 目录备份与跨设备恢复。
- **跨平台兼容**：基于 Lua FFI 实现，原生适配 Windows、Linux 及 macOS 系统光标坐标捕获。

### 安装与使用

1. **下载脚本**：下载本仓库的 `obs-auto-zoom.lua` 文件。
2. **加载脚本**：打开 OBS Studio，点击顶部菜单栏 **工具 -> 脚本**，在弹出窗口点击左下角 **`+`** 导入 `obs-auto-zoom.lua`。
3. **选择缩放源**：在右侧属性面板的 **缩放源 (Zoom Source)** 下拉框中，选择要缩放的显示器采集源。
4. **配置快捷键**：进入 OBS **设置 -> 快捷键**，搜索 `obs-auto-zoom`，配置所需快捷键（例如将“切换缩放至鼠标”绑定为 `Alt + Z`）。

### 快捷键说明

在 OBS 的 **设置 -> 快捷键** 中搜索 `[obs-auto-zoom]` 即可配置以下动作：

| 快捷键名称 | 推荐绑定键 | 功能说明 |
| :--- | :--- | :--- |
| **[obs-auto-zoom] 切换缩放至鼠标** | `Alt + Z` | 开启或关闭画面放大跟随 |
| **[obs-auto-zoom] 切换镜头焦点锁定** | `Alt + L` | 锁定当前视口，鼠标移动时不跟随镜头 |
| **[obs-auto-zoom] 增大缩放倍数** | `Alt + =` | 增大当前放大倍率（按变焦步长递增） |
| **[obs-auto-zoom] 减小缩放倍数** | `Alt + -` | 减小当前放大倍率（按变焦步长递减） |
| **[obs-auto-zoom] 在缩放时切换跟随鼠标** | `Alt + F` | 临时切换是否跟随鼠标光标移动 |

### 核心参数说明

| 参数项 | 说明 | 默认值 |
| :--- | :--- | :--- |
| **缩放倍数 (Zoom Factor)** | 画面放大的目标倍率（1.0 ~ 5.0） | `2.0` |
| **缩放速度 (Zoom Speed)** | 镜头放大与缩小的过渡速度 | `0.06` |
| **缩放动画类型 (Easing)** | 缩放过渡曲线（平滑缓动、线性匀速、减速停靠、电影回弹、瞬间等） | `平滑缓动` |
| **跟随速度 (Follow Speed)** | 镜头跟随光标平移的速度 | `0.25` |
| **跟随弹性强度 (Spring Strength)** | 物理阻尼跟随的弹性硬度，设为 0 关闭弹性 | `0.0` |
| **跟随阻尼比 (Damping Ratio)** | 物理阻尼比，建议范围 `0.5 ~ 0.7` | `0.6` |
| **空闲自动复原 1x** | 鼠标静止达到设定秒数后自动拉远回 1x 全屏 | `关闭 (3.0s)` |
| **按键与鼠标可视化** | 实时显示快捷键与鼠标点击，支持居中/边角/跟随光标 | `关闭` |
| **WebDAV 云端备份** | 支持将当前脚本配置备份到 WebDAV 目录 `obsautozoom` | - |

---

## English

A mouse-following zoom script for OBS Studio. Designed for software tutorials, presentations, and livestreaming where smooth camera focus on cursor interactions is needed.

### Features

- **Smooth Mouse Tracking**: Uses a spring-damper physics model for natural movement and deceleration. Setting spring strength to 0 falls back to standard smoothing.
- **Keystroke & Mouse OSD**: Displays keyboard shortcuts and mouse clicks in real time with configurable position presets, pixel offsets, and display durations.
- **Auto-Reset on Idle**: Smoothly zooms back to 1x full-screen when the mouse cursor remains stationary for a configurable duration.
- **Step Zooming & Focus Lock**: Supports dynamic zoom adjustment via hotkeys (configurable step size) and viewport lock to keep the camera stationary.
- **Config Backup & WebDAV Sync**: Export/import settings to local JSON, or sync backups with WebDAV servers (Nextcloud, Synology NAS, ALiST, Jianguoyun, etc.) into the `obsautozoom` folder.
- **Cross-Platform**: Uses Lua FFI for native cursor tracking across Windows, Linux, and macOS.

### Installation & Quick Start

1. **Download**: Download `obs-auto-zoom.lua` from this repository.
2. **Load into OBS**: In OBS Studio, open **Tools -> Scripts**, click the **`+`** button, and select `obs-auto-zoom.lua`.
3. **Select Source**: Under the script properties panel, choose your Display Capture source from the **Zoom Source** dropdown.
4. **Set Hotkeys**: Navigate to **Settings -> Hotkeys**, filter by `obs-auto-zoom`, and assign your preferred keybindings (e.g., `Alt + Z` for Toggle Zoom).

### Hotkey Reference

Filter by `[obs-auto-zoom]` in OBS **Settings -> Hotkeys**:

| Hotkey Name | Suggested Key | Description |
| :--- | :--- | :--- |
| **[obs-auto-zoom] Toggle Zoom To Mouse** | `Alt + Z` | Enables or disables zoom mode |
| **[obs-auto-zoom] Toggle Lock Focus** | `Alt + L` | Locks the current camera viewport in place |
| **[obs-auto-zoom] Increase Zoom Factor** | `Alt + =` | Increments zoom magnification by step size |
| **[obs-auto-zoom] Decrease Zoom Factor** | `Alt + -` | Decrements zoom magnification by step size |
| **[obs-auto-zoom] Toggle Mouse Follow** | `Alt + F` | Toggles cursor tracking while zoomed |

### Key Settings

| Setting | Description | Default |
| :--- | :--- | :--- |
| **Zoom Factor** | Target magnification ratio (1.0 to 5.0) | `2.0` |
| **Zoom Speed** | Transition speed when zooming in and out | `0.06` |
| **Zoom Easing Curve** | Transition curve (Ease-In-Out, Linear, Overshoot, Instant, etc.) | `Ease-In-Out` |
| **Follow Speed** | Pan tracking speed when following mouse cursor | `0.25` |
| **Spring Strength** | Spring physics hardness for tracking; set to 0 for standard smoothing | `0.0` |
| **Damping Ratio** | Physical damping ratio (recommended: 0.5 to 0.7) | `0.6` |
| **Auto-Reset on Idle** | Reverts zoom to 1x after cursor stays idle for specified seconds | `Disabled (3.0s)` |
| **Keystroke Visualizer** | Displays keystrokes & mouse clicks with customizable positions | `Disabled` |
| **WebDAV Cloud Backup** | Uploads/downloads settings to/from WebDAV folder `obsautozoom` | - |

---

## 许可证 / License

本项目基于 [MIT License](LICENSE) 开源许可。欢迎提交 Issue 与 Pull Request。 / This project is licensed under the [MIT License](LICENSE). Contributions and issues are welcome.
