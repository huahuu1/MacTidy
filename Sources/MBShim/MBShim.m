#import "MBShim.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const kFramework = @"/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";
static NSString *const kConfigClass = @"MBAssessmentModeConfiguration";
static NSString *const kAssertionClass = @"MBAssessmentModeAssertion";

static NSError *MBError(NSString *reason) {
    return [NSError errorWithDomain:@"MBShim" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
}

BOOL MBShimIsAvailable(void) {
    // Nạp lúc chạy: bản macOS nào không có hoặc đổi API thì chỉ báo "không dùng được", không làm app lỗi
    if (!dlopen(kFramework.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) return NO;
    Class config = NSClassFromString(kConfigClass);
    Class assertion = NSClassFromString(kAssertionClass);
    return config && assertion
        && [config instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)]
        && [assertion instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)]
        && [assertion instancesRespondToSelector:@selector(invalidate)];
}

void MBShimActivate(NSArray<NSNumber *> *systemItems,
                    NSArray<NSString *> *bundleIDs,
                    void (^completion)(id _Nullable assertion, NSError * _Nullable error)) {
    void (^finish)(id, NSError *) = ^(id a, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(a, e); });
    };
    if (!MBShimIsAvailable()) { finish(nil, MBError(@"MenuBarClientCore không có trên bản macOS này")); return; }
    @try {
        // Phải là NSArray: framework gọi objectAtIndex:
        id config = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(
            [NSClassFromString(kConfigClass) alloc], @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:),
            [systemItems copy], [bundleIDs copy]);
        id assertion = [[NSClassFromString(kAssertionClass) alloc] init];
        if (!config || !assertion) { finish(nil, MBError(@"Không tạo được cấu hình")); return; }
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(
            assertion, @selector(activateWithConfiguration:completionHandler:), config, ^(NSError *error) {
                finish(error ? nil : assertion, error);
            });
    } @catch (NSException *ex) {
        finish(nil, MBError([NSString stringWithFormat:@"%@: %@", ex.name, ex.reason]));
    }
}

void MBShimInvalidate(id _Nullable assertion) {
    if (!assertion) return;
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
        }
    } @catch (NSException *ex) {
        NSLog(@"MBShim invalidate: %@ %@", ex.name, ex.reason);
    }
}
