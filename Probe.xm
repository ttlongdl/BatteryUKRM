#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <dispatch/dispatch.h>
#import <execinfo.h>
#import <substrate.h>

static NSString *const kLogPath = @"/var/mobile/BatteryUKRM-probe.log";
static BOOL gDidInitialDump = NO;
static BOOL gDidBatteryDump = NO;
static BOOL gMGHookAttempted = NO;

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

typedef BOOL (*MGIsDeviceOneOfTypeFn)(CFTypeRef);
static MGIsDeviceOneOfTypeFn orig_MGIsDeviceOneOfType = NULL;

static BOOL hook_MGIsDeviceOneOfType(CFTypeRef type) {
    BOOL result = orig_MGIsDeviceOneOfType ? orig_MGIsDeviceOneOfType(type) : NO;
    @autoreleasepool {
        NSString *arg = type ? [(__bridge id)type description] : @"(null)";
        void *ra = __builtin_return_address(0);
        Dl_info info = {0};
        NSString *caller = @"(unknown)";
        if (ra && dladdr(ra, &info) && info.dli_fname) {
            caller = [NSString stringWithFormat:@"%s + 0x%llx",
                      info.dli_fname,
                      (unsigned long long)((uintptr_t)ra - (uintptr_t)info.dli_fbase)];
        }
        BUKWrite([NSString stringWithFormat:@"MG CALL type=%@ result=%@ caller=%@",
                  arg, result ? @"YES" : @"NO", caller]);
    }
    return result;
}

static void BUKTryHookMG(void) {
    if (gMGHookAttempted) return;
    gMGHookAttempted = YES;

    void *sym = dlsym(RTLD_DEFAULT, "_MGIsDeviceOneOfType");
    if (!sym) sym = dlsym(RTLD_DEFAULT, "MGIsDeviceOneOfType");

    if (!sym) {
        BUKWrite(@"MG HOOK symbol NOT FOUND");
        return;
    }

    Dl_info info = {0};
    NSString *where = @"(unknown)";
    if (dladdr(sym, &info) && info.dli_fname) where = [NSString stringWithUTF8String:info.dli_fname];
    BUKWrite([NSString stringWithFormat:@"MG HOOK symbol=%p image=%@", sym, where]);

    MSHookFunction(sym, (void *)&hook_MGIsDeviceOneOfType, (void **)&orig_MGIsDeviceOneOfType);
    BUKWrite([NSString stringWithFormat:@"MG HOOK installed original=%p", orig_MGIsDeviceOneOfType]);
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
    BUKWrite([NSString stringWithFormat:@"BatteryUKRM Probe debug3 phase=%@ pid=%d time=%@",
              batteryPhase ? @"BATTERY_LOADED" : @"INITIAL", getpid(), [df stringFromDate:[NSDate date]]]);
    BUKWrite([NSString stringWithFormat:@"SystemHealthUI=%@ PLBatteryUIBackendModel=%@",
              sh ? @"YES" : @"NO", backend ? @"YES" : @"NO"]);

    if (sh) BUKDumpClass(sh, YES);
    if (backend) BUKDumpClass(backend, YES);
    if (batteryPhase) BUKDumpBatteryUsageUIClasses();
    BUKWrite(@"END PROBE");
}

static void BUKImageAdded(const struct mach_header *mh, intptr_t slide) {
    @autoreleasepool {
        Dl_info info = {0};
        if (dladdr(mh, &info) && info.dli_fname) {
            NSString *path = [[NSString stringWithUTF8String:info.dli_fname] lowercaseString];
            if ([path containsString:@"batteryusageui"]) {
                BUKWrite([NSString stringWithFormat:@"IMAGE LOADED %s slide=%p", info.dli_fname, (void *)slide]);
                dispatch_async(dispatch_get_main_queue(), ^{
                    BUKTryHookMG();
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
        BUKTryHookMG();
        _dyld_register_func_for_add_image(BUKImageAdded);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ BUKDumpRuntime(NO); });
    }
}
