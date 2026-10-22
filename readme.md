# Hướng Dẫn Tạo File `.ipa` Có Đánh Số Phiên Bản Tự Động (Chuẩn Giao Diện vFlat)

Bộ mã nguồn này biên dịch ứng dụng iOS gốc **BookSplitScanner** (phiên bản **`v2.0.0`** — thiết kế theo đúng giao diện và cơ chế **Quét 2 trang tự động không cần chạm** của [vFlat Scan](https://vflat.com/en)) thành file **`.ipa` có gắn sẵn số phiên bản và số thứ tự bản dựng (Build Number)** trực tiếp trên **GitHub Actions**.

## 1. Quy tắc đánh số phiên bản tự động trên tên file `.ipa`

Mỗi khi có thay đổi mã nguồn hoặc mỗi lần GitHub Actions chạy, hệ thống sẽ tự động đọc hằng số `let APP_VERSION = "2.0.0"` ở đầu file `BookSplitScannerApp.swift` kết hợp với số thứ tự lần chạy (`run_number`) của GitHub để đặt tên file:

* **Tên gói tải về tại mục Artifacts**: `BookSplitScanner-v2.0.0-b3` (trong đó `v2.0.0` là phiên bản tính năng, `b3` là bản build lần thứ 3).
* **Tên file `.ipa` bên trong sau khi giải nén**: `BookSplitScanner-v2.0.0-b3.ipa`.
* **Hiển thị trực tiếp trong ứng dụng trên iPhone**: Khi bấm vào nút `...` trên màn hình Camera hoặc trong mục `Library`, bạn sẽ thấy dòng chữ `Phiên bản: v2.0.0 (Build 3)` để biết chắc chắn mình đã cài đúng bản mới nhất.

| Lần cập nhật     | Số phiên bản (`APP_VERSION`) | Tên file `.ipa` xuất ra (Ví dụ)      | Nội dung thay đổi chính                                      |
| :--------------- | :--------------------------- | :----------------------------------- | :----------------------------------------------------------- |
| Bản đầu tiên     | `v1.0.0`                     | `BookSplitScanner.ipa`               | Bản cơ bản dùng trình quét mặc định của iOS (`VNDocumentCameraViewController`) |
| Bản nâng cấp 1   | `v1.1.0`                     | `BookSplitScanner.ipa`               | Bổ sung tính năng chụp lại (`Rescan`) thay thế đúng vị trí trang lỗi |
| **Bản hiện tại** | **`v2.0.0`**                 | **`BookSplitScanner-v2.0.0-b3.ipa`** | **Làm lại toàn bộ giao diện & luồng quét giống hệt vFlat: Mở thẳng Camera `[1 \| 2]`, thanh xanh ngọc tự dâng và tự chụp khi ngừng lật trang (No-Tapping Auto-Capture), AI Cleanup khử bóng/ngón tay, OCR tiếng Việt và màn hình Library 2 cột** |

## 2. Cách cập nhật lên phiên bản `v2.0.0` trên GitHub của bạn

Để kích hoạt cơ chế tự động gắn số phiên bản vào tên file `.ipa`, bạn cập nhật 2 file trên [GitHub](https://github.com) của mình:

1. **Cập nhật `BookSplitScannerApp.swift`**: Mở file `BookSplitScannerApp.swift` trên GitHub → bấm biểu tượng **Cây bút (Edit)** → dán toàn bộ nội dung mới từ khung Canvas vào → bấm **Commit changes**.
2. **Cập nhật `.github/workflows/build-ipa.yml`**: Mở file `.github/workflows/build-ipa.yml` trên GitHub → bấm biểu tượng **Cây bút (Edit)** → dán toàn bộ nội dung của file **`build-ipa.yml`** mới vào → bấm **Commit changes**.
3. **Tải file `.ipa` có gắn số phiên bản**: Vào tab **Actions**, đợi khoảng 1–2 phút cho tiến trình **Build Versioned iOS IPA** hoàn tất, kéo xuống mục **Artifacts** để tải về file **`BookSplitScanner-v2.0.0-bX.ipa`**.
