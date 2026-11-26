// SpringBoard 侧：桌面「设置」图标上的角标是 followupd 按跟进项数量随时写回的，
// 「设置」App 不在运行时没有人能把它清掉，所以只能在这里拦。
//
// 「设置」进程那边每次算完都会把该显示的数字写进偏好键 badgeOverride：
//   0   一条建议都不显示，角标锁成没有；
//   N   还剩 N 条；
//   键不存在（或负数）不干预，系统怎么显示就怎么显示。
// 这里只是把那个数字当成「设置」图标的角标值，系统的角标值一个字节都不改，
// 开关全部打开后键就没了，图标立刻回到系统原本的样子。
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <os/log.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

// SpringBoardHome 里 SBIconView / SBIcon 的角标 override，本文件不链接它，按消息声明
@interface NSObject (APNSpringBoardIcon)
- (void)setOverrideBadgeNumberOrString:(id)value;
@end

static NSString *const APNSettingsBundleID = @"com.apple.Preferences";
static NSString *const APNBadgeOverrideKey = @"badgeOverride";
static NSString *const APNHideGroupKey = @"hideGroup";
// 「设置」进程算完新值后发这个通知
static NSString *const APNChangedNotification = @APELIN_PACKAGE_ID "/changed";
// followupd 每次重算角标后发这个通知
static NSString *const APNFollowUpBadgeNotification = @"com.apple.followup.badge.refresh";

static os_log_t APNLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "springboard");
    });
    return log;
}

static BOOL APNPreferenceBool(NSString *key) {
    CFStringRef domain = (__bridge CFStringRef)@APELIN_PACKAGE_ID;
    CFPreferencesAppSynchronize(domain);
    Boolean present = false;
    Boolean value = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key,
                                                    domain, &present);
    return present ? (value != false) : NO;
}

// 该给「设置」图标显示的角标数字；nil 表示不干预
static NSNumber *APNBadgeOverride(void) {
    CFStringRef domain = (__bridge CFStringRef)@APELIN_PACKAGE_ID;
    CFPreferencesAppSynchronize(domain);
    Boolean present = false;
    CFIndex value = CFPreferencesGetAppIntegerValue(
        (__bridge CFStringRef)APNBadgeOverrideKey, domain, &present);
    if (present) {
        return value < 0 ? nil : @((long long)value);
    }
    // 「设置」还没算过（从没打开过）：整行开关打开时也按 0 算
    return APNPreferenceBool(APNHideGroupKey) ? @0 : nil;
}

static id APNValue(id object, NSString *key) {
    id value = nil;
    @try {
        value = [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    return value;
}

// 图标所属的 App bundle id（SBIcon / SBIconView 都有 applicationBundleID）
static NSString *APNIconBundleID(id object) {
    for (NSString *key in @[ @"applicationBundleID", @"applicationBundleIdentifier" ]) {
        if (![object respondsToSelector:NSSelectorFromString(key)]) {
            continue;
        }
        id value = APNValue(object, key);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }
    return nil;
}

// 这个图标（或图标视图）该不该用我们的数字：只认「设置」，其余一律 nil
static NSNumber *APNOverrideFor(id object) {
    if (object == nil) {
        return nil;
    }
    return [APNIconBundleID(object) isEqualToString:APNSettingsBundleID]
        ? APNBadgeOverride() : nil;
}

static id APNOverrideForIconView(id view) {
    return APNOverrideFor(APNValue(view, @"icon"));
}

// 0 表示「没有角标」：返回 nil 让系统按没有角标画
static id APNOverrideValue(NSNumber *override) {
    if (override == nil) {
        return nil;
    }
    return override.integerValue == 0 ? nil : override;
}

#pragma mark - 钩子

// 角标值的来源：SBLeafIcon 重写了 badgeNumberOrString，真正的实现按类链找
static id (*OriginalBadgeNumberOrString)(id, SEL);
// SBIconView 把角标画出来时读的就是它
static id (*OriginalBadgeString)(id, SEL);
static void (*OriginalSetIcon)(id, SEL, id, BOOL);
static void (*OriginalSetOverride)(id, SEL, id);

// 图标视图是 SpringBoard 自己管理生命周期的对象，随时可能被回收：
// 这里必须用 __weak，指针一过期就自动变 nil。曾经用 __unsafe_unretained，
// 视图销毁后定时/通知回调再去 retain 它就是野指针，SpringBoard 直接崩溃。
static __weak id APNSettingsIconView;
// 当前被我们摆过 override 的那个视图；同样用 __weak 跟踪
static __weak id APNOverriddenView;

static id APNHookedBadgeNumberOrString(id self, SEL _cmd) {
    NSNumber *override = APNOverrideFor(self);
    if (override != nil) {
        return APNOverrideValue(override);
    }
    return OriginalBadgeNumberOrString != NULL
        ? OriginalBadgeNumberOrString(self, _cmd) : nil;
}

static id APNHookedBadgeString(id self, SEL _cmd) {
    NSNumber *override = APNOverrideForIconView(self);
    if (override != nil) {
        // 一次性留个证据：确认「画角标」这条读取路径真的被拦到了
        static BOOL logged;
        if (!logged) {
            logged = YES;
            os_log(APNLog(), "APN badgeString suppressed (%{public}@)", override);
        }
        NSNumber *value = APNOverrideValue(override);
        return value == nil ? nil : [value stringValue];
    }
    return OriginalBadgeString != NULL ? OriginalBadgeString(self, _cmd) : nil;
}

// 这个视图现在还是不是「设置」那个图标（视图可能已经被回收、或复用来显示别的 App）
static BOOL APNViewIsSettings(id view) {
    if (view == nil) {
        return NO;
    }
    return [APNIconBundleID(APNValue(view, @"icon")) isEqualToString:APNSettingsBundleID];
}

// 把 override 摆到图标视图上；没有该显示的数字时只撤掉自己摆的那一份
static void APNApplyOverride(id view) {
    if (view == nil) {
        return;
    }
    // 角标刷新走的是通知回调，这里抛出去任何东西都会带走 SpringBoard
    @try {
        if (!APNViewIsSettings(view)) {
            return;
        }
        NSNumber *override = APNBadgeOverride();
        if (override != nil) {
            APNOverriddenView = view;
            id current = APNValue(view, @"overrideBadgeNumberOrString");
            if (![current isEqual:override]) {
                [view setOverrideBadgeNumberOrString:override];
                os_log(APNLog(), "APN badge override -> %{public}@", override);
            }
        } else if (APNOverriddenView == view) {
            APNOverriddenView = nil;
            [view setOverrideBadgeNumberOrString:nil];
            os_log(APNLog(), "APN badge override cleared");
        }
    } @catch (NSException *exception) {
        os_log(APNLog(), "APN badge override failed: %{public}@", exception);
    }
}

static void APNHookedSetIcon(id self, SEL _cmd, id icon, BOOL animated) {
    if (OriginalSetIcon != NULL) {
        OriginalSetIcon(self, _cmd, icon, animated);
    }
    if ([APNIconBundleID(icon) isEqualToString:APNSettingsBundleID]) {
        APNSettingsIconView = self;
        APNApplyOverride(self);
    } else if (APNSettingsIconView == self) {
        // 这个视图被复用去显示别的 App 了，别再留着它
        APNSettingsIconView = nil;
    }
}

// 「设置」在运行时它会自己清掉角标 override；别的图标清掉只是为了不挡路
static void APNHookedSetOverride(id self, SEL _cmd, id value) {
    if (value == nil && APNOverrideForIconView(self) != nil) {
        return;
    }
    if (OriginalSetOverride != NULL) {
        OriginalSetOverride(self, _cmd, value);
    }
}

static void APNRefreshBadge(void) {
    APNApplyOverride(APNSettingsIconView);
    // 让图标视图重新问一遍角标值（badgeNumberOrString / badgeString 都会重新走）
    id icon = APNValue(APNSettingsIconView, @"icon");
    SEL note = NSSelectorFromString(@"noteBadgeDidChange");
    if (icon != nil && [icon respondsToSelector:note]) {
        [icon performSelector:note];
    }
}

static void APNNotifyCallback(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object,
                              CFDictionaryRef userInfo) {
    APNRefreshBadge();
}

static void APNObserveChanges(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    for (NSString *name in @[ APNChangedNotification, APNFollowUpBadgeNotification ]) {
        CFNotificationCenterAddObserver(center, NULL, (CFNotificationCallback)APNNotifyCallback,
                                        (__bridge CFStringRef)name, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

static BOOL APNClassDefinesMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static Class APNImplementingClass(Class cls, SEL selector) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        if (APNClassDefinesMethod(current, selector)) {
            return current;
        }
    }
    return Nil;
}

static BOOL APNHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (cls == Nil || *original != NULL || !APNClassDefinesMethod(cls, selector)) {
        return NO;
    }
    MSHookMessageEx(cls, selector, replacement, original);
    return *original != NULL;
}

static BOOL APNInstallHooks(void) {
    if (objc_getClass("SBIconView") == Nil) {
        dlopen("/System/Library/PrivateFrameworks/SpringBoardHome.framework/SpringBoardHome",
               RTLD_NOW);
    }
    Class iconView = objc_getClass("SBIconView");
    BOOL iconHook = APNHook(iconView, @selector(setIcon:animated:), (IMP)APNHookedSetIcon,
                            (IMP *)&OriginalSetIcon);
    BOOL overrideHook = APNHook(iconView, @selector(setOverrideBadgeNumberOrString:),
                                (IMP)APNHookedSetOverride, (IMP *)&OriginalSetOverride);
    BOOL stringHook = APNHook(iconView, NSSelectorFromString(@"badgeString"),
                              (IMP)APNHookedBadgeString, (IMP *)&OriginalBadgeString);

    // 「设置」图标是 SBApplicationIcon，从它往上找 badgeNumberOrString 的实现类
    Class iconClass = objc_getClass("SBApplicationIcon");
    if (iconClass == Nil) {
        iconClass = objc_getClass("SBLeafIcon");
    }
    SEL badgeSelector = NSSelectorFromString(@"badgeNumberOrString");
    BOOL valueHook = APNHook(APNImplementingClass(iconClass, badgeSelector), badgeSelector,
                             (IMP)APNHookedBadgeNumberOrString,
                             (IMP *)&OriginalBadgeNumberOrString);

    os_log(APNLog(), "APN hooks icon=%d override=%d string=%d value=%d", (int)iconHook,
           (int)overrideHook, (int)stringHook, (int)valueHook);
    return iconHook && (stringHook || valueHook);
}

__attribute__((constructor)) static void APNInitialize(void) {
    os_log(APNLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());
    APNInstallHooks();
    APNObserveChanges();
}
