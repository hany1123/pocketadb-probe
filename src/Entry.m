//
//  Entry.m —— PocketADB Pro 权益链路「只读取证探针」
//
//  目的：在真机上确认 PurchaseStore 的运行时事实，为精确 hook 提供依据。
//  硬约束：
//    · 纯 Objective-C + __attribute__((constructor))，不使用 Logos / CydiaSubstrate
//    · 不 hook 任何系统类方法，不 method_setImplementation，只做只读枚举 + KVC 读取
//    · 不修改 App 任何行为，只把取证结果写到 App Documents/PocketADB_probe.json
//    · 产物零越狱关键词，install name 由 strip_substrate.py 处理为 @rpath/
//
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#define TAG @"[PDBProbe]"

static NSString *PDBEscape(NSString *s) {
    if (!s) return @"";
    NSMutableString *o = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '"') [o appendString:@"\\\""];
        else if (c == '\\') [o appendString:@"\\\\"];
        else if (c == '\n') [o appendString:@"\\n"];
        else if (c < 0x20) [o appendFormat:@"\\u%04x", c];
        else [o appendFormat:@"%C", c];
    }
    return o;
}

// 把任意值渲染成可读字符串（Swift Set/Array/基本类型都可覆盖）
static NSString *PDBDescribe(id v) {
    if (!v) return @"(nil)";
    NSString *cls = NSStringFromClass([v class]) ?: @"?";
    NSString *desc = [v description];
    if (desc.length > 800) desc = [[desc substringToIndex:800] stringByAppendingString:@"…(truncated)"];
    return [NSString stringWithFormat:@"%@ | %@", cls, PDBEscape(desc ?: @"(no description)")];
}

static NSArray<NSString *> *PDBClassCandidates(void) {
    // Swift 类在 ObjC 运行时同时有 mangled 名与 module 名两种写法，全部试探
    return @[
        @"_TtC9PocketADB13PurchaseStore",
        @"PocketADB.PurchaseStore",
        @"PurchaseStore"
    ];
}

static NSString *PDBTypeEncoding(Method m) {
    const char *t = method_getTypeEncoding(m);
    return t ? PDBEscape([NSString stringWithUTF8String:t]) : @"(null)";
}

static void PDBDumpClass(Class cls, NSMutableString *out) {
    unsigned int mc = 0;
    Method *ml = class_copyMethodList(cls, &mc);
    [out appendFormat:@"\n  methods(%u):\n", mc];
    // 只输出权益/订阅相关，外加 init —— 全量输出太大
    for (unsigned int i = 0; i < mc; i++) {
        SEL s = method_getName(ml[i]);
        NSString *sn = NSStringFromSelector(s) ?: @"?";
        NSString *low = [sn lowercaseString];
        BOOL interesting =
            [low containsString:@"pro"] || [low containsString:@"entitle"] ||
            [low containsString:@"legacy"] || [low containsString:@"purchase"] ||
            [low containsString:@"unlock"] || [low containsString:@"product"] ||
            [low containsString:@"verif"] || [low containsString:@"refresh"] ||
            [low containsString:@"init"] || [low containsString:@"restore"];
        if (interesting) {
            [out appendFormat:@"    - %@  type=%@ imp=%p\n",
                PDBEscape(sn), PDBTypeEncoding(ml[i]), method_getImplementation(ml[i])];
        }
    }
    free(ml);

    unsigned int ic = 0;
    Ivar *il = class_copyIvarList(cls, &ic);
    [out appendFormat:@"  ivars(%u):\n", ic];
    for (unsigned int i = 0; i < ic; i++) {
        const char *n = ivar_getName(il[i]);
        NSString *nn = n ? [NSString stringWithUTF8String:n] : @"?";
        NSString *low = [nn lowercaseString];
        if ([low containsString:@"pro"] || [low containsString:@"entitle"] ||
            [low containsString:@"legacy"] || [low containsString:@"product"] ||
            [low containsString:@"unlock"] || [low containsString:@"verif"]) {
            const char *t = ivar_getTypeEncoding(il[i]);
            [out appendFormat:@"    + %@  off=%ld type=%@\n",
                PDBEscape(nn), (long)ivar_getOffset(il[i]),
                t ? PDBEscape([NSString stringWithUTF8String:t]) : @"(null)"];
        }
    }
    free(il);
}

// 尝试从 AppDelegate / SwiftUI App 结构里找到 PurchaseStore 单例
// 策略：遍历类名候选 → 若类存在，尝试 KVC 读关键属性；同时枚举所有已加载类里
//       带 Purchase/Store 名字的类，取第一个能实例化或已存在的对象。
static id PDBFindStoreInstance(Class cls) {
    // 1) 常见单例入口
    NSArray *singletonSels = @[@"shared", @"sharedInstance", @"sharedStore", @"defaultStore"];
    for (NSString *sn in singletonSels) {
        SEL s = NSSelectorFromString(sn);
        if ([cls respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id o = [cls performSelector:s];
#pragma clang diagnostic pop
            if (o) return o;
        }
    }
    // 2) 扫描所有窗口的绑定对象（SwiftUI 环境对象不在 view 树里，兜底尝试）
    UIApplication *app = [UIApplication sharedApplication];
    NSArray *wins = app.windows ?: @[];
    if (@available(iOS 13.0, *)) {
        NSMutableArray *all = [wins mutableCopy];
        for (UIScene *sc in app.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]])
                [all addObjectsFromArray:((UIWindowScene *)sc).windows];
        }
        wins = all;
    }
    for (UIWindow *w in wins) {
        id vc = w.rootViewController;
        for (int i = 0; i < 8 && vc; i++) {
            unsigned int pc = 0;
            objc_property_t *pl = class_copyPropertyList([vc class], &pc);
            for (unsigned int j = 0; j < pc; j++) {
                NSString *pn = [NSString stringWithUTF8String:property_getName(pl[j])];
                NSString *low = [pn lowercaseString];
                if ([low containsString:@"purchase"] || [low containsString:@"store"]) {
                    id val = nil;
                    @try { val = [vc valueForKey:pn]; } @catch (__unused NSException *e) {}
                    if (val && [val isKindOfClass:cls]) { free(pl); return val; }
                }
            }
            free(pl);
            vc = [vc presentedViewController];
        }
    }
    return nil;
}

static void PDBProbe(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"=== PocketADB entitlement probe ===\n"];
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    [out appendFormat:@"bundle=%@ ver=%@ build=%@\n",
        PDBEscape([[NSBundle mainBundle].bundleIdentifier description]),
        PDBEscape(ver), PDBEscape(build)];
    [out appendFormat:@"app=%@\n", NSStringFromClass([[UIApplication sharedApplication] class])];

    Class storeCls = Nil;
    for (NSString *cn in PDBClassCandidates()) {
        Class c = objc_getClass([cn UTF8String]);
        [out appendFormat:@"class %@ -> %@\n", cn, c ? @"EXISTS" : @"no"];
        if (c && !storeCls) storeCls = c;
    }

    if (storeCls) {
        [out appendFormat:@"\n=== %s ===\n", class_getName(storeCls)];
        PDBDumpClass(storeCls, out);

        id inst = PDBFindStoreInstance(storeCls);
        [out appendFormat:@"\ninstance found: %@\n", inst ? @"YES" : @"NO"];
        if (inst) {
            NSArray *keys = @[
                @"verifiedProProductIDs", @"unverifiedProProductIDs",
                @"hasEntitlementSnapshot", @"hasUnverifiedProEntitlements",
                @"activeProProductIDs", @"products", @"legacyAccess",
                @"confirmedLegacyUser", @"hasLegacySnapshot", @"isRefreshing",
                @"pro", @"partialPro", @"requiresPro", @"message", @"operation"
            ];
            [out appendString:@"\n--- KVC values ---\n"];
            for (NSString *k in keys) {
                id v = nil;
                @try { v = [inst valueForKey:k]; }
                @catch (NSException *e) {
                    [out appendFormat:@"  %@ -> <KVC error: %@>\n", k, PDBEscape(e.reason ?: @"?")];
                    continue;
                }
                [out appendFormat:@"  %@ -> %@\n", k, PDBDescribe(v)];
            }
        }
    } else {
        [out appendString:@"\nPurchaseStore class not found via ObjC runtime — 需在真机确认 Swift 命名空间。\n"];
    }

    // 落盘：优先 App Documents（TrollStore 下可直接读）
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = docs.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *path = [dir stringByAppendingPathComponent:@"PocketADB_probe.json"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"%@ wrote probe to %@", TAG, path);
    NSLog(@"%@\n%@", TAG, out);
}

__attribute__((constructor))
static void PDBEntry(void) {
    @autoreleasepool {
        // PurchaseStore 在启动后异步初始化，延迟两轮确保类已加载、实例已建立
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PDBProbe(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PDBProbe(); });
    }
}
