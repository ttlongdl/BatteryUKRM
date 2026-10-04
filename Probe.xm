#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

static NSString *const kLogPath = @"/var/mobile/BatteryUKRM-probe.log";
static IMP gOrigBHSpecifiers = NULL;
static BOOL gDidHook = NO;

static void BUKWrite(NSString *line) {
    NSString *msg = [NSString stringWithFormat:@"%@\n", line ?: @""];
    NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kLogPath]) { [data writeToFile:kLogPath atomically:YES]; return; }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:data]; [fh synchronizeFile]; } @catch (__unused NSException *e) {}
    [fh closeFile];
}

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
            if (value && CFGetTypeID(value) == CFNumberGetTypeID()) result = [(__bridge NSNumber *)value copy];
            if (value) CFRelease(value);
            if (releaseObj) releaseObj(service);
        }
    }
    dlclose(h);
    return result;
}

static id BUKCycleValue(id self, SEL _cmd, id specifier) {
    NSNumber *n = BUKRealCycleCount();
    NSString *v = n ? [n stringValue] : @"--";
    BUKWrite([NSString stringWithFormat:@"DEBUG17 Cycle row value=%@", v]);
    return v;
}

static id BUKMakeCycleSpecifier(id target, NSArray *existing) {
    NSInteger cellType = 4;
    for (id candidate in existing) {
        @try {
            NSString *name = [[candidate valueForKey:@"name"] description];
            if ([name containsString:@"Dung lượng tối đa"] || [name containsString:@"Maximum Capacity"]) {
                id ct = [candidate valueForKey:@"cellType"];
                if ([ct respondsToSelector:@selector(integerValue)]) cellType = [ct integerValue];
                BUKWrite([NSString stringWithFormat:@"DEBUG17 template cellType=%ld", (long)cellType]);
                break;
            }
        } @catch (__unused NSException *e) {}
    }

    Class PS = NSClassFromString(@"PSSpecifier");
    SEL factory = NSSelectorFromString(@"preferenceSpecifierNamed:target:set:get:detail:cell:edit:");
    if (!PS || ![PS respondsToSelector:factory]) {
        BUKWrite(@"DEBUG17 PSSpecifier factory unavailable");
        return nil;
    }

    typedef id (*FactoryFn)(id, SEL, id, id, SEL, SEL, Class, NSInteger, Class);
    FactoryFn make = (FactoryFn)[PS methodForSelector:factory];
    id sp = make(PS, factory, @"Số chu kỳ", target, NULL, @selector(buk_realCycleCount:), Nil, cellType, Nil);
    if (sp && [sp respondsToSelector:@selector(setProperty:forKey:)]) {
        [sp performSelector:@selector(setProperty:forKey:) withObject:@"BatteryUKRMRealCycleCount" withObject:@"id"];
        [sp performSelector:@selector(setProperty:forKey:) withObject:@"BatteryUKRMRealCycleCount" withObject:@"key"];
    }
    BUKWrite([NSString stringWithFormat:@"DEBUG17 created specifier=%@ cellType=%ld", sp, (long)cellType]);
    return sp;
}

static id BUK_BH_specifiers(id self, SEL _cmd) {
    id (*orig)(id, SEL) = (id (*)(id, SEL))gOrigBHSpecifiers;
    id original = orig ? orig(self, _cmd) : nil;
    if (![original isKindOfClass:[NSArray class]]) return original;

    NSMutableArray *out = [original mutableCopy];
    BOOL exists = NO;
    for (id sp in out) {
        @try {
            id ident = [sp valueForKey:@"identifier"];
            id sid = nil;
            if ([sp respondsToSelector:@selector(propertyForKey:)])
                sid = [sp performSelector:@selector(propertyForKey:) withObject:@"id"];
            if ([ident isEqual:@"BatteryUKRMRealCycleCount"] || [sid isEqual:@"BatteryUKRMRealCycleCount"]) { exists = YES; break; }
        } @catch (__unused NSException *e) {}
    }
    NSNumber *cycle = BUKRealCycleCount();
    if (!exists && cycle) {
        id sp = BUKMakeCycleSpecifier(self, out);
        if (sp) {
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
            id groupBefore = nil;
            id groupAfter = nil;
            SEL groupSel = NSSelectorFromString(@"emptyGroupSpecifier");
            if (PS && [PS respondsToSelector:groupSel]) {
                id (*groupFn)(id, SEL) = (id (*)(id, SEL))[PS methodForSelector:groupSel];
                groupBefore = groupFn(PS, groupSel);
                groupAfter = groupFn(PS, groupSel);
            }

            if (groupBefore) {
                [out insertObject:groupBefore atIndex:insertIndex];
                insertIndex++;
            }
            [out insertObject:sp atIndex:insertIndex];
            if (groupAfter) [out insertObject:groupAfter atIndex:insertIndex + 1];

            BUKWrite([NSString stringWithFormat:@"DEBUG17 inserted CycleCount=%@ before peak-group boundary index=%lu groups=%@/%@",
                      cycle, (unsigned long)insertIndex,
                      groupBefore ? @"YES" : @"NO", groupAfter ? @"YES" : @"NO"]);

            @try {
                Ivar iv = class_getInstanceVariable([self class], "_specifiers");
                if (iv) {
                    object_setIvar(self, iv, out);
                    BUKWrite(@"DEBUG17 replaced _specifiers ivar");
                } else {
                    BUKWrite(@"DEBUG17 _specifiers ivar not found");
                }
            } @catch (NSException *e) {
                BUKWrite([NSString stringWithFormat:@"DEBUG17 _specifiers exception=%@", e.name]);
            }
        }
    }
    return out;
}

static void BUKInstall(void) {
    if (gDidHook) return;
    Class cls = NSClassFromString(@"BatteryHealthUIController");
    Method m = cls ? class_getInstanceMethod(cls, @selector(specifiers)) : NULL;
    if (!m) { BUKWrite(@"DEBUG17 BatteryHealthUIController/specifiers unavailable"); return; }

    class_addMethod(cls, @selector(buk_realCycleCount:), (IMP)BUKCycleValue, "@@:@");
    gOrigBHSpecifiers = method_getImplementation(m);
    method_setImplementation(m, (IMP)BUK_BH_specifiers);
    gDidHook = YES;
    BUKWrite(@"DEBUG17 BatteryHealthUIController hook installed");
}

static void BUKImageAdded(const struct mach_header *mh, intptr_t slide) {
    @autoreleasepool {
        Dl_info info = {0};
        if (dladdr(mh, &info) && info.dli_fname) {
            NSString *path = [[NSString stringWithUTF8String:info.dli_fname] lowercaseString];
            if ([path containsString:@"/batteryusageui.bundle/batteryusageui"]) {
                dispatch_async(dispatch_get_main_queue(), ^{ BUKInstall(); });
            }
        }
    }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:kLogPath error:nil];
        BUKWrite(@"BatteryUKRM Probe debug17 loaded");
        _dyld_register_func_for_add_image(BUKImageAdded);
    }
}
