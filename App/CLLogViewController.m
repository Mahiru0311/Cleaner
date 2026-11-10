//
//  CLLogViewController.m
//  Cleaner v2 — read-only log view, adapted from v0.1 main.m's log VC.
//  No share button: sharing was dropped in the v2 refactor.
//

#import "CLLogViewController.h"
#import "CLGrant.h"
#import "CLUI.h"

@interface CLLogViewController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation CLLogViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"日志";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    [self.view addSubview:textView];
    self.textView = textView;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.2.1";
    NSString *build = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"1";
    NSString *header = [NSString stringWithFormat:@"Cleaner %@ (%@)\n%@\n\n", version, build, cl_device_line()];
    self.textView.text = [header stringByAppendingString:cl_log_text()];
}

@end
