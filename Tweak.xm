#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

static IMP gOrigBHSpecifiers = NULL;
static IMP gOrigBadgeValue = NULL;
static BOOL gPrefsHooksInstalled = NO;
static BOOL gBatteryHooksInstalled = NO;
static BOOL gSpringBoardHookInstalled = NO;

static void BUKReplaceInstanceMethod(Class cls, SEL sel, IMP replacement) {
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (m) method_setImplementation(m, replacement);
}

static void BUKReplaceClassMethod(Class cls, SEL sel, IMP replacement) {
    Class meta = cls ? object_getClass(cls) : Nil;
    Method m = meta ? class_getInstanceMethod(meta, sel) : NULL;
    if (m) method_setImplementation(m, replacement);
}

// MARK: - Battery authentication / repair-state behavior preserved from 1.0.1

static void BUK_UpdateFollowupSpecifiers(id self, SEL _cmd, id completion) {
    if (completion) {
        void (^block)(void) = completion;
        block();
    }
}

static BOOL BUK_IsValidCAA(id self, SEL _cmd, id arg) {
    return YES;
}

static id BUK_SystemHealthSpecifiers(id self, SEL _cmd) {
    return nil;
}

static int BUK_ZeroState(id self, SEL _cmd) {
    return 0;
}

static int BUK_GenuineBatteryStatus(id self, SEL _cmd) {
    return 1;
}

static int BUK_ManagementState(id self, SEL _cmd) {
    return 2;
}

static BOOL BUK_SupportsChargingFixedLimit(id self, SEL _cmd) {
    return NO;
}

static id BUK_BadgeValue(id self, SEL _cmd) {
    NSString *bundleID = nil;
    @try {
        if ([self respondsToSelector:@selector(bundleIdentifier)]) {
            bundleID = [self performSelector:@selector(bundleIdentifier)];
        }
    } @catch (__unused NSException *e) {}

    if ([bundleID isEqualToString:@"com.apple.Preferences"]) return nil;

    id (*orig)(id, SEL) = (id (*)(id, SEL))gOrigBadgeValue;
    return orig ? orig(self, _cmd) : nil;
}

// MARK: - Real cycle count

static NSNumber *BUKRealCycleCount(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) return nil;

    typedef void *(*MatchingFn)(const char *);
    typedef unsigned int (*GetServiceFn)(unsigned int, void *);
    typedef const void *(*CreatePropFn)(unsigned int, const void *, const void *, unsigned int);
    typedef int (*ReleaseFn)(unsigned int);

    MatchingFn matching = (MatchingFn)dlsym(h, "IOServiceMatching");
    GetServiceFn getService = (GetServiceFn)dlsym(h, "IOServiceGetMatchingService");
    CreatePropFn createProp = (CreatePropFn)dlsym(h, "IORegistryEntryCreateCFProperty");
    ReleaseFn releaseObj = (ReleaseFn)dlsym(h, "IOObjectRelease");

    NSNumber *result = nil;
    if (matching && getService && createProp) {
        unsigned int service = getService(0, matching("AppleSmartBattery"));
        if (service) {
            CFTypeRef value = (CFTypeRef)createProp(service, CFSTR("CycleCount"), kCFAllocatorDefault, 0);
            if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
                result = [(__bridge NSNumber *)value copy];
            }
            if (value) CFRelease(value);
            if (releaseObj) releaseObj(service);
        }
    }

    dlclose(h);
    return result;
}

static id BUKCycleValue(id self, SEL _cmd, id specifier) {
    NSNumber *n = BUKRealCycleCount();
    return n ? [n stringValue] : @"--";
}

static BOOL BUKIsVietnamese(void) {
    NSString *lang = [[NSLocale preferredLanguages] firstObject] ?: @"en";
    return [lang hasPrefix:@"vi"];
}

static id BUKMakeCycleSpecifier(id target, NSArray *existing) {
    NSInteger cellType = 4;

    for (id candidate in existing) {
        @try {
            NSString *name = [[candidate valueForKey:@"name"] description];
            if ([name containsString:@"Dung lượng tối đa"] || [name containsString:@"Maximum Capacity"]) {
                id ct = [candidate valueForKey:@"cellType"];
                if ([ct respondsToSelector:@selector(integerValue)]) cellType = [ct integerValue];
                break;
            }
        } @catch (__unused NSException *e) {}
    }

    Class PS = NSClassFromString(@"PSSpecifier");
    SEL factory = NSSelectorFromString(@"preferenceSpecifierNamed:target:set:get:detail:cell:edit:");
    if (!PS || ![PS respondsToSelector:factory]) return nil;

    typedef id (*FactoryFn)(id, SEL, id, id, SEL, SEL, Class, NSInteger, Class);
    FactoryFn make = (FactoryFn)[PS methodForSelector:factory];

    NSString *title = BUKIsVietnamese() ? @"Số chu kỳ" : @"Cycle Count";
    id sp = make(PS, factory, title, target, NULL, @selector(buk_realCycleCount:), Nil, cellType, Nil);

    if (sp && [sp respondsToSelector:@selector(setProperty:forKey:)]) {
        [sp performSelector:@selector(setProperty:forKey:) withObject:@"BatteryUKRMRealCycleCount" withObject:@"id"];
        [sp performSelector:@selector(setProperty:forKey:) withObject:@"BatteryUKRMRealCycleCount" withObject:@"key"];
    }

    return sp;
}

static id BUK_BH_specifiers(id self, SEL _cmd) {
    id (*orig)(id, SEL) = (id (*)(id, SEL))gOrigBHSpecifiers;
    id original = orig ? orig(self, _cmd) : nil;
    if (![original isKindOfClass:[NSArray class]]) return original;

    NSMutableArray *out = [original mutableCopy];

    for (id candidate in out) {
        @try {
            id ident = [candidate valueForKey:@"identifier"];
            id sid = nil;
            if ([candidate respondsToSelector:@selector(propertyForKey:)]) {
                sid = [candidate performSelector:@selector(propertyForKey:) withObject:@"id"];
            }
            if ([ident isEqual:@"BatteryUKRMRealCycleCount"] ||
                [sid isEqual:@"BatteryUKRMRealCycleCount"]) {
                return out;
            }
        } @catch (__unused NSException *e) {}
    }

    if (!BUKRealCycleCount()) return out;

    id cycleSpecifier = BUKMakeCycleSpecifier(self, out);
    if (!cycleSpecifier) return out;

    NSUInteger peakIndex = NSNotFound;
    for (NSUInteger i = 0; i < [out count]; i++) {
        id candidate = [out objectAtIndex:i];
        @try {
            NSString *name = [[candidate valueForKey:@"name"] description];
            if ([name containsString:@"Dung lượng hiệu năng đỉnh"] ||
                [name containsString:@"Peak Performance"]) {
                peakIndex = i;
                break;
            }
        } @catch (__unused NSException *e) {}
    }

    NSUInteger insertIndex = peakIndex;
    if (peakIndex != NSNotFound && peakIndex > 0) {
        id previous = [out objectAtIndex:peakIndex - 1];
        @try {
            NSInteger previousCell = [[previous valueForKey:@"cellType"] integerValue];
            if (previousCell == 0) insertIndex = peakIndex - 1;
        } @catch (__unused NSException *e) {}
    }
    if (insertIndex == NSNotFound) insertIndex = MIN((NSUInteger)2, [out count]);

    Class PS = NSClassFromString(@"PSSpecifier");
    SEL groupSel = NSSelectorFromString(@"emptyGroupSpecifier");
    id cycleGroup = nil;
    if (PS && [PS respondsToSelector:groupSel]) {
        id (*groupFn)(id, SEL) = (id (*)(id, SEL))[PS methodForSelector:groupSel];
        cycleGroup = groupFn(PS, groupSel);
    }

    if (cycleGroup) {
        NSString *footer = BUKIsVietnamese()
            ? @"Đây là số lần iPhone đã sử dụng dung lượng pin của bạn."
            : @"This is the number of times iPhone has used your battery’s capacity.";
        if ([cycleGroup respondsToSelector:@selector(setProperty:forKey:)]) {
            [cycleGroup performSelector:@selector(setProperty:forKey:) withObject:footer withObject:@"footerText"];
        }
        [out insertObject:cycleGroup atIndex:insertIndex];
        insertIndex++;
    }

    [out insertObject:cycleSpecifier atIndex:insertIndex];

    @try {
        Ivar iv = class_getInstanceVariable([self class], "_specifiers");
        if (iv) object_setIvar(self, iv, out);
    } @catch (__unused NSException *e) {}

    return out;
}

// MARK: - Hook installation

static void BUKInstallPreferencesHooks(void) {
    if (gPrefsHooksInstalled) return;

    Class prefs = NSClassFromString(@"PSUIPrefsListController");
    Class health = NSClassFromString(@"SystemHealthUI");

    BOOL installed = NO;
    if (prefs) {
        BUKReplaceInstanceMethod(prefs, NSSelectorFromString(@"updateFollowupSpecifiersWithCompletion:"), (IMP)BUK_UpdateFollowupSpecifiers);
        installed = YES;
    }
    if (health) {
        BUKReplaceInstanceMethod(health, NSSelectorFromString(@"isVaildCAA:"), (IMP)BUK_IsValidCAA);
        BUKReplaceInstanceMethod(health, NSSelectorFromString(@"getCurrentSystemHealthInfoSpecifiers"), (IMP)BUK_SystemHealthSpecifiers);
        installed = YES;
    }

    if (installed) gPrefsHooksInstalled = YES;
}

static void BUKInstallBatteryHooks(void) {
    if (gBatteryHooksInstalled) return;

    Class resource = NSClassFromString(@"BatteryUIResourceClass");
    Class backend = NSClassFromString(@"PLBatteryUIBackendModel");
    Class healthUI = NSClassFromString(@"BatteryHealthUIController");

    if (!resource && !backend && !healthUI) return;

    BUKReplaceClassMethod(resource, NSSelectorFromString(@"getBatteryHealthServiceState"), (IMP)BUK_ZeroState);
    BUKReplaceClassMethod(resource, NSSelectorFromString(@"genuineBatteryStatus"), (IMP)BUK_GenuineBatteryStatus);
    BUKReplaceClassMethod(resource, NSSelectorFromString(@"getManagementState"), (IMP)BUK_ManagementState);
    BUKReplaceClassMethod(backend, NSSelectorFromString(@"supportsChargingFixedLimit"), (IMP)BUK_SupportsChargingFixedLimit);

    if (healthUI) {
        Method m = class_getInstanceMethod(healthUI, @selector(specifiers));
        if (m && !gOrigBHSpecifiers) {
            class_addMethod(healthUI, @selector(buk_realCycleCount:), (IMP)BUKCycleValue, "@@:@");
            gOrigBHSpecifiers = method_getImplementation(m);
            method_setImplementation(m, (IMP)BUK_BH_specifiers);
        }
    }

    gBatteryHooksInstalled = YES;
}

static void BUKInstallSpringBoardHook(void) {
    if (gSpringBoardHookInstalled) return;

    Class cls = NSClassFromString(@"SBApplication");
    Method m = cls ? class_getInstanceMethod(cls, @selector(badgeValue)) : NULL;
    if (!m) return;

    gOrigBadgeValue = method_getImplementation(m);
    method_setImplementation(m, (IMP)BUK_BadgeValue);
    gSpringBoardHookInstalled = YES;
}

static void BUKInstallAvailableHooks(void) {
    BUKInstallPreferencesHooks();
    BUKInstallBatteryHooks();
    BUKInstallSpringBoardHook();
}

static void BUKImageAdded(const struct mach_header *mh, intptr_t slide) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BUKInstallAvailableHooks();
    });
}

%ctor {
    @autoreleasepool {
        BUKInstallAvailableHooks();
        _dyld_register_func_for_add_image(BUKImageAdded);
    }
}
