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

// H: targeted READ-ONLY diagnostics, not a synchronization fix.
#import <string.h>
#import <stdio.h>
#import <sys/stat.h>
static NSString *UDHPath;
static NSTimeInterval UDHEnd;
static NSUInteger UDHEvents;
static BOOL UDHBusy;
static BOOL UDHActive(void) {
    return NSThread.isMainThread && UDHPath && NSDate.date.timeIntervalSince1970 < UDHEnd;
}
static void UDHLog(NSString *text) {
    if (!UDHActive()) return;
    struct stat st;
    if (stat(UDHPath.fileSystemRepresentation, &st) != 0 || st.st_size >= 512 * 1024) return;
    FILE *f = fopen(UDHPath.fileSystemRepresentation, "a");
    if (!f) return;
    fprintf(f, "%.3f [UD-H] %s\n", NSDate.date.timeIntervalSince1970, text.UTF8String);
    fclose(f);
}
static NSString *UDHOrientation(id object) {
    SEL sel = NSSelectorFromString(@"orientation");
    if (!UDHasReturn(object, sel, 'q')) return @"unavailable";
    long long value = ((long long (*)(id, SEL))objc_msgSend)(object, sel);
    return [NSString stringWithFormat:@"%lld", value];
}
static void UDHWindow(UIWindow *window, NSString *reason) {
    if (!UDHActive() || UDHBusy) return;
    UDHBusy = YES;
    @try {
        id bar = nil;
        SEL sel = NSSelectorFromString(@"statusBar");
        if (UDHasReturn(window, sel, '@')) bar = ((id (*)(id, SEL))objc_msgSend)(window, sel);
        UIWindowScene *scene = window.windowScene;
        UDHLog([NSString stringWithFormat:@"%@ win=%p class=%@ scene=%p sceneID=%@ activation=%ld interface=%ld own=%@ bar=%p barClass=%@ barOrientation=%@ hidden=%d level=%.1f root=%@ bounds=%@", reason, (__bridge void *)window, NSStringFromClass(window.class), (__bridge void *)scene, scene.session.persistentIdentifier, (long)scene.activationState, (long)scene.interfaceOrientation, UDHOrientation(window), (__bridge void *)bar, bar ? NSStringFromClass([bar class]) : @"nil", UDHOrientation(bar), window.hidden, window.windowLevel, NSStringFromClass(window.rootViewController.class), NSStringFromCGRect(window.bounds)]);
        // Discover the actual wrapper ABI once. Never invoke its unknown setters.
        static Class seenClass;
        if (bar && [bar class] != seenClass) {
            seenClass = [bar class];
            for (Class c = seenClass; c && c != UIView.class && c != NSObject.class; c = class_getSuperclass(c)) {
                unsigned int n = 0;
                Method *list = class_copyMethodList(c, &n);
                for (unsigned int i = 0; i < n; ++i) {
                    NSString *name = NSStringFromSelector(method_getName(list[i]));
                    if ([name rangeOfString:@"orientation" options:NSCaseInsensitiveSearch].location != NSNotFound || [name rangeOfString:@"statusBar" options:NSCaseInsensitiveSearch].location != NSNotFound)
                        UDHLog([NSString stringWithFormat:@"wrapperABI %@ %@ %s", NSStringFromClass(c), name, method_getTypeEncoding(list[i])]);
                }
                free(list);
            }
        }
        if ([bar isKindOfClass:UIView.class]) {
            UIView *view = (UIView *)bar;
            UDHLog([NSString stringWithFormat:@"barView class=%@ hidden=%d alpha=%.2f transform=%@", NSStringFromClass(view.class), view.hidden, view.alpha, NSStringFromCGAffineTransform(view.transform)]);
            NSUInteger count = 0;
            for (UIView *child in view.subviews) {
                if (++count > 8) break;
                UDHLog([NSString stringWithFormat:@"barChild class=%@ orientation=%@ hidden=%d transform=%@", NSStringFromClass(child.class), UDHOrientation(child), child.hidden, NSStringFromCGAffineTransform(child.transform)]);
            }
        }
    } @catch (NSException *e) {
        UDHLog([NSString stringWithFormat:@"readException=%@", e.name]);
    } @finally {
        UDHBusy = NO;
    }
}
static void UDHEvent(id object, NSString *name, long long value, NSString *phase) {
    if (!UDHActive() || UDHBusy || UDHEvents >= 400) return;
    ++UDHEvents;
    UDHWindow((UIWindow *)object, [NSString stringWithFormat:@"setter=%@ requested=%lld %@", name, value, phase]);
}
%group UDHTrace
%hook SBStatusBarWindow
- (void)setOrientation:(long long)value {
    UDHEvent(self, @"setOrientation:", value, @"before");
    %orig;
    UDHEvent(self, @"setOrientation:", value, @"after");
}
- (void)setOrientation:(long long)value animationParameters:(id)parameters {
    UDHEvent(self, @"setOrientation:animationParameters:", value, @"before");
    %orig;
    UDHEvent(self, @"setOrientation:animationParameters:", value, @"after");
}
- (void)_setStatusBarWindowOrientation:(long long)value {
    UDHEvent(self, @"_setStatusBarWindowOrientation:", value, @"before");
    %orig;
    UDHEvent(self, @"_setStatusBarWindowOrientation:", value, @"after");
}
%end
%end
static BOOL UDHSignature(Class cls, NSString *name, const char *encoding) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(name));
    return m && strcmp(method_getTypeEncoding(m), encoding) == 0;
}
%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"] || NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 17) return;
    Class cls = NSClassFromString(@"SBStatusBarWindow");
    BOOL valid = UDHSignature(cls, @"setOrientation:", "v24@0:8q16") && UDHSignature(cls, @"setOrientation:animationParameters:", "v32@0:8q16@24") && UDHSignature(cls, @"_setStatusBarWindowOrientation:", "v24@0:8q16");
    if (valid) {
        %init(UDHTrace);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [directory stringByAppendingPathComponent:@"upsidedowned-H.txt"];
        FILE *f = fopen(path.fileSystemRepresentation, "w");
        if (!f) {
            path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"upsidedowned-H.txt"];
            f = fopen(path.fileSystemRepresentation, "w");
        }
        if (!f) return;
        fclose(f);
        chmod(path.fileSystemRepresentation, 0600);
        UDHPath = [path copy];
        UDHEnd = NSDate.date.timeIntervalSince1970 + 180.0;
        UDHLog([NSString stringWithFormat:@"READ ONLY path=%@ setterHooks=%d duration=180s cap=512KiB; no lock/mask/statusbar writes", path, valid]);
        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            if (!UDHActive()) { [t invalidate]; return; }
            UDHLog([NSString stringWithFormat:@"sample device=%ld", (long)UIDevice.currentDevice.orientation]);
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (![s isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)s).windows) {
                    NSString *name = NSStringFromClass(w.class);
                    if ([w isKindOfClass:cls] || [name isEqualToString:@"SBHomeScreenWindow"] || [name isEqualToString:@"SBCoverSheetWindow"])
                        UDHWindow(w, @"sample");
                }
            }
            if (NSDate.date.timeIntervalSince1970 >= UDHEnd - 1.1) {
                UDHLog(@"sampling finished; setter logging disabled");
                UDHEnd = 0;
                [t invalidate];
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
