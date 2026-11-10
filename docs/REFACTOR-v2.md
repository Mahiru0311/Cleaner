# Cleaner v2 — 完全重构方案（2026-11-10）

目标：不再是 WQFiles 的汉化版，而是我们自己的 Cleaner。
只留清理真正需要的东西，界面按 KernelSU 风格 + iOS 26 Liquid Glass 重做，
技术栈选体积最小、界面最好看的那条路。

## 1. worse_query 到底是什么（已核对原仓库 + WQAccess.m）

worse_query 是 forcequitOS（Taj C）在 2026-11-08 发布的 iOS 沙盒逃逸 PoC，
bad_query 的直接后继，GPL-3.0。不是越狱，作者明确说永远不会是越狱。

支持：iOS 26.0–26.7.2 / 27.2。你的 iPhone 17 / iOS 27.0.1 在范围内。

### 原理（3 步）

1. **前提：App Group。** 应用必须带一个 App Group 权限，
   用 `containerURLForSecurityApplicationGroupIdentifier` 拿到自己的群组容器。
   没有它，什么都拿不到。
2. **换 Caches。** 把自己群组容器里的 `Library/Caches` 临时换成目标路径
   （WQFiles 里叫 `WQCacheSwapBegin`，带中断恢复标记，做完再换回来）。
3. **问容器管理要 token。** 用私有库 `libsystem_containermanager.dylib`：
   `container_query_create`，class 7（App Group 容器），
   group identifiers = 自己的 App Group，part 3 = `Library/Caches`，
   flags 有标准 / 备用两套（iOS 26 要备用那套），
   `container_query_get_single_result` → `container_copy_sandbox_token` →
   `sandbox_extension_consume(token)`，拿到一个 handle。
   拿到后要验证它真的能打开目标（只认 EPERM 不算，其他权限问题 token 也救不了），
   不行就换另一套 flags 再试一次，成功的那套记下来以后都用它。

拿到 token 后，进程就有了那个文件夹的沙盒扩展（sandbox extension），
可以像打开自己文件一样打开它。

### 能到哪些路径

```
/var/containers/Data/System (iOS 27)
/var/containers/Shared/SystemGroup/* (iOS 27)
/var/mobile/Containers/Data/Application/*
/var/mobile/Containers/Data/InternalDaemon/*
/var/mobile/Containers/Data/PluginKitPlugin/*
/var/mobile/Containers/Shared/AppGroup/*
/var/mobile/Containers/Shared/AppGroup (iOS 27)
```

### 两个配套技术（不是 worse_query 本身，但 Cleaner 缺了它们不行）

- **fsgetpath 枚举（来自 KAMUI）：** 容器父目录拿不到 token、列不出目录时，
  按 inode 号一个个问内核要路径，拼出容器列表。首次全扫慢，之后只查新增，
  每周一次全扫，列表存本地 plist 记住。
- **LaunchServices 数据库：** 直接读 lsd 的数据库拿应用名和图标，
  iOS 26 上不用全盘扫就能列出 App / 扩展 / App Group，省下近 1 小时。

## 2. 对 Cleaner 有用的 / 没用的

| 模块 | 有用吗 | 结论 |
|---|---|---|
| `wq_app_group` / `wq_query_token` / `wq_query` / `wq_grant` / grant LRU（最多 192 个，超了放掉最老的） | ★ 核心 | 留，改名 `CLGrant`，只留这一个入口 |
| `WQCacheSwapBegin` / Recover（换 Caches + 中断恢复） | ★ 核心 | 留，Cleaner 只在清理那一刻换，平时不碰 |
| fsgetpath 扫描 + 本地缓存（增量 / 每周全扫） | ★ 核心 | 留，简化：只扫 App 数据 + 扩展，不扫守护进程 |
| LaunchServices 读名 / 图标 | ★ 核心 | 留 |
| 缓存安全校验：无符号链接祖先、目标必须属于该容器、身份校验、按 inode 验证 | ★ 核心 | 留，这是“清不坏”的底线 |
| `WQCacheMeasureDirectory` / `wq_purge_contents_cancellable`（量大小 / 可取消删除） | ★ 核心 | 留 |
| 应用数据清空 + 先备份再清 | 有用 | 留简化版：只清 Documents / Library / tmp，先问备份 |
| 崩溃日志清理（SystemGroup osanalytics） | 有用 | 留，iOS 27 才有，iOS 26 自动隐藏 |
| 文件浏览器、Go to Path、System Groups 浏览 | 没用 | 扔 |
| Plist 编辑器、Hex 编辑器、文本编辑 | 没用 | 扔（约 1500 行） |
| 分享 / ZIP 导出、Open As | 没用 | 扔 |
| WQApps 完整备份/恢复管理 | 太重 | 只留“清空”那一条，备份恢复以后再说 |

算下来：原来 10,331 行，v2 目标约 3,000–3,500 行，
只留 `CLGrant`（沙盒）+ `CLScan`（扫描/名字）+ `CLCache`（量/清）+ `CLApp`（应用清空）+ 新 UI。

## 3. 技术栈：体积最小 + 界面最好看

| 选项 | 体积 | 界面 | 结论 |
|---|---|---|---|
| Objective-C + UIKit（纯 C/ObjC，无 Swift） | 最小 | 原生 Liquid Glass | ★ 选这个 |
| Swift + SwiftUI | 大（Swift 运行时 + SwiftUI 框架） | 好看，但体积和启动都大 | 不选 |
| Swift + UIKit | 中 | 好看 | 不选，Swift 运行时白白占体积 |
| Flutter / React Native / WebView | 最大 | 不原生 | 不选 |

v0.1 实测：二进制 635,632 字节，IPA 285,187 字节（压缩后）。
其中图标 PNG 约 850KB 未压缩，是 IPA 里的大头。

v2 体积打法：

- 语言：纯 Objective-C + C，UIKit only，不引 Swift、不用第三方库、不用 WebView
- 编译：`clang -Os -flto -dead_strip`，strip 符号，单架构 arm64，无 bitcode
- 图标：只留 iPhone 需要的尺寸，去掉 iPad 那两张（76 / 83.5），PNG 用 pngquant 再压一次；
  界面图标全部用 SF Symbols，不打包图片资源
- 资源：零图片、零字体、零本地化包（中文直接写死，Cleaner 只做中文）
- 目标：二进制 < 500KB，IPA < 250KB

## 4. 界面：KernelSU 风格，落在 iOS 26 上

KernelSU Manager（Android，Jetpack Compose，Material 3 / Miuix，v3.2 重做过）：

- 首页是一张大状态卡：工作状态（正常 / 受限）、内核版本、一个主操作
- 底部导航：首页 / 授权 / 模块 / 设置，手机上是底部栏，平板上是侧边栏
- 卡片圆角大、留白大、一个主色、状态用小 pill（圆角标签）表示
- 列表按大小排，右上角一个主按钮

搬到 iOS 26 / Cleaner 上，改成这样：

- **底部导航（v2.1 修正：iOS 26 原生液态玻璃，删掉自定义悬浮白底胶囊栏）**
  （用户 2026-11-10 18:14 真机截图反馈：界面乱飞、很丑，底栏要用 iOS 26 底层液态玻璃，像 huami GestaltX 那个；
  GestaltX 用的是 plain SwiftUI `TabView` + `.tint(.blue)`，iOS 26 上自动就是原生液态玻璃底栏）
  - 用标准 `UITabBarController`，4 个 tab 各包一个 `UINavigationController`，tint 蓝色；
    系统在 iOS 26 上自动渲染为液态玻璃底栏（悬浮玻璃 pill、滚动时收缩），不要手写胶囊 view、不要纯白底、不要手动阴影
  - 系统自动处理 safe-area / content inset，每页最后一行滚动到底必须完整可见
  - 首页 / 清理 / 应用 / 设置，4 个（对应 KernelSU 的 Home / Superuser / Module / Settings）
- **图标语言（用户 2026-11-10 16:50 不许 emoji；2026-11-10 17:00 指定参考 huamidev/GestaltX）**
  - GestaltX 的语言（源码 `~/workspace/temporary/GestaltX/`，只参考设计，不抄 logo 和代码；
    它是 SwiftUI 应用，我们只借鉴图标设计，v2 仍纯 ObjC + UIKit）：
    应用标志是极简黑色图形——两条粗横线加两个药丸形滑块，暖米色底 #F5F1E8，线条粗而圆；
    App 内全部 SF Symbols，一个功能一个符号，字重尺寸统一，黑色字形 + 唯一蓝色强调色 #007AFF；
    分类行是「符号 + 粗标题 + 灰色副标题」；底部标签是 SF Symbols。
  - Cleaner 规范：全站 SF Symbols，默认黑色，选中/强调才用系统蓝 #007AFF；不要 emoji，不要多彩图标。
    底部栏：首页 house.fill、清理 trash.fill、应用 square.grid.2x2.fill、设置 gearshape.fill。
    首页信息行（GestaltX 分类行样式）：Cleaner 版本 tag.fill、系统版本 cpu、设备型号 iphone、
    沙盒技术 shield.fill、App Group 状态 lock.shield.fill、支持范围 checkmark.shield.fill。
    清理列表：选中圆圈蓝色实心对勾，应用图标用真实彩色图标。
  - Cleaner 自己的应用标志：学 GestaltX 极简风但不要抄它的滑块标志——暖米色底 #F5F1E8 上一个
    黑色粗线条垃圾桶/清扫造型，线条同样粗圆；用在设置页关于区和 AppIcon（只留 iPhone 尺寸）。
  - 设置页底部加一行：图标风格参考 huamidev/GestaltX（GPL-3.0）。
  - 也借鉴 Filza（扁平原生风、每种文件配彩色图标）：清理列表每行用真实彩色应用图标。
- **第一页（首页）：按 KernelSU 老版本（v3.2.5，Miuix 风格）首页截图一比一复刻，只改名字**
  （用户 2026-11-10 16:55 发截图说老版本非常好看；截图存为 `docs/kernelsu-old-home-reference.jpg`；
  对应源码 `~/workspace/temporary/KernelSU/manager/.../home/HomeMiuix.kt`；
  之前 Material 版首页方案作废）
  - 背景浅灰；右上角电源图标（点开菜单：重新扫描）；左上超大粗标题「Cleaner」
  - 标题下一行：左侧浅绿大卡 #DFFAE4（圆角约 28，占一半多宽），三行字
    「已授权」「<App Group> [沙盒模式]」「版本：0.2.0」，右下角超大绿色对勾圆圈
    #36D167、110dp、往右下溢出（照抄源码 offset(27dp, 31dp)）；
    右侧一列两张白小卡：「应用 / 38」「可清理 / 2.52 GB」（灰色小标签在上，超大黑色粗数字在下）
  - 下面一张白色大圆角卡，信息行是 GestaltX 分类行样式（左侧符号 + 黑色粗体标题在上、灰色值在下），行距大：
    Cleaner 版本 / v0.2.0 (0.2.0)；系统版本 / iOS 27.0.1；设备型号 / iPhone 17；
    沙盒技术 / worse_query · App Group；App Group 状态 / 正常；支持范围 / iOS 26.0–26.7.2 / 27.2
    （符号见上节图标语言：tag.fill / cpu / iphone / shield.fill / lock.shield.fill / checkmark.shield.fill）
  - 底部是标准 `UITabBarController`（v2.1 起，iOS 26 原生液态玻璃，见上节；
    v2.0 的自定义悬浮白底胶囊栏已删）：首页 house.fill、清理 trash.fill、
    应用 square.grid.2x2.fill、设置 gearshape.fill，tint 蓝色
  - 图标借鉴 Filza（iOS 文件管理器，扁平原生风、每种文件配彩色图标）：
    底部栏用实心填充 SF Symbols；清理列表每行用真实彩色应用图标（LaunchServices 取的）
  - **首页四种状态（用户 2026-11-10 17:20 要求写扎实）：**
    已授权（绿卡，对勾 #36D167）、受限（琥珀卡 #FFF3D6，三角感叹号，系统橙）、
    未授权（红卡 #F9DEDC，三角感叹号）、不支持（红卡，xmark.octagon.fill）。
    判定：系统版本不在 26.0–26.7.2 / 27.0–27.2 → 不支持；无 App Group → 未授权；
    有 App Group 但授权探针失败 → 受限；探针通过 → 已授权。
    探针：后台线程对自家容器调一次 `cl_grant`（机制本身能不能签发权限），每启动只跑一次，
    「重新扫描」时重跑；跑完之前状态卡显示「正在检查…」（灰卡 + hourglass）。
    点状态卡：已授权/受限 → 直接进清理页（受限也可能部分可用，清理页会显示实际失败）；
    未授权/不支持 → 先弹说明框（怎么修：重签保留 App Group / 系统版本超出范围），
    框里有 [去清理]（仍可进清理页看扫描失败）和 [取消]；检查中点按忽略。
    警告卡：未授权/不支持/受限时显示（受限是琥珀底），平时隐藏。
    信息行「App Group 状态」跟随状态：正常 / 受限 / 未授权；检查中显示「检查中…」。
- **第二页（清理）：按原版 WQFiles Cache Cleaner（WQCache.m）一比一复刻，只改中文**
  （用户 2026-11-10 16:58 指定；复用 v0.1 的 WQCache 逻辑改名 CLCache，不重写扫描/清理）
  - InsetGrouped 列表，标题「缓存清理」
  - 顶部汇总卡：小字「可清理」（扫描时「正在扫描…」+ spinner，清理时「正在清理…」），
    34pt 粗体大数字总量，蓝色进度条（已选占比），灰色 footnote 状态行（已选 xx MB · n 个应用 / 清理结果）
  - 搜索框 placeholder「搜索应用」，一直显示；下拉刷新重新扫描
  - 列表行从左到右：24pt 选中圆圈（checkmark.circle.fill 蓝 / circle 灰）、36pt 真实应用图标（圆角 8）、
    应用名、下面灰色「缓存 xx · 临时 xx」、最右 15pt 半粗体等宽数字大小；按大小降序；
    最后一行特殊项「崩溃日志」（「崩溃日志 · osanalytics」或「访问受限」）
  - 右上角：清理主按钮（仅选中 >0 可用）+ 选择菜单：全选 / 全不选 / 只选大缓存（50 MB+）；
    扫描中不显示按钮，清理中显示「停止」
  - 确认框：标题「清理缓存？」，写清范围（删除 n 个应用的 Library/Caches 和 tmp + 崩溃日志）与
    「无法撤销，不保留备份」，红色清理按钮；清理时显示进度「正在清理第 x / n 个：应用名」，支持停止
  - 渲染用 iOS 26 Liquid Glass，图标 SF Symbols，不要 emoji
  - 与 1:1 的一处偏差（v2 已删文件浏览器所致）：原版长按菜单全是“在文件浏览器中显示缓存/tmp/应用数据”，
    v2 没有文件浏览器，这菜单取消；受限行点按提示也不再提文件浏览器
  - **状态机（用户 2026-11-10 17:20 要求写扎实）：**
    扫描中（汇总卡「正在扫描…」+ spinner，右上角不显示按钮，点行无效）→
    可清理（清理按钮仅选中 >0 时可用；选择菜单：全选 / 全不选 / 只选大缓存 50MB+，只作用于当前搜索可见行，
    受限行永远不选）→ 清理中（进度「正在清理第 x / n 个：应用名」，右上角变「停止」）→
    完成 / 已停止 / 失败。
    每个分支都有明确收尾：完成、停止、验证失败都会自动重新扫描并在状态行写结果
    （「已释放 xx」「已停止。已释放 xx」「清理已取消/停止：原因。已重新扫描。」）；
    清理前先全量校验选中项（容器/目标身份），任一项失败则整个清理拒绝、什么都不删、自动重扫；
    清理中每条记录删除前再校验一次，失败即停。
    取消的扫描一定调 completion（`cancelled=YES`），调用方据此复位状态——切走再回来不会卡在「正在扫描…」；
    回到本页时无完成扫描或数据超过 60 秒就重扫；下拉刷新强制重扫。
    崩溃日志行：只在 iOS 27 出现（iOS 26 不显示该行），可清理时正常参与选择和确认范围，
    访问受限时显示「访问受限」且不可选。
    首页和清理页共享一次扫描：`CLCacheStore.scanning` 标志防止两页重复扫；
    显式操作（下拉刷新、进页）优先于该标志。
- **颜色：** 首页是扁平 Miuix 风，不是 Liquid Glass：浅灰底（`systemGroupedBackground`）、
  白卡、绿卡 #DFFAE4 + 对勾 #36D167；选中态用系统蓝。深色模式跟随系统（绿卡深色版 #1A3825，
  照抄源码）。不自己画磨砂图，不贴图。
- **字体：** 系统字体，大数字用加粗大号，小字用 secondary 颜色
- **简便：** 首页只做一件事——看状态、点状态卡进清理；别的功能都收到底部导航里

用户 2026-11-10 16:47 已说“开始吧”，直接写 ObjC，不再等网页原型确认。

## 5. v2 目录（新代码，不动 v0.1 的 main 分支）

```
Cleaner/
  App/            新 UI：CLHome（四态 + 探针）, CLCleaner（状态机）, CLApps（备份/恢复/清空）,
                  CLSettings（关于/来源/日志）, CLLog（只读日志）,
                  CLTabBarController（v2.1 起：标准 UITabBarController，iOS 26 原生液态玻璃）,
                  CLUI（共用 UI）, main.m（入口 + resolvers + 恢复中断的还原）
  Core/
    CLGrant.m     worse_query：App Group + token + grant LRU
    CLScan.m      fsgetpath 扫描 + 本地缓存 + LaunchServices 名字/图标
    CLCache.m     量缓存/tmp、清理、可取消、崩溃日志 + CLCacheScanner/CLCacheStore（两页共享扫描）
    CLApp.m       应用备份/恢复（含 journal + 回滚）/清空
    CLSafety.h    安全校验（头文件内联）：符号链接、目标归属、身份、cache swap
    CLLaunchServices.h/m  名字/图标/容器映射
    CLAppSupport.h        备份清单/journal/签名校验
  build.sh        同 v0.1，输出 Cleaner.ipa（只编新源码，-Os -flto -dead_strip + strip）
  .github/workflows/build.yml   同 v0.1，macOS 构建（main + refactor/v2）
```

v0.1 的 `main.m / WQCache.m / WQApps.m / WQPlistEditor.m / WQHexViewer.m / WQSharing.m / WQDir`
在 v2 里全部删掉，不留着当包袱。

## 7. Stage 1 实现状态（2026-11-10 晚，审计后）

分支 `refactor/v2`，v0.1 的 `main` 不动。新代码共 7,008 行（构建修复后）
（Core 4,685 行：CLGrant 671、CLScan 805、CLCache 536、CLApp 780、CLLaunchServices 820、
CLSafety.h 398、CLAppSupport.h 367、其余头文件 308；
App 2,325 行：清理 559、首页 521、应用 465、设置 127、胶囊栏 164、CLUI 285、日志 40、main 58、
其余头文件 106）。
没达到最初 3,000–3,500 行的目标——留下的扫描/备份/恢复引擎本身就占大头，
省掉的是文件浏览器/编辑器/分享那 ~3,300 行（v0.1 共 10,331 行）。

审计修掉的问题（都是不修就编不过或卡死的）：
- `CLAppsViewController.m` 移植截断：`init` 写进 ivar 大括号、`scan`/`visibleApps` 各重复一行、
  尾部 `cl_replace_part` 只剩半个函数且无 `@end`（Core 里已有完整版，VC 里那段删掉）。
- 跨文件调 static 函数：`cl_errno`/`cl_is_denied`/`cl_norm`（CLGrant.m static，被 CLCache/CLScan 调），
  `cl_dir_size_cancellable`（CLApp.m static，被应用页调）——全部改导出，在头文件声明；
  应用页 `clear:` 原先内联实现改成调 Core 的 `cl_clear_app_data`。
- 提取残留：`CLGrant.m` 里两处 `WQ_TREE_HOOK` 未改名、`CLApp.m` 引用不存在的 `CLApps.h`、
  `cl_test_volume_limit`/`cl_test_backup_root`/`cl_test_app_backup_root` 丢了声明——已补。
- 扫描器取消不调 completion：清理页切走再回来会卡在「正在扫描…」。
  改成取消也调 completion（`cancelled=YES`），两页据此复位状态；应用页取消同理（代际 guard）。
- 首页只有三态：补上「受限」（授权探针：后台对自家容器调一次 `cl_grant`）+ 各态跳转规则（见 §4）。
- 清理页 `_cleanRequiresRescan` 死状态：验证失败改为自动重扫，标志删除。
- 首页 `refreshFromStore` 可能在后台线程改 UI：加主线程 hop。

本地已验（Linux，无 Xcode）：`browser_ui_regressions.py` 通过；
`python3 -m unittest discover` 16 个，2 个失败与 v0.1 相同（`test_build` 两个用例缺 `plutil`，
Linux 上本来就跑不了）；`bash -n build.sh` 及各 runner 脚本通过；
结构检查（括号/`@implementation`/`@end`/重复方法）与符号检查（跨文件 static 调用、重复定义）全过。

GitHub Actions 构建：2026-11-10，8 轮修复后通过。
成功运行 42796385987（Xcode 26.6，iOS SDK 26.5），head 294a2b5a527f，
artifact `Cleaner-ipa` 132,764 字节（zip）。下载验证
（`~/workspace/downloads/cleaner-v2-ipa/Cleaner.ipa`，138,209 字节，
SHA-256 e3de9b7bac1ac4258493b7f5ef8e3b65a3db0616ef27325f7e15108697e0cc45）：
Mach-O 64-bit arm64，主二进制 348,848 字节（目标 <500KB ✓），
IPA 138,209 字节（目标 <250KB ✓）；Info.plist：Cleaner /
com.mahiru.cleaner / 0.2.0 / build 1 / MinimumOS 26.0 / zh_CN /
iPhone only / 竖屏；图标只含 iPhone 尺寸（40x40 / 60x60 @2x/@3x），
米色底 #F5F1E8；22 条中文串（缓存清理/已授权/受限/清理缓存/崩溃日志等）
全部在二进制里（UTF-16LE）；build.sh 的签名后校验已确认 entitlements
含 App Group（ad-hoc 签名，用户仍需用保留 App Group 的方式重签）。
8 轮失败的原因全是提取/移植时丢的声明、导入、重复行和可空性标注，
已逐轮修掉并把检查固化进本地脚本（`/tmp/v2_check.py` 结构/符号/导入/
重复行检查、`/tmp/v2_imports.py` 跨文件导入闭包检查）。
真机验证仍未做（见下）。

## 8. v2.1 布局修复（2026-11-10 晚，真机截图反馈）

用户在 iPhone 17 Pro Max / iOS 27.0 上装了 0.2.0（截图
`docs/v2-real-device-home-2026-11-10.jpg`）：功能是通的（已授权、App Group
正常、114 个应用、6.15 GB 可清理），但界面三处翻车，用户原话“界面完全乱飞，
界面真的很丑”，并点名底栏要用 iOS 26 底层的液态玻璃，像 huami GestaltX 那个。

修了什么（版本 0.2.1，build 1 不变）：
1. **底栏（最大问题）：删掉自定义悬浮白底胶囊栏**（`CLTabBarController` 原先
   是 `UIViewController` + 手写白底圆角 view + 手工阴影 + 灰色 pill + 92pt
   `additionalSafeAreaInsets`）。改成标准 `UITabBarController`：4 个 tab 各包
   一个 `UINavigationController`，tint 蓝色——和 GestaltX 的 plain SwiftUI
   `TabView` + `.tint(.blue)` 同一个做法；iOS 26 上系统自动渲染成原生液态玻璃
   底栏（悬浮玻璃 pill、滚动时收缩），不要手写胶囊、不要纯白底、不要手动阴影。
2. **内容被底栏盖住：** 截图里最后一行「支持范围」一半藏在浮动栏后面，
   因为 scroll view 只留了给浮动栏的 -110 底部留白，栏本身又不属于 safe area。
   v2.1 起系统接管 safe-area / content inset：首页 content 底部留白改 -20，
   各页最后一行滚动到底必须完整可见（本地无法截真机图验证，见下）。
3. **绿色对勾圆圈位置：** 截图里它落在绿卡底部中央偏右，跨过卡片下沿，
   压到下面信息卡的顶部。KSU 原版（HomeMiuix.kt）是锚在卡片右下角、
   110pt、往右 +27、往下 +31 溢出——我们的约束本来就是这么写的，出问题的是
   下一行只隔了 12pt，对勾往下溢出 31pt，19pt 直接撞上信息卡。修法：状态行
   之后改 44pt 间距（31 溢出 + 13 空隙），绿卡加最小高度 200pt，
   保证三行文字（约 100pt）和对勾顶部（高 - 79）永不相撞。
4. **绿卡模式行断词：** `<App Group> [沙盒模式]` 在 16pt 下于窄卡里断成
   “[沙盒 / 模式]”。改 15pt、最多 2 行。
5. 其余不变：绿卡 #DFFAE4、对勾 #36D167、信息卡六行、GestaltX 图标语言
   （SF Symbols、黑字形、蓝强调色）、不许 emoji。

本地已验（Linux，无 Xcode）：`browser_ui_regressions.py` 通过（新增断言：
原生 tab bar、禁自定义胶囊栏/手动阴影/手动 safe-area、模式行 15pt/2 行、
44pt 间距、绿卡最小高 200、content 底部 -20、版本 0.2.1）；
`python3 -m unittest discover -s tests -p 'test_*.py'` 16 个，2 个失败与 v2.0
相同（`test_build` 两用例缺 `plutil`，Linux 固有）；`bash -n build.sh` 及
各 runner 通过；`/tmp/v2_check.py` 全过。`/tmp/v2_imports.py` 报 2 项是
误报（`CLLSLayout` 是 CLLaunchServices.m 文件内 typedef，
`CLPrivate` 是 CLUI.m 文件内 category），两文件本次未动，属既有检查器噪声。

GitHub Actions 构建：运行 42798422761，`completed / success`，head
76856a3b8703（Xcode 26.6 / iOS SDK 26.5），一次通过，无需修复轮次。
artifact `Cleaner-ipa`（id 13754232881）130,025 字节（zip）。下载验证
（`~/workspace/downloads/cleaner-v2-1-ipa/Cleaner.ipa`，135,390 字节，
SHA-256 b2dcb322519e7257c8aa7b893e78ca0ffb4392c5c0c1fe9b7b67390e438dc51d）：
Mach-O 64-bit arm64（cputype 0100000c），主二进制 348,912 字节（目标 <500KB ✓），
IPA 135,390 字节（目标 <250KB ✓）；Info.plist：Cleaner /
com.mahiru.cleaner / 0.2.1 / build 1 / MinimumOS 26.0 / zh_CN /
iPhone only；图标只含 iPhone 尺寸；10 条中文串（缓存清理/已授权/受限/
清理缓存/崩溃日志/重新扫描/清理/应用/设置/首页）全部在二进制里（UTF-16LE）；
内嵌 entitlements 含 `application-groups` = `group.com.mahiru.cleaner`
（ad-hoc 签名，无 get-task-allowed；build.sh 在 macOS 上签名后也校验过）。
真机验证仍未做：液态玻璃底栏观感、对勾圆圈位置、最后一行是否完整可见、
扫描/清理/停止后重扫、备份/恢复/清空、首页四态、崩溃日志行——都须用户在
iPhone 17 Pro Max / iOS 27.0 上看截图确认。

## 6. 风险（先说）

- worse_query 是 PoC，不是正式 API：iOS 27.2.1 / 26.7.3 已发，官方没说修没修，
  以后系统升级可能失效，Cleaner 要在首页老实显示“已授权 / 受限”，失效了就明说。
- 清缓存不备份：确认弹窗必须留，误删离线内容（音乐、地图、下载）要重新下载。
- 真机验证只能在你 iPhone 17 / iOS 27.0.1 上做，我这边 Linux 编不出 IPA，
  靠 GitHub Actions 构建，你那边装了试。
