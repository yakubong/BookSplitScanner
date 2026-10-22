# Hướng Dẫn Tạo File `.ipa` Phiên Bản `v2.1.0` (Khóa Ngang Chế Độ 2 Trang & Nhận Diện Sách Chính Xác)

Bộ mã nguồn này biên dịch ứng dụng iOS gốc **BookSplitScanner (`v2.1.0`)** thành file **`BookSplitScanner-v2.1.0-bX.ipa`** trực tiếp trên **GitHub Actions**.

## 1. Lịch sử cập nhật phiên bản (`Changelog`)

| Phiên bản (`APP_VERSION`) | Tên file `.ipa` xuất ra | Nội dung sửa lỗi & nâng cấp chính |
| :--- | :--- | :--- |
| **`v2.1.0` (Mới nhất)** | **`BookSplitScanner-v2.1.0-bX.ipa`** | **1. Khóa cố định màn hình ngang khi ở chế độ 2 trang (`[1\|2]`):** Không bị ảnh hưởng bởi chế độ Tự xoay / Khóa xoay của iPhone; vạch đứt nét cắt dọc đúng gáy sách, số `1 \| 2` và các nút điều khiển đứng thẳng đúng chiều cầm ngang.<br>**2. Chỉ tự chụp khi thực sự nhận diện được trang sách:** Kết hợp `VNDetectRectanglesRequest` + kiểm tra độ sáng nền giấy & mật độ dòng chữ in (khắc phục triệt để lỗi tự chụp khi chỉa camera ra bàn/sàn nhà). |
| `v2.0.0` | `BookSplitScanner-v2.0.0-bX.ipa` | Làm lại giao diện Camera & Library 2 cột theo chuẩn [vFlat Scan](https://vflat.com/en), tích hợp AI Cleanup và OCR tiếng Việt |
| `v1.1.0` | `BookSplitScanner.ipa` | Bổ sung tính năng chụp lại (`Rescan`) thay thế đúng vị trí trang lỗi |

## 2. Cách cập nhật lên `v2.1.0` trên GitHub

1. Mở file **`BookSplitScannerApp.swift`** trên [GitHub](https://github.com) của bạn → bấm biểu tượng **Cây bút (Edit)** → dán toàn bộ nội dung mới từ khung Canvas (`let APP_VERSION = "2.1.0"`) vào → bấm **Commit changes**.
2. *(Tùy chọn)* Nếu muốn khóa cứng hướng xoay hệ thống trong `Info.plist`, bạn cũng có thể cập nhật thêm file `.github/workflows/build-ipa.yml` và `project.yml` bên dưới.
3. Vào tab **Actions**, đợi 1–2 phút và tải gói **`BookSplitScanner-v2.1.0-bX`** tại mục **Artifacts**.
