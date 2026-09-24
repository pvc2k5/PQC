## 1. Clone repo về máy

```bash
git clone https://github.com/pvc2k5/PQC.git
cd PQC
```

## 2. Tạo nhánh riêng cho mình

Tạo nhánh 1 nhánh làm việc của mỗi cá nhân (chỉ phải tạo 1 lần khi mới clone về máy):

```bash
git checkout main
git pull origin main
git checkout -b <ten-nhanh>
```

## 3. Code và commit
trước khi commit, xem những gì đã thay đổi bằng lệnh
```bash
git status
```
những file màu đỏ là đã được thay đổi nhưng chưa được stage
dùng add để thêm file vào stage
```bash
git add path/to/file
```
hoặc nếu muốn thêm tất cả file vào stage dùng:
```bash
git add .
```
commit dùng lệnh:
```bash
git commit -m "mô tả"
```
## 4. Push nhánh lên GitHub

```bash
git push origin <tên-nhánh-đã-tạo>
```

Lần đầu push nhánh mới, Git có thể yêu cầu thêm `-u`:

```bash
git push -u origin <tên-nhánh-đã-tạo>
```

## 5. Test kỹ trước khi tạo Pull Request

- Đảm bảo code chạy đúng, không lỗi.
- Đảm bảo không làm hỏng phần code của người khác.
- Nếu nhánh `main` đã có cập nhật mới trong lúc bạn làm, nên cập nhật nhánh của mình trước khi tạo PR:

```bash
git checkout main
git pull origin main
git checkout ten-nhanh-cua-ban
git merge main
```

Xử lý conflict (nếu có) rồi commit lại, sau đó push tiếp lên nhánh của mình.

## 6. Tạo Pull Request (PR)

1. Vào repo trên GitHub.
2. Chọn **Pull requests** → **New pull request**.
3. Base: `main` ← Compare: `ten-nhanh-cua-ban`.
4. Viết tiêu đề và mô tả ngắn gọn về thay đổi.
5. Nhấn **Create pull request**.

## 7. Sau khi PR được duyệt và merge

Xoá nhánh cũ (không bắt buộc nhưng nên làm để repo gọn gàng):

```bash
git checkout main
git pull origin main
git branch -d <ten-nhanh>
git push origin --delete <ten-nhanh>
```

## Quy tắc chung

- Không push thẳng lên `main`.
- Mỗi người chỉ làm việc trên nhánh của mình, tránh sửa trực tiếp nhánh của người khác.
- Luôn test kỹ trước khi tạo PR.
