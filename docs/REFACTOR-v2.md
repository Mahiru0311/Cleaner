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
| 文件浏览器、Go to Path、System Groups 浏览 | 没用 | 扔（v2.2 例外：用户点名要“点应用进目录”，只加了一个只读的应用内目录钻取，见 §9；plist/hex 编辑器、分享/ZIP、Go to Path 仍不加） |
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
  - 应用图标（v2.2，Filza 式）：取应用自己的真实图标、全分辨率（60pt 格式 @3x
    = 180px，后台加载也不再错用 2.0 缩放）、按 iOS 连续圆角（squircle，
    `CALayer.cornerCurve = continuous`，半径 22.37%）裁成方形（居中裁切、绝不拉伸），
    兜底的彩色符号 tile 也走同一个圆角。旧做法是固定 40pt 位图 + 普通圆角矩形
    （圆弧不是 squircle）+ 非方形源硬拉成方形，看着又糊又假。清理列表与应用页
    共用 `cl_app_icon`，两处一起改好。注意：iOS 26/27 上私有接口常只给占位图，
    拿不到真图标时仍会回退到应用包内散 PNG 或符号 tile——真机上到底多少行是
    真图标，须用户看截图确认。
  - Cleaner 自己的应用标志：学 GestaltX 极简风但不要抄它的滑块标志——暖米色底 #F5F1E8 上一个
    黑色粗线条垃圾桶/清扫造型，线条同样粗圆；用在设置页关于区和 AppIcon（只留 iPhone 尺寸）。
  - 设置页底部加一行：图标风格参考 huamidev/GestaltX（GPL-3.0）。
  - 也借鉴 Filza（扁平原生风、每种文件配彩色图标）：清理列表每行用真实彩色应用图标。
- **第一页（首页）：按 KernelSU 老版本（v3.2.5，Miuix 风格）首页截图一比一复刻，只改名字**
  （用户 2026-11-10 16:55 发截图说老版本非常好看；截图存为 `docs/kernelsu-old-home-reference.jpg`；
  对应源码 `~/workspace/temporary/KernelSU/manager/.../home/HomeMiuix.kt`；
  之前 Material 版首页方案作废）
  - 背景浅灰；左上超大粗标题「Cleaner」（v2.2：右上角的电源图标删了，它除了
    弹“重新扫描”什么都不干；重新扫描改成下拉刷新）
  - 标题下一行：左侧浅绿大卡 #DFFAE4（圆角约 28，占一半多宽），三行字
    「已授权」「<App Group> [沙盒模式]」「版本：0.2.2」，右下角绿色对勾圆圈
    #36D167、88pt、完全收在卡内（右/下各留 12pt）；
    v2.2 之前是照抄 KSU 的 110dp、往右下溢出 (27dp, 31dp)，但我们的右列
    底部与绿卡底部对齐、列间距只有 13pt，任何 ≥13pt 的右溢出都会撞上白卡，
    而白卡画在上层——v2.1 真机截图里对勾右半边就是这么被「可清理」卡盖掉的。
    v2.1 加的 44pt 下间距只修了纵向碰撞，没修这个横向的。收进卡内后，
    圆圈帧与任何右列卡都不相交（本地测试用布局数学断言了这一点）；
    右侧一列两张白小卡：「应用 / 38」「可清理 / 2.52 GB」（灰色小标签在上，超大黑色粗数字在下）
  - 首页排布（v2.2）：16pt 边距、13pt 卡间距；状态行绿卡与右列等高
    （行高取两者较大值，绿卡最小高 212pt：三行文字约 97pt + 对勾 88pt +
    下留 12pt + 15pt 空隙）；下拉刷新重新扫描（同时重跑授权探针）
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
  - 扫描（v2.2，比原来快三处）：① 4 个 worker 并行量容器（`dispatch_apply(4, …)`
    分片，不是全量并发）；② 增量出结果——每量完 8 个就先把行送出来，列表边扫
    边长，扫完再以完整排序列表为准；③ 持久测量缓存（`cl-cache-measure.plist`，
    24 小时）：容器身份 + 两目录的 (mtime, size) 没变就不重走整棵树；只缓存
    两边都量成功的，量受限的下次重测。另：一次祖先检查同时验容器 + 两个目标
    （原来每个目标各走一遍祖先），量大小的探查从整层 readdir 换成一次 open()。
    缓存安全校验一点没动，清理前照样全量重验。真机上到底快几秒 Linux 测不出，
    须用户在手机上看。
  - 列表行从左到右：24pt 选中圆圈（checkmark.circle.fill 蓝 / circle 灰）、36pt 真实应用图标（见下）、
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
  App/            新 UI：CLHome（四态 + 探针）, CLCleaner（状态机）, CLApps（应用列表）,
                  CLAppDirectory（v2.2：点应用进目录，只读钻取）, CLAppActions（v2.2：
                  备份/恢复/清空流程，应用页与目录页共用）,
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
v2.1 后新代码共 6,908 行：Core 4,675、App 2,233（底栏 164→52 行——删掉手写胶囊栏，
首页 521→536 行——加了 44pt 间距与绿卡最小高 200，应用 465→466 行）。
v2.2 后新代码共 7,659 行：Core 4,952、App 2,707（新增目录浏览器 317 行 +
备份/恢复/清空共享流程 137 行；扫描器并行化 + 测量缓存 + 图标重写占其余）。
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

## 9. v2.2（2026-11-10 晚，v2.1 真机截图反馈）

用户在 iPhone 17 Pro Max / iOS 27.0 上装了 0.2.1（截图
`docs/v2-1-real-device-home-2026-11-10.jpg`，18:42，114 个应用、5.95 GB）：
底栏（原生液态玻璃）没再被抱怨，功能正常；但提了 5 件事（版本 0.2.2，build 1 不变）。

1. **对勾圆圈还在飘。** v2.1 的修法只对了一半：截图里圆圈落在绿卡右下角，
   右半边被白色的「可清理」卡盖住了。根因是横向碰撞，不是纵向的——绿卡与
   右列底部对齐，列间距 13pt，KSU 的 +27 右溢出必然撞上白卡，而白卡画在
   上层。v2.1 加的 44pt 下间距只修了与信息卡的纵向碰撞。修法（不再照抄
   KSU 的溢出）：圆圈改 88pt，完全收进绿卡右下角（右/下各留 12pt），
   不再溢出任何一边；绿卡最小高改 212pt（三行文字约 97pt + 对勾 88pt +
   下留 12pt + 15pt 空隙）；状态行下间距改回标准 13pt；圆圈再
   `bringSubviewToFront` 一次。本地测试用布局数学断言：对任意行宽，圆圈帧
   严格在绿卡内、与右列卡不相交。为什么不选“绿卡加高 40pt 让溢出落在空
   地上”：圆圈顶部在绿卡底线上方 79pt，白卡底边只比绿卡底边高 40pt，
   两者仍有 15×39pt 的重叠——要完全不相交绿卡得比右列高 79pt 以上，太难看。
2. **右上角电源键删了。** 它在 KernelSU 里是快捷入口，在我们这除了弹
   “重新扫描”什么都不干。删掉后首页只剩大标题「Cleaner」左对齐；重新
   扫描改成首页下拉刷新（同时重跑授权探针）。顺带修了一个潜伏 bug：
   `invalidateScan` 从不重置 `lastScanFinished`，首页 `ensureScan` 会在
   任何一次扫描完成后直接返回——旧电源键的“重新扫描”在扫过一次后其实
   是空操作。v2.2 起 `invalidateScan` 把上次扫描标为过期（进行中的扫描
   仍由 `scanning` 标志挡住，不会重复开扫）。
3. **清理页扫描加快。** 四点：① 4 个 worker 并行量容器（`dispatch_apply(4, …)`
   分片，`cl_grant` 带锁、名字查询带锁、安全检查是纯 stat 调用、测量缓存
   只读 + 入库加锁，并行安全）；② 增量出结果，每量完 8 个先把行送出来，
   列表边扫边长；③ 持久测量缓存（`cl-cache-measure.plist`，24 小时），
   容器身份 + 两目录 (mtime, size) 没变就不重走整棵树，只缓存两边都量成功
   的；④ 精简 stat：容器 + 两个目标一次祖先检查（原来 3 遍），量大小的
   探查从整层 readdir 换成一次 `open()`，目标记录复用扫描时已取的 stat。
   缓存安全校验一点没动，清理前照样全量重验。真机上到底快几秒 Linux
   测不出，须用户在手机上看。
4. **应用图标按 Filza 重做。** 查到的三处毛病：① 后台加载图标时拿不到
   前景 scene 的缩放，错用 2.0（3x 机上只要到 120px 的图）；② 圆角是
   固定 40pt 位图 + 普通圆角矩形（圆弧不是 iOS 的 squircle），非方形源
   还被硬拉成方形；③ 图层没设 `contentsScale` 的话 3x 上下文里会按 1x
   渲染发糊。修法：设备缩放缓存一次、默认 3.0；私有接口格式 2/3/1/0/4
   按大小试到有真图为止；按原图分辨率居中裁方（绝不拉伸），用
   `CALayer.cornerCurve = continuous`、半径 22.37% 做 iOS 同款 squircle；
   兜底彩色符号 tile 也走同一个圆角。清理列表与应用页共用 `cl_app_icon`，
   两处一起改好。注意：iOS 26/27 上私有接口常只给占位图，拿不到真图标时
   仍回退到包内散 PNG 或符号 tile——真机上到底多少行是真图标，须用户
   看截图确认。
5. **应用页点按直接进目录。** 原流程是点应用 → 弹出备份/恢复/清空表，
   目录要按了备份才出现。v2.2 改成：点应用直接 push 进该应用的容器目录
   （新 `CLAppDirectoryViewController`：文件夹点进去继续钻取，文件点按
   只看详情，符号链接不跟随；根目录导航栏放备份 + 更多菜单里的恢复/清空）。
   备份/恢复/清空流程抽成 `CLAppActions`，应用页与目录页共用同一份。
   这是 v2“扔掉文件浏览器”的决定被用户明确推翻的一部分——只限这一个
   只读钻取：不加 plist/hex 编辑器、分享/ZIP、Go to Path。目录页每次列
   目录前验 containment（规范路径必须在容器内）+ 无符号链接祖先。

本地已验（Linux，无 Xcode）：`browser_ui_regressions.py` 通过（新增断言：
无电源键、下拉刷新、圆圈 88pt/内收 12pt、布局数学不相交、连续圆角
22.37%/contentsScale/多格式、4 worker/增量批次/测量缓存/合并安全检查、
点应用 push 目录页、目录页 containment、版本 0.2.2）；
`python3 -m unittest discover -s tests -p 'test_*.py'` 16 个，2 个失败与
v2.0/v2.1 相同（`test_build` 两用例缺 `plutil`，Linux 固有）；`bash -n build.sh`
及各 runner 通过；`/tmp/v2_check.py` 结构/符号/导入/重复行检查通过。
macOS runner 上 16 个 unittest 全过（有 plutil）。

构建第一轮失败：Actions run 42803714335，completed/failure。`UIAction`
没有 `actionWithTitle:image:attributes:handler:`，iOS 语法检查在
`CLAppDirectoryViewController.m` 两处清空动作都报错。修在 commit
5b5bd5a：改用 `actionWithTitle:image:identifier:handler:`，事后设
`.attributes = UIMenuElementAttributesDestructive`；顺手把两处重复的
清空动作合并成一个。

构建第二轮成功：Actions run **42803963489**，completed/success（Xcode 26.6 /
iOS SDK 26.5）。本地 d0316ac（v2.2）+ 5b5bd5a（UIAction 修复）→ 远程
ed13b65 → 140f7977，`refactor/v2`，两次推送 tree SHA 与本地逐字节一致。
IPA：`~/workspace/downloads/cleaner-v2-2-ipa/Cleaner.ipa`，**145,122 字节**
（目标 <250KB ✓），主二进制 **382,176 字节**（目标 <500KB ✓；比 v2.1
的 348,912 大——目录浏览器 + 扫描缓存），SHA-256
**6f2f663df7dafbac13aa7104ce7e9928cfc07671f4a7c8ab196015473c439e0c**，
Mach-O 64-bit arm64，Info.plist Cleaner / com.mahiru.cleaner / 0.2.2 /
build 1 / MinimumOS 26.0 / zh_CN / 仅 iPhone（UIDeviceFamily [1]）。
二进制含中文串（UTF-16LE，如 不保留备份 / 丢弃后无法恢复）；
App Group `group.com.mahiru.cleaner` 在 entitlements.plist，build.sh
PlistBuddy 检查 OK，签名用了 `--entitlements entitlements.plist`。
已发给用户（ad-hoc 签名——重签时保留 App Group）。
真机验证仍未做：对勾圆圈位置、电源键已删、扫描到底快几秒、图标观感
（多少行是真图标）、目录钻取与目录内备份/恢复/清空——都须用户在
iPhone 17 Pro Max / iOS 27.0 上装 0.2.2 后看截图确认。

## 6. 风险（先说）

- worse_query 是 PoC，不是正式 API：iOS 27.2.1 / 26.7.3 已发，官方没说修没修，
  以后系统升级可能失效，Cleaner 要在首页老实显示“已授权 / 受限”，失效了就明说。
- 清缓存不备份：确认弹窗必须留，误删离线内容（音乐、地图、下载）要重新下载。
- 真机验证只能在你 iPhone 17 / iOS 27.0.1 上做，我这边 Linux 编不出 IPA，
  靠 GitHub Actions 构建，你那边装了试。

## 10. v2.3（2026-11-10 晚，v2.2 真机截图反馈 + GitHub 研究）

用户在 iPhone 17 Pro Max / iOS 27.0 上装了 0.2.2（截图
`docs/v2-2-real-device-home-2026-11-10.jpg`，19:10，清理后应用 0 /
可清理 0 KB），提了 7 件事（版本 0.2.3，build 1 不变）。本轮先做 Phase 0
GitHub 研究（`docs/GITHUB-RESEARCH-v2.3.md`），再动手。

### Phase 0 研究（先做，写进文档，再指导实现）

- **YangJiiii/3105（GPL-3.0，Swift/SwiftUI，982★）**：唯一另一个不用
  越狱的清理器。借到两样东西：① fd 遍历（`open`/`openat`/`fstatat`
  `AT_SYMLINK_NOFOLLOW`/`fdopendir`/`unlinkat`，永不跟随链接——没有
  TOCTOU 窗口，比 WQFiles 的路径字符串检查严格；Swift 代码不移植，
  按思路用 C 重写）；② 清理前后重扫记账（`freed = 清理前 − 清理后`，
  删成功/失败的条数）。不借它的容器访问（MobileHouseArrest + 固定
  bundle ID + iOS 17/18 内核漏洞，要企业证书）。
- **Erosion（GPL-3.0，666★）**：worse_query 的定制工具箱（MobileGestalt
  改机型、壁纸、拨号盘），没有清理逻辑——只确认 worse_query 支持
  iOS 27.0–27.2.1、27.3b1。
- **WQFiles 32 个 fork**：全是原样复制，无功能 fork（项目才 2 天）。
  worse_query：394★ / 75 fork，GPL-3.0。
- **iCleaner**：越狱（root）专用，出局；**iOS Clean Pro**：
  TrollStore 专用、iOS 14–17.0，出局；**Sweeply**：macOS 清理器，
  MIT，只有分类思路可借；**FilzaJailedDS / MobileHouseArrest-PoC**：
  漏洞 PoC，不是清理器，出局。
- **各应用缓存子路径**：没有权威的开源清单（微信/QQ/抖音/B站/小红书
  都搜过）。唯一可移植的模型是 Apple 的目录语义：`Library/Caches` +
  `tmp` = 可丢弃/可再生（不备份，系统可清），随便删；`Documents` +
  `Library/Application Support` = 用户数据（备份，系统不自动删），
  默认绝不碰。所以“更强”来自 fd 遍历 + 更细的分类 + 自定义规则，
  不是抄一张路径表。
- 许可证：Cleaner 已是 GPL-3.0（与 WQFiles / worse_query / 3105 一致），
  借思路不产生新的许可证义务；来源记在 §10 与 Settings 的来源行。

### 首页方向三改（19:17 → 19:20 → 19:28，最终以最后一条为准）

- 19:17 用户说“上面直接是一个长方形”：改跟 KernelSU 最新版
  `HomeMaterial.kt` 的通栏 StatusCard（单张通栏卡、左对勾、中标题、
  右蓝 pill，两张白卡删掉）。已按这条改了一版。
- 19:20 用户说“算了，你还是改成之前那种吧，这种真的很丑……不按它的
  颜色了和样子，就是只参考参照物”：改回分栏，但状态卡改白色、标题黑、
  副标题灰、对勾实心 #34C759 + 白色粗对勾、KSU 只作参照。已按这条
  改了一版。
- 19:28 用户说“白色版太丑，改回和 KernelSU 一模一样的”：**最终方向是
  KSU 老版首页 1:1**，上面两条作废。实现按参照图
  `docs/kernelsu-old-home-reference.jpg` 与 `HomeMiuix.kt` 源码核对过：
  浅绿卡 #DFFAE4（已授权 / `<App Group> [沙盒模式]` / 版本：0.2.3，
  标题 22pt semibold、版本 15pt）、右侧两张白卡（应用 / 可清理）、
  对勾是 `Icons.Rounded.CheckCircleOutline`——**空心粗环 + 粗对勾**，
  #36D167、110pt、锚在绿卡右下角向外溢出（+27 右 / +31 下）。对勾是手画
  的 `CLCheckBadgeView`（SF Symbol 的 checkmark.circle 环太细），
  环与对勾各 ~12pt 粗，环内是绿卡底色。
- 溢出能成立的条件（v2.2 §9 里明确拒绝过的“绿卡加高”方案，用户两次
  推翻了这个判断——现在绿卡就是比右列高）：状态行用
  `UIStackViewAlignmentTop`（KSU 的 Row 默认顶对齐），右列不被拉伸；
  绿卡高 = 右列高 + 90pt；对勾顶部在绿卡底线上方 79pt，右列底边在
  绿卡底线上方 90pt——对勾与白卡之间留 11pt 空隙；行下间距 44pt，
  对勾向下溢出 31pt 后离信息卡还有 13pt。本地测试用布局数学断言这
  两个间隙（`browser_ui_regressions.py`），改回 Fill 对齐或改小高差
  都会失败。v2.1 的教训：只修纵向（44pt）不够，横向碰撞才是根因。
- 四态保留：已授权是上面这套绿卡 + 空心绿对勾；受限/未授权/不支持仍
  是 v2 的琥珀/红/灰卡 + 卡内 88pt SF Symbol 图标（不溢出）。

### 其余 6 项

1. **应用图标黑白风。** v2.2 的彩色符号兜底（按 bundle ID 关键词挑
   颜色 + 符号）用户说“真的很丑”，已删（`cl_service_tile` 整个删掉）。
   新规则：只有确认为高清真图标才显示真图标，否则一律中性 tile——
   应用名首字、黑色、米色 #F5F1E8（与应用 mark 同色）、连续 squircle
   （22.37%），清理列表（36pt）与应用页共用 `cl_app_icon`，两处一致。
   彩色符号块全项目已禁（测试断言）。
2. **删机型编号。** 清理页与应用页搜索栏下的
   `cl_device_header`（“iPhone 17 Pro Max (iPhone18,2) · iOS …”）整
   条删掉；`cl_device_line` 只留给日志页页眉。顺带修了一个真 bug：
   首页 `cl_device_model` 的 iPhone18,x 映射是错的（18,1→iPhone 17、
   18,2→iPhone 17 Pro、18,3→iPhone 17 Pro Max），已按 Apple 设备码
   核对改过来（18,1=17 Pro、18,2=17 Pro Max、18,3=17、18,4=Air、
   18,5=17e）。注意：用户手机报的是 iPhone18,3，所以信息卡的设备型
   号从 0.2.3 起会显示 **iPhone 17**，不再是之前错误映射给出的
   “iPhone 17 Pro Max”——不是改错了，是之前显示错了。
3. **应用数清理后变 0 的 bug。** 根因：`scanOneContainer` 对缓存 +
   临时 < 64KB 的应用不返回行，`CLCacheStore.appCount` 数的是行数；
   清理后所有应用都 ~0 字节，重扫后一行不剩，应用数变成 0。修法：
   扫描器数所有量过的容器（`ctx.totalContainers`，含 <64KB 的），
   经 completion 传给 store 的 `totalAppCount`；首页应用数改读
   `totalAppCount`，与缓存大小无关；清理列表仍不显示 <64KB 的行。
   回归测试：`tests/CLCustomCleanTests.m` 里清完后
   `totalAppCount` 仍是 114、`appCount` 0、`totalBytes` 0。
4. **iPhone 快捷指令（无服务器）。** URL scheme `cleaner://clean` 与
   `cleaner://scan`：`CFBundleURLTypes` 注册在 Info.plist，
   `CLSceneDelegate` 的 `scene:openURLContexts:`（含冷启动的
   `connectionOptions.URLContexts`）交给 `CLTabBarController` 的
   `handleShortcutURL:`，跳清理页后调 `startShortcutAction:`；clean
   会全选可清理行并**照常弹确认框**（快捷指令不经确认不删东西），
   扫描进行中触发则等扫描结束再跑。设置页新增「快捷指令」区：2 步
   指南（新建快捷指令 → 打开 URL → `cleaner://clean`）与复制链接两行。
   **App Intents 没做**：intent 跑在独立的扩展进程里，App Group 沙盒
   授权签发在主应用进程内——不打开应用直接清理需要新 extension
   target + 未验证的授权流程，老实说做不到，先给 URL scheme。
5. **WQFiles 清理全移植 + 更强 + 自定义清理。** 原项目功能已在 v2/v2.2
   齐了（每应用 Caches + tmp、崩溃日志、备份/恢复/清空、目录钻取），
   本轮补齐最后一块并加强：① **fd 测量**：`cl_measure_tree` 从
   NSFileManager 路径枚举改成 fd 遍历（`fstatat
   AT_SYMLINK_NOFOLLOW` + `fdopendir` + `openat O_NOFOLLOW`，3105 的
   思路，C 重写）——路径字符串走查可能钻进符号链接目录导致多算，
   fd 走查没有这个窗口；清理本身 v2 起已是 fd 的（`cl_purge_fd`）。
   ② **Caches 子目录拆分**：扫描时量 Caches 的前 5 大一级子目录
   （`cl_measure_tree_subdirs`，结果进测量缓存），目录页在
   `Library/Caches` 下直接显示文件夹大小，不再只显示项数。
   ③ **目录页左滑清文件夹**：`cl_purge_folder_contents`（只清内容、
   文件夹保留；容器本身与容器外拒绝；Documents/Library 子文件夹
   多一句用户数据警告；整应用清空仍走根目录先备份的「清空数据」）。
   ④ **自定义清理**（新 `Core/CLCustomClean.*` +
   `App/CLCustomCleanViewController`，入口在清理页「选择」菜单）：
   规则 = 应用（或全部）+ 文件夹相对路径 / 扩展名 / 文件名包含；
   4 个预设（视频缓存 .mp4/.mov/.m3u8/.ts、图片缓存
   .jpg/.jpeg/.png/.webp/.heic/.gif、日志 .log/.txt、临时文件 tmp）；
   排除列表（应用、文件夹，任何规则都不碰）；文件夹规则禁容器根、
   Documents、Library 本身；扩展名/文件名规则只碰 Library/Caches +
   tmp（`cl_clean_matching_files` 强制）；执行在后台队列，逐规则报
   进度，结果给释放字节 + 失败数 + 非缓存目标警告。⑤ **清理前后记账**
   （3105 的思路）：每应用记清理前 − 清理后（`freed` 按应用写日志），
   清理完重扫核对。
6. **动画重做。** 全部用系统动画（UIView spring / CADisplayLink），
   不再手写 spinner：① 扫描增量行改 `insertRows` 淡入（搜索时回退
   reloadData；表头计数手动刷新）；② 扫描进度条读真实进度
   （`正在测量应用 23/114…` 解析成 N/M）；③ 清理时当前行在对勾位
   置转 spinner、清完的行变绿对勾；④ 大总数用 CADisplayLink 在
   0.4 秒内按实际释放量倒数（ease-out）；⑤ 清完且重扫结束后，摘要
   卡里绿对勾弹簧放大（damping 0.6）+ 成功震动
   （`UINotificationFeedbackGenerator`）。主线程从不阻塞：量、清、
   自定义清理全在后台队列，主线程只更新 UI。

本地已验（Linux，无 Xcode）：`browser_ui_regressions.py` 通过（新增断言：
KSU 1:1 对勾 110pt/+27/+31/顶对齐/+90/44pt 间隙与布局数学、黑白图标
首字 tile、无机型编号条、正确 18,x 映射、应用数清后不变、fd 遍历与
子目录拆分、目录页左滑清文件夹、自定义清理、cleaner:// scheme、
动画钩子、版本 0.2.3）；
`python3 -m unittest discover -s tests -p 'test_*.py'` 16 个，2 个失败与
v2.0–v2.2 相同（`test_build` 两用例缺 `plutil`，Linux 固有）；`bash -n
build.sh` 及各 runner 通过。macOS runner 上 16 个 unittest 全过（有
plutil），另有 ObjC 套件 9 个（含新增 `CLCustomCleanTests`：文件夹
规则校验、扩展名/文件名只碰 Caches+tmp、排除生效、按文件夹清理、
子目录拆分、应用数清后不变）。

构建第一轮成功：Actions run **42809329899**，completed/success（Xcode 26.6 /
iOS SDK 26.5），一次过。本地 4ef012f（Core）+ 9bd1c36（App）→ 远程
dc765f0d → b3be1840，`refactor/v2`，两次推送 tree SHA 与本地逐字节一致。
IPA（第一轮）：`~/workspace/downloads/cleaner-v2-3-ipa/Cleaner.ipa`，
**163,190 字节**（目标 <250KB ✓），主二进制 **432,448 字节**（目标
<500KB ✓；比 v2.2 的 382,176 大——自定义清理 + 动画 + fd 测量），
SHA-256 a21d6cc3fbaf47b1dc1d4f71a4944c7cb5ce1089749966e97a8ac5347a25fe4b。

构建第二轮（开关 tag 修补）：本地 f5572f1 → 远程 ff9c7f17，tree SHA
逐字节一致；Actions run **42809580201**，completed/success，一次过。
**最终 IPA**：`~/workspace/downloads/cleaner-v2-3-ipa/Cleaner.ipa`，
**163,268 字节**，SHA-256
**ecdea1510839c2e34af99714fe15d444f9f8eead39ba0a79c27e01d539b02afc**，
Mach-O 64-bit arm64，Info.plist Cleaner / com.mahiru.cleaner / 0.2.3 /
build 1 / MinimumOS 26.0 / zh_CN / 仅 iPhone（UIDeviceFamily [1]）。
二进制含中文串（UTF-16LE，如 已授权 / 可清理 / 自定义清理 /
快捷指令 / cleaner://clean）；URL scheme `cleaner://` 已注册在
Info.plist；App Group `group.com.mahiru.cleaner` 在二进制内，build.sh
PlistBuddy 检查 OK，签名用了 `--entitlements entitlements.plist`。
已发给用户（ad-hoc 签名——重签时保留 App Group）。
真机验证仍未做：对勾位置（空心环是否落在空白处）、图标观感（多少行
是真图标、首字 tile 是否顺眼）、应用数清理后是否仍是 114、快捷指令
调用、自定义清理流程、动画（倒数、弹簧对勾、震动）——都须用户在
iPhone 17 / iOS 27.0 上装 0.2.3 后看截图确认。另：设备型号行会从
“iPhone 17 Pro Max”变成“iPhone 17”（映射修正，见上）。

## 11. v2.4（2026-11-10 晚，v2.3 真机截图反馈：绿板子 + 1226 + 后台快捷指令 + 规则细化）

用户 2026-11-10 19:50 反馈（截图 docs/v2-3-real-device-home-2026-11-10.jpg）：
「你看这样哪里好看了啊？这里长出来这么多」（绿卡是高出一大截的空板子）；
「我说的快捷方式是不需要打开应用，直接点击快捷方式，它就会自动清理，我的意思是在后台」；
「规则还得细心一点，逻辑也得增强，继续优化修改」。
另：截图上应用数显示 1226（错误，应为 114）。
20:00 用户又指出对勾做法的根本问题（Muse 已核对 KernelSU 源码 + 原图裁剪放大确认，
见下），取代了原计划的「绿卡 +90pt + 完整圆环溢出」方案。

1. **首页对勾：裁剪，不是溢出。** KSU 的 ✅ 并不是一个完整的圆圈。
   HomeMiuix.kt（本地 clone：manager/app/src/main/java/me/weishu/kernelsu/ui/screen/home/HomeMiuix.kt，
   StatusCard）确实是 Icons.Rounded.CheckCircleOutline、110dp、offset(+27dp, +31dp)、tint #36D167——
   但关键是：那个图标放在 Card 里面，而 Card 会裁剪内容，所以圆环超出卡片底边和右边的部分根本不画出来。
   原图放大看得很清楚：圆环在左、上是完整的，到右下角被卡片的右边缘和底边缘齐齐切断，只剩约四分之三的弧 +
   里面的对勾。Muse 用像素核对过：圆环底部弧线在 x340–420、y1030–1057 区域是 0 像素（左侧对照 145），
   而左、上侧完整——确实被切断了。我们 v2.0–v2.3 的 CLCheckBadgeView 是反的：画了一个完整圆环，而且
   status 卡 clipsToBounds = NO，让整个圆吊在卡片外面——这就是它一直看着飘、看着假的原因。
   改法：状态卡 clipsToBounds = YES，对勾保持 110pt、+27/+31 偏移，卡片会像 KSU 一样把圆环切断。
   由此 90pt 加高不再需要——裁剪后对勾不可能碰到白卡。绿卡高度按实测的 KSU 比例：绿卡高 ≈ 右列总高
   （约 1:1；实测：KSU 原图 1206×2680，绿卡 x 40–583、y 约 480–1058，高 ≈578；右列 x 619–1168、
   y 482–1056，高 ≈574；比值 ≈1.007；绿卡宽 543、右列宽 549，约 50/50；圆环 bbox x 213–582、
   y 697–1055）。实现：绿卡宽改为 row 的 0.48（原 0.55），高改为 = 右列高（删 +90 与 212pt 下限），
   行下间距 44pt 改回 13pt。v2.3 截图实测的板子：绿卡高 ≈312pt、右列 ≈193pt，比值 ≈1.6——
   +90 是板子的根因。「高出一截的空绿板子」连根拔掉。测试断言相应改：状态卡 clipsToBounds 为真；
   绿卡高与右列总高比值约 1:1；对勾 frame 超出卡片边界（+27/+31，证明裁剪确实在切它）；其他三态的
   88pt 卡内图标不受影响。
2. **应用数 1226 修回 114。** 根因：v2.3 的 totalAppCount 数的是 CONTAINERS——扫描器数了
   Application 根下的 114 个应用容器 + PluginKitPlugin 根下的约 1112 个扩展容器（每个应用有好几个
   容器/插件/扩展），合计 1226。修法：扫描器新增 ctx.totalAppContainers，只在 Application 根下计数
   （一个容器 = 一个应用），completion 传它；totalContainers 仍保留（进度条用）。首页读 totalAppCount
   不变，清理后仍是 114（枚举与缓存大小无关）。回归测试：tests/CLCustomCleanTests.m 里清完后
   totalAppCount 仍是 114（注释已改：是应用数，不是容器数）。
3. **后台快捷指令：App Intent 在主应用内，不开扩展。** v2.3 的 cleaner://clean（打开应用 + 弹确认框）
   不满足「不需要打开应用，直接点击快捷方式，它就会自动清理，我的意思是在后台」——不再把它当作解法，
   只留作备用。实现方式**与原计划不同，原计划是新建 App Intents 扩展 target**；动手前核对了两件事，
   改成了更稳的方案，理由记在这里：
   - 现代 App Intents 扩展是 ExtensionKit 形态（`@main struct : AppIntentsExtension`、
     Info.plist 用 `EXAppExtensionAttributes` → `EXExtensionPointIdentifier`、装进 `Extensions/` 目录），
     不是老式的 NSExtension/PlugIns——老形态会被系统静默忽略；而且从无 .xcodeproj 的 clang CLI 构建
     里拼一个 ExtensionKit 扩展，包结构和入口点都无法在本地验证。
   - 三个独立来源（jot-mobile 的 shortcuts 研究、playola 的设计文档、IntentTodo 的执行过程技能，
     均引 WWDC 2026-345）确认：plain `AppIntent` 编译进**主应用 target**、`openAppWhenRun = false`
     时，iOS 会无头启动应用进程（不建 scene）、在进程内跑 perform()、把结果返回快捷指令——用户看不到
     应用打开。App Intents 扩展不是必需的；WWDC 2026 的建议是把会写数据的 intent 钉在主应用进程
     （`allowedExecutionTargets = [.main]`，本次没加——包里没有扩展，系统只能选主应用；且该 API 的
     SDK 可用版本未经核对，不赌）。
   - 决定性好处：intent 跑在**主应用进程里**，沙盒授权就是 v2/v2.3 已在真机上验证过的同一条路，
     「扩展进程里授权能不能签发」这个未验证问题直接消失；测量的 24h 缓存和自定义规则 plist 也不用搬去
     App Group（同一进程，目录相同）。
   实现：新文件 Intents/CleanerIntents.swift（`CleanCacheIntent: AppIntent`，标题「清理全部缓存」，
   `openAppWhenRun = false`；`CleanerShortcuts: AppShortcutsProvider` 预置一条快捷指令，出现在快捷指令
   应用里，可绑操作按钮）+ Intents/CleanerIntents-Bridging-Header.h；新 Core/CLBackgroundClean.*
   （`CLBackgroundCleanRun(25)`：同步跑默认清理——扫描（走 24h 缓存）+ 逐应用先 CLCacheValidateItem
   再清 Library/Caches + tmp + 已启用的自定义规则；不含崩溃日志；25 秒预算——快捷指令约 30 秒执行上限，
   超时就停开新应用并如实报部分进度 partial=YES、appsRemaining>0；结果含 freed/customFreed/failed/
   appsCleaned/appsSkipped/appsRemaining/appsTotal/partial/timedOut/duration）。
   build.sh：先 swiftc 编译 Swift（-swift-version 5，生成 CleanerIntents-Swift.h），再把对象文件链进主
   二进制（+ `-framework AppIntents`，+ Core/CLBackgroundClean.m）；main.m 调
   `[CLIntentsBootstrap keepAlive]`（Swift 侧的 @objc 类，引用两个 intent 类型，防止 -dead_strip 把它们
   链掉——系统靠扫描二进制发现 intent，无引用会被静默删掉）；build.sh 校验二进制链接 AppIntents 且仍含
   CleanCacheIntent / CleanerShortcuts。设置页文案改成后台清理为主、URL scheme 为备用。
   **仍须用户在真机上验证**：快捷指令里能否看到「清理全部缓存」；点一下是否不打开应用就清理、返回释放了多少；
   25 秒预算够不够一次清完（不够会报部分完成，再跑一次即可——缓存已热、已清的应用量出来 ~0）。
4. **自定义清理：规则更细 + 逻辑更硬。** 规则新增 4 个可选筛选（仅扩展名/文件名规则可用；
   文件夹规则整文件夹清，不支持这些筛选，校验会拒绝而不是静默忽略）：
   (a) 年龄——只删 N 天前的文件（minAgeDays，0–3650 天）；
   (b) 大小——只删大于 X / 小于 Y 的文件（minSize/maxSize，单位字节，UI 里填 KB，上限 1TB，min≤max）；
   (c) 子目录——规则只在某个子目录下生效（subfolder，如 Library/Caches/com.foo；裸名视为
   Library/Caches 下的子目录；只能在 Library/Caches 或 tmp 之下）；
   (d) **试运行预览**——执行前先算匹配文件数 + 总字节 + 前 50 个样例路径，确认后再清理（点一条规则 →
   「预览匹配」→ 弹框显示「会删 N 个文件，共 X，涉及 M 个应用」+ 前 10 个样例 → 「清理这些文件」；
   另有单条执行 cl_custom_clean_run_one_rule）。
   (e) 规则校验——cl_custom_clean_validate_rule：类型/内容/年龄/大小/子目录全量校验，无效规则跳过并上报、
   永不执行（旧的 folder pattern 校验保留）。
   (f) 引擎加固——删除前立即重验容器身份（fd 遍历里每次 unlink 前 lstat 容器比对 dev/ino，变了就停）；
   逐项记账（freed / failed / skipped / matched / matchedBytes，skipped = 匹配了模式但被年龄/大小筛掉的）；
   部分失败上报（failed + reason）；幂等重跑（第二次 freed 0、无错误）；中断安全（取消只停在应用之间，
   删是逐文件 unlinkat，没有半删状态，下一跑接着清；新 cl_custom_clean_run_with_cancellation）。
   UI：加规则时扩展名/文件名会多一步「筛选（可选）」（年龄天数、最小 KB、最大 KB、子目录，留空=不过滤，
   「跳过」= 不筛选）；规则行点开有预览/启用停用/删除；规则摘要里显示筛选（如「· 30天前 · >1MB ·
   于 Library/Caches/xxx」）；运行结果里报跳过数。

本地已验（Linux，无 Xcode）：`browser_ui_regressions.py` 通过（新增断言：首页裁剪（clipsToBounds 真、
绿卡=右列高、0.48 宽、对勾 +27/+31 超出卡片、行下间距 13）、应用数只计 Application 容器、
主应用内 App Intent（无 appex/PlugIns、swiftc + AppIntents 链接、keepAlive、25 秒预算）、
规则筛选 + 试运行 + 校验 + 引擎记账、版本 0.2.4）；
`python3 -m unittest discover -s tests -p 'test_*.py'` 16 个，2 个失败与 v2.0–v2.3 相同
（`test_build` 两用例缺 `plutil`，Linux 固有）；`bash -n build.sh` 及各 runner 通过。
macOS runner 上 16 个 unittest 应全过（有 plutil），另有 ObjC 套件（含新增
`CLCustomCleanTests`：规则校验、年龄/大小/子目录筛选、试运行数学与实际一致、幂等重跑、
中断安全（预取消 + 中途取消 2000 文件）、试运行预览 + 单条执行）。
