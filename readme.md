# Hướng Dẫn Tạo File `.ipa` Phiên Bản `v2.3.0` (Tự Chụp Nhanh Kiểu vFlat, Không Cần Giữ Máy Thật Yên)

Bộ mã nguồn này biên dịch ứng dụng iOS gốc **BookSplitScanner (`v2.3.0`)** thành file **`BookSplitScanner-v2.3.0-bX.ipa`** trực tiếp trên **GitHub Actions**.

## 1. Lịch sử cập nhật phiên bản (`Changelog`)

| Phiên bản (`APP_VERSION`) | Tên file `.ipa` xuất ra | Nội dung sửa lỗi & nâng cấp chính |
| :--- | :--- | :--- |
| **`v2.3.0` (Mới nhất)** | **`BookSplitScanner-v2.3.0-bX.ipa`** | **Tự chụp dễ hơn, kiểu vFlat (chụp rộng trước, cắt sau):**<br>1. Cho phép rung tay nhẹ: đo rung bằng độ sáng trung bình theo ô + độ xê dịch khung sách, thay vì từng điểm ảnh (rất nhạy với nét chữ).<br>2. Thời gian giữ mặc định 0.6 giây (chọn 0.6 / 1.0 / 1.5s); rung vừa phải chỉ làm thanh đếm giảm từ từ, không reset.<br>3. Ảnh chụp kèm cả phần rìa; sau đó mới dò trang sách trên ảnh độ phân giải cao để cắt & nắn phẳng (nới rộng 2.5% để không mất chữ sát mép). Nếu ảnh chụp không dò được, dùng 4 góc sách đã thấy trên Preview lúc chụp.<br>4. Sửa tham số Vision không hợp lệ trong bước cắt & nắn phẳng ảnh (trước đây bước này luôn bị bỏ qua). |
| `v2.2.0` | `BookSplitScanner-v2.2.0-bX.ipa` | **Sửa lỗi không nhận diện được trang sách:**<br>1. Sửa tham số `VNDetectRectanglesRequest` không hợp lệ (`maximumAspectRatio = 2.1`, Vision chỉ chấp nhận 0…1) khiến bước nhận diện luôn lỗi âm thầm.<br>2. Dùng thêm `VNDetectDocumentSegmentationRequest` (AI nhận diện giấy/tài liệu) – nhận được cả sách mở bị cong; vẫn nhận diện khi để camera sát sách không thấy mép.<br>3. Kiểm tra nền giấy & chữ in theo ngưỡng tương đối, chỉ trong vùng sách tìm được, quét cả 2 chiều (đúng cho cả chế độ 1 trang và 2 trang).<br>4. Khung hình phân tích được xoay dọc khớp Preview → khung xanh bám đúng vị trí sách trên màn hình. |
| `v2.1.0` | `BookSplitScanner-v2.1.0-bX.ipa` | **1. Khóa cố định màn hình ngang khi ở chế độ 2 trang (`[1\|2]`):** Không bị ảnh hưởng bởi chế độ Tự xoay / Khóa xoay của iPhone; vạch đứt nét cắt dọc đúng gáy sách, số `1 \| 2` và các nút điều khiển đứng thẳng đúng chiều cầm ngang.<br>**2. Chỉ tự chụp khi thực sự nhận diện được trang sách:** Kết hợp `VNDetectRectanglesRequest` + kiểm tra độ sáng nền giấy & mật độ dòng chữ in (khắc phục triệt để lỗi tự chụp khi chỉa camera ra bàn/sàn nhà). |
| `v2.0.0` | `BookSplitScanner-v2.0.0-bX.ipa` | Làm lại giao diện Camera & Library 2 cột theo chuẩn [vFlat Scan](https://vflat.com/en), tích hợp AI Cleanup và OCR tiếng Việt |
| `v1.1.0` | `BookSplitScanner.ipa` | Bổ sung tính năng chụp lại (`Rescan`) thay thế đúng vị trí trang lỗi |

## 2. Cách cập nhật lên `v2.3.0` trên GitHub

1. Mở file **`BookSplitScannerApp.swift`** trên [GitHub](https://github.com) của bạn → bấm biểu tượng **Cây bút (Edit)** → dán toàn bộ nội dung mới từ khung Canvas (`let APP_VERSION = "2.3.0"`) vào → bấm **Commit changes**.
2. *(Tùy chọn)* Nếu muốn khóa cứng hướng xoay hệ thống trong `Info.plist`, bạn cũng có thể cập nhật thêm file `.github/workflows/build-ipa.yml` và `project.yml` bên dưới.
3. Vào tab **Actions**, đợi 1–2 phút và tải gói **`BookSplitScanner-v2.3.0-bX`** tại mục **Artifacts**.

## 3. Sprint thực địa: Matrix kiểm thử tự chụp (để hiệu chỉnh ngưỡng)

### 3.1 Mục tiêu vòng test
- Giảm chụp hụt khi thiếu sáng.
- Giảm chụp nhầm khi người dùng lật trang nhanh.
- Theo dõi KPI:
  - Tỷ lệ auto-capture thành công.
  - Thời gian hội tụ từ lúc nhận diện sách đến lúc tự chụp.

### 3.2 Matrix kịch bản cần chạy
- Ánh sáng: **Mạnh / Vừa / Thiếu sáng**
- Chuyển động tay: **Ổn định / Rung nhẹ / Rung mạnh**
- Hồ sơ ngưỡng: **Tự động theo ánh sáng / Ưu tiên thiếu sáng / Ưu tiên ánh sáng tốt**
- Thời gian giữ: **0.6s / 1.0s / 1.5s**
- Chế độ trang: **1 trang / 2 trang**

## 4. Instrumentation đã có trong app (phục vụ vòng hiệu chỉnh)

- Trong menu Camera (nút `...`) có thể bật **Hiện Debug Auto-Capture**.
- Overlay debug hiển thị tín hiệu thời gian thực:
  - `paperLevel`, `paperRatio`, `textTransitions`
  - `motionScore`, `quadShift`
  - `decision` pass/fail của vòng auto-capture
  - Số lần auto-capture pass và latency hội tụ gần nhất
- App tự hiển thị gợi ý UX:
  - **“Thiếu sáng → nên bật Low light để dễ tự chụp hơn”** khi phát hiện thiếu sáng kéo dài.

## 5. Regression checklist trước phát hành

- [ ] Không phá luồng chụp rộng trước → cắt/nắn sau trên ảnh full-res.
- [ ] Fallback về `pageQuadHint` khi ảnh chụp không tự dò được biên trang.
- [ ] Trạng thái `waitingForPageTurn` vẫn chặn chụp liên tiếp sai thời điểm.
- [ ] Chế độ 2 trang vẫn tách trang ổn định theo gáy.
- [ ] So sánh nhanh hành vi giữa profile `Auto` / `Low light` / `Normal light`.
- [ ] Chạy lại build iOS trên GitHub Actions và kiểm tra artifact `.ipa`.
- [ ] Test thủ công tối thiểu trên 2 thiết bị iPhone đời khác nhau.
