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
    UIInterfaceOrientationMask originalMask = %orig;
    return originalMask | UIInterfaceOrientationMaskPortraitUpsideDown;
}
%end

%group UDIOS17UpsideDownPolicy
%hook SpringBoard
- (BOOL)supportsPortraitUpsideDownOrientation { return YES; }
%end
%end

// E: change only the supported mask at the SpringBoard scene boundary.
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
        // Do not change Apple system scenes or the established Home/Lock behavior.
        if ([bundle hasPrefix:@"com.apple."]) return originalMask;
        unsigned long long result = originalMask | UIInterfaceOrientationMaskPortraitUpsideDown;
        static unsigned int diagnosticCount = 0;
        if (diagnosticCount < 80) {
            ++diagnosticCount;
            NSLog(@"[UD-E] app=%@ supported=0x%llx -> 0x%llx", bundle, originalMask, result);
        }
        return result;
    } @catch (NSException *exception) {
        (void)exception;
    }
    return originalMask;
}
%end
%end

#import <os/log.h>
#include <string.h>

// S1: only relax the SYSTEM status-bar root-controller orientation mask.
// No transforms, window-frame edits, orientation setters or Medusa hooks.
static BOOL UDSBSignature(id object, SEL selector, const char *types) {
    if (!object) return NO;
    Method m = class_getInstanceMethod(object_getClass(object), selector);
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char result[32] = {0};
    method_getReturnType(m, result, sizeof(result));
    return result[0] && result[1] == '\0' && strchr(types, result[0]);
}
static id UDSBObject(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!UDSBSignature(object, sel, "@")) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}
static BOOL UDSBBool(id object, NSString *name, BOOL *value) {
    SEL sel = NSSelectorFromString(name);
    if (!UDSBSignature(object, sel, "Bc")) return NO;
    *value = ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
    return YES;
}
static BOOL UDSBEligible(id root) {
    if (![NSThread isMainThread]) return NO;
    id window = UDSBObject(root, @"statusBarWindow");
    Class wc = NSClassFromString(@"SBStatusBarWindow");
    if (!wc || ![window isKindOfClass:wc]) return NO;
    UIWindowScene *scene = [(UIWindow *)window windowScene];
    BOOL main = NO;
    if (!UDSBBool(scene, @"isMainDisplayWindowScene", &main) || !main)
        return NO;
    if (scene.interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown)
        return NO;

    // Require positive Home/Lock evidence; unknown states fail closed.
    id cover = UDSBObject(scene, @"coverSheetPresentationManager");
    BOOL presented = NO;
    if (!UDSBBool(cover, @"isPresented", &presented)) return NO;
    if (presented) return YES;
    id icons = UDSBObject(NSClassFromString(@"SBIconController"),
                          @"sharedInstanceIfExists");
    BOOL occluded = YES;
    if (!UDSBBool(icons, @"areHomeScreenIconsOccluded", &occluded) || occluded)
        return NO;
    id home = UDSBObject(icons, @"homeScreenViewController");
    if (![home isKindOfClass:[UIViewController class]]) return NO;
    UIView *view = [(UIViewController *)home viewIfLoaded];
    UIWindow *homeWindow = view.window;
    return homeWindow && homeWindow.windowScene == scene &&
           !homeWindow.hidden && !view.hidden && view.alpha > 0.01;
}


// S2: preserve all App requests; only correct a portrait request for an
// already-upside-down Home/Cover scene. Let Apple's setter perform layout.
static NSInteger UDSBRequestedOrientation(id window, NSInteger requested) {
    if (requested != UIInterfaceOrientationPortrait || ![NSThread isMainThread]) return requested;
    @try {
        if (![window isKindOfClass:UIWindow.class]) return requested;
        UIViewController *root = [(UIWindow *)window rootViewController];
        if (!UDSBEligible(root)) return requested;
        static unsigned int count = 0;
        if (count++ < 40) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
                "[UDSB-S2] Home/Cover portrait request corrected to upside-down");
        }
        return UIInterfaceOrientationPortraitUpsideDown;
    } @catch (NSException *exception) {
        (void)exception;
        return requested;
    }
}
static BOOL UDSBSetterCompatible(Class cls, SEL sel, unsigned int arguments) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != arguments) return NO;
    char result[16] = {0}, arg[16] = {0}, params[16] = {0};
    method_getReturnType(m, result, sizeof(result));
    method_getArgumentType(m, 2, arg, sizeof(arg));
    if (strcmp(result, "v") || strcmp(arg, @encode(NSInteger))) return NO;
    if (arguments == 4) {
        method_getArgumentType(m, 3, params, sizeof(params));
        if (params[0] != '@') return NO;
    }
    return YES;
}
%group UDSBWindowOrientationS2
%hook SBStatusBarWindow
- (void)setOrientation:(NSInteger)orientation {
    NSInteger corrected = UDSBRequestedOrientation(self, orientation);
    %orig(corrected);
}
- (void)setOrientation:(NSInteger)orientation animationParameters:(id)parameters {
    NSInteger corrected = UDSBRequestedOrientation(self, orientation);
    %orig(corrected, parameters);
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
                NSLog(@"[UD-E] SpringBoard-only scene mask candidate enabled");
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
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"] &&
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17) {
        Class statusWindow = NSClassFromString(@"SBStatusBarWindow");
        if (UDSBSetterCompatible(statusWindow, @selector(setOrientation:), 3) &&
            UDSBSetterCompatible(statusWindow, @selector(setOrientation:animationParameters:), 4)) {
            %init(UDSBWindowOrientationS2);
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[UDSB-S2] installed");
        }
    }

}
