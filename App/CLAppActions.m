
//
//  CLAppActions.m
//  Cleaner v2.2 — backup / restore / clear flows for one app. Extracted from
//  CLAppsViewController (v2.0) so the Apps list and the directory browser
//  (v2.2) run the exact same flows. The Core work lives in CLApp.m; this
//  file is only the alerts and the queue hops around it.
//

#import "CLAppActions.h"
#import "CLApp.h"
#import "CLGrant.h"
#import "CLUI.h"

@implementation CLAppActions

// Runs the backup; `next` gets YES + the result text (no alert here — the
// caller decides what to show, e.g. the clear flow shows its own result).
+ (void)backupApp:(CLAppItem *)app then:(void (^)(BOOL ok, NSString *message))next
{
    dispatch_async(cl_io(), ^{
        NSString *error = nil;
        NSString *dest = cl_make_app_backup(app.bundleID, app.container, app.containerDevice,
                                             app.containerInode, nil, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (next) {
                next(dest != nil, dest
                     ? [NSString stringWithFormat:@"已保存到 AppBackups/%@/%@", app.bundleID, dest.lastPathComponent]
                     : [NSString stringWithFormat:@"什么都没保存：%@", error ?: @"详见日志"]);
            }
        });
    });
}

+ (void)backupApp:(CLAppItem *)app from:(UIViewController *)host
       completion:(void (^)(void))completion
{
    [self backupApp:app then:^(BOOL ok, NSString *message) {
        cl_alert(host, ok ? @"已备份" : @"备份失败", message);
        if (completion) completion();
    }];
}

// The clear itself lives in Core (cl_clear_app_data): validate the container
// before every part, purge + verify each part, validate again at the end.
+ (void)clearApp:(CLAppItem *)app from:(UIViewController *)host
      completion:(void (^)(void))completion
{
    dispatch_async(cl_io(), ^{
        unsigned long long freed = 0;
        NSString *error = nil;
        BOOL ok = cl_clear_app_data(app, &freed, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            cl_alert(host, ok ? @"数据已清空" : @"部分清空",
                     [NSString stringWithFormat:@"已释放约 %@。%@打开 %@ 重新开始。", cl_size_text(freed),
                      ok ? @"" : [NSString stringWithFormat:@" %@。请保持应用关闭再试一次。", error ?: @"部分项目未能删除（详见日志）"], app.name]);
            if (completion) completion();
        });
    });
}

+ (void)confirmClearApp:(CLAppItem *)app from:(UIViewController *)host
             completion:(void (^)(void))completion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"清空 %@？", app.name]
        message:@"删除该应用 Documents、Library 和 tmp 里的全部内容，如同刚安装。可选备份只包含 Documents 和 Library；tmp 丢弃后无法恢复。登录信息、设置和离线内容都会丢失。请先关闭该应用。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"先备份再清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self backupApp:app then:^(BOOL ok, NSString *__unused message) {
            if (ok) [self clearApp:app from:host completion:completion];
            else {
                cl_alert(host, @"未清空", @"备份未完成，什么都没删。");
                if (completion) completion();
            }
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"直接清空，不备份" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self clearApp:app from:host completion:completion];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

+ (void)confirmRestoreApp:(CLAppItem *)app from:(NSDictionary *)backup
                     host:(UIViewController *)host
               completion:(void (^)(void))completion
{
    NSString *path = backup[@"path"];
    NSString *warning = [backup[@"verified"] boolValue] ? @""
        : [NSString stringWithFormat:@"\n\n该备份未验证（%@）。Cleaner 会在修改前重新检查它的内容。",
           backup[@"reason"] ?: @"没有类型化清单"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"恢复 %@？", app.name]
        message:[NSString stringWithFormat:@"用 %@ 的备份替换该应用当前的 Documents 和 Library；tmp 不动。当前数据会先备份，失败时放回。请先关闭该应用：运行中的应用可能导致操作不一致。%@",
                 cl_backup_label(backup), warning]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        dispatch_async(cl_io(), ^{
            NSString *title = nil, *message = nil;
            cl_restore_app(app, path, &title, &message);
            dispatch_async(dispatch_get_main_queue(), ^{
                cl_alert(host, title, message);
                if (completion) completion();
            });
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

+ (void)restoreApp:(CLAppItem *)app from:(UIViewController *)host
        sourceView:(UIView *)source
        completion:(void (^)(void))completion
{
    NSArray *backups = cl_app_backups(app.bundleID);
    if (!backups.count) {
        cl_alert(host, @"没有备份", @"这个应用还没有备份。先备份一次，才能恢复。");
        return;
    }
    if (backups.count == 1) {
        [self confirmRestoreApp:app from:backups.firstObject host:host completion:completion];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"恢复哪个备份？" message:app.name
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *b in backups) {
        [sheet addAction:[UIAlertAction actionWithTitle:cl_backup_label(b) style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *__unused a) {
            [self confirmRestoreApp:app from:b host:host completion:completion];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: host.view;
    sheet.popoverPresentationController.sourceRect = (source ?: host.view).bounds;
    [host presentViewController:sheet animated:YES completion:nil];
}

@end
