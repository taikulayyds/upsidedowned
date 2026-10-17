#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
    return %orig;
}
%end

%hook SBTraitsSceneParticipantDelegate
- (BOOL)_isAllowedToHavePortraitUpsideDown { return YES; }
- (NSInteger)_orientationMode {
    NSMutableDictionary *d = NSThread.currentThread.threadDictionary;
    NSNumber *old = d[UDPadDepthKey];
    d[UDPadDepthKey] = @([old unsignedIntegerValue] + 1);
    @try {
        return %orig;
    }
    @finally {
        if (old) d[UDPadDepthKey] = old; else [d removeObjectForKey:UDPadDepthKey];
    }
}
%end

%hook SpringBoard
- (NSInteger)homeScreenRotationStyle { return 1; }
%end

// Test A: SBApplication.isMedusaCapable is NOT hooked.

%hook SBHomeScreenViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // Home Screen only: allow portrait and upside-down, exclude landscape.
    return UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown;
}
%end
%hook SBCoverSheetPrimarySlidingViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown;
}
%end

%group UDIOS17UpsideDownPolicy
%hook SpringBoard
- (BOOL)supportsPortraitUpsideDownOrientation { return YES; }
%end
%end

// F: change only the supported mask at the SpringBoard scene boundary.
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
        // Include Apple apps (e.g. Settings); only SpringBoard keeps its
        // separate Home/Lock policy instead of the application-scene override.
        if ([bundle isEqualToString:@"com.apple.springboard"]) return originalMask;
        // Only expand scenes that already support portrait. A landscape-only
        // playback scene retains its original mask, even inside a portrait app.
        unsigned long long result = originalMask | UIInterfaceOrientationMaskAll;
        static unsigned int diagnosticCount = 0;
        if (diagnosticCount < 80) {
            ++diagnosticCount;
            NSLog(@"[UD-F] app=%@ supported=0x%llx -> 0x%llx", bundle, originalMask, result);
        }
        return result;
    } @catch (NSException *exception) {
        (void)exception;
    }
    return originalMask;
}
%end
%end

%ctor {
    %init;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17) {
        Class sceneClass = NSClassFromString(@"SBTraitsSceneParticipantDelegate");
        Method maskMethod = class_getInstanceMethod(sceneClass, NSSelectorFromString(@"_supportedOrientations"));
        char maskType[16] = {0};
        if (maskMethod && method_getNumberOfArguments(maskMethod) == 2) {
            method_getReturnType(maskMethod, maskType, sizeof(maskType));
            if (maskType[0] == 'Q' && maskType[1] == '\0') {
                %init(UDSceneUpsideMask);
                NSLog(@"[UD-F] SpringBoard-only scene mask candidate enabled");
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

// I: narrowly bypass the observed no-op in SBStatusBarWindow's public setter.
#import <string.h>
#import <stdio.h>
static char UDIChangedKey;
static BOOL UDIBusy;
static NSString *UDIPath;
static NSTimeInterval UDIEnd;
static NSUInteger UDILogCount;
static BOOL UDISignature(Class c, NSString *name, const char *encoding) {
    Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(name)) : NULL;
    return m && strcmp(method_getTypeEncoding(m), encoding) == 0;
}
static id UDIObject(id o, NSString *name) {
    SEL s = NSSelectorFromString(name);
    return UDHasReturn(o, s, '@') ? ((id (*)(id, SEL))objc_msgSend)(o, s) : nil;
}
static long long UDIOrientation(id o) {
    SEL s = NSSelectorFromString(@"orientation");
    return UDHasReturn(o, s, 'q') ? ((long long (*)(id, SEL))objc_msgSend)(o, s) : -1;
}
static BOOL UDIVisibleWindow(UIWindowScene *scene, NSString *wc, NSString *rc) {
    Class windowClass = NSClassFromString(wc), rootClass = NSClassFromString(rc);
    if (!windowClass || !rootClass) return NO;
    for (UIWindow *w in scene.windows) {
        if ([w isKindOfClass:windowClass] && !w.hidden && w.alpha > 0.01 &&
            [w.rootViewController isKindOfClass:rootClass]) return YES;
    }
    return NO;
}
static BOOL UDIHomeOrLock(UIWindow *w) {
    UIWindowScene *s = w.windowScene;
    if (!s || w.hidden || ![s.session.persistentIdentifier isEqualToString:@"com.apple.springboard"])
        return NO;
    SEL main = NSSelectorFromString(@"isMainDisplayWindowScene");
    if (!UDHasReturn(s, main, 'B') || !((BOOL (*)(id, SEL))objc_msgSend)(s, main)) return NO;
    // A visible Cover Sheet is allowed even if an application is suspended underneath.
    id cover = UDIObject(s, @"coverSheetPresentationManager");
    SEL visible = NSSelectorFromString(@"isVisibleAndNotDisappearing");
    if (!UDHasReturn(cover, visible, 'B')) return NO;
    if (((BOOL (*)(id, SEL))objc_msgSend)(cover, visible))
        return UDIVisibleWindow(s, @"SBCoverSheetWindow", @"SBCoverSheetPrimarySlidingViewController");
    // Home window visibility alone is NOT a foreground-app test.
    id manager = UDIObject(s, @"sceneManager");
    id handles = UDIObject(manager, @"externalForegroundApplicationSceneHandles");
    if (![handles isKindOfClass:NSArray.class] && ![handles isKindOfClass:NSSet.class]) return NO;
    if ([handles count] != 0) return NO;
    return UDIVisibleWindow(s, @"SBHomeScreenWindow", @"SBHomeScreenViewController");
}
static void UDILog(NSString *text) {
    if (!UDIPath || UDILogCount >= 80 || NSDate.date.timeIntervalSince1970 >= UDIEnd) return;
    ++UDILogCount;
    FILE *f = fopen(UDIPath.fileSystemRepresentation, "a");
    if (!f) return;
    fprintf(f, "%.3f [UD-I] %s\n", NSDate.date.timeIntervalSince1970, text.UTF8String);
    fclose(f);
}
%group UDIStatusBar
%hook SBStatusBarWindow
- (void)setOrientation:(long long)value animationParameters:(id)parameters {
    // Preserve the native call, its requested orientation and animation parameters.
    %orig;
    if (!NSThread.isMainThread || UDIBusy) return;
    UDIBusy = YES;
    @try {
        UIWindow *window = (UIWindow *)self;
        id bar = UDIObject(self, @"statusBar");
        BOOL changed = [objc_getAssociatedObject(self, &UDIChangedKey) boolValue];
        BOOL context = UDIHomeOrLock(window);
        long long ownBefore = UDIOrientation(self), barBefore = UDIOrientation(bar);
        BOOL start = context && value == UIInterfaceOrientationPortraitUpsideDown &&
            (ownBefore != value || barBefore != value);
        // On leaving Home/Lock, release only state owned by this patch, once,
        // using the current native request. Never force Portrait in an app.
        BOOL restore = changed && value >= 1 && value <= 4 && (!context || value != 2);
        if ((start || restore) &&
            UDISignature(object_getClass(self), @"_setStatusBarWindowOrientation:", "v24@0:8q16") &&
            [bar isKindOfClass:NSClassFromString(@"STUIStatusBar_Wrapper")] &&
            UDISignature(object_getClass(bar), @"setOrientation:", "v24@0:8q16") &&
            ownBefore >= 1 && barBefore >= 1) {
            // Mark before invoking either setter, so partial success is restorable.
            objc_setAssociatedObject(self, &UDIChangedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void (*)(id, SEL, long long))objc_msgSend)(self,
                NSSelectorFromString(@"_setStatusBarWindowOrientation:"), value);
            if (UDIOrientation(bar) != value)
                ((void (*)(id, SEL, long long))objc_msgSend)(bar, NSSelectorFromString(@"setOrientation:"), value);
            if (restore && UDIOrientation(self) == value && UDIOrientation(bar) == value)
                objc_setAssociatedObject(self, &UDIChangedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UDILog([NSString stringWithFormat:@"request=%lld context=%d start=%d restore=%d scene=%ld own=%lld->%lld bar=%lld->%lld",
            value, context, start, restore, (long)window.windowScene.interfaceOrientation,
            ownBefore, UDIOrientation(self), barBefore, UDIOrientation(bar)]);
    } @catch (NSException *e) {
        UDILog([NSString stringWithFormat:@"exception=%@", e.name]);
    } @finally {
        UDIBusy = NO;
    }
}
%end
%end
%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"] ||
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 17) return;
    Class c = NSClassFromString(@"SBStatusBarWindow");
    if (!UDISignature(c, @"setOrientation:animationParameters:", "v32@0:8q16@24") ||
        !UDISignature(c, @"_setStatusBarWindowOrientation:", "v24@0:8q16")) return;
    %init(UDIStatusBar);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"upsidedowned-I.txt"];
        if ([[NSFileManager defaultManager] createFileAtPath:path contents:NSData.data
                attributes:@{NSFilePosixPermissions: @0600}]) {
            UDIPath = path;
            UDIEnd = NSDate.date.timeIntervalSince1970 + 180;
            UDILog(@"enabled; log only: 180s/80 lines; fix has no expiry");
        }
    });
}
