# 设置首页去除 Apple ID 建议

一个注入「设置」（`com.apple.Preferences`）的 tweak：把首页上的「Apple ID 建议」这一行
整行隐藏，或者按条目逐个隐藏。附带一个设置面板，自动列出当前出现过的每一条建议。

## 关键事实（改代码前先读）

- 首页那一行是一个 **FollowUpList_** specifier，id 形如
  `FollowUpList_com.apple.followup.group.account`（有时带 `.0` 之类后缀，所以用前缀匹配）。
  它的 `followUpItems` 属性里放着系统当前投递到 `com.apple.followup.group.account` 组的所有
  `FLFollowUpItem`，单元格角标就是条目数。**没有任何写死的清单**，内容完全由运行时决定，
  所以只能运行时枚举，不能靠一份固定的行名列表。
- 首页控制器是 `PSUIPrefsListController`（在 `PreferencesUI.framework` 里，可能比本 tweak
  晚加载），它**重写**了 `-reloadSpecifiers`，所以挂 `PSListController` 的父类钩子等不到它。
  另外它的类名里**没有 "Root"**，别用 `containsString:@"Root"` 去认它。
- 列表是**异步装配**的：`viewWillAppear:` 时只有几十条，稍后才补齐到两百多条，
  那时 `FollowUpList_` 才出现。所以过滤要做多遍（0.05/0.2/0.5/1.0/2.5 秒各一次，另加 2 秒定时器兜底）。
- 那一行是**成批插入**的：走 `-[PSListController insertContiguousSpecifiers:atIndex:]`
  （以及私有的 `_insertContiguousSpecifiers:atIndex:animated:`），**不走** `insertSpecifier:atIndex:animated:`。
  只钩后者的话，行会先被插进表里画出来、等下一遍过滤才删掉，用户就会看到约半秒的闪现。
  两个成批插入的钩子必须在装配时就把它从数组里剔掉，这样它从来不进表。
- 条目用「稳定 kind」做开关的 key：`clientIdentifier` + `.` + `typeIdentifier`
  （`typeIdentifier` 为空时退回 `clientIdentifier`；都没有时用去掉 UUID 段的 UID）。
  **不要用 UID 做 key**，它随账号/重投递变化。
- 原始条目存在 specifier 的 `apelinOriginalItems` 属性里，每次过滤都从它重算，
  这样把开关关掉时能把条目还原回来（否则只能重启「设置」）。
- 整行被删掉后无法从数组里恢复，只能让「设置」自己 `reloadSpecifiers` 重建；
  这一步只在收到设置变更通知时做，定时器不做（否则会无限重建）。

## 文件

- `Sources/Tweak.m` — 全部逻辑：过滤、钩子、通知、落盘。
- `Sources/Prefs/APSNoSuggestionsRootListController.m` — 设置面板，读 `items.plist` 动态生成逐条开关。
- `Resources/Bundle/{Root,Info,Entry}.plist` — 面板的 specifier、bundle id、PreferenceLoader 入口。
- `Resources/APSNoSuggestions.plist` — tweak 的 filter（只注入 `com.apple.Preferences`）。
- `apelin/build.sh` — 构建脚本（见下）。
- `apelin-project.json` — Apelin 的项目描述，`buildSystem: external`，`projectID`/`kind` 不要改。

## 构建

```
apelin_project_build
```

走 `apelin/build.sh`：clang 编译 dylib（`-dynamiclib`）和面板（`-bundle`），`ldid -S` 签名，
把 `@PACKAGE_ID@` / `@VERSION@` 塞进 plist，最后 `dpkg-deb -b` 出包。不要在别处自己打 deb。

- **架构**：两种引导都编 `arm64` + `arm64e`，用 `lipo` 合成通用二进制（A11 及更早的设备
  与 arm64e 设备共用同一个 dylib）。包里的 `Architecture` 仍取 `$APELIN_ARCHITECTURE`
  （roothide → `iphoneos-arm64e`，rootless → `iphoneos-arm64`）。
- **包内路径**：从 `$APELIN_PREFIX` 起（rootless 是 `/var/jb`，roothide 为空）。
- **头文件**：开发支持组件在引导自己的 root 里，脚本在 `/rootfs` 下先找出
  `usr/share/apelin/development`，去掉 `/rootfs` 前缀交给 clang；编 rootless 包时也用这一份。
- **交付**：`apelin_project_build` 分别带 `configuration: release` 和 `bootstrap: roothide` /
  `rootless` 各编一次，两个包一起发布；改内容时升 `control` 里的 `Version`。

`-DAPSN_DEBUG_DUMP=1` 打开时才会写 `/var/mobile/Library/APSNoSuggestions/{state.txt,specs.txt}`
这类诊断文件；正式版不带这个宏，只有 `os_log`。

## 测试

安装后用 `icli` 重启「设置」并看状态文件（需先带调试宏构建）：

```
icli app kill --force com.apple.Preferences; icli app launch com.apple.Preferences
cat <jbroot>/var/mobile/Library/APSNoSuggestions/state.txt
```

改开关用 `icli prefs write <包 id> hideGroup true --type bool`，再
`icli notify post <包 id>/changed` 让它即时刷新。
注意：「设置」在后台会被挂起，通知要等它回到前台才处理，所以实时验证时它必须在前台。

判断是否生效看这几行：`row badge=N items=...`、`hid N of M items`、
`removed follow-up row (...)`。

## 注意

- 屏幕工具读不到「设置」的界面：切到前台后 Apelin 会重新成为前台应用，
  `apelin_screen_read_tree` 会报 not verified。要截屏只能在**同一条 shell 命令**里
  先 `icli app launch`、再 `icli screen shot --output <项目绝对路径>`。
- 路径一律用 `APSNBootstrapPath()` / `dladdr` 在运行时求，绝不写死 `.jbroot-*`。
