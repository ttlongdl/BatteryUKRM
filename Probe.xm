#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <dispatch/dispatch.h>

static NSString *const kLogPath = @"/var/mobile/BatteryUKRM-probe.log";
static BOOL gDidInitialDump = NO;
static BOOL gDidBatteryDump = NO;

static void BUKWrite(NSString *line) {
    NSString *msg = [NSString stringWithFormat:@"%@
", line ?: @""];
    NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:kLogPath]) {
        [data writeToFile:kLogPath atomically:YES];
        return;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh synchronizeFile];
    } @catch (__unused NSException *e) {}
    [fh closeFile];
}

static BOOL BUKInterestingSelector(const char *name) {
    if (!name) return NO;
    NSString *s = [[NSString stringWithUTF8String:name] lowercaseString];
    return [s containsString:@"cycle"] ||
           [s containsString:@"charge"] ||
           [s containsString:@"health"] ||
           [s containsString:@"support"] ||
           [s containsString:@"capacity"] ||
           [s containsString:@"systemhealth"] ||
           [s containsString:@"specifier"];
}

static void BUKDumpClass(Class cls, BOOL allMethods) {
    if (!cls) return;

    const char *className = class_getName(cls);
    const char *imageName = class_getImageName(cls);
    BUKWrite([NSString stringWithFormat:@"CLASS %s image=%s",
              className ?: "(null)", imageName ?: "(unknown)"]);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *selName = sel_getName(sel);
        if (allMethods || BUKInterestingSelector(selName)) {
            IMP imp = method_getImplementation(methods[i]);
            const char *types = method_getTypeEncoding(methods[i]);
            BUKWrite([NSString stringWithFormat:@"  - %s IMP=%p types=%s",
                      selName ?: "(null)", imp, types ?: "(null)"]);
        }
    }
    free(methods);

    Class meta = object_getClass(cls);
    methods = class_copyMethodList(meta, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *selName = sel_getName(sel);
        if (allMethods || BUKInterestingSelector(selName)) {
            IMP imp = method_getImplementation(methods[i]);
            const char *types = method_getTypeEncoding(methods[i]);
            BUKWrite([NSString stringWithFormat:@"  + %s IMP=%p types=%s",
                      selName ?: "(null)", imp, types ?: "(null)"]);
        }
    }
    free(methods);
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
    BUKWrite([NSString stringWithFormat:@"BatteryUKRM Probe debug2 phase=%@ pid=%d time=%@",
              batteryPhase ? @"BATTERY_LOADED" : @"INITIAL",
              getpid(), [df stringFromDate:[NSDate date]]]);

    BUKWrite([NSString stringWithFormat:@"SystemHealthUI=%@ PLBatteryUIBackendModel=%@",
              sh ? @"YES" : @"NO", backend ? @"YES" : @"NO"]);

    if (sh) BUKDumpClass(sh, YES);
    if (backend) BUKDumpClass(backend, NO);

    int n = objc_getClassList(NULL, 0);
    if (n > 0) {
        Class *classes = (__unsafe_unretained Class *)calloc((size_t)n, sizeof(Class));
        n = objc_getClassList(classes, n);
        BUKWrite(@"-- classes containing Battery/Health/Charge --");
        for (int i = 0; i < n; i++) {
            const char *cn = class_getName(classes[i]);
            if (!cn) continue;
            NSString *s = [[NSString stringWithUTF8String:cn] lowercaseString];
            if ([s containsString:@"battery"] ||
                [s containsString:@"health"] ||
                [s containsString:@"charge"]) {
                const char *img = class_getImageName(classes[i]);
                BUKWrite([NSString stringWithFormat:@"  %s image=%s",
                          cn, img ?: "(unknown)"]);
            }
        }
        free(classes);
    }

    BUKWrite(@"END PROBE");
}

static void BUKImageAdded(const struct mach_header *mh, intptr_t slide) {
    @autoreleasepool {
        Dl_info info = {0};
        if (dladdr(mh, &info) && info.dli_fname) {
            NSString *path = [[NSString stringWithUTF8String:info.dli_fname] lowercaseString];
            if ([path containsString:@"batteryusageui"]) {
                BUKWrite([NSString stringWithFormat:@"IMAGE LOADED %s slide=%p",
                          info.dli_fname, (void *)slide]);
                dispatch_async(dispatch_get_main_queue(), ^{
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
        _dyld_register_func_for_add_image(BUKImageAdded);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BUKDumpRuntime(NO);
        });
    }
}
