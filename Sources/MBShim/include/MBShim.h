#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// macOS 27 có framework riêng MenuBarClientCore (dùng cho chế độ khoá máy khi thi) cho phép
/// giới hạn thanh menu chỉ hiện icon của các app trong danh sách. macOS tự ẩn icon còn lại,
/// không để khoảng trống. Tham khảo cách Hidden Bar 1.11 (dwarvesf/hidden, MIT) dùng API này.
BOOL MBShimIsAvailable(void);

/// Bật giới hạn: chỉ hiện icon hệ thống trong `systemItems` và icon của các app trong `bundleIDs`.
/// `completion` chạy trên main thread; giữ `assertion` lại, gọi MBShimInvalidate để bỏ giới hạn.
void MBShimActivate(NSArray<NSNumber *> *systemItems,
                    NSArray<NSString *> *bundleIDs,
                    void (^completion)(id _Nullable assertion, NSError * _Nullable error));

void MBShimInvalidate(id _Nullable assertion);

NS_ASSUME_NONNULL_END
