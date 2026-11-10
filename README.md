# Cleaner

**Cleaner** 是 iOS 26 / 27 的中文清理工具：缓存清理为主，界面更简洁、更好看。

基于 [kolbicz/WQFiles](https://github.com/kolbicz/WQFiles) v0.7（GPL-3.0-or-later），保留它的沙盒技术和安全机制，只做中文界面和清理体验改进。

- 支持：iOS 26.0–26.7.2、iOS 27，已在原版上测试过 26.7.1 / 27.0.1 / 27.2
- 免越狱，无内核漏洞
- 需要：能保留 App Group 权限的侧载工具（AltStore / SideStore 最省事）

## 0.1.0 改了什么

- **首页就是清理入口**：工具栏第一位就是「缓存清理」，其次才是「应用」
- **缓存清理中文版**：标题、搜索、全选 / 全不选 / 只选大缓存（50 MB+）、状态、确认弹窗，全部中文
- **清理按钮会显示大小**：选中多少，就显示「清理（xx MB）」，不用先算
- **顶部汇总卡片**：可清理总量、已选大小、进度条，一眼看清
- **其余界面中文**：应用数据、应用分组、扩展数据、系统守护进程、系统数据、系统分组、应用备份、文件备份、日志
- **核心没动**：worse_query 沙盒访问、`fsgetpath` 容器枚举、缓存安全校验、备份机制，全部保留原版逻辑

## 缓存清理怎么用

1. 打开「缓存清理」，等扫描完成（首次慢，之后只查新增文件）
2. 列表按大小从大到小排，每行显示应用名、图标、缓存大小、临时文件大小
3. 点一行可选中 / 取消；顶部菜单可全选、全不选、只选大缓存
4. 点右上角「清理（xx MB）」，确认后开始清理
5. 清理会删选中应用的 `Library/Caches` 和 `tmp`，以及选中的崩溃日志
6. **不保留备份**，请先关闭要清理的应用；部分离线内容（音乐、地图、下载）清掉后会重新下载

长按某一行，可以跳到它的 Caches / tmp / 数据文件夹。

## 应用管理

- 每个应用显示数据大小
- 备份 Documents + Library、恢复最新备份、清空数据、打开文件夹、分享备份为 ZIP
- 清空时会问：先备份再清空，还是直接清空（不备份）
- `tmp` 不进备份，清了找不回；操作前请先关掉目标应用

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

也可以用 GitHub Actions 构建：推到 `main` 或手动触发，macOS runner 上跑 `./build.sh`，产物 `Cleaner.ipa` 会作为 artifact 上传，见 `.github/workflows/build.yml`。

## 来源与协议

- 沙盒技术：[worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit)
- 容器枚举 `fsgetpath`：来自 [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus
- 基础项目：[WQFiles](https://github.com/kolbicz/WQFiles) by kolbicz，v0.7

Cleaner 是 GPL-3.0-or-later（见 `LICENSE`）。
