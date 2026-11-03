// 设置首页去除 Apple ID 建议 — 主 tweak（注入「设置」App）
//
// 「设置」首页上的「Apple ID 建议」是一个 FollowUpList_ 的 specifier，
// id 形如 FollowUpList_com.apple.followup.group.account，它把系统当前所有
// 投递到该组的跟进项（FLFollowUpItem）放在 properties 的 followUpItems 里，
// 单元格上的角标就是这些项目的数量。
//
// 所以这一行里出现什么，完全由系统运行时决定，没有任何写死的清单。
// 本 tweak 每次刷新都重新读一遍：
//   * hideGroup 打开 → 整行删掉；
//   * 否则按 hide-<kind> 逐条删掉被关掉的建议，并同步角标；
//   * 一条都不剩时同样整行删掉。
// kind 是条目的稳定标识（客户端 ID + 类型 ID，去掉随账号变化的 UUID），
// 因此换了账号、条目重新投递，开关依然有效。
// 同时把见过的每一条写进 items.plist，供设置面板列出逐条开关。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <substrate.h>

// 「设置」的列表控制器（PSListController）改行、改角标用的接口；
// 本 tweak 不链接 Preferences，只在这里按消息声明。
@interface NSObject (APSNPreferences)
- (void)removeSpecifier:(id)specifier animated:(BOOL)animated;
- (void)insertSpecifier:(id)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)reloadSpecifier:(id)specifier;
// 表格里某一行的 indexPath 对应第几个 specifier（隐藏行高要用）
- (NSUInteger)indexForIndexPath:(NSIndexPath *)indexPath;
@end

static NSString *const APSNHideGroupKey = @"hideGroup";
static NSString *const APSNItemKeyPrefix = @"hide-";
static NSString *const APSNFollowUpPrefix = @"FollowUpList_";
static NSString *const APSNHiddenKey = @"apelinHidden";

static os_log_t APSNLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

static NSString *APSNClassName(id object) {
    return object == nil ? @"nil" : NSStringFromClass([object class]);
}

// bootstrap 里的路径（沙盒进程只可靠地能写 bootstrap 的 /var）
static NSString *APSNBootstrapPath(NSString *path) {
#ifdef APELIN_BOOTSTRAP_ROOTHIDE
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char anchor = 0;
        Dl_info info;
        if (dladdr(&anchor, &info) == 0 || info.dli_fname == NULL) {
            return;
        }
        NSArray<NSString *> *parts =
            [@(info.dli_fname) componentsSeparatedByString:@"/"];
        for (NSUInteger i = 0; i < parts.count; i++) {
            if ([parts[i] hasPrefix:@".jbroot-"]) {
                root = [[parts subarrayWithRange:NSMakeRange(0, i + 1)]
                    componentsJoinedByString:@"/"];
                break;
            }
        }
    });
    return root == nil ? nil : [root stringByAppendingString:path];
#else
    return [@"/var/jb" stringByAppendingString:path];
#endif
}

static NSString *APSNStateDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        directory = APSNBootstrapPath(@"/var/mobile/Library/APSNoSuggestions");
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL];
    });
    return directory;
}

#pragma mark - 设置

// 设置面板改完开关会发这个通知，首页立刻重新过滤
static NSString *const APSNChangedNotification = @APELIN_PACKAGE_ID "/changed";

static void APSNWriteState(NSString *text) {
#if APSN_DEBUG_DUMP
    // 定时器每两秒一次，别把文件写成无限长
    static int writes;
    static NSString *last;
    if (writes >= 80 || [text isEqualToString:(last ?: @"")]) {
        return;
    }
    writes++;
    last = [text copy];
    NSString *directory = APSNStateDirectory();
    if (directory == nil) {
        return;
    }
    NSString *path = [directory stringByAppendingPathComponent:@"state.txt"];
    NSString *existing = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], text];
    [[(existing ?: @"") stringByAppendingString:line]
        writeToFile:path
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:NULL];
#else
    (void)text;
#endif
}

static BOOL APSNPreferenceBool(NSString *key) {
    CFStringRef domain = (__bridge CFStringRef)@APELIN_PACKAGE_ID;
    CFPreferencesAppSynchronize(domain);
    Boolean present = false;
    Boolean value = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key,
                                                    domain, &present);
    return present ? (value != false) : NO;
}

#pragma mark - 跟进项

static id APSNItemValue(id item, NSString *key) {
    id value = nil;
    @try {
        value = [item valueForKey:key];
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    return value;
}

static NSString *APSNItemUID(id item) {
    for (NSString *key in @[ @"uniqueIdentifier", @"identifier", @"targetIdentifier" ]) {
        id value = APSNItemValue(item, key);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }
    return nil;
}

static NSString *APSNItemTitle(id item) {
    id value = APSNItemValue(item, @"title");
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// UID 里常带随账号/安装变化的 UUID，换成开关 key 会失效，先剔掉。
static NSString *APSNStripUUIDs(NSString *text) {
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByString:@"."]) {
        if (part.length == 0) {
            continue;
        }
        if ([[NSUUID alloc] initWithUUIDString:part] != nil) {
            continue;
        }
        [kept addObject:part];
    }
    return [kept componentsJoinedByString:@"."];
}

// 条目的稳定标识：客户端 ID + 类型 ID。同类的多条建议共用一个开关。
static NSString *APSNItemKind(id item) {
    id client = APSNItemValue(item, @"clientIdentifier");
    id type = APSNItemValue(item, @"typeIdentifier");
    if ([client isKindOfClass:[NSString class]] && [client length] > 0) {
        if ([type isKindOfClass:[NSString class]] && [type length] > 0) {
            return [NSString stringWithFormat:@"%@.%@", client, type];
        }
        return client;
    }
    NSString *uid = APSNItemUID(item);
    return uid == nil ? nil : APSNStripUUIDs(uid);
}

// 把见过的每一条建议并进 items.plist（旧的保留，这样条目暂时消失时开关还在）
static void APSNWriteItems(NSArray *items) {
    NSString *directory = APSNStateDirectory();
    if (directory == nil) {
        return;
    }
    NSString *path = [directory stringByAppendingPathComponent:@"items.plist"];
    NSArray *existing = [NSArray arrayWithContentsOfFile:path];
    NSMutableArray<NSMutableDictionary *> *records = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byKind =
        [NSMutableDictionary dictionary];
    for (id record in existing) {
        if (![record isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *kind = record[@"kind"];
        if (![kind isKindOfClass:[NSString class]] || kind.length == 0) {
            continue;
        }
        NSMutableDictionary *copy = [record mutableCopy];
        [records addObject:copy];
        byKind[kind] = copy;
    }

    for (id item in items) {
        NSString *kind = APSNItemKind(item);
        if (kind == nil) {
            continue;
        }
        NSString *title = APSNItemTitle(item) ?: kind;
        NSString *uid = APSNItemUID(item) ?: kind;
        NSMutableDictionary *record = byKind[kind];
        if (record == nil) {
            record = [@{
                @"kind" : kind,
                @"uid" : uid,
                @"title" : title,
            } mutableCopy];
            [records addObject:record];
            byKind[kind] = record;
        } else {
            record[@"uid"] = uid;
            record[@"title"] = title;
        }
    }

    if ([records isEqualToArray:(existing ?: @[])]) {
        return;
    }
    [records writeToFile:path atomically:YES];
    os_log(APSNLog(), "APSN recorded %lu follow-up kinds", (unsigned long)records.count);
}

#pragma mark - 过滤首页列表

static id APSNSpecifierValue(id spec, NSString *key) {
    if ([spec respondsToSelector:@selector(propertyForKey:)]) {
        id value = [spec performSelector:@selector(propertyForKey:) withObject:key];
        if (value != nil) {
            return value;
        }
    }
    id value = nil;
    @try {
        value = [spec valueForKey:key];
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    return value;
}

// 「设置」图标上的角标：跟首页还剩几条建议走，0 就是清掉角标。
// 这个角标是「设置」自己这个 App 的，改它只能在本进程里改。
static void APSNSetIconBadge(NSUInteger count) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) {
        return;
    }
    if (app.applicationIconBadgeNumber == (NSInteger)count) {
        return;
    }
    app.applicationIconBadgeNumber = (NSInteger)count;
    os_log(APSNLog(), "APSN icon badge -> %lu", (unsigned long)count);
}

// 「这一行」在列表里永远保留，只按开关决定画不画：整行隐藏时打上 apelinHidden
// 标记，再由 tableView:heightForRowAtIndexPath: 把高度算成 0。
// 不删行就不会改变列表的行数，下面的分组（越狱插件列表）也就不会跟着上下跳。
static BOOL APSNItemHidden(id item) {
    NSString *kind = APSNItemKind(item);
    return kind != nil &&
        APSNPreferenceBool([APSNItemKeyPrefix stringByAppendingString:kind]);
}

// 这一行现在是否整行不显示（只看开关，不动 specifier）
static BOOL APSNFollowUpHiddenNow(id spec) {
    if (APSNPreferenceBool(APSNHideGroupKey)) {
        return YES;
    }
    id items = APSNSpecifierValue(spec, @"apelinOriginalItems");
    if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
        items = APSNSpecifierValue(spec, @"followUpItems");
    }
    if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
        return NO;
    }
    for (id item in items) {
        if (!APSNItemHidden(item)) {
            return NO;
        }
    }
    return YES;
}

// 按开关把条目、角标、隐藏标记算一遍。返回 YES 表示这一行应当整行隐藏。
static BOOL APSNApplyFollowUpVisibility(id spec) {
    id items = APSNSpecifierValue(spec, @"apelinOriginalItems");
    if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
        items = APSNSpecifierValue(spec, @"followUpItems");
        if ([items isKindOfClass:[NSArray class]] && [items count] > 0) {
            [spec setProperty:items forKey:@"apelinOriginalItems"];
        }
    }
    BOOL groupHidden = APSNPreferenceBool(APSNHideGroupKey);
    if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
        [spec setProperty:(groupHidden ? @YES : nil) forKey:APSNHiddenKey];
        if (groupHidden) {
            APSNSetIconBadge(0);
        }
        return groupHidden;
    }
    APSNWriteItems(items);

    NSMutableArray *kept = [NSMutableArray array];
    for (id item in items) {
        if (!APSNItemHidden(item)) {
            [kept addObject:item];
        }
    }
    if (groupHidden || [kept count] == 0) {
        [spec setProperty:@YES forKey:APSNHiddenKey];
        [spec setProperty:@[] forKey:@"followUpItems"];
        [spec setProperty:@0 forKey:@"badgeNumber"];
        [spec setProperty:nil forKey:@"cellObject"];
        APSNSetIconBadge(0);
        APSNWriteState(groupHidden ? @"row hidden (group switch)" : @"row hidden (all items hidden)");
        return YES;
    }
    [spec setProperty:nil forKey:APSNHiddenKey];
    id previous = APSNSpecifierValue(spec, @"followUpItems");
    NSArray *previousArray = [previous isKindOfClass:[NSArray class]] ? previous : @[];
    if (![previousArray isEqualToArray:kept]) {
        [spec setProperty:kept forKey:@"followUpItems"];
        // 单元格是缓存在 specifier 上的，不清掉的话角标还是旧数字
        [spec setProperty:nil forKey:@"cellObject"];
    }
    [spec setProperty:@([kept count]) forKey:@"badgeNumber"];
    APSNSetIconBadge([kept count]);
    return NO;
}

// 首页列表里那一行的下标（没有就 NSNotFound）
static NSUInteger APSNFollowUpIndex(NSArray *specs) {
    for (NSUInteger i = 0; i < [specs count]; i++) {
        id identifier = APSNSpecifierValue(specs[i], @"identifier");
        if ([identifier isKindOfClass:[NSString class]] &&
            [identifier hasPrefix:APSNFollowUpPrefix]) {
            return i;
        }
    }
    return NSNotFound;
}

// 运行时刷新：只改这一行自己的内容，行本身留在列表里（隐藏靠高度）。
// 改完仍然走 PSListController 的 reloadSpecifier:，让表格重新问一次高度和角标。
static BOOL APSNUpdateLive(id controller) {
    id specs = APSNSpecifierValue(controller, @"specifiers");
    if (![specs isKindOfClass:[NSArray class]] || [specs count] == 0) {
        APSNWriteState([NSString stringWithFormat:@"%@: no specifier list yet (%lu)",
                                                  APSNClassName(controller),
                                                  (unsigned long)[specs count]]);
        return NO;
    }
    NSUInteger index = APSNFollowUpIndex(specs);
    if (index == NSNotFound) {
        return NO;
    }
    id spec = specs[index];

    BOOL wasHidden = [APSNSpecifierValue(spec, APSNHiddenKey) boolValue];
    id previous = APSNSpecifierValue(spec, @"followUpItems");
    NSUInteger previousCount = [previous isKindOfClass:[NSArray class]] ? [previous count] : 0;

    BOOL hidden = APSNApplyFollowUpVisibility(spec);
    id now = APSNSpecifierValue(spec, @"followUpItems");
    NSUInteger nowCount = [now isKindOfClass:[NSArray class]] ? [now count] : 0;

    // 已经是这个样子了就不动表格，免得每次刷新都重建这一行
    if (hidden == wasHidden && nowCount == previousCount) {
        return NO;
    }
    if ([controller respondsToSelector:@selector(reloadSpecifier:)]) {
        [(id)controller reloadSpecifier:spec];
    }
    os_log(APSNLog(), "APSN live row hidden=%d -> %d items=%lu -> %lu",
           (int)wasHidden, (int)hidden, (unsigned long)previousCount, (unsigned long)nowCount);
    APSNWriteState([NSString stringWithFormat:@"live row hidden=%d items=%lu/%lu",
                                              (int)hidden, (unsigned long)nowCount,
                                              (unsigned long)previousCount]);
    return YES;
}

#pragma mark - 找到「设置」首页控制器

// 「设置」首页那个控制器叫 PSUIPrefsListController，名字里并没有 Root
static BOOL APSNIsHomeController(id controller) {
    if (controller == nil) {
        return NO;
    }
    NSString *name = APSNClassName(controller);
    // 本 tweak 自己的设置面板类名里也带 Root，绝不能当成首页控制器
    if ([name hasPrefix:@"APSNoSuggestions"]) {
        return NO;
    }
    return [name containsString:@"Root"] || [name isEqualToString:@"PSUIPrefsListController"];
}

static UIViewController *APSNFindController(UIViewController *controller, int depth) {
    if (controller == nil || depth > 8) {
        return nil;
    }
    Class listControllerClass = objc_getClass("PSListController");
    if (listControllerClass != Nil && [controller isKindOfClass:listControllerClass] &&
        APSNIsHomeController(controller)) {
        return controller;
    }
    if ([controller isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in [(UINavigationController *)controller viewControllers]) {
            UIViewController *found = APSNFindController(child, depth + 1);
            if (found != nil) {
                return found;
            }
        }
    }
    UIViewController *found = APSNFindController([controller presentedViewController], depth + 1);
    if (found != nil) {
        return found;
    }
    // 首页根视图是 PSSplitViewController，它的列不在 childViewControllers 里
    if ([controller isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in [(UISplitViewController *)controller viewControllers]) {
            found = APSNFindController(child, depth + 1);
            if (found != nil) {
                return found;
            }
        }
    }
    for (UIViewController *child in [controller childViewControllers]) {
        found = APSNFindController(child, depth + 1);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static UIViewController *APSNRootListController(void) {
    UIApplication *application = [UIApplication sharedApplication];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in [application connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:[(UIWindowScene *)scene windows]];
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (windows.count == 0) {
        [windows addObjectsFromArray:[application windows]];
    }
#pragma clang diagnostic pop
    APSNWriteState([NSString stringWithFormat:@"scenes=%lu windows=%lu rootVC=%@",
                                              (unsigned long)[[application connectedScenes] count],
                                              (unsigned long)windows.count,
                                              APSNClassName([[windows firstObject] rootViewController])]);
    for (UIWindow *window in windows) {
        UIViewController *found = APSNFindController([window rootViewController], 0);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

// 首页控制器：viewWillAppear / reloadSpecifiers 触发时记下来，
// 定时刷新和通知刷新都直接用它（不持有，控制器归「设置」自己管）。
static __unsafe_unretained UIViewController *APSNKnownRoot;

static void APSNRememberRoot(id controller) {
    if (APSNIsHomeController(controller)) {
        APSNKnownRoot = (UIViewController *)controller;
    }
}

// 一次性把首页列表里的 specifier 全写出来，确认「Apple ID 建议」到底在不在里面
static void APSNDumpSpecifiers(id controller) {
#if APSN_DEBUG_DUMP
    static BOOL done;
    if (done) {
        return;
    }
    id specs = APSNSpecifierValue(controller, @"specifiers");
    if (![specs isKindOfClass:[NSArray class]] || [specs count] < 20) {
        return;
    }
    done = YES;
    NSMutableString *text = [NSMutableString stringWithFormat:@"%@ count=%lu\n",
                                                              APSNClassName(controller),
                                                              (unsigned long)[specs count]];
    NSUInteger limit = MIN([specs count], (NSUInteger)320);
    for (NSUInteger i = 0; i < limit; i++) {
        id identifier = APSNSpecifierValue(specs[i], @"identifier");
        id name = APSNSpecifierValue(specs[i], @"name");
        [text appendFormat:@"%lu\t%@\t%@\n", (unsigned long)i,
                           [identifier isKindOfClass:[NSString class]] ? identifier : @"-",
                           [name isKindOfClass:[NSString class]] ? name : @"-"];
    }
    NSString *directory = APSNStateDirectory();
    [text writeToFile:[directory stringByAppendingPathComponent:@"specs.txt"]
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:NULL];
#else
    (void)controller;
#endif
}

static BOOL APSNHasFollowUpRow(id controller) {
    id specs = APSNSpecifierValue(controller, @"specifiers");
    if (![specs isKindOfClass:[NSArray class]]) {
        return NO;
    }
    for (id spec in specs) {
        id identifier = APSNSpecifierValue(spec, @"identifier");
        if ([identifier isKindOfClass:[NSString class]] &&
            [identifier hasPrefix:APSNFollowUpPrefix]) {
            return YES;
        }
    }
    return NO;
}

static void APSNRefresh(NSString *reason) {
    static BOOL wroteMissingRoot;
    // 首页控制器在 viewWillAppear 时抓到过，直接用它，不再靠视图树搜索
    UIViewController *root = APSNKnownRoot != nil ? APSNKnownRoot : APSNRootListController();
    if (root == nil) {
        if (!wroteMissingRoot) {
            wroteMissingRoot = YES;
            APSNWriteState([NSString stringWithFormat:@"refresh(%@): no root controller", reason]);
        }
        return;
    }
    wroteMissingRoot = NO;
    APSNDumpSpecifiers(root);
    if (APSNUpdateLive(root)) {
        os_log(APSNLog(), "APSN refreshed (%{public}@)", reason);
    }
}

#pragma mark - 定时刷新

static void APSNStartTimer(void) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(timer, ^{
            APSNRefresh(@"timer");
        });
        dispatch_resume(timer);
    });
}

// 设置面板改完开关后，这里立刻重新过滤一次
static void APSNChangedCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    APSNRefresh(@"prefs changed");
}

static void APSNObserveChanges(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    (CFNotificationCallback)APSNChangedCallback,
                                    (__bridge CFStringRef)APSNChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

#pragma mark - Hook

// 只在类自己实现了这个方法时才挂，否则 MSHookMessageEx 会改到父类上，
// 把已经挂好的钩子再包一层，直接递归爆栈。
static BOOL APSNClassDefinesMethod(Class cls, SEL selector) {
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

static void (*OriginalReloadSpecifiers)(id, SEL);
static void (*OriginalRootReloadSpecifiers)(id, SEL);

static void APSNHookedReloadSpecifiers(id self, SEL _cmd) {
    if (OriginalReloadSpecifiers != NULL) {
        OriginalReloadSpecifiers(self, _cmd);
    }
    APSNRememberRoot(self);
    APSNWriteState([NSString stringWithFormat:@"hook(base) %@", APSNClassName(self)]);
    APSNUpdateLive(self);
}

static void APSNHookedRootReloadSpecifiers(id self, SEL _cmd) {
    if (OriginalRootReloadSpecifiers != NULL) {
        OriginalRootReloadSpecifiers(self, _cmd);
    }
    APSNRememberRoot(self);
    APSNWriteState([NSString stringWithFormat:@"hook(root) %@", APSNClassName(self)]);
    APSNUpdateLive(self);
}

static BOOL APSNHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (cls == Nil || *original != NULL || !APSNClassDefinesMethod(cls, selector)) {
        return NO;
    }
    MSHookMessageEx(cls, selector, replacement, original);
    return *original != NULL;
}

// 在类及其父类里找真正实现这个方法的那个类；都没有就返回 Nil。
static Class APSNImplementingClass(Class cls, SEL selector) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        if (APSNClassDefinesMethod(current, selector)) {
            return current;
        }
    }
    return Nil;
}

static void (*OriginalViewWillAppear)(id, SEL, BOOL);

static void APSNHookedViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (OriginalViewWillAppear != NULL) {
        OriginalViewWillAppear(self, _cmd, animated);
    }
    APSNRememberRoot(self);
    APSNWriteState([NSString stringWithFormat:@"hook(appear) %@", APSNClassName(self)]);
    id specs = APSNSpecifierValue(self, @"specifiers");
    os_log(APSNLog(), "APSN appear %{public}@ specs=%lu row=%d",
           APSNClassName(self), (unsigned long)[specs count],
           (int)APSNHasFollowUpRow(self));
    // 列表是异步装配的（先 97 条，之后才补齐），多过滤几遍兜底
    for (NSNumber *delay in @[ @0.05, @0.2, @0.5, @1.0, @2.5 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)([delay doubleValue] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            APSNUpdateLive(self);
        });
    }
}

static void (*OriginalSetSpecifiers)(id, SEL, NSArray *);

// 列表装配完成后一定会走 setSpecifiers:，在这里过滤最稳，
// 不依赖 reloadSpecifiers 有没有被调用。
static void APSNHookedSetSpecifiers(id self, SEL _cmd, NSArray *specifiers) {
    if ([specifiers isKindOfClass:[NSArray class]] && [specifiers count] > 0) {
        NSUInteger index = APSNFollowUpIndex(specifiers);
        if (index != NSNotFound) {
            BOOL hidden = APSNApplyFollowUpVisibility(specifiers[index]);
            os_log(APSNLog(), "APSN setSpecifiers %{public}@ %lu hidden=%d",
                   APSNClassName(self), (unsigned long)[specifiers count], (int)hidden);
            APSNWriteState([NSString stringWithFormat:@"setSpecifiers %@ %lu hidden=%d",
                                                      APSNClassName(self),
                                                      (unsigned long)[specifiers count],
                                                      (int)hidden]);
        }
    }
    if (OriginalSetSpecifiers != NULL) {
        OriginalSetSpecifiers(self, _cmd, specifiers);
    }
}

// 「这一行」的行高：该隐藏时给 0，表格就把它当没有一样画，
// 但列表的行数不变，下面的分组不会跟着上下跳。
static id APSNSpecifierAtRowIndexPath(id controller, NSIndexPath *indexPath) {
    if (indexPath == nil || ![controller respondsToSelector:@selector(indexForIndexPath:)]) {
        return nil;
    }
    NSInteger index = (NSInteger)[(id)controller indexForIndexPath:indexPath];
    id specs = APSNSpecifierValue(controller, @"specifiers");
    if (![specs isKindOfClass:[NSArray class]] || index < 0 ||
        index >= (NSInteger)[specs count]) {
        return nil;
    }
    return specs[(NSUInteger)index];
}

static BOOL APSNIsHiddenFollowUpSpec(id spec) {
    if (spec == nil) {
        return NO;
    }
    id identifier = APSNSpecifierValue(spec, @"identifier");
    if (![identifier isKindOfClass:[NSString class]] || ![identifier hasPrefix:APSNFollowUpPrefix]) {
        return NO;
    }
    return APSNFollowUpHiddenNow(spec);
}

static CGFloat (*OriginalHeightForRow)(id, SEL, UITableView *, NSIndexPath *);
static CGFloat (*OriginalEstimatedHeightForRow)(id, SEL, UITableView *, NSIndexPath *);
static CGFloat (*OriginalHeightForHeader)(id, SEL, UITableView *, NSInteger);
static CGFloat (*OriginalHeightForFooter)(id, SEL, UITableView *, NSInteger);

static CGFloat APSNHookedHeightForRow(id self, SEL _cmd, UITableView *tableView,
                                      NSIndexPath *indexPath) {
    if (APSNIsHomeController(self) &&
        APSNIsHiddenFollowUpSpec(APSNSpecifierAtRowIndexPath(self, indexPath))) {
        return 0.0;
    }
    return OriginalHeightForRow != NULL
        ? OriginalHeightForRow(self, _cmd, tableView, indexPath) : UITableViewAutomaticDimension;
}

static CGFloat APSNHookedEstimatedHeightForRow(id self, SEL _cmd, UITableView *tableView,
                                               NSIndexPath *indexPath) {
    if (APSNIsHomeController(self) &&
        APSNIsHiddenFollowUpSpec(APSNSpecifierAtRowIndexPath(self, indexPath))) {
        return 0.0;
    }
    return OriginalEstimatedHeightForRow != NULL
        ? OriginalEstimatedHeightForRow(self, _cmd, tableView, indexPath)
        : UITableViewAutomaticDimension;
}

// 这一行是它那一组里唯一一行时，组头和组尾的间距也要一起收掉
static BOOL APSNIsHiddenFollowUpSection(id controller, UITableView *tableView, NSInteger section) {
    if (!APSNIsHomeController(controller) || tableView == nil) {
        return NO;
    }
    if ([tableView numberOfSections] <= section || section < 0) {
        return NO;
    }
    if ([tableView numberOfRowsInSection:section] != 1) {
        return NO;
    }
    NSIndexPath *path = [NSIndexPath indexPathForRow:0 inSection:section];
    return APSNIsHiddenFollowUpSpec(APSNSpecifierAtRowIndexPath(controller, path));
}

static CGFloat APSNHookedHeightForHeader(id self, SEL _cmd, UITableView *tableView,
                                         NSInteger section) {
    if (APSNIsHiddenFollowUpSection(self, tableView, section)) {
        return 0.0;
    }
    return OriginalHeightForHeader != NULL
        ? OriginalHeightForHeader(self, _cmd, tableView, section) : -1.0;
}

static CGFloat APSNHookedHeightForFooter(id self, SEL _cmd, UITableView *tableView,
                                         NSInteger section) {
    if (APSNIsHiddenFollowUpSection(self, tableView, section)) {
        return 0.0;
    }
    return OriginalHeightForFooter != NULL
        ? OriginalHeightForFooter(self, _cmd, tableView, section) : -1.0;
}

static BOOL APSNInstallHooks(void) {
    SEL selector = @selector(reloadSpecifiers);
    if (objc_getClass("PSUIPrefsListController") == Nil) {
        dlopen("/System/Library/PrivateFrameworks/PreferencesUI.framework/PreferencesUI",
               RTLD_NOW);
    }
    Class rootController = objc_getClass("PSUIPrefsListController");

    if (OriginalSetSpecifiers == NULL && rootController != Nil) {
        Class owner = APSNImplementingClass(rootController, @selector(setSpecifiers:));
        if (owner != Nil) {
            MSHookMessageEx(owner, @selector(setSpecifiers:),
                            (IMP)APSNHookedSetSpecifiers,
                            (IMP *)&OriginalSetSpecifiers);
        }
    }

    APSNHook(objc_getClass("PSListController"), selector,
             (IMP)APSNHookedReloadSpecifiers,
             (IMP *)&OriginalReloadSpecifiers);
    // 首页那个控制器重写了 reloadSpecifiers，父类的钩子等不到它；
    // 它在 PreferencesUI.framework 里，可能比本 tweak 晚加载，所以要一直重试到挂上。
    APSNHook(rootController, selector,
             (IMP)APSNHookedRootReloadSpecifiers,
             (IMP *)&OriginalRootReloadSpecifiers);

    // reloadSpecifiers 只在列表真的要重载时才会调；进首页时一定会走 viewWillAppear:。
    if (OriginalViewWillAppear == NULL && rootController != Nil) {
        Class owner = APSNImplementingClass(rootController, @selector(viewWillAppear:));
        if (owner != Nil) {
            MSHookMessageEx(owner, @selector(viewWillAppear:),
                            (IMP)APSNHookedViewWillAppear,
                            (IMP *)&OriginalViewWillAppear);
        }
    }

    // 整行隐藏靠行高：PSListController 自己实现了 tableView:heightForRowAtIndexPath:
    // 等几个表格代理方法，把它们包一层就够了，列表的行数从头到尾不变。
    Class listController = objc_getClass("PSListController");
    if (listController != Nil) {
        if (OriginalHeightForRow == NULL) {
            Class owner = APSNImplementingClass(listController,
                                                @selector(tableView:heightForRowAtIndexPath:));
            if (owner != Nil) {
                MSHookMessageEx(owner, @selector(tableView:heightForRowAtIndexPath:),
                                (IMP)APSNHookedHeightForRow,
                                (IMP *)&OriginalHeightForRow);
            }
        }
        if (OriginalEstimatedHeightForRow == NULL) {
            Class owner = APSNImplementingClass(listController,
                                                @selector(tableView:estimatedHeightForRowAtIndexPath:));
            if (owner != Nil) {
                MSHookMessageEx(owner, @selector(tableView:estimatedHeightForRowAtIndexPath:),
                                (IMP)APSNHookedEstimatedHeightForRow,
                                (IMP *)&OriginalEstimatedHeightForRow);
            }
        }
        if (OriginalHeightForHeader == NULL) {
            Class owner = APSNImplementingClass(listController,
                                                @selector(tableView:heightForHeaderInSection:));
            if (owner != Nil) {
                MSHookMessageEx(owner, @selector(tableView:heightForHeaderInSection:),
                                (IMP)APSNHookedHeightForHeader,
                                (IMP *)&OriginalHeightForHeader);
            }
        }
        if (OriginalHeightForFooter == NULL) {
            Class owner = APSNImplementingClass(listController,
                                                @selector(tableView:heightForFooterInSection:));
            if (owner != Nil) {
                MSHookMessageEx(owner, @selector(tableView:heightForFooterInSection:),
                                (IMP)APSNHookedHeightForFooter,
                                (IMP *)&OriginalHeightForFooter);
            }
        }
    }
    return OriginalRootReloadSpecifiers != NULL;
}

static void APSNRetryInstallHooks(int remaining) {
    BOOL hooked = APSNInstallHooks();
    APSNWriteState([NSString stringWithFormat:@"hooks base=%d root=%d left=%d",
                                              OriginalReloadSpecifiers != NULL,
                                              OriginalRootReloadSpecifiers != NULL, remaining]);
    if (!hooked && remaining > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            APSNRetryInstallHooks(remaining - 1);
        });
    }
}

__attribute__((constructor)) static void APSNInitialize(void) {
    os_log(APSNLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID,
           getprogname());

    // Preferences.framework 在「设置」进程里可能还没加载，先把它拉进来。
    if (objc_getClass("PSListController") == Nil) {
        dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
               RTLD_NOW);
    }
    APSNRetryInstallHooks(60);
    APSNObserveChanges();
    APSNStartTimer();
}
