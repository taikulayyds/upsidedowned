#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface SBApplicationInfo : NSObject
@property(nonatomic, readonly) UIInterfaceOrientationMask supportedInterfaceOrientations;
@property(nonatomic, readonly) NSString *bundleIdentifier;
@end
@interface SBApplication : NSObject
@property(nonatomic, readonly) SBApplicationInfo *info;
@end

// Test B: no UIDevice idiom override and no _orientationMode hook.
%hook SBTraitsSceneParticipantDelegate
- (BOOL)_isAllowedToHavePortraitUpsideDown {
    return YES;
}
%end

%hook SpringBoard
- (NSInteger)homeScreenRotationStyle { return 1; }
%end

// Keep the landscape-App safeguard. The only extra YES is for the
// SpringBoard descriptor itself; do not make every third-party app Medusa.
%hook SBApplication
- (BOOL)isMedusaCapable {
    SBApplicationInfo *info = [self respondsToSelector:@selector(info)] ? self.info : nil;
    NSString *bid = [info respondsToSelector:@selector(bundleIdentifier)] ? info.bundleIdentifier : nil;
    if ([bid isEqualToString:@"com.apple.springboard"])
        return YES;
    if (!info || ![info respondsToSelector:@selector(supportedInterfaceOrientations)])
        return %orig;
    UIInterfaceOrientationMask m = info.supportedInterfaceOrientations;
    if (m == 0) return %orig;
    return (m & UIInterfaceOrientationMaskPortrait) != 0;
}
%end

%hook SBHomeScreenViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // Home Screen only: allow portrait and upside-down, exclude landscape.
    return UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown;
}
%end
%hook SBCoverSheetPrimarySlidingViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask originalMask = %orig;
    return originalMask | UIInterfaceOrientationMaskPortraitUpsideDown;
}
%end

%group UDIOS17UpsideDownPolicy
%hook SpringBoard
- (BOOL)supportsPortraitUpsideDownOrientation { return YES; }
%end
%end
%ctor {
    %init;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17) {
        Class c = NSClassFromString(@"SpringBoard");
        Method m = class_getInstanceMethod(c, @selector(supportsPortraitUpsideDownOrientation));
        char t[16] = {0};
        if (m && method_getNumberOfArguments(m) == 2) {
            method_getReturnType(m, t, sizeof(t));
            if ((t[0] == 'B' || t[0] == 'c') && t[1] == '\0') %init(UDIOS17UpsideDownPolicy);
        }
    }
}
