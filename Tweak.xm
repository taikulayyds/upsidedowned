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
