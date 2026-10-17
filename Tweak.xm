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


// Bounded local diagnostics: private file, no network or screen content.
#import <stdio.h>
#import <stdarg.h>
#import <sys/stat.h>
static NSString *UDGFilePath;
static void UDGPrepareFile(void) {
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"upsidedowned-G.txt"];
    FILE *file = fopen(path.fileSystemRepresentation, "w");
    if (!file) {
        path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"upsidedowned-G.txt"];
        file = fopen(path.fileSystemRepresentation, "w");
    }
    if (file) {
        chmod(path.fileSystemRepresentation, 0600);
        fprintf(file, "G file diagnostics; overwritten on SpringBoard restart.\n");
        fclose(file);
        UDGFilePath = [path copy];
    }
}
static void UDGWrite(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void UDGWrite(NSString *format, ...) {
    if (!UDGFilePath) return;
    struct stat info;
    if (stat(UDGFilePath.fileSystemRepresentation, &info) == 0 && info.st_size >= 2 * 1024 * 1024) return;
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FILE *file = fopen(UDGFilePath.fileSystemRepresentation, "a");
    if (!file) return;
    fprintf(file, "%.3f %s\n", NSDate.date.timeIntervalSince1970, text.UTF8String);
    fclose(file);
}

// G diagnostic only: no status-bar transform, no orientation-mask change.
// It records the classes/methods present on this build before any future policy hook.
static void UD_G_LogClassMethods(Class cls) {
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;
    UDGWrite(@"[UD-G] class=%@ instanceMethods=%u", NSStringFromClass(cls), count);
    for (unsigned int i = 0; i < count; ++i) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if ([name rangeOfString:@"statusBar" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"orientation" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"rotation" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"scene" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            UDGWrite(@"[UD-G] %@ - %@ types=%s", NSStringFromClass(cls), name, method_getTypeEncoding(methods[i]));
        }
    }
    free(methods);
}

static void UD_G_LogState(NSString *reason) {
    if (![NSThread isMainThread]) return;
    UIDevice *device = UIDevice.currentDevice;
    UIApplication *application = UIApplication.sharedApplication;
    NSString *appOrientation = @"unavailable";
    SEL appSel = NSSelectorFromString(@"statusBarOrientation");
    if ([application respondsToSelector:appSel]) {
        UIInterfaceOrientation value = ((UIInterfaceOrientation (*)(id, SEL))objc_msgSend)(application, appSel);
        appOrientation = [NSString stringWithFormat:@"%ld", (long)value];
    }
    UDGWrite(@"[UD-G] state reason=%@ deviceOrientation=%ld appStatusBarOrientation=%@", reason, (long)device.orientation, appOrientation);
    // UIApplication.windows is deprecated and treated as an error by the
    // GitHub Xcode build. Enumerate windows through connected window scenes.
    NSSet *connectedScenes = application.connectedScenes;
    for (UIScene *scene in connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            UDGWrite(@"[UD-G] window class=%@ level=%.1f hidden=%d bounds=%@ interface=%ld", NSStringFromClass(window.class), window.windowLevel, window.hidden, NSStringFromCGRect(window.bounds), (long)windowScene.interfaceOrientation);
        }
    }
}

%ctor {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 17) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UDGPrepareFile();
        UDGWrite(@"[UD-G] file=%@", UDGFilePath);
        NSArray *names = @[
            @"SBStatusBarManager", @"SBStatusBarStateAggregator", @"SBStatusBarSceneManager",
            @"SBStatusBarWindow", @"SBStatusBarView", @"SBSceneManager", @"SBSceneHandle",
            @"SBTraitsSceneParticipantDelegate", @"UIStatusBar", @"UIStatusBarManager",
            @"_UIStatusBar", @"_UIStatusBarManager"
        ];
        for (NSString *name in names) UD_G_LogClassMethods(NSClassFromString(name));
        UD_G_LogState(@"initial");
        __block NSUInteger samples = 0;
        NSTimer *timer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *activeTimer) {
            UD_G_LogState(@"periodic-2s");
            if (++samples >= 90) {
                UDGWrite(@"[UD-G] periodic sampling finished after 3 minutes");
                [activeTimer invalidate];
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            UD_G_LogState(@"UIDeviceOrientationDidChange");
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            UD_G_LogState(@"UIApplicationDidBecomeActive");
        }];
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            UD_G_LogState(@"UIApplicationWillResignActive");
        }];
    });
}
