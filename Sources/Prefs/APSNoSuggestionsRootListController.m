// 「设置 → Apple ID 建议」面板：一个总开关，加上当前每一条建议的单独开关。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <dlfcn.h>

@interface APSNoSuggestionsRootListController : PSListController
@end

@implementation APSNoSuggestionsRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// 面板也跑在「设置」进程里，同样从 bootstrap 的 /var 读 tweak 写下的列表
static NSString *APSNBundleStatePath(NSString *name) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#ifdef APELIN_BOOTSTRAP_ROOTHIDE
        static const char anchor = 0;
        Dl_info info;
        if (dladdr(&anchor, &info) == 0 || info.dli_fname == NULL) {
            return;
        }
        NSArray<NSString *> *parts = [@(info.dli_fname) componentsSeparatedByString:@"/"];
        for (NSUInteger i = 0; i < parts.count; i++) {
            if ([parts[i] hasPrefix:@".jbroot-"]) {
                root = [[parts subarrayWithRange:NSMakeRange(0, i + 1)]
                    componentsJoinedByString:@"/"];
                break;
            }
        }
#else
        root = @"/var/jb";
#endif
    });
    if (root == nil) {
        return nil;
    }
    return [root stringByAppendingPathComponent:
                     [@"/var/mobile/Library/APSNoSuggestions" stringByAppendingPathComponent:name]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self buildItemSpecifiers];
}

- (void)buildItemSpecifiers {
    NSArray *items = [NSArray arrayWithContentsOfFile:APSNBundleStatePath(@"items.plist")];
    NSArray *specifiers = [self specifiers];
    PSSpecifier *group = [self specifierForID:@"ITEMS_GROUP"];
    PSSpecifier *placeholder = [self specifierForID:@"ITEMS_PLACEHOLDER"];

    for (PSSpecifier *specifier in [specifiers copy]) {
        NSString *key = [specifier propertyForKey:@"key"];
        if ([key isKindOfClass:[NSString class]] && [key hasPrefix:@"hide-"]) {
            [self removeSpecifier:specifier animated:NO];
        }
    }
    group = [self specifierForID:@"ITEMS_GROUP"];
    placeholder = [self specifierForID:@"ITEMS_PLACEHOLDER"];
    specifiers = [self specifiers];
    NSInteger index = specifiers.count;
    if (group != nil) {
        NSUInteger groupIndex = [specifiers indexOfObjectIdenticalTo:group];
        if (groupIndex != NSNotFound) {
            index = (NSInteger)groupIndex + 1;
        }
    }

    if (items.count == 0) {
        if (placeholder == nil) {
            placeholder = [PSSpecifier preferenceSpecifierNamed:@"暂时没读到建议：先打开一次「设置」首页，再回到这里。"
                                                            target:nil
                                                               set:NULL
                                                               get:NULL
                                                            detail:Nil
                                                              cell:PSStaticTextCell
                                                              edit:Nil];
            [placeholder setProperty:@"ITEMS_PLACEHOLDER" forKey:@"id"];
            [self insertSpecifier:placeholder atIndex:index animated:NO];
        } else {
            [placeholder setProperty:@"暂时没读到建议：先打开一次「设置」首页，再回到这里。"
                             forKey:@"label"];
            [self reloadSpecifier:placeholder];
        }
        return;
    }
    if (placeholder != nil) {
        [self removeSpecifier:placeholder animated:NO];
    }
    for (NSDictionary *item in items) {
        NSString *kind = item[@"kind"];
        NSString *title = item[@"title"];
        if (![kind isKindOfClass:[NSString class]] || kind.length == 0) {
            continue;
        }
        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:
                                            ([title isKindOfClass:[NSString class]] ? title : kind)
                                                          target:self
                                                             set:@selector(setPreferenceValue:specifier:)
                                                             get:@selector(readPreferenceValue:)
                                                          detail:Nil
                                                            cell:PSSwitchCell
                                                            edit:Nil];
        [spec setProperty:[@"hide-" stringByAppendingString:kind] forKey:@"key"];
        [spec setProperty:@APELIN_PACKAGE_ID forKey:@"defaults"];
        [spec setProperty:@NO forKey:@"default"];
        [self insertSpecifier:spec atIndex:index++ animated:NO];
    }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    // 让 tweak 立刻重新过滤「设置」首页。
    // 注意：不要在这里顺手 reloadSpecifiers 首页 —— 面板还压在栈上，
    // 重建首页会把面板的列表一起清成空白，得退出去再进来才恢复。
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)(@APELIN_PACKAGE_ID "/changed"),
                                         NULL, NULL, true);
}

@end
