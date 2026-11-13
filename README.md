# DLTDOAReceiver (iOS)

Ứng dụng SwiftUI nhận bản tin UWB **DL-TDoA** trên iPhone bằng `NearbyInteraction` (`NIDLTDOAConfiguration` / `NIDLTDOAMeasurement`).

> **Lưu ý quan trọng về trạng thái build:** Mã nguồn này được tạo trên Windows nên **chưa được biên dịch bằng Xcode**. Bạn cần mở trên **Mac + Xcode** để build lên iPhone thật (UWB không chạy trên Simulator).

## Yêu cầu hệ thống
- **iPhone hỗ trợ UWB + DL-TDoA** (kiểm tra runtime qua `NISession.deviceCapabilities.supportsDLTDOAMeasurement`).
- **iOS 26.0+** (API `NIDLTDOAConfiguration` và `NIDLTDOAMeasurement` được giới thiệu từ iOS 26.0).
  - *iOS 26.x:* Có thể yêu cầu entitlement DL-TDoA từ Apple.
  - *iOS 27.0+:* Theo tài liệu Apple, DL-TDoA không còn yêu cầu entitlement, và hỗ trợ thêm `DiscoveryMethod.wifi`.
- **Xcode** tương thích iOS 26+ SDK trên macOS.

## Cách mở và build trên Mac (Xcode)
1. Clone repo và mở trực tiếp file **`DLTDOAReceiver.xcodeproj`** bằng Xcode.
2. Chọn target **DLTDOAReceiver** -> tab **Signing & Capabilities** -> chọn **Team** của bạn (và đổi Bundle Identifier nếu cần).
3. Cắm iPhone thật (hỗ trợ UWB, iOS 26.0+) và nhấn **Run (Cmd + R)**.

## Lưu ý về Discovery (BLE / Wi-Fi)
- Theo tài liệu Apple, `NIDLTDOAConfiguration(networkIdentifier: 42)` dùng **BLE** (mặc định) hoặc **Wi-Fi** (iOS 27+) để **discover** anchor trước khi thu UWB DL-TDoA.
- Kit **QM35825 DK-05** chỉ có chip UWB, **không có BLE hay Wi-Fi**. Vì vậy, để iPhone thực sự kích hoạt được `session(_:didUpdateDLTDOA:)`, bạn cần thêm một thiết bị phát BLE/Wi-Fi discovery theo **Nearby Interaction Accessory Specification** của Apple (tài liệu này nằm sau cổng đăng nhập Apple Developer: `https://developer.apple.com/nearby-interaction/specification`).
