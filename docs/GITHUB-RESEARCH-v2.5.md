# GitHub 研究 — Cleaner v2.5（2026-11-10）

用户要求：多找沙盒相关和清理类相关的项目——自定义规则要做到「点开新页面选目录、
右上角选择确认」，逻辑要借鉴相关项目；快捷指令要让人找得到。

结论先说：**目录选择这件事，桌面清理器早有标准答案（BleachBit 的 Custom 清单 +
文件选择器；SD Maid SE 的自定义过滤器），iOS 沙盒内只能用应用内钻取（系统文件
选择器够不到别的 App 的容器），而 FilzaWorse 证明了 Filza 那套钻取界面就跑在
这个沙盒上。** 沙盒这边没有新逃逸路线：worse_query 的 85 个 fork 全是白拷贝，
WQFiles 的 35 个 fork 也是；新冒出来的容器文件管理器只有 worsefiles-ios（1★）
和 worse-query-explorer（0★），都太新，没东西可借。

## 1. 沙盒 / worse_query 生态（2026-11-10 实查，GitHub API）

| 项目 | ★ / fork | 状态 | 结论 |
|---|---|---|---|
| forcequitOS/worse_query | 407 / 85 | 我们的地基 | fork 全是白拷贝（0–1★，2026-11-08/09 推过，无功能改动） |
| kolbicz/WQFiles | 403 / 35 | 原项目 | fork 全是白拷贝（0★） |
| jailbreakdotparty/Erosion | 670 / 97 | 定制工具箱 | 佐证 worse_query 支持 iOS 27.0–27.2.1、27.3b1（同 v2.3） |
| YangJiiii/3105 | 982 / 189 | 2026-09-14 后无推送 | 清理思路已在 v2.3 借完；无新东西 |
| Torrekie/FilzaWorse | 11 / 1 | **新**：非官方 Filza 5.0.1 b3 + worse_query 文件访问（GPL-3.0，ObjC） | Filza 的钻取界面就跑在这个沙盒上——我们的目录选择器照 Filza 的样子做，是验证过的路线 |
| fucknima/worsefiles-ios | 1 / 1 | **新**：iOS 26/27 容器文件管理器（GPL-3.0，Swift） | 太新太小，无可借；只记下来观望 |
| Kianuni/WQFiles-CN | 10 / 0 | WQFiles 简体中文全量汉化 | 佐证中文界面是刚需；技术上没东西可借（我们自己已经汉化） |
| strawhatdev01/worse-query-explorer | 0 / 0 | SwiftUI 研究壳（GPL-3） | 研究壳，不是清理器 |
| adnan120hz/WorkTweaks | 8 | MobileGestalt 工具（worse_query） | 与清理无关 |
| wormprojects/badshell | — | a-Shell 分叉终端（bad_query） | 与清理无关 |
| frs0n/placard | — | 海报墙纸（bad_query） | 与清理无关 |

出局（同 v2.3）：iCleaner（越狱）、iOS Clean Pro（TrollStore）、3105 的取容器
方式（MobileHouseArrest + 企业证书，与我们的 worse_query 路线不同）。

## 2. 自定义目录清理：桌面清理器早有标准答案

### BleachBit（bleachbit/bleachbit，7435★，GPL-3.0，Python）——主参考

- **Preferences → Custom 选项卡**：点按钮 → 文件选择器选文件/整个文件夹 → 进清
  理清单；System 清理器下有个 Custom 项，运行时一并清理。这正是用户要的流程：
  「打开新页面选目录 → 确认 → 以后清理里就有它」。
- **Whitelist（现叫 keep list）**：不想删的路径加进去，任何清理都不碰——对应我们
  已有的排除列表。
- **预览模式**：先列出会删的每一个文件（"Preview – Files to be deleted"），
  确认后再删——对应我们的试运行预览（v2.4 已有，v2.5 保留）。
- **5.1.0 beta 的保护路径**：用户把受保护路径（如 c:\windows\system32、/bin）加
  进自定义删除清单时，非专家模式会**警告并拒绝**；专家模式才放行。对应我们的
  安全边界：容器根目录 / Documents / Library 本身拒绝；Caches/tmp 之外的目录
  警告（不明着禁，但要用户明确确认）——同一个思路，换到 iOS 目录语义上。
- 自定义清理器还支持 XML 定义（winapp2.ini 导入）——桌面才需要，iOS 上规则存
  plist 已够用，不搬。

### SD Maid SE（d4rken-org/sdmaid-se，8039★，GPL-3.0，Kotlin）——规则结构参考

SystemCleaner 的自定义过滤器由这几部分组成（DeepWiki 核对）：

- **标签**（用户起的名字）→ 我们的规则摘要（一行中文，如「微信 · 目录 …」）。
- **数据区域**（扫哪些存储区）→ 我们的「应用」（规则属于哪个 App 的容器）。
- **文件类型限制**（文件 / 目录 / 两者）→ 我们的范围选择：清空整个目录 vs
  按条件删文件。
- **路径条件 + 名字条件 + 匹配方式**（开头 / 包含 / 结尾 / 等于）→ 我们的
  目录路径 + 扩展名/文件名包含（包含匹配是够用的子集，不做全文匹配模式）。
- **排除项** → 我们的排除列表。
- 另两条原则也照搬：**每个工具先出结果再删东西**（试运行预览）；**StorageAnalyzer
  按大小排文件夹**（我们 v2.3 的 Caches Top 5 同款思路）。

### macOS 清理器（只借「先展示再删」这一条）

- Sweeply（0x61A/sweeply，MIT）：扫出来每个缓存、日志都带真实路径和真实大小。
- Mole（tw93/Mole）：删除前展示全部内容；有风险的操作只走工具自己的命令。
- purge-app（jithin-sabu/purge-app，1.8K★）：默认先去废纸篓，可恢复——iOS
  沙盒内没有废纸篓概念，我们的等价物是「先预览、后备份、再清空数据」，不搬。

## 3. 为什么不用系统文件选择器

iOS 的 UIDocumentPickerViewController 只能进「文件」App 能看到的位置
（iCloud、「我的 iPhone」），别的 App 的容器根本不在里面——系统选择器够不到
我们的目标目录。**应用内钻取是唯一路线**：选应用 → 进容器逐级点文件夹（Filza
式），或粘贴路径。这不是偷懒，是沙盒决定的。

## 4. 快捷指令找得到：检查写错了，不是包里没意图（词替换，run 42825889428 验实）

用户 2026-11-10 20:44 真机证据：在「快捷指令」App 里搜 cleaner，一个结果都
没有。20:46 第二张截图排除了最先的两个猜测：手机上确实是 v0.2.4 (1)，而且
已经打开过——「还装着 v2.3」「装了但没打开过，系统没索引」都不成立，是真 bug。

**更正（本节原先写的「-dead_strip 根因」是错的）：** 原先的根因结论靠两处证据，
两处都测不到东西：(1) 在 v2.4 二进制上 grep 字面混淆名
`$s14CleanerIntents16CleanCacheIntentV` / `$s14CleanerIntents17CleanerShortcutsV`
和 `appShortcuts`，全是 0 次——但 Swift 的混淆名会做词替换（word substitution），
这些字面串在任何二进制里都不会出现；(2) 一个已被 `strip -x` 抽掉本地符号的符号
表（415 个全局符号、1 个本地），Swift 结构体的元数据符号是本地的，strip 本来就
会删掉它们。v2.5 的诊断转储（run 42825889428，把链接后二进制里全部
CleanerIntents 符号打到日志里）证明了这一点：类型一直在包里，真正的符号是
`$s14CleanerIntents16CleanCacheIntentV`（拼全名）和
`$s14CleanerIntents0A9ShortcutsV`（"Cleaner" → 替换 0A，只拼 "Shortcuts"），
appShortcuts 的访问器是 `0A9ShortcutsV03appC0`。v2.4 真机搜不到的真正原因仍未定
（可能是当时装的还是 v2.3、或系统索引延迟），只能等用户在 0.2.5 上亲测。
v2.5 为此连错了 5 次构建检查才找到这里——教训：**先打转储看二进制里到底有什
么，再写检查；不要先编一个机制（优化器删类型），再按机制写检查。**

**关键陷阱（仍然成立，但原因不同）：build.sh 里 `grep -a -q "CleanCacheIntent"`
这种裸名 grep 在坏包上也能通过，因为裸名字符串还在——查裸名等于没查。** 同样的
假检查还有两处：`tests/browser_ui_regressions.py:371`（只是在 build.sh 文本里
grep "CleanCacheIntent"）和 `tests/test_build.py:42`（假 otool 只打印标记，不读二
进制）。三处都要改成真检查（见 §5 决定），而且真检查必须 grep 真正发出的符号
（替换后的形式），不是“看起来像”的字面名。

注：混淆符号里的长度数之争（"CleanerShortcuts" 是 16 还是 17 个字符）是白争——
真正发出的符号根本不拼全名，长度数不适用。v2.5 的构建检查直接 grep 确切的替换后
符号，不用长度不敏感的正则猜。

v2.5 的做法（意图接线本身不用动——openAppWhenRun = false 的后台意图设计不变；
要动的是构建检查和指引页）：

- **给意图类型一个优化器删不掉的真实引用**：`CLCleanerShortcutsInfo`（Swift）
  直接读 `CleanerShortcuts.appShortcuts`，设置里的指引页把标题显示出来——
  数据流一路到 UIKit 标签。keepAlive 保留，但不再是保护。
- 设置里给一个真正的指引页，**先讲前置条件**：装 0.2.5 → 打开一次 Cleaner →
  系统索引之后再去「快捷指令」里搜 Cleaner 才会出现「清理全部缓存」；搜不到
  就重启手机再试。
- 指引页带 **live 状态**：当前版本带不带意图（运行时读
  `CLCleanerShortcutsInfo.shortcutTitles`——即真实的注册结果，不是“类在不在
  二进制里”）、
  这台手机上 Cleaner 打开过没有（NSUserDefaults 标记，只在真正进界面时记一次，
  无头跑意图不记），让用户自己能判断是「没装新版」还是「注册坏了」。
- 一个按钮直接打开快捷指令 App（shortcuts://），不用用户自己去找。
- **「搜不到」不算修好**：只有用户在真机上搜到并点过一次，才算验证通过。

## 5. 决定

- 搬：BleachBit 的 Custom 清单 + 文件选择器流程（选目录 → 确认 → 进清理清单）、
  保护路径警告/拒绝、预览先行；SD Maid SE 的自定义过滤器结构（标签 / 数据区域 /
  文件类型 / 路径+名字条件 / 排除）；Filza（经 FilzaWorse 验证跑在 worse_query
  上）的钻取界面。
- 不搬：worse_query / WQFiles 各 fork（白拷贝）、worsefiles-ios（太新）、
  3105 取容器方式、任何越狱/TrollStore 专属逻辑、系统文件选择器（够不到容器）、
  BleachBit 的 XML 清理器定义（桌面才需要）。
- 新增（v2.5）：目录选择器页（CLRulePickerViewController：选应用 → 钻取目录 →
  选范围「清空整个目录 / 按条件删」→ 右上角选择确认；支持粘贴路径，绝对路径自动
  解析到应用+相对路径）、新规则类型 directory（scope all/filtered；filtered 用
  fd 遍历在任意容器内目录下按扩展名/名字/年龄/大小删——CLCache 的 roots 限制为此
  开一个 allowAnyRoot 口子，仅已校验的目录规则可用）、规则编辑（重开选择器预填）、
  快捷指令指引页（前置条件 + live 状态 + 打开快捷指令按钮）、意图防删
  （CLCleanerShortcutsInfo 真实数据流 + build.sh 混淆符号与 appShortcuts 二进制
  校验，裸名字符串不算数；两处假测试桩改成真检查）。
- 许可证：Cleaner 已是 GPL-3.0，与 BleachBit / SD Maid SE / FilzaWorse /
  worsefiles-ios 一致；借的是流程与结构思路，不搬代码，不产生新的许可证义务；
  来源记在 REFACTOR-v2.md §12 与 Settings 的来源行。
