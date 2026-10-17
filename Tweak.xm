#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
// Read-only APIs declared in the iOS 17.0.3 runtime-header dump.
// Validate the runtime ABI; unknown states must not enable the override.
static BOOL UDHasReturn(id receiver, SEL selector, char expected) {
    if (!receiver) return NO;
    Method method = class_getInstanceMethod(object_getClass(receiver), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char type[32] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (expected == '@') return type[0] == '@';
    if (expected == 'B') return (type[0] == 'B' || type[0] == 'c') && type[1] == '\0';
    return type[0] == expected && type[1] == '\0';
}


// Read-only, bounded diagnostics. No bundle IDs, text, geometry or personal data.
static void UDFLog(NSInteger hook, long long a, long long b, long long c) {
    if (![NSThread isMainThread]) return;
    static NSUInteger count = 0;
    if (count++ >= 600) return;
    @try {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/UDFSystemTest"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"orientation.log"];
        if ([[fm attributesOfItemAtPath:path error:NULL][NSFileSize] unsignedLongLongValue] >= 65536) return;
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:path];
        [f seekToEndOfFile];
        [f writeData:[[NSString stringWithFormat:@"%ld %lld %lld %lld\n", (long)hook, a, b, c] dataUsingEncoding:NSUTF8StringEncoding]];
        [f closeFile];
    } @catch (NSException *e) { (void)e; }
}
static BOOL UDFOneOrientation(NSString *name, NSString *selector) {
    Method m = class_getInstanceMethod(NSClassFromString(name), NSSelectorFromString(selector));
    if (!m || method_getNumberOfArguments(m) != 3) return NO;
    char r[16] = {0}, a[16] = {0};
    method_getReturnType(m, r, sizeof(r));
    method_getArgumentType(m, 2, a, sizeof(a));
    return !strcmp(r, "v") && !strcmp(a, "q");
}
static long long UDFReadOrientation(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!UDHasReturn(object, sel, 'q')) return -1;
    return ((long long (*)(id, SEL))objc_msgSend)(object, sel);
}
static void UDFViewProbe(id object, NSInteger hook) {
    if (![NSThread isMainThread]) return;
    @try {
        if (![object isKindOfClass:UIViewController.class]) return;
        UIViewController *vc = object;
        UIWindow *w = vc.viewIfLoaded.window;
        if (!w) return;
        UDFLog(hook, UDFReadOrientation(vc, @"interfaceOrientation"),
            UDFReadOrientation(w.windowScene, @"interfaceOrientation"), 0);
    } @catch (NSException *e) { (void)e; }
}

static BOOL UDAppUpsideDownAllowedNow(void) {
    // Do not synchronously dispatch from SpringBoard capability queries.
    if (![NSThread isMainThread]) return NO;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 17) return NO;
    Class cls = NSClassFromString(@"SBOrientationLockManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL userLock = NSSelectorFromString(@"isUserLocked");
    SEL effectiveLock = NSSelectorFromString(@"isEffectivelyLocked");
    if (!UDHasReturn((id)cls, shared, '@')) return NO;
    id manager = ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
    if (!UDHasReturn(manager, userLock, 'B') ||
        !UDHasReturn(manager, effectiveLock, 'B')) return NO;
    BOOL userLocked = ((BOOL (*)(id, SEL))objc_msgSend)(manager, userLock);
    BOOL effectivelyLocked = ((BOOL (*)(id, SEL))objc_msgSend)(manager, effectiveLock);
    return !userLocked && !effectivelyLocked;
}




@interface SBApplicationInfo : NSObject
@property(nonatomic, readonly) UIInterfaceOrientationMask supportedInterfaceOrientations;
@property(nonatomic, readonly) NSString *bundleIdentifier;
@end
@interface SBApplication : NSObject
@property(nonatomic, readonly) SBApplicationInfo *info;
@end

static NSString *const UDPadDepthKey = @"com.34306.upsidedowned.padDepth";

%hook UIDevice
- (UIUserInterfaceIdiom)userInterfaceIdiom {
    if ([NSThread.currentThread.threadDictionary[UDPadDepthKey] unsignedIntegerValue] > 0)
        return UIUserInterfaceIdiomPad;
    UIUserInterfaceIdiom original = %orig;
    return original;
}
%end

%hook SBTraitsSceneParticipantDelegate
- (BOOL)_isAllowedToHavePortraitUpsideDown { return YES; }
- (NSInteger)_orientationMode {
    NSMutableDictionary *d = NSThread.currentThread.threadDictionary;
    NSNumber *old = d[UDPadDepthKey];
    d[UDPadDepthKey] = @([old unsignedIntegerValue] + 1);
    @try {
        NSInteger original = %orig;
        return original;
    }
    @finally {
        if (old) d[UDPadDepthKey] = old; else [d removeObjectForKey:UDPadDepthKey];
    }
}
%end

%hook SpringBoard
- (NSInteger)homeScreenRotationStyle { return 1; }
%end

// No Medusa capability hooks.

%hook SBHomeScreenViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UDFViewProbe(self, 20);
    // Home Screen only: allow portrait and upside-down, exclude landscape.
    return UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown;
}
%end
%hook SBCoverSheetPrimarySlidingViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask originalMask = %orig;
    UDFViewProbe(self, 21);
    return (originalMask | UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown) & ~(UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight);
}
%end

%group UDIOS17UpsideDownPolicy
%hook SpringBoard
- (BOOL)supportsPortraitUpsideDownOrientation { return YES; }
%end
%end

// F: based on E; change only the supported mask at the SpringBoard scene boundary.
// _application and _supportedOrientations are declared in iOS 17 headers.
%group UDSceneUpsideMask
%hook SBTraitsSceneParticipantDelegate
- (unsigned long long)_supportedOrientations {
    unsigned long long originalMask = %orig;
    @try {
        if (!(originalMask & UIInterfaceOrientationMaskPortrait)) return originalMask;
        if (!UDAppUpsideDownAllowedNow()) return originalMask;
        SEL appSelector = NSSelectorFromString(@"_application");
        if (!UDHasReturn(self, appSelector, '@')) return originalMask;
        id app = ((id (*)(id, SEL))objc_msgSend)(self, appSelector);
        if (!app || ![app isKindOfClass:NSClassFromString(@"SBApplication")]) return originalMask;
        SEL infoSelector = NSSelectorFromString(@"info");
        if (!UDHasReturn(app, infoSelector, '@')) return originalMask;
        id info = ((id (*)(id, SEL))objc_msgSend)(app, infoSelector);
        SEL bundleSelector = NSSelectorFromString(@"bundleIdentifier");
        if (!UDHasReturn(info, bundleSelector, '@')) return originalMask;
        id bundle = ((id (*)(id, SEL))objc_msgSend)(info, bundleSelector);
        if (![bundle isKindOfClass:NSString.class] || ![bundle length]) return originalMask;
        // Apple allowlist: Settings only. Do not expand other Apple scenes.
        if ([bundle hasPrefix:@"com.apple."] && ![bundle isEqualToString:@"com.apple.Preferences"]) return originalMask;
        SEL supported = NSSelectorFromString(@"supportedInterfaceOrientations");
        if (!UDHasReturn(info, supported, 'Q')) return originalMask;
        unsigned long long declared = ((unsigned long long (*)(id, SEL))objc_msgSend)(info, supported);
        // Both current scene AND application-info masks must include portrait.
        // Never turn a landscape-only fullscreen request into a portrait request.
        if (!(declared & UIInterfaceOrientationMaskPortrait)) return originalMask;
        unsigned long long result = originalMask | UIInterfaceOrientationMaskAll;
        UDFLog(10, originalMask, declared, result);
        return result;
    } @catch (NSException *exception) {
        (void)exception;
    }
    return originalMask;
}
%end
%end


// Observe a different, actual layout chain; do not repeat S1/S2 overrides.
%group UDFLayoutProbe
%hook SBMainDisplaySceneLayoutStatusBarView
- (void)layoutStatusBarForSpringBoardRotationToOrientation:(long long)orientation {
    %orig;
    @try {
        if ([NSThread isMainThread] && [(id)self isKindOfClass:UIView.class]) {
            UIWindow *w = ((UIView *)self).window;
            UDFLog(30, orientation, UDFReadOrientation(self, @"containerOrientation"),
                UDFReadOrientation(w.windowScene, @"interfaceOrientation"));
        }
    } @catch (NSException *e) { (void)e; }
}
%end
%end
%group UDFWindowProbe
%hook SBStatusBarWindow
- (void)_setStatusBarWindowOrientation:(long long)orientation {
    %orig;
    @try {
        if ([NSThread isMainThread] && [(id)self isKindOfClass:UIWindow.class]) {
            UDFLog(31, orientation, UDFReadOrientation(self, @"orientation"),
                UDFReadOrientation(((UIWindow *)self).windowScene, @"interfaceOrientation"));
        }
    } @catch (NSException *e) { (void)e; }
}
%end
%end

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    %init;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17) {
        if (UDFOneOrientation(@"SBMainDisplaySceneLayoutStatusBarView", @"layoutStatusBarForSpringBoardRotationToOrientation:")) {
            %init(UDFLayoutProbe);
            UDFLog(2, 0, 0, 0);
        }
        if (UDFOneOrientation(@"SBStatusBarWindow", @"_setStatusBarWindowOrientation:")) {
            %init(UDFWindowProbe);
            UDFLog(3, 0, 0, 0);
        }
    }
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17) {
        Class sceneClass = NSClassFromString(@"SBTraitsSceneParticipantDelegate");
        Method maskMethod = class_getInstanceMethod(sceneClass, NSSelectorFromString(@"_supportedOrientations"));
        char maskType[16] = {0};
        if (maskMethod && method_getNumberOfArguments(maskMethod) == 2) {
            method_getReturnType(maskMethod, maskType, sizeof(maskType));
            if (maskType[0] == 'Q' && maskType[1] == '\0') {
                %init(UDSceneUpsideMask);
                UDFLog(1, 0, 0, 0);
            }
        }
    }
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
