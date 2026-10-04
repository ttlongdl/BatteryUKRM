#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <dispatch/dispatch.h>
#import <execinfo.h>

static NSString *const kLogPath = @"/var/mobile/BatteryUKRM-probe.log";
static BOOL gDidInitialDump = NO;
static BOOL gDidBatteryDump = NO;
static IMP gOrigBHSpecifiers = NULL;
static IMP gOrigBUISpecifiers = NULL;
static IMP gOrigBUIInit = NULL;
static IMP gOrigBUIViewDidLoad = NULL;
static IMP gOrigBUIViewWillAppear = NULL;
static IMP gOrigGetChargeCycles = NULL;
static IMP gOrigInternalSpecifiers = NULL;
static BOOL gDidInternalProbe = NO;
static BOOL gDidHookBatteryHealth = NO;

static void BUKWrite(NSString *line) {
    NSString *msg = [NSString stringWithFormat:@"%@\n", line ?: @""];
    NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kLogPath]) { [data writeToFile:kLogPath atomically:YES]; return; }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:data]; [fh synchronizeFile]; }
    @catch (__unused NSException *e) {}
    [fh closeFile];
}

static void BUKDumpClass(Class cls, BOOL allMethods) {
    if (!cls) return;
    const char *className = class_getName(cls);
    const char *imageName = class_getImageName(cls);
    BUKWrite([NSString stringWithFormat:@"CLASS %s image=%s", className ?: "(null)", imageName ?: "(unknown)"]);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        IMP imp = method_getImplementation(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        BUKWrite([NSString stringWithFormat:@"  - %s IMP=%p types=%s",
                  sel_getName(sel) ?: "(null)", imp, types ?: "(null)"]);
    }
    free(methods);

    Class meta = object_getClass(cls);
    methods = class_copyMethodList(meta, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        IMP imp = method_getImplementation(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        BUKWrite([NSString stringWithFormat:@"  + %s IMP=%p types=%s",
                  sel_getName(sel) ?: "(null)", imp, types ?: "(null)"]);
    }
    free(methods);
}

static void BUKLogMGSymbol(void) {
    void *sym = dlsym(RTLD_DEFAULT, "_MGIsDeviceOneOfType");
    if (!sym) sym = dlsym(RTLD_DEFAULT, "MGIsDeviceOneOfType");
    if (!sym) {
        BUKWrite(@"MG SYMBOL NOT FOUND");
        return;
    }
    Dl_info info = {0};
    NSString *where = @"(unknown)";
    unsigned long long offset = 0;
    if (dladdr(sym, &info) && info.dli_fname) {
        where = [NSString stringWithUTF8String:info.dli_fname];
        offset = (unsigned long long)((uintptr_t)sym - (uintptr_t)info.dli_fbase);
    }
    BUKWrite([NSString stringWithFormat:@"MG SYMBOL passive=%p image=%@ offset=0x%llx",
              sym, where, offset]);
}

static BOOL BUKIsBatteryUsageUIImage(const char *imageName) {
    if (!imageName) return NO;
    NSString *p = [[NSString stringWithUTF8String:imageName] lowercaseString];
    return [p containsString:@"/batteryusageui.bundle/batteryusageui"];
}

static void BUKDumpBatteryUsageUIClasses(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)n, sizeof(Class));
    n = objc_getClassList(classes, n);
    BUKWrite(@"-- ALL Objective-C classes/methods from BatteryUsageUI --");
    unsigned int matched = 0;
    for (int i = 0; i < n; i++) {
        const char *img = class_getImageName(classes[i]);
        if (BUKIsBatteryUsageUIImage(img)) {
            matched++;
            BUKDumpClass(classes[i], YES);
        }
    }
    BUKWrite([NSString stringWithFormat:@"-- BatteryUsageUI class count=%u --", matched]);
    free(classes);
}

static void BUKDumpRuntime(BOOL batteryPhase) {
    Class sh = NSClassFromString(@"SystemHealthUI");
    Class backend = NSClassFromString(@"PLBatteryUIBackendModel");

    if (batteryPhase) {
        if (gDidBatteryDump || !backend) return;
        gDidBatteryDump = YES;
    } else {
        if (gDidInitialDump || (!sh && !backend)) return;
        gDidInitialDump = YES;
    }

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    BUKWrite(@"============================================================");
    BUKWrite([NSString stringWithFormat:@"BatteryUKRM Probe debug10 phase=%@ pid=%d time=%@",
              batteryPhase ? @"BATTERY_LOADED" : @"INITIAL", getpid(), [df stringFromDate:[NSDate date]]]);
    BUKWrite([NSString stringWithFormat:@"SystemHealthUI=%@ PLBatteryUIBackendModel=%@",
              sh ? @"YES" : @"NO", backend ? @"YES" : @"NO"]);

    if (sh) BUKDumpClass(sh, YES);
    if (backend) BUKDumpClass(backend, YES);
    if (batteryPhase) BUKDumpBatteryUsageUIClasses();
    BUKWrite(@"END PROBE");
}


static NSString *BUKSafeValue(id obj, NSString *key) {
    @try {
        id v = [obj valueForKey:key];
        return v ? [v description] : @"(nil)";
    } @catch (__unused NSException *e) {
        return @"(KVC unavailable)";
    }
}

static id BUK_BH_specifiers(id self, SEL _cmd) {
    id (*orig)(id, SEL) = (id (*)(id, SEL))gOrigBHSpecifiers;
    id result = orig ? orig(self, _cmd) : nil;
    BUKWrite([NSString stringWithFormat:@"HOOK BatteryHealthUIController specifiers -> %@ count=%lu",
              NSStringFromClass([result class]),
              (unsigned long)([result respondsToSelector:@selector(count)] ? [result count] : 0)]);
    if ([result isKindOfClass:[NSArray class]]) {
        NSUInteger i = 0;
        for (id sp in (NSArray *)result) {
            BUKWrite([NSString stringWithFormat:@"  SPEC[%lu] class=%@ name=%@ identifier=%@ id=%@ key=%@ getter=%@ cellType=%@",
                      (unsigned long)i++,
                      NSStringFromClass([sp class]),
                      BUKSafeValue(sp, @"name"),
                      BUKSafeValue(sp, @"identifier"),
                      BUKSafeValue(sp, @"id"),
                      BUKSafeValue(sp, @"key"),
                      BUKSafeValue(sp, @"getter"),
                      BUKSafeValue(sp, @"cellType")]);
        }
    }
    return result;
}

static id BUK_BUI_getChargeCycles(id self, SEL _cmd, id specifier) {
    id (*orig)(id, SEL, id) = (id (*)(id, SEL, id))gOrigGetChargeCycles;
    id result = orig ? orig(self, _cmd, specifier) : nil;
    BUKWrite([NSString stringWithFormat:@"HOOK BatteryUIController getChargeCycles: specifier=%@ name=%@ identifier=%@ key=%@ -> %@",
              specifier, BUKSafeValue(specifier, @"name"), BUKSafeValue(specifier, @"identifier"),
              BUKSafeValue(specifier, @"key"), result]);
    return result;
}

static id BUK_BUI_setUpInternalSpecifiers(id self, SEL _cmd) {
    id (*orig)(id, SEL) = (id (*)(id, SEL))gOrigInternalSpecifiers;
    id result = orig ? orig(self, _cmd) : nil;
    BUKWrite([NSString stringWithFormat:@"HOOK BatteryUIController setUpInternalSpecifiers -> %@ count=%lu",
              NSStringFromClass([result class]),
              (unsigned long)([result respondsToSelector:@selector(count)] ? [result count] : 0)]);
    if ([result isKindOfClass:[NSArray class]]) {
        NSUInteger i = 0;
        for (id sp in (NSArray *)result) {
            BUKWrite([NSString stringWithFormat:@"  INTERNAL[%lu] class=%@ name=%@ identifier=%@ id=%@ key=%@ getter=%@",
                      (unsigned long)i++, NSStringFromClass([sp class]),
                      BUKSafeValue(sp, @"name"), BUKSafeValue(sp, @"identifier"),
                      BUKSafeValue(sp, @"id"), BUKSafeValue(sp, @"key"), BUKSafeValue(sp, @"getter")]);
        }
    }
    return result;
}

static void BUKProbeInternalOnLiveController(id self) {
    if (gDidInternalProbe || !self) return;
    gDidInternalProbe = YES;
    BUKWrite([NSString stringWithFormat:@"DEBUG8 LIVE BatteryUIController=%@", self]);
    @try {
        id (*internalCall)(id, SEL) = (id (*)(id, SEL))gOrigInternalSpecifiers;
        id internal = internalCall ? internalCall(self, @selector(setUpInternalSpecifiers)) : nil;
        BUKWrite([NSString stringWithFormat:@"DEBUG8 DIRECT internal -> %@ count=%lu",
                  NSStringFromClass([internal class]),
                  (unsigned long)([internal respondsToSelector:@selector(count)] ? [internal count] : 0)]);
        if ([internal isKindOfClass:[NSArray class]]) {
            NSUInteger i = 0;
            for (id sp in (NSArray *)internal) {
                NSString *name = BUKSafeValue(sp, @"name");
                NSString *identifier = BUKSafeValue(sp, @"identifier");
                NSString *key = BUKSafeValue(sp, @"key");
                NSString *getter = BUKSafeValue(sp, @"getter");
                BUKWrite([NSString stringWithFormat:@"  DEBUG8 INTERNAL[%lu] class=%@ name=%@ identifier=%@ key=%@ getter=%@ cellType=%@",
                          (unsigned long)i++, NSStringFromClass([sp class]), name, identifier, key, getter,
                          BUKSafeValue(sp, @"cellType")]);
                NSString *hay = [[NSString stringWithFormat:@"%@ %@ %@ %@", name, identifier, key, getter] lowercaseString];
                if ([hay containsString:@"cycle"] || [hay containsString:@"charge"] || [hay containsString:@"battery"]) {
                    @try {
                        id (*cycleCall)(id, SEL, id) = (id (*)(id, SEL, id))gOrigGetChargeCycles;
                        id v = cycleCall ? cycleCall(self, @selector(getChargeCycles:), sp) : nil;
                        BUKWrite([NSString stringWithFormat:@"    DEBUG8 CANDIDATE getChargeCycles -> %@ class=%@",
                                  v, v ? NSStringFromClass([v class]) : @"(nil)"]);
                    } @catch (NSException *e) {
                        BUKWrite([NSString stringWithFormat:@"    DEBUG8 CANDIDATE EXCEPTION %@ reason=%@", e.name, e.reason]);
                    }
                }
            }
        }
    } @catch (NSException *e) {
        BUKWrite([NSString stringWithFormat:@"DEBUG8 INTERNAL EXCEPTION %@ reason=%@", e.name, e.reason]);
    }
}

static id BUK_BUI_init(id self, SEL _cmd) {
    id (*orig)(id, SEL) = (id (*)(id, SEL))gOrigBUIInit;
    id obj = orig ? orig(self, _cmd) : self;
    BUKWrite([NSString stringWithFormat:@"DEBUG9 BatteryUIController init -> %@", obj]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BUKProbeInternalOnLiveController(obj);
    });
    return obj;
}

static void BUK_BUI_viewDidLoad(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))gOrigBUIViewDidLoad;
    if (orig) orig(self, _cmd);
    BUKWrite([NSString stringWithFormat:@"DEBUG9 BatteryUIController viewDidLoad self=%@", self]);
    BUKProbeInternalOnLiveController(self);
}

static void BUK_BUI_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))gOrigBUIViewWillAppear;
    if (orig) orig(self, _cmd, animated);
    BUKWrite([NSString stringWithFormat:@"DEBUG9 BatteryUIController viewWillAppear self=%@ animated=%d", self, animated]);
    BUKProbeInternalOnLiveController(self);
}

static id BUK_BUI_specifiers(id self, SEL _cmd) {
    id (*orig)(id, SEL) = (id (*)(id, SEL))gOrigBUISpecifiers;
    id result = orig ? orig(self, _cmd) : nil;
    BUKWrite([NSString stringWithFormat:@"HOOK BatteryUIController specifiers live=%@ -> %@ count=%lu",
              self, NSStringFromClass([result class]),
              (unsigned long)([result respondsToSelector:@selector(count)] ? [result count] : 0)]);
    dispatch_async(dispatch_get_main_queue(), ^{ BUKProbeInternalOnLiveController(self); });
    return result;
}

static void BUKProbeIOKitCycle(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) { BUKWrite(@"DEBUG10 IOKit dlopen failed"); return; }

    typedef void *(*MatchingFn)(const char *);
    typedef unsigned int (*GetServiceFn)(unsigned int, void *);
    typedef const void *(*CreatePropFn)(unsigned int, const void *, const void *, unsigned int);
    typedef int (*ReleaseFn)(unsigned int);

    MatchingFn matching = (MatchingFn)dlsym(h, "IOServiceMatching");
    GetServiceFn getService = (GetServiceFn)dlsym(h, "IOServiceGetMatchingService");
    CreatePropFn createProp = (CreatePropFn)dlsym(h, "IORegistryEntryCreateCFProperty");
    ReleaseFn releaseObj = (ReleaseFn)dlsym(h, "IOObjectRelease");

    if (!matching || !getService || !createProp) {
        BUKWrite(@"DEBUG10 IOKit symbols unavailable");
        dlclose(h);
        return;
    }

    unsigned int service = getService(0, matching("AppleSmartBattery"));
    if (!service) {
        BUKWrite(@"DEBUG10 AppleSmartBattery service unavailable");
        dlclose(h);
        return;
    }

    CFTypeRef value = (CFTypeRef)createProp(service, CFSTR("CycleCount"), kCFAllocatorDefault, 0);
    BUKWrite([NSString stringWithFormat:@"DEBUG10 IOKIT CycleCount=%@", (__bridge id)value]);
    if (value) CFRelease(value);
    if (releaseObj) releaseObj(service);
    dlclose(h);
}

static void BUKInstallBatteryHealthHooks(void) {
    if (gDidHookBatteryHealth) return;
    Class cls = NSClassFromString(@"BatteryHealthUIController");
    if (!cls) {
        BUKWrite(@"HOOK BatteryHealthUIController unavailable");
        return;
    }
    Method m = class_getInstanceMethod(cls, @selector(specifiers));
    if (m) {
        gOrigBHSpecifiers = method_getImplementation(m);
        method_setImplementation(m, (IMP)BUK_BH_specifiers);
    }

    Class bui = NSClassFromString(@"BatteryUIController");
    Method c = bui ? class_getInstanceMethod(bui, @selector(getChargeCycles:)) : NULL;
    Method internal = bui ? class_getInstanceMethod(bui, @selector(setUpInternalSpecifiers)) : NULL;
    Method buiSpecs = bui ? class_getInstanceMethod(bui, @selector(specifiers)) : NULL;
    Method buiInit = bui ? class_getInstanceMethod(bui, @selector(init)) : NULL;
    Method buiVDL = bui ? class_getInstanceMethod(bui, @selector(viewDidLoad)) : NULL;
    Method buiVWA = bui ? class_getInstanceMethod(bui, @selector(viewWillAppear:)) : NULL;
    if (c) {
        gOrigGetChargeCycles = method_getImplementation(c);
        method_setImplementation(c, (IMP)BUK_BUI_getChargeCycles);
    }
    if (internal) {
        gOrigInternalSpecifiers = method_getImplementation(internal);
        method_setImplementation(internal, (IMP)BUK_BUI_setUpInternalSpecifiers);
    }
    if (buiSpecs) {
        gOrigBUISpecifiers = method_getImplementation(buiSpecs);
        method_setImplementation(buiSpecs, (IMP)BUK_BUI_specifiers);
    }
    if (buiInit) {
        gOrigBUIInit = method_getImplementation(buiInit);
        method_setImplementation(buiInit, (IMP)BUK_BUI_init);
    }
    if (buiVDL) {
        gOrigBUIViewDidLoad = method_getImplementation(buiVDL);
        method_setImplementation(buiVDL, (IMP)BUK_BUI_viewDidLoad);
    }
    if (buiVWA) {
        gOrigBUIViewWillAppear = method_getImplementation(buiVWA);
        method_setImplementation(buiVWA, (IMP)BUK_BUI_viewWillAppear);
    }
    gDidHookBatteryHealth = (m || c || internal || buiSpecs || buiInit || buiVDL || buiVWA);
    BUKWrite([NSString stringWithFormat:@"HOOK INSTALL BH.specifiers=%@ BUI.getChargeCycles=%@ BUI.internalSpecifiers=%@ BUI.specifiers=%@ init=%@ viewDidLoad=%@ viewWillAppear=%@",
              m ? @"YES" : @"NO", c ? @"YES" : @"NO", internal ? @"YES" : @"NO", buiSpecs ? @"YES" : @"NO", buiInit ? @"YES" : @"NO", buiVDL ? @"YES" : @"NO", buiVWA ? @"YES" : @"NO"]);
}

static void BUKImageAdded(const struct mach_header *mh, intptr_t slide) {
    @autoreleasepool {
        Dl_info info = {0};
        if (dladdr(mh, &info) && info.dli_fname) {
            NSString *path = [[NSString stringWithUTF8String:info.dli_fname] lowercaseString];
            if ([path containsString:@"batteryusageui"]) {
                BUKWrite([NSString stringWithFormat:@"IMAGE LOADED %s slide=%p", info.dli_fname, (void *)slide]);
                dispatch_async(dispatch_get_main_queue(), ^{
                    BUKLogMGSymbol();
                    BUKInstallBatteryHealthHooks();
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ BUKProbeIOKitCycle(); });
                    BUKDumpRuntime(YES);

                });
            }
        }
    }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:kLogPath error:nil];
        BUKWrite(@"BatteryUKRM Probe loaded into Preferences");
        BUKLogMGSymbol();
        _dyld_register_func_for_add_image(BUKImageAdded);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ BUKDumpRuntime(NO); });
    }
}
