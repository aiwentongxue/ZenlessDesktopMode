# ZenlessDesktopMode

ZenlessDesktopMode 在 PlayCover 中启用《绝区零》iOS 客户端自带的键鼠布局，支持键鼠与原生手柄热切换。当前适配国服 **3.3.1（构建 4）**，需要 Apple Silicon Mac 和带有用户插件功能的 PlayCover。插件以独立的 arm64 Mac Catalyst dylib 交付，源码按 MIT 授权。

已验证的操作包括 WASD 短按和组合键、苹果键盘的 Fn + F1–F4、鼠标转动镜头、滚轮平滑缩放，以及 DualSense 摇杆和十字键。按住左 `Option` 可以呼出游戏箭头并回中，松开后恢复镜头控制。打开地图等界面时，加载中的箭头仍跟随鼠标移动。

在街区按住 `Tab`，移动鼠标选方向，松开即可打开对应菜单。选择时指针隐藏，鼠标留在中心附近时，松开只关闭轮盘。

## 安装

1. 从 [最新 Release](https://github.com/aiwentongxue/ZenlessDesktopMode/releases/latest) 下载 `libZenlessDesktopMode.dylib`，然后退出游戏。
2. 在 PlayCover 的游戏设置中打开插件列表，备份并移除旧的 PC 模式插件或同名测试插件，再导入新版 dylib。
3. 关闭该游戏的 PlayCover 键盘映射，保持内置鼠标支持开启，再启动游戏。

启动时会沿用已保存的桌面布局。原设置为触屏时，已连接手柄就启动为手柄布局，其余情况启动为键鼠布局。手柄断开后会切回键鼠。要回退，退出游戏后移除本插件，再导入备份的 dylib。

## 输入与光标

按键、点击、滚动或明显移动鼠标时切到键鼠。按手柄按键或推动摇杆时切到手柄。「设置 → 输入 → UI 布局」同步显示当前布局，也可手动选择键鼠或已连接的手柄。

游戏内可分别调整镜头 X 轴和 Y 轴灵敏度，插件的镜头输入倍率也随 PlayCover 的灵敏度设置调整。键位可在「键鼠按键」中修改。苹果键盘的顶排设为系统功能键时，按住 `Fn` 或地球键可使用对应的游戏快捷键。[Apple 功能键说明](https://support.apple.com/en-la/102439)

Release 的 dylib 已内置游戏箭头。要替换箭头，将自己的 64×64 PNG 命名为 `cursor.png`，放到以下路径并重启游戏。插件依次使用有效的本机图片、构建时内置的图片和系统箭头。

```text
~/Library/Containers/com.miHoYo.Nap/Data/Library/Application Support/ZenlessDesktopMode/cursor.png
```

## 兼容性

插件当前适配 PlayCover 中的国服 iOS 客户端，应用标识为 `com.miHoYo.Nap`。游戏更新后需要核对客户端版本和 UnityFramework 的原生输入入口。

## 构建

需要 Apple Silicon Mac 和能构建 arm64 Mac Catalyst 动态库的 Xcode。本版使用 Xcode 27.2 构建。

```sh
./Scripts/test.sh
./Scripts/build.sh
```

默认输出 `.build/libZenlessDesktopMode.dylib`。构建脚本会对产物做 ad hoc 签名并校验。如需在单个 dylib 中内置箭头，构建时传入自己的 64×64 PNG。

```sh
ZZZDM_CURSOR_PNG="/path/to/cursor.png" ./Scripts/build.sh .build/with-cursor
```

## 输入诊断

在光标配置目录创建空文件 `diagnostics`，重启游戏，即可查看布局切换、光标回中、加载状态和轮盘选中项。测试完成后移走该文件并重启游戏。

```sh
log stream --style compact --predicate 'process == "ZenlessZoneZero" AND eventMessage CONTAINS "ZenlessDesktopMode"'
```

## 实现参考

`Sources/ZenlessInput.mm` 校验客户端构建与 UnityFramework UUID，负责原生输入、布局切换和快捷轮盘确认。`Sources/PlayCoverHost.mm` 处理 PlayCover 的窗口焦点、视口、光标和设备输入。`Sources/GameInput.hpp` 定义宿主与游戏适配层的接口。

视口、光标和快捷轮盘交互参考同类项目。游戏箭头的权利归对应权利人。[StarRailDesktopMode v0.1.2](https://github.com/aiwentongxue/StarRailDesktopMode/releases/tag/v0.1.2) · [GenshinDesktopMode](https://github.com/cnSniperMike/GenshinDesktopMode) · [Unity Input System](https://docs.unity3d.com/Packages/com.unity.inputsystem@1.11/manual/Events.html)
