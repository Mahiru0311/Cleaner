//
//  WQUI.h
//  Cleaner shared UI helpers
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

static inline UIBarButtonItemStyle cl_primary_button_style(void)
{
    if (@available(iOS 26.0, *)) return UIBarButtonItemStyleProminent;
    return UIBarButtonItemStylePlain;
}

dispatch_queue_t cl_io(void);
void cl_alert(UIViewController *host, NSString *title, NSString *_Nullable message);
NSString *cl_size_text(unsigned long long size);
UIView *cl_device_header(CGFloat width);
// "iPhone 17 Pro Max (iPhone18,2) · iOS 27.0.1 (24A446)"
NSString *cl_device_line(void);
UIImage *_Nullable cl_app_icon(NSString *_Nullable bundleID);

NS_ASSUME_NONNULL_END
