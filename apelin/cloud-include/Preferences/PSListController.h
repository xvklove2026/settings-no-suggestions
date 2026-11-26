// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
// Adapted from Apelin's MIT-licensed development support declarations.
#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@class PSSpecifier;
typedef NS_ENUM(NSInteger, PSCellType) {
    PSGroupCell = 0, PSLinkCell = 1, PSLinkListCell = 2, PSListItemCell = 3,
    PSTitleValueCell = 4, PSSliderCell = 5, PSSwitchCell = 6, PSStaticTextCell = 7,
    PSEditTextCell = 8, PSSegmentCell = 9, PSGiantIconCell = 10, PSGiantCell = 11,
    PSSecureEditTextCell = 12, PSButtonCell = 13, PSEditTextViewCell = 14
};
@interface PSViewController : UIViewController
@end
@interface PSListController : PSViewController {
@protected
    NSMutableArray *_specifiers;
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (PSSpecifier *)specifierForID:(NSString *)identifier;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
- (void)addSpecifier:(PSSpecifier *)specifier;
- (void)insertSpecifier:(PSSpecifier *)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)removeSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end
@interface PSSpecifier : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) id target;
@property (nonatomic) PSCellType cellType;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(PSCellType)cell edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)emptyGroupSpecifier;
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (void)removePropertyForKey:(NSString *)key;
@end
