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
static IMP gOrigGetChargeCycles = NULL;
static IMP gOrigInternalSpecifiers = NULL;
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
    BUKWrite([NSString stringWithFormat:@"BatteryUKRM Probe debug6 phase=%@ pid=%d time=%@",
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
    if (c) {
        gOrigGetChargeCycles = method_getImplementation(c);
        method_setImplementation(c, (IMP)BUK_BUI_getChargeCycles);
    }
    if (internal) {
        gOrigInternalSpecifiers = method_getImplementation(internal);
        method_setImplementation(internal, (IMP)BUK_BUI_setUpInternalSpecifiers);
    }
    gDidHookBatteryHealth = (m || c || internal);
    BUKWrite([NSString stringWithFormat:@"HOOK INSTALL BH.specifiers=%@ BUI.getChargeCycles=%@ BUI.internalSpecifiers=%@",
              m ? @"YES" : @"NO", c ? @"YES" : @"NO", internal ? @"YES" : @"NO"]);
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
