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
    BUKWrite([NSString stringWithFormat:@"DEBUG12 Cycle row value=%@", v]);
    return v;
}

static id BUKMakeCycleSpecifier(id target, NSArray *existing) {
    id template = nil;
    for (id sp in existing) {
        NSString *name = nil;
        @try { name = [[sp valueForKey:@"name"] description]; } @catch (__unused NSException *e) {}
        if ([name containsString:@"Dung lượng tối đa"] || [name containsString:@"Maximum Capacity"]) {
            template = sp;
            break;
        }
    }
    if (!template) {
        BUKWrite(@"DEBUG12 Maximum Capacity template not found");
        return nil;
    }

    id sp = [template copy];
    @try {
        if ([sp respondsToSelector:@selector(setName:)])
            [sp performSelector:@selector(setName:) withObject:@"Số chu kỳ"];
        else
            [sp setValue:@"Số chu kỳ" forKey:@"name"];

        if ([sp respondsToSelector:@selector(setGetter:)]) {
            NSMethodSignature *sig = [sp methodSignatureForSelector:@selector(setGetter:)];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                SEL setGetter = @selector(setGetter:);
                SEL getter = @selector(buk_realCycleCount:);
                [inv setSelector:setGetter]; [inv setTarget:sp];
                [inv setArgument:&getter atIndex:2]; [inv invoke];
            }
        }
        if ([sp respondsToSelector:@selector(setProperty:forKey:)]) {
            [sp performSelector:@selector(setProperty:forKey:) withObject:@"BatteryUKRMRealCycleCount" withObject:@"id"];
            [sp performSelector:@selector(setProperty:forKey:) withObject:@"BatteryUKRMRealCycleCount" withObject:@"key"];
        }
    } @catch (NSException *e) {
        BUKWrite([NSString stringWithFormat:@"DEBUG12 template configure exception=%@", e.name]);
        return nil;
    }
    BUKWrite(@"DEBUG12 cloned Maximum Capacity specifier");
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
            [out addObject:sp];
            BUKWrite([NSString stringWithFormat:@"DEBUG12 inserted real CycleCount=%@", cycle]);
        }
    }
    return out;
}

static void BUKInstall(void) {
    if (gDidHook) return;
    Class cls = NSClassFromString(@"BatteryHealthUIController");
    Method m = cls ? class_getInstanceMethod(cls, @selector(specifiers)) : NULL;
    if (!m) { BUKWrite(@"DEBUG12 BatteryHealthUIController/specifiers unavailable"); return; }

    class_addMethod(cls, @selector(buk_realCycleCount:), (IMP)BUKCycleValue, "@@:@");
    gOrigBHSpecifiers = method_getImplementation(m);
    method_setImplementation(m, (IMP)BUK_BH_specifiers);
    gDidHook = YES;
    BUKWrite(@"DEBUG12 BatteryHealthUIController hook installed");
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
        BUKWrite(@"BatteryUKRM Probe debug12 loaded");
        _dyld_register_func_for_add_image(BUKImageAdded);
    }
}
