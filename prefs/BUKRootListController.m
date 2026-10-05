#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>

extern char **environ;

static NSString * const kBUKPrefsDomain = @"com.ttlongdl.batteryukrm";

@interface BUKRootListController : PSListController
@end

@implementation BUKRootListController

- (NSString *)localized:(NSString *)key {
    return [[NSBundle bundleForClass:[self class]] localizedStringForKey:key value:key table:nil];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:@"BatteryUKRM"];
    [header setProperty:[self localized:@"HIDE_REPAIR_DESC"] forKey:@"footerText"];
    [specifiers addObject:header];

    PSSpecifier *repair = [PSSpecifier preferenceSpecifierNamed:[self localized:@"HIDE_REPAIR_TITLE"]
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [repair setProperty:@"HideRepairWarnings" forKey:@"key"];
    [repair setProperty:@YES forKey:@"default"];
    [repair setProperty:kBUKPrefsDomain forKey:@"defaults"];
    [specifiers addObject:repair];

    PSSpecifier *capacityGroup = [PSSpecifier groupSpecifierWithName:@""];
    [capacityGroup setProperty:[self localized:@"MAX_CAPACITY_DESC"] forKey:@"footerText"];
    [specifiers addObject:capacityGroup];

    PSSpecifier *capacity = [PSSpecifier preferenceSpecifierNamed:[self localized:@"MAX_CAPACITY_TITLE"]
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [capacity setProperty:@"RestoreMaximumCapacity" forKey:@"key"];
    [capacity setProperty:@YES forKey:@"default"];
    [capacity setProperty:kBUKPrefsDomain forKey:@"defaults"];
    [specifiers addObject:capacity];

    PSSpecifier *cycleGroup = [PSSpecifier groupSpecifierWithName:@""];
    [cycleGroup setProperty:[self localized:@"CYCLE_COUNT_DESC"] forKey:@"footerText"];
    [specifiers addObject:cycleGroup];

    PSSpecifier *cycle = [PSSpecifier preferenceSpecifierNamed:[self localized:@"CYCLE_COUNT_TITLE"]
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [cycle setProperty:@"ShowCycleCount" forKey:@"key"];
    [cycle setProperty:@YES forKey:@"default"];
    [cycle setProperty:kBUKPrefsDomain forKey:@"defaults"];
    [specifiers addObject:cycle];

    PSSpecifier *actionGroup = [PSSpecifier groupSpecifierWithName:@""];
    [actionGroup setProperty:[self localized:@"RESPRING_NOTE"] forKey:@"footerText"];
    [specifiers addObject:actionGroup];

    PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:[self localized:@"RESPRING"]
        target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    [respring setButtonAction:@selector(respring)];
    [specifiers addObject:respring];

    PSSpecifier *footer = [PSSpecifier groupSpecifierWithName:@""];
    [footer setProperty:[self localized:@"PACKAGE_FOOTER"] forKey:@"footerText"];
    [specifiers addObject:footer];

    _specifiers = [specifiers copy];
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kBUKPrefsDomain];
    id value = [prefs objectForKey:[specifier propertyForKey:@"key"]];
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *prefs = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:kBUKPrefsDomain] mutableCopy];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    [prefs setObject:value forKey:[specifier propertyForKey:@"key"]];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:prefs forName:kBUKPrefsDomain];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)spawnExecutable:(NSString *)path arguments:(NSArray<NSString *> *)arguments {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) return NO;

    NSMutableArray<NSString *> *allArgs = [NSMutableArray arrayWithObject:path];
    [allArgs addObjectsFromArray:arguments];

    char **argv = calloc(allArgs.count + 1, sizeof(char *));
    if (!argv) return NO;

    for (NSUInteger i = 0; i < allArgs.count; i++) {
        argv[i] = strdup(allArgs[i].UTF8String);
    }

    pid_t pid = 0;
    int status = posix_spawn(&pid, path.UTF8String, NULL, NULL, argv, environ);

    for (NSUInteger i = 0; i < allArgs.count; i++) free(argv[i]);
    free(argv);

    return status == 0;
}

- (void)respring {
    if ([self spawnExecutable:@"/var/jb/usr/bin/sbreload" arguments:@[]]) return;
    if ([self spawnExecutable:@"/usr/bin/sbreload" arguments:@[]]) return;
    if ([self spawnExecutable:@"/var/jb/usr/bin/killall" arguments:@[@"-9", @"SpringBoard"]]) return;
    [self spawnExecutable:@"/usr/bin/killall" arguments:@[@"-9", @"SpringBoard"]];
}

@end
