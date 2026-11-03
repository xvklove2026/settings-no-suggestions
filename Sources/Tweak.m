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

// 「设置」的列表控制器（PSListController）改行、改角标用的两个接口；
// 本 tweak 不链接 Preferences，只在这里按消息声明。
@interface NSObject (APSNPreferences)
- (void)removeSpecifier:(id)specifier animated:(BOOL)animated;
- (void)insertSpecifier:(id)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)reloadSpecifier:(id)specifier;
@end

static NSString *const APSNHideGroupKey = @"hideGroup";
static NSString *const APSNItemKeyPrefix = @"hide-";
static NSString *const APSNFollowUpPrefix = @"FollowUpList_";

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

// 首页那一行现在还该不该出现：总开关没关，并且至少有一条没被单独关掉。
// 全部条目都被关掉时行就该消失，这时不必让「设置」重建列表。
static BOOL APSNRowShouldShow(void) {
    if (APSNPreferenceBool(APSNHideGroupKey)) {
        return NO;
    }
    NSString *directory = APSNStateDirectory();
    NSString *path = directory != nil
        ? [directory stringByAppendingPathComponent:@"items.plist"] : nil;
    NSArray *items = path != nil ? [NSArray arrayWithContentsOfFile:path] : nil;
    if ([items count] == 0) {
        return YES;  // 还没读到过条目，先留着这一行
    }
    for (NSDictionary *record in items) {
        if (![record isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *kind = record[@"kind"];
        if (![kind isKindOfClass:[NSString class]] || kind.length == 0) {
            continue;
        }
        if (!APSNPreferenceBool([APSNItemKeyPrefix stringByAppendingString:kind])) {
            return YES;
        }
    }
    return NO;
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

// 之前整行被删掉时留着的那个 specifier：再需要它时插回原位。
static id APSNRemovedSpec;
static NSInteger APSNRemovedIndex = -1;

// 返回是否改动了列表
static BOOL APSNFilterSpecifiers(NSMutableArray *specs) {
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < [specs count]; i++) {
        id identifier = APSNSpecifierValue(specs[i], @"identifier");
        if ([identifier isKindOfClass:[NSString class]] &&
            [identifier hasPrefix:APSNFollowUpPrefix]) {
            index = i;
            break;
        }
    }
    if (index == NSNotFound) {
        return NO;
    }

    id spec = specs[index];

    if (APSNPreferenceBool(APSNHideGroupKey)) {
        [specs removeObjectAtIndex:index];
        APSNRemovedSpec = spec;
        APSNRemovedIndex = (NSInteger)index;
        APSNSetIconBadge(0);
        os_log(APSNLog(), "APSN removed follow-up row (group switch)");
        APSNWriteState(@"removed follow-up row (group switch)");
        return YES;
    }

    // 原始条目存一份，之后每次都从它算起，这样开关关掉时能把条目还原回来
    id items = APSNSpecifierValue(spec, @"apelinOriginalItems");
    if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
        items = APSNSpecifierValue(spec, @"followUpItems");
        if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
            APSNWriteState([NSString stringWithFormat:@"follow-up spec but items=%@ count=%lu",
                                                      APSNClassName(items),
                                                      (unsigned long)[items count]]);
            return NO;
        }
        [spec setProperty:items forKey:@"apelinOriginalItems"];
    }
    APSNWriteItems(items);

    id previous = APSNSpecifierValue(spec, @"followUpItems");
    NSUInteger previousCount = [previous isKindOfClass:[NSArray class]] ? [previous count] : 0;

    NSMutableArray *kept = [NSMutableArray array];
    for (id item in items) {
        NSString *kind = APSNItemKind(item);
        BOOL hidden = kind != nil &&
            APSNPreferenceBool([APSNItemKeyPrefix stringByAppendingString:kind]);
        if (!hidden) {
            [kept addObject:item];
        }
    }
    if ([kept count] == 0) {
        [specs removeObjectAtIndex:index];
        APSNRemovedSpec = spec;
        APSNRemovedIndex = (NSInteger)index;
        APSNSetIconBadge(0);
        os_log(APSNLog(), "APSN removed follow-up row (all items hidden)");
        APSNWriteState(@"removed follow-up row (all items hidden)");
        return YES;
    }
    [spec setProperty:kept forKey:@"followUpItems"];
    [spec setProperty:@([kept count]) forKey:@"badgeNumber"];
    APSNSetIconBadge([kept count]);
    if ([kept count] == previousCount && [kept count] == [items count]) {
        return NO;
    }
    if ([kept count] != previousCount) {
        NSMutableArray *titles = [NSMutableArray array];
        for (id item in kept) {
            NSString *title = APSNItemTitle(item);
            [titles addObject:title ?: @"?"];
        }
        APSNWriteState([NSString stringWithFormat:@"row badge=%@ items=%@",
                                                  APSNSpecifierValue(spec, @"badgeNumber"),
                                                  [titles componentsJoinedByString:@" | "]]);
        os_log(APSNLog(), "APSN hid %lu of %lu follow-up items",
               (unsigned long)([items count] - [kept count]), (unsigned long)[items count]);
        APSNWriteState([NSString stringWithFormat:@"hid %lu of %lu items",
                                                  (unsigned long)([items count] - [kept count]),
                                                  (unsigned long)[items count]]);
    }
    return YES;
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

// 之前整行被删掉时留着的那个 specifier：再需要它时插回原位，
// 这样不用让「设置」整个重建列表（重建会连带把面板的列表清成空白）。
static void APSNRestoreRemovedRow(id controller) {
    if (APSNRemovedSpec == nil || !APSNRowShouldShow()) {
        return;
    }
    if (![controller respondsToSelector:@selector(insertSpecifier:atIndex:animated:)]) {
        return;
    }
    id spec = APSNRemovedSpec;
    APSNRemovedSpec = nil;
    id specs = APSNSpecifierValue(controller, @"specifiers");
    NSInteger at = APSNRemovedIndex;
    if (at < 0 || at > (NSInteger)[specs count]) {
        at = (NSInteger)[specs count];
    }
    APSNRemovedIndex = -1;
    [(id)controller insertSpecifier:spec atIndex:at animated:NO];
    os_log(APSNLog(), "APSN put the follow-up row back at %ld", (long)at);
}

// 运行时刷新。改完必须走 PSListController 自己的接口（reloadSpecifier: /
// removeSpecifier:animated:）：直接改 _specifiers 数组表格不会跟着变，
// 表现就是角标数字不变、整行删掉后还留一格空白。
static BOOL APSNUpdateLive(id controller) {
    id specs = APSNSpecifierValue(controller, @"specifiers");
    if (![specs isKindOfClass:[NSArray class]] || [specs count] == 0) {
        APSNWriteState([NSString stringWithFormat:@"%@: no follow-up specifier in %lu",
                                                  APSNClassName(controller),
                                                  (unsigned long)[specs count]]);
        return NO;
    }
    NSUInteger index = APSNFollowUpIndex(specs);
    if (index == NSNotFound) {
        return NO;
    }
    id spec = specs[index];

    // 原始条目存一份，之后每次都从它算起，这样开关关掉时能把条目还原回来
    id items = APSNSpecifierValue(spec, @"apelinOriginalItems");
    if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
        items = APSNSpecifierValue(spec, @"followUpItems");
        if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
            return NO;
        }
        [spec setProperty:items forKey:@"apelinOriginalItems"];
    }
    APSNWriteItems(items);

    NSMutableArray *kept = [NSMutableArray array];
    for (id item in items) {
        NSString *kind = APSNItemKind(item);
        BOOL hidden = kind != nil &&
            APSNPreferenceBool([APSNItemKeyPrefix stringByAppendingString:kind]);
        if (!hidden) {
            [kept addObject:item];
        }
    }

    if (APSNPreferenceBool(APSNHideGroupKey) || [kept count] == 0) {
        if (![controller respondsToSelector:@selector(removeSpecifier:animated:)]) {
            return NO;
        }
        APSNRemovedSpec = spec;
        APSNRemovedIndex = (NSInteger)index;
        [(id)controller removeSpecifier:spec animated:NO];
        APSNSetIconBadge(0);
        os_log(APSNLog(), "APSN removed follow-up row (live) hideGroup=%d kept=%lu of %lu",
               (int)APSNPreferenceBool(APSNHideGroupKey),
               (unsigned long)[kept count], (unsigned long)[items count]);
        APSNWriteState(@"removed follow-up row (live)");
        return YES;
    }

    id previous = APSNSpecifierValue(spec, @"followUpItems");
    NSArray *previousArray = [previous isKindOfClass:[NSArray class]] ? previous : @[];
    // 已经是这个样子了就不动表格，免得每次刷新都重建这一行
    if ([previousArray isEqualToArray:kept] &&
        [APSNSpecifierValue(spec, @"badgeNumber") integerValue] == (NSInteger)[kept count]) {
        return NO;
    }
    NSUInteger previousCount = [previousArray count];
    [spec setProperty:kept forKey:@"followUpItems"];
    [spec setProperty:@([kept count]) forKey:@"badgeNumber"];
    APSNSetIconBadge([kept count]);
    // 单元格是缓存在 specifier 上的，不清掉的话角标还是旧数字
    [spec setProperty:nil forKey:@"cellObject"];
    if ([controller respondsToSelector:@selector(reloadSpecifier:)]) {
        [(id)controller reloadSpecifier:spec];
    }
    if ([kept count] != previousCount) {
        NSMutableArray *titles = [NSMutableArray array];
        for (id item in kept) {
            NSString *title = APSNItemTitle(item);
            [titles addObject:title ?: @"?"];
        }
        os_log(APSNLog(), "APSN hid %lu of %lu follow-up items",
               (unsigned long)([items count] - [kept count]), (unsigned long)[items count]);
        APSNWriteState([NSString stringWithFormat:@"row badge=%lu items=%@",
                                                  (unsigned long)[kept count],
                                                  [titles componentsJoinedByString:@" | "]]);
    }
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
    static BOOL reloading;
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
    APSNRestoreRemovedRow(root);
    if (APSNUpdateLive(root)) {
        os_log(APSNLog(), "APSN refreshed (%{public}@)", reason);
    }
    // 行没了又没有留底（比如系统自己重建过列表）时，只能让「设置」重新装配一次；
    // 只在设置变更时做，定时器不去反复重建。
    if ([reason isEqualToString:@"prefs changed"] && !reloading && APSNRemovedSpec == nil &&
        !APSNHasFollowUpRow(root) && APSNRowShouldShow()) {
        reloading = YES;
        @try {
            [(id)root performSelector:@selector(reloadSpecifiers)];
        } @catch (__unused NSException *exception) {
        }
        reloading = NO;
        APSNWriteState(@"rebuilt list to bring the row back");
        APSNUpdateLive(root);
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
        NSMutableArray *filtered = [specifiers mutableCopy];
        BOOL hadRow = APSNFollowUpIndex(specifiers) != NSNotFound;
        if (APSNFilterSpecifiers(filtered)) {
            os_log(APSNLog(), "APSN setSpecifiers %{public}@ %lu -> %lu (row=%d)",
                   APSNClassName(self), (unsigned long)[specifiers count],
                   (unsigned long)[filtered count], (int)hadRow);
            APSNWriteState([NSString stringWithFormat:@"setSpecifiers %@ -> %lu (was %lu)",
                                                      APSNClassName(self),
                                                      (unsigned long)[filtered count],
                                                      (unsigned long)[specifiers count]]);
            specifiers = filtered;
        } else if (hadRow) {
            os_log(APSNLog(), "APSN setSpecifiers %{public}@ %lu, row kept",
                   APSNClassName(self), (unsigned long)[specifiers count]);
        }
    }
    if (OriginalSetSpecifiers != NULL) {
        OriginalSetSpecifiers(self, _cmd, specifiers);
    }
}

// 这一行现在该不该出现在列表里；该出现时顺手把条目过滤好。
// 插进列表的那一刻就用它拦一次，「设置」首页刚回来时那一闪就没了。
static BOOL APSNFollowUpSpecifierShouldShow(id spec) {
    if (APSNPreferenceBool(APSNHideGroupKey)) {
        return NO;
    }
    id items = APSNSpecifierValue(spec, @"apelinOriginalItems");
    if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
        items = APSNSpecifierValue(spec, @"followUpItems");
        if (![items isKindOfClass:[NSArray class]] || [items count] == 0) {
            return YES;
        }
        [spec setProperty:items forKey:@"apelinOriginalItems"];
    }
    NSMutableArray *kept = [NSMutableArray array];
    for (id item in items) {
        NSString *kind = APSNItemKind(item);
        BOOL hidden = kind != nil &&
            APSNPreferenceBool([APSNItemKeyPrefix stringByAppendingString:kind]);
        if (!hidden) {
            [kept addObject:item];
        }
    }
    if ([kept count] == 0) {
        return NO;
    }
    [spec setProperty:kept forKey:@"followUpItems"];
    [spec setProperty:@([kept count]) forKey:@"badgeNumber"];
    [spec setProperty:nil forKey:@"cellObject"];
    APSNSetIconBadge([kept count]);
    return YES;
}

static void (*OriginalInsertSpecifier)(id, SEL, id, NSInteger, BOOL);
static void (*OriginalAddSpecifier)(id, SEL, id);
static void (*OriginalInsertContiguous)(id, SEL, NSArray *, NSInteger);
static void (*OriginalPrivateInsertContiguous)(id, SEL, NSArray *, NSInteger, BOOL);

// 系统那一行是一批 specifier 一起插进来的（insertContiguousSpecifiers:atIndex:），
// 不走 insertSpecifier:，所以这里也得拦一遍。
static NSArray *APSNFilterInsertedSpecifiers(id self, NSArray *specifiers, NSInteger index) {
    if (![specifiers isKindOfClass:[NSArray class]] || [specifiers count] == 0) {
        return specifiers;
    }
    NSString *name = APSNClassName(self);
    if ([name hasPrefix:@"APSNoSuggestions"]) {
        return specifiers;
    }
    NSMutableArray *kept = [NSMutableArray array];
    BOOL dropped = NO;
    for (NSUInteger i = 0; i < [specifiers count]; i++) {
        id spec = specifiers[i];
        id identifier = APSNSpecifierValue(spec, @"identifier");
        if ([identifier isKindOfClass:[NSString class]] &&
            [identifier hasPrefix:APSNFollowUpPrefix] &&
            !APSNFollowUpSpecifierShouldShow(spec)) {
            APSNRemovedSpec = spec;
            APSNRemovedIndex = index >= 0 ? index + (NSInteger)i : -1;
            dropped = YES;
            continue;
        }
        [kept addObject:spec];
    }
    if (!dropped) {
        return specifiers;
    }
    APSNSetIconBadge(0);
    os_log(APSNLog(), "APSN blocked follow-up row insert (%lu -> %lu) at %ld",
           (unsigned long)[specifiers count], (unsigned long)[kept count], (long)index);
    return kept;
}

static void APSNHookedInsertContiguous(id self, SEL _cmd, NSArray *specifiers, NSInteger index) {
    NSArray *kept = APSNFilterInsertedSpecifiers(self, specifiers, index);
    if ([specifiers count] > 0 && [kept count] == 0) {
        return;
    }
    if (OriginalInsertContiguous != NULL) {
        OriginalInsertContiguous(self, _cmd, kept, index);
    }
}

static void APSNHookedPrivateInsertContiguous(id self, SEL _cmd, NSArray *specifiers,
                                             NSInteger index, BOOL animated) {
    NSArray *kept = APSNFilterInsertedSpecifiers(self, specifiers, index);
    if ([specifiers count] > 0 && [kept count] == 0) {
        return;
    }
    if (OriginalPrivateInsertContiguous != NULL) {
        OriginalPrivateInsertContiguous(self, _cmd, kept, index, animated);
    }
}

static BOOL APSNHookShouldSkip(id self, id specifier) {
    NSString *name = APSNClassName(self);
    if ([name hasPrefix:@"APSNoSuggestions"]) {
        return NO;
    }
    id identifier = APSNSpecifierValue(specifier, @"identifier");
    if (![identifier isKindOfClass:[NSString class]] ||
        ![identifier hasPrefix:APSNFollowUpPrefix]) {
        return NO;
    }
    return !APSNFollowUpSpecifierShouldShow(specifier);
}

static void APSNHookedInsertSpecifier(id self, SEL _cmd, id specifier, NSInteger index, BOOL animated) {
    if (APSNHookShouldSkip(self, specifier)) {
        APSNRemovedSpec = specifier;
        APSNRemovedIndex = index;
        APSNSetIconBadge(0);
        os_log(APSNLog(), "APSN blocked follow-up row insert at %ld", (long)index);
        return;
    }
    if (OriginalInsertSpecifier != NULL) {
        OriginalInsertSpecifier(self, _cmd, specifier, index, animated);
    }
}

static void APSNHookedAddSpecifier(id self, SEL _cmd, id specifier) {
    if (APSNHookShouldSkip(self, specifier)) {
        APSNRemovedSpec = specifier;
        APSNRemovedIndex = -1;
        APSNSetIconBadge(0);
        os_log(APSNLog(), "APSN blocked follow-up row append");
        return;
    }
    if (OriginalAddSpecifier != NULL) {
        OriginalAddSpecifier(self, _cmd, specifier);
    }
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

    // 列表是边装配边往表格里插的：在这一行被插进来的那一刻就拦掉，
    // 首页回来时才不会先闪一下再消失。
    if (rootController != Nil) {
        SEL insertSelector = @selector(insertSpecifier:atIndex:animated:);
        if (OriginalInsertSpecifier == NULL) {
            Class owner = APSNImplementingClass(rootController, insertSelector);
            if (owner != Nil) {
                MSHookMessageEx(owner, insertSelector,
                                (IMP)APSNHookedInsertSpecifier,
                                (IMP *)&OriginalInsertSpecifier);
            }
        }
        if (OriginalAddSpecifier == NULL) {
            Class owner = APSNImplementingClass(rootController, @selector(addSpecifier:));
            if (owner != Nil) {
                MSHookMessageEx(owner, @selector(addSpecifier:),
                                (IMP)APSNHookedAddSpecifier,
                                (IMP *)&OriginalAddSpecifier);
            }
        }
        SEL contiguousSelector = @selector(insertContiguousSpecifiers:atIndex:);
        if (OriginalInsertContiguous == NULL) {
            Class owner = APSNImplementingClass(rootController, contiguousSelector);
            if (owner != Nil) {
                MSHookMessageEx(owner, contiguousSelector,
                                (IMP)APSNHookedInsertContiguous,
                                (IMP *)&OriginalInsertContiguous);
            }
        }
        SEL privateContiguousSelector = NSSelectorFromString(@"_insertContiguousSpecifiers:atIndex:animated:");
        if (OriginalPrivateInsertContiguous == NULL) {
            Class owner = APSNImplementingClass(rootController, privateContiguousSelector);
            if (owner != Nil) {
                MSHookMessageEx(owner, privateContiguousSelector,
                                (IMP)APSNHookedPrivateInsertContiguous,
                                (IMP *)&OriginalPrivateInsertContiguous);
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
