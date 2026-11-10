# GitHub 研究 — Cleaner v2.3（2026-11-10）

用户要求：看看 GitHub 上有没有项目能帮我们把清理做得更强，而且要支持我们这个沙盒
（App Group + worse_query，只能进别的 App 的容器目录）。

结论先说：**能直接搬代码的只有一个（3105 的清理思路，Swift，需用 C 重写）；
能搬“做法”的有两样（fd 式安全遍历、清理前后复测记账）； per-app 缓存子路径没有
任何公开的权威清单——“更强”只能来自遍历安全 + 分类更细 + 自定义规则，而不是
抄一份现成的路径表。** 越狱限定（iCleaner）和 TrollStore 限定（iOS Clean Pro）的
项目一律出局。

## 1. 候选表

| 项目 | 许可证 | 清理逻辑 | 进我们沙盒吗 | 结论 |
|---|---|---|---|---|
| forcequitOS/worse_query（我们地基） | GPL-3.0 | 沙盒逃逸 PoC 本身，不含清理 | 是 | 已在用 |
| kolbicz/WQFiles v0.7（原项目） | GPL-3.0 | 见 §2 清单 | 是 | 全部搬运（v2.3 §6） |
| YangJiiii/3105 v2.0 | GPL-3.0 | 每 App 只清 `Library/Caches` + `tmp`，见 §3 | 部分：清理思路进，取容器方式不进 | 借思路（fd 遍历 + 前后复测），Swift 代码不直接搬 |
| jailbreakdotparty/Erosion | GPL-3.0 | 无清理；MobileGestalt/壁纸/拨号盘美化 | 是（同款 worse_query） | 跳过清理；只佐证 worse_query 支持 iOS 27.0–27.2.1、27.3b1 |
| WQFiles 的 32 个 fork | GPL-3.0 | 与上游描述完全一致，无功能 fork | 是 | 无新东西（项目才 2 天） |
| iCleaner | — | root 级全盘清理 | 否（要越狱 + root） | 出局 |
| iOS Clean Pro | — | TrollStore 权限深清 | 否（TrollStore，iOS 14–17.0） | 出局 |
| 0x61A/sweeply（macOS 清理器） | MIT | 六类清理、真实路径、先进废纸篓 | 否（macOS，不是 iOS 沙盒） | 只借分类思路，不搬代码 |
| FilzaJailedDS / MobileHouseArrest-PoC 等 | 各异 | 漏洞 PoC，不是清理器 | 否（另一条逃逸路线） | 出局 |

注：worse_query 现 394★ / 75 fork；WQFiles 32 fork；3105 982★ / 189 fork；
Erosion 666★ / 96 fork。数字是 2026-11-10 查的。

## 2. WQFiles 的清理功能清单（本地 clone 核对，v2.3 要全搬）

- **Cache Cleaner**：每 App 量 `Library/Caches` + `tmp`（可取消），删这两个目录内容；
  崩溃日志（`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/
  Library/Logs/CrashReporter`，iOS 27 才有）；全选 / 只选大缓存 50MB+；确认对话框；
  清理中可停止；清理后要求重扫。
- **应用数据管理**：备份（`Documents` + `Library`，清单 `.wqbackup.plist`，
  未完成备份用 `.incomplete-` 前缀隔离，严格校验）；恢复（journal + 回滚，
  恢复前先做安全备份）；清空数据（`Documents` + `Library`，先问备份，
  `tmp` 清掉但不备份）；操作前要求先关掉目标 App。
- **安全校验**（WQCacheSafety.h）：无符号链接祖先、目标必须属于该容器、身份校验、
  按 inode 验证。——这是“清不坏”的底线，v2.3 不削弱，只加强（见 §3）。
- **文件浏览器**：v2 已扔；v2.2 只加回只读目录钻取（用户点名要的），plist/hex 编辑、
  分享/ZIP、Go to Path 仍不加。

## 3. 从 3105 借的东西（GPL-3.0，可借；Swift 代码用 C/ObjC 重写）

3105 的 `LimitedCleanerService.swift`（263 行）只清 `Library/Caches` + `tmp`，
和我们边界完全一致。它比 WQFiles 强在两点，v2.3 采用：

1. **fd 式遍历（最值得借）**：根目录 `open(O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)`，
   之后全程 `openat` / `fstatat(AT_SYMLINK_NOFOLLOW)` / `fdopendir` / `unlinkat`，
   符号链接、socket、设备节点一律不跟随、不计数、不删除。
   好处：没有“先校验路径、再操作路径”之间的竞态窗口（TOCTOU），比 WQFiles 的
   路径字符串校验更结实。v2.3 把 `CLCache` 的量大小 / 删除改成 fd 式，
   但保留 WQFiles 的容器归属 + 身份校验（两者叠加，不互相替代）。
2. **清理前后复测记账**：`clean()` 先扫一遍（before），删完再扫一遍（after），
   报告 `freedBytes = before - after`、删掉的条目数、失败条目数。
   v2.3 采用：每 App 清理结果按“清理前 / 清理后 / 释放 / 失败”记，汇总卡显示
   真实释放量（不再是“预计释放”），失败的 App 单独列出来。
3. **稳定排序**：大小降序，大小相同按名字、再按 bundle ID——v2.3 采用，
   列表顺序不再抖动。

**不借的**：3105 取容器的方式（MobileHouseArrest + 固定 bundle ID
`com.apple.mobile.MobileHouseArrest` + iOS 17/18 内核漏洞可选项）与我们的
worse_query 授权路线不同，且要求企业证书签名；我们的授权路线更适合 iOS 27。
3105 的 SwiftUI 界面也不搬。

## 4. per-app 缓存子路径：查过，没有公开清单

搜过 WeChat / QQ / 抖音 / Bilibili / 小红书等 App 的 iOS 缓存子目录：
没有任何开源项目或文档给出“某 App 的某子目录可删 / 不可删”的权威表。
唯一公开、可信的模型是 Apple 的目录语义（deepwiki / cleanor.app 均一致）：

- `Library/Caches/` + `tmp/`：半持久、可再生、不备份、系统缺空间时可自行清除
  ——**可删**，App 自己会重建。
- `Documents/` + `Library/Application Support/`：用户数据、备份、不自动删
  ——**不可默认删**，只能用户明确操作（备份后清空、按文件夹清理）。
- `Library/` 下其他子目录（Preferences、WebKit 等）：混合，默认不动。

所以 v2.3 “比原项目更强”的打法不是抄路径表，而是：

- **Caches 内部分类**：扫描时把 `Library/Caches` 的一级子目录单独列出来
  （大小 Top 5），用户可以在目录页按文件夹清理，而不是只能整目录删。
- **自定义清理**：用户自己定规则（选 App + 文件夹/文件类型模式），存成预设，
  加排除列表（这些 App/文件夹永远不碰）。规则是用户自己的知识，不依赖外部清单。
- **内置安全子路径表（保守版）**：只收 Apple 语义下明确可再生的通用子路径，
  如 `Library/Caches/*`、`tmp/*`、`Library/WebKit/WebsiteData`（网站数据，
  可再生但会退登录——默认不勾选，只在自定义规则里可选），不写任何 App 专属路径，
  避免误删用户数据。

## 5. 决定

- 搬：WQFiles 全部清理功能（§2）+ 3105 的 fd 遍历 + 前后复测记账 + 稳定排序。
- 不搬：3105 的取容器方式、Erosion 的美化功能、任何越狱/TrollStore 专属逻辑。
- 新增：自定义清理（规则/预设/排除）、Caches 一级子目录分类、目录页按文件夹清理、
  快捷指令 URL Scheme、动画重做、图标极简风、✅ 回归 KSU 原样、清理后应用数 bug 修复。
- 许可证：Cleaner 已是 GPL-3.0（与 WQFiles / worse_query / 3105 一致），借思路
  不产生新的许可证义务；在 REFACTOR-v2.md §10 注明来源（3105 fd 遍历、
  WQFiles 全部清理功能）。
