# Cleaner

**Cleaner** 是 iOS 26 / 27 的中文清理工具：缓存清理为主，界面更简洁、更好看。

v2（0.2.0）是我们自己的重构，不再是 WQFiles 的翻译版：只保留有用的 worse_query 沙盒技术和安全机制，文件浏览器、plist 编辑器、十六进制查看器、分享/ZIP、Go to Path、系统分组浏览全部删掉。纯 Objective-C + UIKit，无 Swift、无第三方库、无 WebView。

- 支持：iOS 26.0–26.7.2、iOS 27.0–27.2（worse_query 的已知范围；27.2.1 / 26.7.3 是否修掉它，官方没说）
- 免越狱，无内核漏洞
- 需要：能保留 App Group 权限的侧载工具（AltStore / SideStore 最省事）
- 体积目标：二进制 <500KB、IPA <250KB（`-Os -flto -dead_strip` + strip，arm64 only，iPhone only）

## 四个页

- **首页**：只看状态，不做清理。按 KernelSU v3.2.5（Miuix 风格）首页 1:1 复刻，只改文案：浅灰底、右上角电源图标（菜单：重新扫描）、超大粗标题、左侧浅绿状态卡（已授权 / App Group / 沙盒模式 / 版本，右下角超大绿色对勾圆圈）、右侧两张白小卡（应用数 / 可清理总量）、一张白色信息大卡。点状态卡进清理页。未授权或系统不支持时状态卡变红并显示警告。
- **清理**：按原版 WQFiles Cache Cleaner 1:1 复刻，只改中文：顶部汇总卡（可清理总量、已选占比、状态行）、搜索、下拉刷新、按大小降序、每行真实应用图标 + 缓存/临时大小、最后一行崩溃日志（仅 iOS 27）、右上角清理按钮（显示已选大小「清理（xx MB）」）+ 选择菜单（全选 / 全不选 / 只选大缓存 50MB+）、确认弹窗（无法撤销，不保留备份）、清理进度与停止。
- **应用**：应用列表 + 大小，点一行可备份数据、恢复备份、清空数据。清空前先问要不要备份；恢复按最新备份走，有 journal，出错可回滚。
- **设置**：关于、来源与协议、日志（只读，无分享）。

图标全部 SF Symbols（单色，默认黑色，选中/强调才用系统蓝 #007AFF），不许用 emoji。应用标志是暖米色底 #F5F1E8 上的黑色粗线垃圾桶（图标风格参考 huamidev/GestaltX）。

## 缓存清理怎么用

1. 打开「清理」，等扫描完成（首次慢，之后只查新增文件）
2. 列表按大小从大到小排，每行显示应用名、图标、缓存大小、临时文件大小
3. 点一行可选中 / 取消；顶部菜单可全选、全不选、只选大缓存
4. 点右上角「清理（xx MB）」，确认后开始清理
5. 清理会删选中应用的 `Library/Caches` 和 `tmp`，以及选中的崩溃日志
6. **不保留备份**，请先关闭要清理的应用；部分离线内容（音乐、地图、下载）清掉后会重新下载

## 应用管理

- 每个应用显示数据大小
- 备份 Documents + Library、恢复备份、清空数据（先备份再清空，或直接清空）
- `tmp` 不进备份，清了找不回；操作前请先关掉目标应用
- 备份存在 `Cleaner/AppBackups`（Files App 里也能看到）

## 安全

- 覆盖 / 删除普通文件前，先复制到应用内的「备份」（Files App 里也能看到），长按备份可恢复
- 清缓存、清数据不逐文件备份，一定要弹窗确认
- 改别的 App / 系统文件可能搞坏东西，只改你懂的

## 安装（AltStore / SideStore）

添加这个源：

```
https://raw.githubusercontent.com/Mahiru0311/Cleaner/main/source.json
```

或直接在 Releases 里下载 `Cleaner.ipa` 自己签名。

## 签名：App Group

Cleaner 需要 **App Group** 才能工作：worse_query 通过你应用的群组容器请求访问。签名工具必须给它一个 App Group，群组名不重要，应用会用实际拿到的那个，顶部日志会显示它，没拿到会显示 "No App Group"。

- **AltStore、SideStore、Sideloadly（用 Apple ID）**：会自动创建 App Group，最省事
- **Feather、ESign 等用证书（.p12）+ 描述文件**：描述文件里必须含 App Group；通配符 App ID（`*`）装不下 App Group，会报权限错误
- **自己的开发者账号**：开发者后台建 App Group → 建带 App Groups 能力的显式 App ID → 建描述文件 → 签名时保留 App Group 权限

## 构建

```bash
./build.sh
```

在 macOS + Xcode 上编译 arm64，ad-hoc 签名（带 App Group 权限），生成 `Cleaner.ipa`。
构建前会先跑回归测试（`./tests/run_all_tests.sh`）。

也可以用 GitHub Actions 构建：推到 `main` 或 `refactor/v2`、或手动触发，macOS runner 上跑 `./build.sh`，产物 `Cleaner.ipa` 会作为 artifact 上传，见 `.github/workflows/build.yml`。

## 来源与协议

- 沙盒技术：[worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit)
- 容器枚举 `fsgetpath`：来自 [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus
- 缓存清理界面：[WQFiles](https://github.com/kolbicz/WQFiles) by kolbicz，v0.7
- 首页界面：[KernelSU Manager](https://github.com/tiann/KernelSU) by tiann（v3.2.5 Miuix 风格）
- 图标风格参考：[GestaltX](https://github.com/huamidev/GestaltX) by huamidev（GPL-3.0）

Cleaner 是 GPL-3.0-or-later（见 `LICENSE`）。
