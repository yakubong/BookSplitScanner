# Hướng Dẫn Tạo File `.ipa` Bằng GitHub Actions & Cài Đặt BookSplitScanner Lên iPhone

Bộ mã nguồn này giúp bạn tự biên dịch ứng dụng iOS gốc **BookSplitScanner** (viết bằng SwiftUI) thành file **`BookSplitScanner.ipa`** trực tiếp trên máy chủ macOS miễn phí của **GitHub Actions** mà không cần sở hữu máy Mac hay cài đặt phần mềm Xcode.

## 1. Cấu trúc các file trong dự án

| Tên file | Vị trí trên GitHub Repository | Công dụng |
| :--- | :--- | :--- |
| `BookSplitScannerApp.swift` | Thư mục gốc (`BookSplitScannerApp.swift`) | Toàn bộ mã nguồn ứng dụng iOS: gọi Camera gốc VisionKit sắc nét của iPhone, tự động nhận diện gáy sách, tách đôi 2 trang, khử bóng gáy sách và xuất PDF |
| `project.yml` | Thư mục gốc (`project.yml`) | Cấu hình để công cụ XcodeGen tự động sinh file dự án `.xcodeproj` và cấp quyền Camera / Thư viện ảnh trong `Info.plist` |
| `build-ipa.yml` | `.github/workflows/build-ipa.yml` | Kịch bản tự động chạy máy ảo macOS trên GitHub để biên dịch ứng dụng và đóng gói ra file `BookSplitScanner.ipa` |

## 2. Các bước đưa code lên GitHub và lấy file `.ipa` (Chỉ mất 3 phút)

### Bước 1: Tạo một kho lưu trữ (Repository) mới trên GitHub
1. Đăng nhập vào tài khoản tại [GitHub](https://github.com) và nhấn nút **+** ở góc trên bên phải, chọn **New repository**.
2. Đặt tên bất kỳ cho repository (ví dụ: `book-split-ios`).
3. Chọn chế độ **Public** (để sử dụng không giới hạn số phút chạy máy chủ macOS miễn phí của GitHub Actions).
4. Tích chọn ô **Add a README file**, sau đó bấm nút **Create repository**.

### Bước 2: Tải file mã nguồn `BookSplitScannerApp.swift` và `project.yml` lên
1. Trong giao diện repository vừa tạo, bấm nút **Add file** → chọn **Upload files**.
2. Kéo thả 2 file **`BookSplitScannerApp.swift`** và **`project.yml`** vào khung tải lên.
3. Bấm nút xanh **Commit changes** ở phía dưới để lưu.

### Bước 3: Tạo kịch bản tự động tạo file `.ipa` (`.github/workflows/build-ipa.yml`)
Vì GitHub yêu cầu file cấu hình tự động hóa phải nằm đúng trong thư mục `.github/workflows/`, bạn thực hiện như sau:
1. Tại trang chính của repository, bấm nút **Add file** → chọn **Create new file**.
2. Ở ô nhập tên file (`Name your file...`), gõ chính xác đường dẫn sau (bao gồm cả dấu chấm ở đầu):
   ```text
   .github/workflows/build-ipa.yml
   ```
3. Mở file **`build-ipa.yml`** đã tải về, copy toàn bộ nội dung bên trong và dán vào khung soạn thảo lớn trên GitHub.
4. Bấm nút **Commit changes...** ở góc trên bên phải → xác nhận **Commit changes**.

### Bước 4: Chạy GitHub Actions và tải file `BookSplitScanner.ipa` về máy
1. Ngay sau khi bạn lưu file ở Bước 3, bấm vào tab **Actions** trên thanh menu ngang của repository.
2. Bạn sẽ thấy tiến trình **Build Unsigned iOS IPA** đang tự động chạy (biểu tượng chấm vàng xoay tròn). Nếu muốn chủ động bấm chạy lại bất cứ lúc nào, bạn chọn **Build Unsigned iOS IPA** ở cột bên trái → bấm nút **Run workflow** → chọn nút xanh **Run workflow**.
3. Chờ khoảng **1 đến 2 phút** cho đến khi tiến trình chuyển sang dấu tích màu xanh lá (**Success**).
4. Bấm trực tiếp vào tên tiến trình vừa hoàn tất, kéo xuống cuối trang tại mục **Artifacts**, bạn sẽ thấy mục **`BookSplitScanner-IPA`**.
5. Bấm vào **`BookSplitScanner-IPA`** để tải file `.zip` về máy, giải nén ra bạn sẽ nhận được file **`BookSplitScanner.ipa`**.

## 3. Cách cài đặt file `BookSplitScanner.ipa` lên iPhone cá nhân

Vì file `.ipa` tạo từ GitHub là file chưa gắn chứng chỉ cá nhân (Ad-Hoc / Unsigned), bạn có thể dùng một trong các công cụ miễn phí phổ biến sau để ký bằng tài khoản Apple ID cá nhân và cài vào iPhone:

* **Sử dụng Sideloadly (Dễ nhất trên Windows / macOS)**: Mở phần mềm Sideloadly, cắm cáp kết nối iPhone với máy tính, kéo thả file `BookSplitScanner.ipa` vào ô IPA, nhập Apple ID của bạn và bấm **Start**.
* **Sử dụng AltStore hoặc SideStore**: Chuyển file `BookSplitScanner.ipa` sang iPhone (qua AirDrop, iCloud Drive, Zalo hoặc cáp), mở ứng dụng AltStore / SideStore trên iPhone → vào tab **My Apps** → bấm dấu **`+`** ở góc trên bên trái và chọn file `BookSplitScanner.ipa`.
* **Lưu ý bật Developer Mode trên iOS 16 trở lên**: Sau khi cài xong lần đầu, vào **Cài đặt (Settings)** trên iPhone → **Quyền riêng tư & Bảo mật (Privacy & Security)** → kéo xuống cuối bật **Chế độ nhà phát triển (Developer Mode)** và xác nhận **Tin cậy (Trust)** chứng chỉ nhà phát triển trong mục **Cài đặt chung → Quản lý VPN & Thiết bị**.

## 4. Mẹo sử dụng ứng dụng để quét sách sắc nét nhất

1. **Quét liên tiếp nhiều trang đôi**: Bấm nút **Quét Sách (Tự Tách 2 Trang)** ở dưới cùng. Giữ iPhone song song với mặt sách mở rộng dưới ánh sáng đều; trình quét gốc của iOS sẽ tự động bắt nét cụm ống kính chính, tự chụp khi khung màu xanh cố định và tự làm phẳng trang nghiêng. Bạn cứ lật trang sách tiếp theo để chụp liên tục 10–30 trang đôi rồi bấm **Save (Lưu)** một lần.
2. **Tự động tách gáy & chỉnh tay**: Ứng dụng sẽ tự động dò rãnh tối ở giữa gáy sách để cắt thành **Trang Trái** và **Trang Phải**, đồng thời gọt bỏ phần viền đen ở sát rãnh gáy (mặc định `1.5%`). Nếu có trang nào sách mở lệch, bạn chỉ cần chạm vào trang đó để kéo thanh trượt vạch đỏ chỉnh lại vị trí cắt.
3. **Chọn thứ tự đọc**: Thanh công cụ phía trên cho phép đổi nhanh giữa **Trái → Phải** (sách tiếng Việt, tiếng Anh) và **Phải → Trái** (truyện tranh Manga hoặc sách cổ).
4. **Xuất file PDF**: Nhập tên sách ở ô tiêu đề và bấm nút **Xuất PDF** ở góc trên bên phải để lưu thẳng vào ứng dụng **Tệp (Files)**, gửi qua AirDrop, Zalo hoặc mở đọc ngay trong Apple Books.
