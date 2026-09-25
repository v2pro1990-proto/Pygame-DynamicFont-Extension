#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "c_parser.h"
#include <SheenBidi/SheenBidi.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define CP_TAG_CMD_MAX 64    /* longest tag command, e.g. "[aa];[size=128]/bolditalic" */
#define CP_MAX_SIZE    1024  /* largest accepted inline font size */

int cp_classify_script(uint32_t code) {
    if (code == 0x20 || code == 0x00A0) return 0;  /* Space */
    if (code >= 0x0590 && code <= 0x05FF) return 1;  /* Hebrew */
    if ((code >= 0x0600 && code <= 0x08FF) || 
        (code >= 0xFB50 && code <= 0xFDFF) || 
        (code >= 0xFE70 && code <= 0xFEFF)) return 2;  /* Arabic */
    if (code >= 0x0900 && code <= 0x0DFF) return 3;  /* Indic */
    if (code >= 0x0E00 && code <= 0x0EFF) return 4;  /* Thai */
    if (code >= 0x0F00 && code <= 0x109F) return 5;  /* Tibetan */
    if (code >= 0x1780 && code <= 0x17FF) return 6;  /* Khmer */
    return 7;  /* Latin/CJK/Other */
}

int cp_is_ignorable(uint32_t code) {
    if (code < 0x20 && code != '\t' && code != '\n' && code != '\r') return 1;
    if (code >= 0x7F && code <= 0x9F) return 1;
    /* ZWSP is dropped. BiDi controls (LRM/RLM/ALM, embeddings, overrides,
     * isolates) are KEPT: they steer cp_itemize()'s bidi algorithm, and
     * HarfBuzz renders them invisible (default-ignorable). */
    return code == 0x200B;
}

static inline void cp_copy_str(char* dst, const char* src, int max_len) {
    if (!dst || max_len <= 0) return;
    if (!src) {
        dst[0] = '\0';
        return;
    }
    int i = 0;
    while (i < max_len - 1 && src[i] != '\0') {
        dst[i] = src[i];
        i++;
    }
    dst[i] = '\0';
}

/* Reads a decimal number at p. Returns the digits consumed (0 = none);
 * *out gets the value, or 0 when it's outside 1..CP_MAX_SIZE. */
static int parse_size_value(const char* p, int* out) {
    int n = 0, used = 0;
    while (p[used] >= '0' && p[used] <= '9' && used < 6) {
        n = n * 10 + (p[used] - '0');
        used++;
    }
    *out = (used > 0 && n >= 1 && n <= CP_MAX_SIZE) ? n : 0;
    return used;
}

/* Reads up to 3 digits at p[*pos] as a 0-255 channel. */
static int parse_channel(const char* p, int len, int* pos, int* out) {
    int used = 0, v = 0;
    while (*pos < len && p[*pos] >= '0' && p[*pos] <= '9' && used < 3) {
        v = v * 10 + (p[*pos] - '0');
        (*pos)++;
        used++;
    }
    if (used == 0 || v > 255) return 0;
    *out = v;
    return 1;
}

/*
 * Parses exactly len chars at p as a color tag value, written the way
 * Python writes it (spaces were already removed, text lowercased):
 *   (R,G,B)  or  (R,G,B,A)   a tuple — also what an f-string makes of a
 *                            tuple / pygame.Color variable (A is ignored)
 *   color(R,G,B,A)           pygame-ce's str(pygame.Color)
 *   gradient#N               a gradient (its f-string / name-lookup handle)
 * Named variables — color(ORANGE) — are resolved to one of these on the
 * Python side before the text gets here.
 * Returns 1 for a plain color (*out filled), 2 for a gradient reference
 * (*out_grad_id = N), 0 when the value isn't valid (nothing changed) —
 * including a bare "R,G,B" without the tuple's parentheses.
 */
static int parse_color_value(const char* p, int len, CP_Color* out, int* out_grad_id) {
    int pos = 0, r, g, b, a, id = 0, used = 0;

    /* pygame-ce's str(pygame.Color) is "Color(R, G, B, A)" (lowercased
     * here by the caller) — drop the name, keep the parenthesized part. */
    if (len > 7 && strncmp(p, "color(", 6) == 0 && p[len - 1] == ')') {
        p += 5;
        len -= 5;
    }
    if (len > 9 && strncmp(p, "gradient#", 9) == 0) {
        pos = 9;
        while (pos < len && p[pos] >= '0' && p[pos] <= '9' && used < 9) {
            id = id * 10 + (p[pos] - '0');
            pos++;
            used++;
        }
        if (used == 0 || pos != len || id <= 0) return 0;
        *out_grad_id = id;
        return 2;
    }
    /* A plain color must be a tuple: "(R,G,B)". */
    if (len < 2 || p[0] != '(' || p[len - 1] != ')') return 0;
    p++;
    len -= 2;
    if (!parse_channel(p, len, &pos, &r) || pos >= len || p[pos++] != ',') return 0;
    if (!parse_channel(p, len, &pos, &g) || pos >= len || p[pos++] != ',') return 0;
    if (!parse_channel(p, len, &pos, &b)) return 0;
    if (pos < len) {
        if (p[pos++] != ',' || !parse_channel(p, len, &pos, &a)) return 0;
    }
    if (pos != len) return 0;
    out->r = (uint8_t)r;
    out->g = (uint8_t)g;
    out->b = (uint8_t)b;
    return 1;
}

/*
 * Parses the command part of an opening tag (between '<' or '</' and '={'),
 * case-insensitive, spaces ignored:
 *
 *   alias                    toggle anti-aliasing
 *   size(40)                 font size only (the face stays as it is)
 *   color((255,136,0))       text color only (the face stays as it is);
 *                            the value is a tuple, gradient#N, or (after
 *                            the Python-side name lookup) a variable name
 *                            such as color(ORANGE) — see parse_color_value
 *   [aa]/size(40)            toggle anti-aliasing + size ('/' optional)
 *   [aa]/color((255,136,0))  toggle anti-aliasing + color ('/' optional)
 *   bold                     face only
 *   [aa]/bold  or [aa]bold   toggle anti-aliasing + face
 *   [size=40]/bold           size + face
 *   [color=(255,136,0)]/bold color + face
 *   tnum                     tabular (equal-width) digits only (the face
 *                            stays as it is) — OpenType feature 'tnum'
 *   [tnum]/bold              tabular digits + face
 *   [aa];[size=40];[color=(255,136,0)];[tnum]/bold
 *                            any mix of [option] groups, in any order,
 *                            before the (optional) '/' and the face name
 *
 * *out_aa_toggle gets CP_STYLE_* flags (anti-aliasing toggle, tabular
 * digits). out_face is left empty when the tag names no face, which keeps the current
 * face. out_size is 0 when the tag sets no (valid) size, meaning "the
 * render() call's size". *out_has_color is 1 when the tag sets a (valid)
 * plain color (in *out_color), 2 when it references a gradient (its id in
 * *out_grad_id).
 */
static void parse_face_cmd(const char* raw_cmd, int cmd_len, char* out_face,
                           int* out_aa_toggle, int* out_size,
                           int* out_has_color, CP_Color* out_color, int* out_grad_id) {
    char buf[CP_TAG_CMD_MAX];
    int len = 0;
    const char* p;
    const char* close;
    int olen, used;

    for (int k = 0; k < cmd_len && len < CP_TAG_CMD_MAX - 1; ++k) {
        if (raw_cmd[k] != ' ' && raw_cmd[k] != '\t') {
            buf[len++] = (char)tolower((unsigned char)raw_cmd[k]);
        }
    }
    buf[len] = '\0';

    out_face[0] = '\0';
    *out_aa_toggle = 0;
    *out_size = 0;
    *out_has_color = 0;

    if (strcmp(buf, "alias") == 0) {
        *out_aa_toggle = CP_STYLE_AA;
        return;
    }

    /* [option] groups, optionally separated by ';' */
    p = buf;
    while (*p == '[') {
        close = strchr(p, ']');
        if (!close) break;
        olen = (int)(close - (p + 1));
        if (olen == 2 && strncmp(p + 1, "aa", 2) == 0) {
            *out_aa_toggle |= CP_STYLE_AA;
        } else if (olen == 4 && strncmp(p + 1, "tnum", 4) == 0) {
            *out_aa_toggle |= CP_STYLE_TNUM;
        } else if (olen > 5 && strncmp(p + 1, "size=", 5) == 0) {
            used = parse_size_value(p + 6, out_size);
            if (used != olen - 5) *out_size = 0;   /* junk after the number */
        } else if (olen > 6 && strncmp(p + 1, "color=", 6) == 0) {
            *out_has_color = parse_color_value(p + 7, olen - 6, out_color, out_grad_id);
        }
        p = close + 1;
        if (*p == ';') p++;
    }
    if (*p == '/') p++;

    /* tnum in place of a face name: "tnum", "[aa]/tnum" — tabular digits,
     * keeps the current face. */
    if (strcmp(p, "tnum") == 0) {
        *out_aa_toggle |= CP_STYLE_TNUM;
        return;
    }

    /* color(...) in place of a face name: "color((255,0,0))",
     * "[aa]/color((255,0,0))" — sets the color and keeps the current face. */
    if (strncmp(p, "color(", 6) == 0) {
        int clen = (int)strlen(p);
        if (clen > 7 && p[clen - 1] == ')') {
            *out_has_color = parse_color_value(p + 6, clen - 7, out_color, out_grad_id);
            return;
        }
    }

    /* size(N) in place of a face name: "size(40)", "[aa]/size(40)",
     * "[aa]size(40)" — sets the size and keeps the current face. */
    if (strncmp(p, "size(", 5) == 0) {
        int size_val;
        used = parse_size_value(p + 5, &size_val);
        if (used > 0 && p[5 + used] == ')' && p[6 + used] == '\0') {
            if (size_val > 0) *out_size = size_val;
            return;
        }
    }
    cp_copy_str(out_face, p, 32);
}

int cp_parse_text(
    const uint32_t* codepoints,
    int length,
    CP_Color default_color,
    const char* default_face,
    const CP_PaletteEntry* palette,
    uint32_t* out_clean_chars,
    int* out_clean_len,
    CP_Run* out_runs,
    int max_runs
) {
    int i = 0;
    int clean_count = 0;
    int run_count = 0;

    /* cur_color / cur_is_default: the ^X palette color (Rich Text v1).
     * tag_color: a <color(...)> / [color=...] tag's color, which OVERRIDES
     * ^X for the text it covers; ^X codes inside it are still tracked and
     * take effect again once the tag closes. */
    CP_Color cur_color = default_color;
    int cur_is_default = 1;   /* lets the caller swap in a gradient for untagged text */
    int tag_has_color = 0;     /* 0 none, 1 tag_color, 2 gradient tag_grad_id */
    CP_Color tag_color = default_color;
    int tag_grad_id = 0;
    int tag_seq = 0;           /* id of the open tag (0 = none); runs of one tag share it */
    int tag_counter = 0;
    char cur_face[32];
    cp_copy_str(cur_face, default_face ? default_face : "", 32);
    int cur_aa_toggle = 0;
    int cur_size = 0;         /* 0 = the render() call's size */

    int cur_run_start = 0;
    int cur_run_len = 0;
    int cur_script = -1;

    while (i < length) {
        uint32_t ch = codepoints[i];

        /* 1. Dynamic Color Tag ^X */
        if (ch == '^' && i + 1 < length) {
            uint32_t cmd = codepoints[i + 1];
            int is_reset = (cmd == 'r');
            int is_palette = (cmd < 256 && palette && palette[cmd].is_set);

            if (is_reset || is_palette) {
                /* Inside a color tag the visible color doesn't change, so
                 * the run needn't be split. */
                if (cur_run_len > 0 && run_count < max_runs && !tag_has_color) {
                    out_runs[run_count].start = cur_run_start;
                    out_runs[run_count].length = cur_run_len;
                    out_runs[run_count].script_group = cur_script;
                    out_runs[run_count].color = tag_has_color ? tag_color : cur_color;
                    cp_copy_str(out_runs[run_count].face, cur_face, 32);
                    out_runs[run_count].aa_toggle = cur_aa_toggle;
                    out_runs[run_count].color_is_default = tag_has_color ? 0 : cur_is_default;
                    out_runs[run_count].size = cur_size;
                    out_runs[run_count].grad_id = (tag_has_color == 2) ? tag_grad_id : 0;
                    out_runs[run_count].tag_seq = tag_seq;
                    run_count++;
                    cur_run_start = clean_count;
                    cur_run_len = 0;
                }
                if (is_reset) {
                    cur_color = default_color;
                    cur_is_default = 1;
                } else {
                    cur_is_default = 0;
                    cur_color.r = palette[cmd].r;
                    cur_color.g = palette[cmd].g;
                    cur_color.b = palette[cmd].b;
                }
                i += 2;
                continue;
            }
        }

        /* 2. Face open tag <tag={ */
        if (ch == '<') {
            int eq_idx = -1;
            for (int k = i + 1; k < length && (k - i) < CP_TAG_CMD_MAX; ++k) {
                /* A tag command is plain ASCII with no '<': this '<' is just
                 * text ("a < b", "Giá < 5đ") and a tag further on starts at
                 * its own '<'. (Scanning on used to take the text in between
                 * as the tag command — non-ASCII bytes there crashed render().) */
                if (codepoints[k] == '<' || codepoints[k] > 127) break;
                if (codepoints[k] == '=' && (k + 1) < length && codepoints[k + 1] == '{') {
                    eq_idx = k;
                    break;
                }
            }

            if (eq_idx != -1) {
                if (cur_run_len > 0 && run_count < max_runs) {
                    out_runs[run_count].start = cur_run_start;
                    out_runs[run_count].length = cur_run_len;
                    out_runs[run_count].script_group = cur_script;
                    out_runs[run_count].color = tag_has_color ? tag_color : cur_color;
                    cp_copy_str(out_runs[run_count].face, cur_face, 32);
                    out_runs[run_count].aa_toggle = cur_aa_toggle;
                    out_runs[run_count].color_is_default = tag_has_color ? 0 : cur_is_default;
                    out_runs[run_count].size = cur_size;
                    out_runs[run_count].grad_id = (tag_has_color == 2) ? tag_grad_id : 0;
                    out_runs[run_count].tag_seq = tag_seq;
                    run_count++;
                    cur_run_start = clean_count;
                    cur_run_len = 0;
                }

                int start_offset = (i + 1 < length && codepoints[i + 1] == '/') ? (i + 2) : (i + 1);
                int cmd_len = eq_idx - start_offset;
                char raw_cmd[CP_TAG_CMD_MAX];
                int c_idx = 0;
                for (int k = start_offset; k < eq_idx && c_idx < CP_TAG_CMD_MAX - 1; ++k) {
                    raw_cmd[c_idx++] = (char)codepoints[k];
                }
                raw_cmd[c_idx] = '\0';

                char parsed_face[32];
                int parsed_aa = 0;
                int parsed_size = 0;
                int parsed_has_color = 0;
                int parsed_grad_id = 0;
                CP_Color parsed_color = {0, 0, 0};
                parse_face_cmd(raw_cmd, c_idx, parsed_face, &parsed_aa, &parsed_size,
                               &parsed_has_color, &parsed_color, &parsed_grad_id);

                if (parsed_face[0] != '\0') {
                    cp_copy_str(cur_face, parsed_face, 32);
                }
                cur_aa_toggle = parsed_aa;
                cur_size = parsed_size;
                tag_has_color = parsed_has_color;
                if (parsed_has_color == 1) tag_color = parsed_color;
                if (parsed_has_color == 2) tag_grad_id = parsed_grad_id;
                tag_seq = ++tag_counter;

                i = eq_idx + 2;
                continue;
            }
        }

        /* 3. Face close tag }> */
        if (ch == '}' && i + 1 < length && codepoints[i + 1] == '>') {
            if (cur_run_len > 0 && run_count < max_runs) {
                out_runs[run_count].start = cur_run_start;
                out_runs[run_count].length = cur_run_len;
                out_runs[run_count].script_group = cur_script;
                out_runs[run_count].color = tag_has_color ? tag_color : cur_color;
                cp_copy_str(out_runs[run_count].face, cur_face, 32);
                out_runs[run_count].aa_toggle = cur_aa_toggle;
                out_runs[run_count].color_is_default = tag_has_color ? 0 : cur_is_default;
                out_runs[run_count].size = cur_size;
                out_runs[run_count].grad_id = (tag_has_color == 2) ? tag_grad_id : 0;
                out_runs[run_count].tag_seq = tag_seq;
                run_count++;
                cur_run_start = clean_count;
                cur_run_len = 0;
            }
            cp_copy_str(cur_face, default_face ? default_face : "", 32);
            cur_aa_toggle = 0;
            cur_size = 0;
            tag_has_color = 0;
            tag_seq = 0;
            i += 2;
            continue;
        }

        /* 4. Ignorable characters */
        if (cp_is_ignorable(ch)) {
            i++;
            continue;
        }

        /* 5. Plain character. Runs here are STYLE runs only (tags / ^X
         * colors) in logical order: direction, script and visual order
         * come from cp_itemize() (UAX #9 + UAX #24 via SheenBidi). */
        if (cur_run_len == 0) {
            cur_script = 7;
        }

        out_clean_chars[clean_count++] = ch;
        cur_run_len++;
        i++;
    }

    if (cur_run_len > 0 && run_count < max_runs) {
        out_runs[run_count].start = cur_run_start;
        out_runs[run_count].length = cur_run_len;
        out_runs[run_count].script_group = cur_script;
        out_runs[run_count].color = tag_has_color ? tag_color : cur_color;
        cp_copy_str(out_runs[run_count].face, cur_face, 32);
        out_runs[run_count].aa_toggle = cur_aa_toggle;
        out_runs[run_count].color_is_default = tag_has_color ? 0 : cur_is_default;
        out_runs[run_count].size = cur_size;
        out_runs[run_count].grad_id = (tag_has_color == 2) ? tag_grad_id : 0;
        out_runs[run_count].tag_seq = tag_seq;
        run_count++;
    }

    *out_clean_len = clean_count;
    return run_count;
}

int cp_parse_debug(
    const uint32_t* codepoints,
    int length,
    const char* default_face,
    const CP_PaletteEntry* palette,
    CP_DebugToken* out_tokens,
    int max_tokens
) {
    int i = 0;
    int token_count = 0;
    char cur_face[32];
    int cur_size = 0;
    int tag_has_color = 0;
    CP_Color tag_color = {0, 0, 0};
    int tag_grad_id = 0;
    cp_copy_str(cur_face, default_face ? default_face : "", 32);

    while (i < length && token_count < max_tokens) {
        uint32_t ch = codepoints[i];

        /* 1. Tag Color ^X */
        if (ch == '^' && i + 1 < length) {
            uint32_t cmd = codepoints[i + 1];
            int is_reset = (cmd == 'r');
            int is_palette = (cmd < 256 && palette && palette[cmd].is_set);

            if (is_reset || is_palette) {
                out_tokens[token_count].codepoint = 0;
                out_tokens[token_count].is_tag = 1;
                out_tokens[token_count].script_group = -1;
                out_tokens[token_count].size = cur_size;
                out_tokens[token_count].has_color = tag_has_color;
                out_tokens[token_count].color = tag_color;
                out_tokens[token_count].grad_id = (tag_has_color == 2) ? tag_grad_id : 0;
                cp_copy_str(out_tokens[token_count].active_face, cur_face, 32);

                char ttype[32] = "COLOR:";
                ttype[6] = (char)cmd;
                ttype[7] = '\0';
                cp_copy_str(out_tokens[token_count].tag_type, ttype, 32);

                token_count++;
                i += 2;
                continue;
            }
        }

        /* 2. Tag Face Open <tag={ */
        if (ch == '<') {
            int eq_idx = -1;
            for (int k = i + 1; k < length && (k - i) < CP_TAG_CMD_MAX; ++k) {
                /* A tag command is plain ASCII with no '<': this '<' is just
                 * text ("a < b", "Giá < 5đ") and a tag further on starts at
                 * its own '<'. (Scanning on used to take the text in between
                 * as the tag command — non-ASCII bytes there crashed render().) */
                if (codepoints[k] == '<' || codepoints[k] > 127) break;
                if (codepoints[k] == '=' && (k + 1) < length && codepoints[k + 1] == '{') {
                    eq_idx = k;
                    break;
                }
            }

            if (eq_idx != -1) {
                int start_offset = (i + 1 < length && codepoints[i + 1] == '/') ? (i + 2) : (i + 1);
                int cmd_len = eq_idx - start_offset;
                char raw_cmd[CP_TAG_CMD_MAX];
                int c_idx = 0;
                for (int k = start_offset; k < eq_idx && c_idx < CP_TAG_CMD_MAX - 1; ++k) {
                    raw_cmd[c_idx++] = (char)codepoints[k];
                }
                raw_cmd[c_idx] = '\0';

                char parsed_face[32];
                int parsed_aa = 0;
                int parsed_size = 0;
                int parsed_has_color = 0;
                int parsed_grad_id = 0;
                CP_Color parsed_color = {0, 0, 0};
                parse_face_cmd(raw_cmd, c_idx, parsed_face, &parsed_aa, &parsed_size,
                               &parsed_has_color, &parsed_color, &parsed_grad_id);

                if (parsed_face[0] != '\0') {
                    cp_copy_str(cur_face, parsed_face, 32);
                }
                cur_size = parsed_size;
                tag_has_color = parsed_has_color;
                if (parsed_has_color == 1) tag_color = parsed_color;
                if (parsed_has_color == 2) tag_grad_id = parsed_grad_id;

                out_tokens[token_count].codepoint = 0;
                out_tokens[token_count].is_tag = 1;
                out_tokens[token_count].script_group = -1;
                out_tokens[token_count].size = cur_size;
                out_tokens[token_count].has_color = tag_has_color;
                out_tokens[token_count].color = tag_color;
                out_tokens[token_count].grad_id = (tag_has_color == 2) ? tag_grad_id : 0;
                cp_copy_str(out_tokens[token_count].active_face, cur_face, 32);

                char ttype[32] = "FACE_OPEN:";
                int tlen = 10;
                for (int k = 0; parsed_face[k] != '\0' && tlen < 31; ++k) {
                    ttype[tlen++] = parsed_face[k];
                }
                ttype[tlen] = '\0';
                cp_copy_str(out_tokens[token_count].tag_type, ttype, 32);

                token_count++;
                i = eq_idx + 2;
                continue;
            }
        }

        /* 3. Tag Face Close }> */
        if (ch == '}' && i + 1 < length && codepoints[i + 1] == '>') {
            cp_copy_str(cur_face, default_face ? default_face : "", 32);
            cur_size = 0;
            tag_has_color = 0;

            out_tokens[token_count].codepoint = 0;
            out_tokens[token_count].is_tag = 1;
            out_tokens[token_count].script_group = -1;
            out_tokens[token_count].size = 0;
            out_tokens[token_count].has_color = tag_has_color;
            out_tokens[token_count].color = tag_color;
            out_tokens[token_count].grad_id = (tag_has_color == 2) ? tag_grad_id : 0;
            cp_copy_str(out_tokens[token_count].active_face, cur_face, 32);
            cp_copy_str(out_tokens[token_count].tag_type, "FACE_CLOSE", 32);

            token_count++;
            i += 2;
            continue;
        }

        /* 4. Regular character */
        out_tokens[token_count].codepoint = ch;
        out_tokens[token_count].is_tag = 0;
        out_tokens[token_count].script_group = cp_classify_script(ch);
        out_tokens[token_count].size = cur_size;
        out_tokens[token_count].has_color = tag_has_color;
        out_tokens[token_count].color = tag_color;
        out_tokens[token_count].grad_id = (tag_has_color == 2) ? tag_grad_id : 0;
        cp_copy_str(out_tokens[token_count].active_face, cur_face, 32);
        cp_copy_str(out_tokens[token_count].tag_type, "-", 32);

        token_count++;
        i++;
    }

    return token_count;
}

/* ------------------------------------------------------------------------
 * cp_itemize — BiDi (UAX #9) + script (UAX #24) itemization via SheenBidi.
 * ---------------------------------------------------------------------- */

/* True if the text can produce a right-to-left level at all. */
static int cp_text_has_rtl(const uint32_t* text, int len) {
    for (int i = 0; i < len; ++i) {
        if (text[i] < 0x0590) continue;   /* nothing below Hebrew is RTL / a bidi control */
        switch (SBCodepointGetBidiType(text[i])) {
            case SBBidiTypeR: case SBBidiTypeAL: case SBBidiTypeAN:
            case SBBidiTypeRLE: case SBBidiTypeRLO: case SBBidiTypeRLI:
            case SBBidiTypeFSI:
                return 1;
            default:
                break;
        }
    }
    return 0;
}

/* True if every character is Latin / Vietnamese / common punctuation — text
 * HarfBuzz already shapes as Latin by itself, so script itemization can be
 * skipped (no SBScriptLocator pass). */
static int cp_text_is_simple_latin(const uint32_t* text, int len) {
    for (int i = 0; i < len; ++i) {
        uint32_t c = text[i];
        if (c < 0x0250) continue;                   /* ASCII, Latin-1, Latin Extended-A/B */
        if (c >= 0x0300 && c < 0x0370) continue;    /* combining diacritics */
        if (c >= 0x1E00 && c < 0x1F00) continue;    /* Latin Extended Additional (Vietnamese) */
        if (c >= 0x2000 && c < 0x2070) continue;    /* general punctuation */
        if (c >= 0x20A0 && c < 0x20D0) continue;    /* currency symbols */
        return 0;
    }
    return 1;
}

/* One script locator for the whole process: creating and releasing one per
 * render() call was a measurable share of the itemization cost. (Callers
 * run under the Python GIL, one at a time.) */
static SBScriptLocatorRef g_script_locator = NULL;

/* UAX #9 rule L2 on one paragraph's items [first, last): from the highest
 * level down to the lowest odd level, reverse every maximal sequence of
 * items at that level or higher. */
static void cp_reorder_items(CP_Run* items, int first, int last) {
    int max_level = 0, min_odd = 255, lvl, i, j;
    CP_Run tmp;
    for (i = first; i < last; ++i) {
        if (items[i].level > max_level) max_level = items[i].level;
        if ((items[i].level & 1) && items[i].level < min_odd) min_odd = items[i].level;
    }
    if (min_odd == 255) return;   /* all even: nothing to reverse */
    for (lvl = max_level; lvl >= min_odd; --lvl) {
        i = first;
        while (i < last) {
            if (items[i].level < lvl) { ++i; continue; }
            j = i;
            while (j < last && items[j].level >= lvl) ++j;
            for (int a = i, b = j - 1; a < b; ++a, --b) {
                tmp = items[a]; items[a] = items[b]; items[b] = tmp;
            }
            i = j;
        }
    }
}

/* UAX #9 levels per character (paragraph by paragraph, line rules L1
 * applied) into levels[length]; paragraph end offsets into para_end
 * (room for length + 1). Returns the paragraph count. */
static int cp_bidi_levels(const SBCodepointSequence* seq_in, const uint32_t* text, int length,
                          int base_dir, SBUInt8* levels, int* para_end) {
    SBCodepointSequence seq = *seq_in;
    SBLevel base_level;
    int n_para = 0;
    memset(levels, 0, (size_t)length);
    base_level = base_dir == CP_DIR_FORCE_RTL ? 1 : base_dir == CP_DIR_FORCE_LTR ? 0 : SBLevelDefaultLTR;
    if (base_dir != CP_DIR_FORCE_RTL && !cp_text_has_rtl(text, length)) {
        /* Pure left-to-right text: every level is 0 — skip the algorithm.
         * Paragraphs still end after each "\n", as the algorithm's would, so
         * items never run across a line break. */
        for (int k = 0; k < length - 1; ++k)
            if (text[k] == '\n') para_end[n_para++] = k + 1;
        para_end[n_para++] = length;
    } else {
        SBAlgorithmRef algo = SBAlgorithmCreate(&seq);
        SBUInteger offset = 0;
        while (algo && offset < (SBUInteger)length) {
            SBParagraphRef para = SBAlgorithmCreateParagraph(algo, offset, (SBUInteger)length - offset, base_level);
            if (!para) break;
            SBUInteger plen = SBParagraphGetLength(para);
            SBLineRef line = SBParagraphCreateLine(para, offset, plen);
            if (line) {
                const SBRun* runs = SBLineGetRunsPtr(line);
                SBUInteger rc = SBLineGetRunCount(line);
                for (SBUInteger r = 0; r < rc; ++r)
                    for (SBUInteger k = 0; k < runs[r].length; ++k)
                        levels[runs[r].offset + k] = runs[r].level;
                SBLineRelease(line);
            }
            SBParagraphRelease(para);
            offset += plen;
            para_end[n_para++] = (int)offset;
            if (plen == 0) break;
        }
        if (algo) SBAlgorithmRelease(algo);
        if (n_para == 0 || para_end[n_para - 1] != length) para_end[n_para++] = length;
    }

    return n_para;
}

#define CP_ITEMIZE_STACK 256

int cp_itemize(const uint32_t* text, int length, const CP_Run* style_runs, int n_style,
               int base_dir, CP_Run* out_items, int max_items) {
    SBCodepointSequence seq;
    SBUInt8 levels_stack[CP_ITEMIZE_STACK];
    SBUInt32 scripts_stack[CP_ITEMIZE_STACK];
    int para_stack[CP_ITEMIZE_STACK + 1];
    SBUInt8* levels = levels_stack;
    SBUInt32* scripts = scripts_stack;
    int* para_end = para_stack;
    int heap = 0;
    int n_items = 0, n_para = 0, i, s_idx, seg_start;

    if (length <= 0 || n_style <= 0) return 0;
    if (length > CP_ITEMIZE_STACK) {
        levels = (SBUInt8*)malloc((size_t)length);
        scripts = (SBUInt32*)malloc((size_t)length * sizeof(SBUInt32));
        para_end = (int*)malloc((size_t)(length + 1) * sizeof(int));
        heap = 1;
        if (!levels || !scripts || !para_end) {
            free(levels); free(scripts); free(para_end);
            return -1;
        }
    }
    seq.stringEncoding = SBStringEncodingUTF32;
    seq.stringBuffer = text;
    seq.stringLength = (SBUInteger)length;

    /* ---- levels: UAX #9 per paragraph, line rules (L1) applied ---- */
    n_para = cp_bidi_levels(&seq, text, length, base_dir, levels, para_end);

    /* ---- scripts: UAX #24 runs (Common / Inherited resolved to context).
     * Plain Latin text keeps script 0: HarfBuzz then detects Latin itself,
     * exactly as before itemization existed. ---- */
    memset(scripts, 0, (size_t)length * sizeof(SBUInt32));
    if (!cp_text_is_simple_latin(text, length)) {
        if (!g_script_locator) g_script_locator = SBScriptLocatorCreate();
        if (g_script_locator) {
            const SBScriptAgent* agent = SBScriptLocatorGetAgent(g_script_locator);
            SBScriptLocatorLoadCodepoints(g_script_locator, &seq);
            while (SBScriptLocatorMoveNext(g_script_locator)) {
                SBUInt32 tag = SBScriptGetUnicodeTag(agent->script);
                for (SBUInteger k = 0; k < agent->length; ++k)
                    scripts[agent->offset + k] = tag;
            }
            /* Drop the locator's pointer to our (stack) text. */
            SBScriptLocatorReset(g_script_locator);
        }
    }

    /* ---- items: cut at every style / level / script change ---- */
    s_idx = 0;
    seg_start = 0;
    for (int p = 0; p < n_para; ++p) {
        int p_end = para_end[p];
        int first_item = n_items;
        i = seg_start;
        while (i < p_end) {
            int start = i;
            while (s_idx < n_style - 1 && start >= style_runs[s_idx].start + style_runs[s_idx].length) ++s_idx;
            int style_end = style_runs[s_idx].start + style_runs[s_idx].length;
            if (style_end > p_end) style_end = p_end;
            if (style_end <= start) style_end = start + 1;   /* defensive: never stall */
            ++i;
            while (i < style_end && levels[i] == levels[start] && scripts[i] == scripts[start]) ++i;
            if (n_items >= max_items) break;
            out_items[n_items] = style_runs[s_idx];
            out_items[n_items].start = start;
            out_items[n_items].length = i - start;
            out_items[n_items].level = levels[start];
            out_items[n_items].script_tag = scripts[start];
            ++n_items;
        }
        cp_reorder_items(out_items, first_item, n_items);
        seg_start = p_end;
    }

    if (heap) { free(levels); free(scripts); free(para_end); }
    return n_items;
}

/* SheenBidi SBScript id -> Unicode script name (generated from SBScript.h). */
static const char* const cp_script_names[] = {
    NULL, "Inherited", "Common", "Unknown", "Arabic", "Armenian",
    "Bengali", "Bopomofo", "Cyrillic", "Devanagari", "Georgian", "Greek",
    "Gujarati", "Gurmukhi", "Hangul", "Han", "Hebrew", "Hiragana",
    "Katakana", "Kannada", "Lao", "Latin", "Malayalam", "Oriya",
    "Tamil", "Telugu", "Thai", "Tibetan", "Braille", "Canadian Aboriginal",
    "Cherokee", "Ethiopic", "Khmer", "Mongolian", "Myanmar", "Ogham",
    "Runic", "Sinhala", "Syriac", "Thaana", "Yi", "Deseret",
    "Gothic", "Old Italic", "Buhid", "Hanunoo", "Tagbanwa", "Tagalog",
    "Cypriot", "Limbu", "Linear B", "Osmanya", "Shavian", "Tai Le",
    "Ugaritic", "Buginese", "Coptic", "Glagolitic", "Kharoshthi", "Syloti Nagri",
    "New Tai Lue", "Tifinagh", "Old Persian", "Balinese", "Nko", "Phags Pa",
    "Phoenician", "Cuneiform", "Carian", "Cham", "Kayah Li", "Lepcha",
    "Lycian", "Lydian", "Ol Chiki", "Rejang", "Saurashtra", "Sundanese",
    "Vai", "Imperial Aramaic", "Avestan", "Bamum", "Egyptian Hieroglyphs", "Javanese",
    "Kaithi", "Tai Tham", "Lisu", "Meetei Mayek", "Old Turkic", "Inscriptional Pahlavi",
    "Inscriptional Parthian", "Samaritan", "Old South Arabian", "Tai Viet", "Batak", "Brahmi",
    "Mandaic", "Chakma", "Meroitic Cursive", "Meroitic Hieroglyphs", "Miao", "Sharada",
    "Sora Sompeng", "Takri", "Caucasian Albanian", "Bassa Vah", "Duployan", "Elbasan",
    "Grantha", "Pahawh Hmong", "Khojki", "Linear A", "Mahajani", "Manichaean",
    "Mende Kikakui", "Modi", "Mro", "Old North Arabian", "Nabataean", "Palmyrene",
    "Pau Cin Hau", "Old Permic", "Psalter Pahlavi", "Siddham", "Khudawadi", "Tirhuta",
    "Warang Citi", "Ahom", "Hatran", "Anatolian Hieroglyphs", "Old Hungarian", "Multani",
    "SignWriting", "Adlam", "Bhaiksuki", "Marchen", "Newa", "Osage",
    "Tangut", "Masaram Gondi", "Nushu", "Soyombo", "Zanabazar Square", "Dogra",
    "Gunjala Gondi", "Makasar", "Medefaidrin", "Hanifi Rohingya", "Sogdian", "Old Sogdian",
    "Elymaic", "Nyiakeng Puachue Hmong", "Nandinagari", "Wancho", "Chorasmian", "Dives Akuru",
    "Khitan Small Script", "Yezidi", "Cypro Minoan", "Old Uyghur", "Tangsa", "Toto",
    "Vithkuqi", "Kawi", "Nag Mundari", "Garay", "Gurung Khema", "Kirat Rai",
    "Ol Onal", "Sunuwar", "Todhri", "Tulu Tigalari", "Beria Erfe", "Sidetic",
    "Tai Yo",
};
#define CP_N_SCRIPT_NAMES ((int)(sizeof(cp_script_names) / sizeof(cp_script_names[0])))

const char* cp_script_name(int sb_script) {
    if (sb_script <= 0 || sb_script >= CP_N_SCRIPT_NAMES) return NULL;
    return cp_script_names[sb_script];
}

uint32_t cp_script_tag(int sb_script) {
    return sb_script > 0 ? SBScriptGetUnicodeTag((SBScript)sb_script) : 0;
}

int cp_analyze_chars(const uint32_t* text, int length, int base_dir,
                     uint8_t* out_levels, uint8_t* out_scripts) {
    SBCodepointSequence seq;
    int para_stack[CP_ITEMIZE_STACK + 1];
    int* para_end = para_stack;

    if (length <= 0) return 0;
    if (length > CP_ITEMIZE_STACK) {
        para_end = (int*)malloc((size_t)(length + 1) * sizeof(int));
        if (!para_end) return -1;
    }
    seq.stringEncoding = SBStringEncodingUTF32;
    seq.stringBuffer = text;
    seq.stringLength = (SBUInteger)length;

    cp_bidi_levels(&seq, text, length, base_dir, out_levels, para_end);

    /* Scripts always resolved here (render() skips this for plain Latin,
     * where HarfBuzz detects Latin by itself — same result). */
    memset(out_scripts, 0, (size_t)length);
    if (!g_script_locator) g_script_locator = SBScriptLocatorCreate();
    if (g_script_locator) {
        const SBScriptAgent* agent = SBScriptLocatorGetAgent(g_script_locator);
        SBScriptLocatorLoadCodepoints(g_script_locator, &seq);
        while (SBScriptLocatorMoveNext(g_script_locator)) {
            for (SBUInteger k = 0; k < agent->length; ++k)
                out_scripts[agent->offset + k] = (uint8_t)agent->script;
        }
        SBScriptLocatorReset(g_script_locator);
    }
    if (para_end != para_stack) free(para_end);
    return length;
}
