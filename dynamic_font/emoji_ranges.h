#ifndef EMOJI_RANGES_H
#define EMOJI_RANGES_H

/*
 * emoji_ranges.h — Bảng tra cứu emoji trích xuất TRỰC TIẾP từ dataset
 * của thư viện Python `emoji` (EMOJI_DATA), chỉ giữ các entry
 * single-codepoint (bỏ qua sequence nhiều codepoint như ZWJ combo,
 * vì is_emoji() chỉ kiểm tra 1 ký tự tại 1 thời điểm).
 *
 * Sinh tự động — KHÔNG sửa tay. Muốn cập nhật: chạy lại script generator
 * với phiên bản `emoji` mới hơn.
 *
 * Tổng: 147 dải, phủ chính xác 1400 codepoint (không dư/thiếu).
 */

typedef struct {
    unsigned int start;
    unsigned int end;
} EmojiRange;

extern const EmojiRange EMOJI_RANGES[];
extern const int EMOJI_RANGES_COUNT;

/* Binary search — trả về 1 nếu code nằm trong bảng, 0 nếu không. */
int is_emoji_codepoint(unsigned int code);

#endif
