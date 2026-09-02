#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "c_parser.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define CP_DIR_LTR 0
#define CP_DIR_RTL 1
#define CP_DIR_NEUTRAL 2

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
    switch (code) {
        case 0x200B: case 0x200E: case 0x200F:
        case 0x202A: case 0x202B: case 0x202C: case 0x202D: case 0x202E:
        case 0x2066: case 0x2067: case 0x2068: case 0x2069:
        case 0x061C:
            return 1;
        default:
            return 0;
    }
}

int cp_is_inheritable(uint32_t code) {
    if (code >= 0x0300 && code <= 0x036F) return 1;
    if (code >= 0x0483 && code <= 0x0489) return 1;
    if (code >= 0x0591 && code <= 0x05BD) return 1;
    if (code >= 0x05BF && code <= 0x05C7) return 1;
    if (code >= 0x0610 && code <= 0x061A) return 1;
    if (code >= 0x064B && code <= 0x065F) return 1;
    if (code >= 0x0670 && code <= 0x06DC) return 1;
    if (code >= 0x0900 && code <= 0x0903) return 1;
    if (code >= 0x093A && code <= 0x094F) return 1;
    if (code >= 0x0E31 && code <= 0x0E3A) return 1;
    if (code >= 0x0E47 && code <= 0x0E4E) return 1;
    if (code >= 0x17B4 && code <= 0x17D3) return 1;
    if (code >= 0xFE20 && code <= 0xFE2F) return 1;
    if (code >= 0x200C && code <= 0x200D) return 1;
    return 0;
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

static void parse_face_cmd(const char* raw_cmd, int cmd_len, char* out_face, int* out_aa_toggle) {
    char buf[32];
    int len = 0;
    for (int k = 0; k < cmd_len && k < 31; ++k) {
        if (raw_cmd[k] != ' ' && raw_cmd[k] != '\t') {
            buf[len++] = (char)tolower((unsigned char)raw_cmd[k]);
        }
    }
    buf[len] = '\0';

    if (strcmp(buf, "alias") == 0) {
        out_face[0] = '\0';
        *out_aa_toggle = 1;
        return;
    }

    if (strncmp(buf, "[aa]", 4) == 0) {
        const char* p = buf + 4;
        if (*p == '/') p++;
        cp_copy_str(out_face, p, 32);
        *out_aa_toggle = 1;
        return;
    }

    cp_copy_str(out_face, buf, 32);
    *out_aa_toggle = 0;
}

void cp_reorder_bidi_runs(CP_Run* runs, int run_count) {
    if (!runs || run_count <= 1) return;

    int stack_dirs[128];
    int* dirs = stack_dirs;
    if (run_count > 128) {
        dirs = (int*)malloc(run_count * sizeof(int));
        if (!dirs) return;
    }

    for (int i = 0; i < run_count; ++i) {
        int sg = runs[i].script_group;
        if (sg == 1 || sg == 2 || sg == 6) {
            dirs[i] = CP_DIR_RTL;
        } else if (sg == 0) {
            dirs[i] = CP_DIR_NEUTRAL;
        } else {
            dirs[i] = CP_DIR_LTR;
        }
    }

    for (int i = 0; i < run_count; ++i) {
        if (dirs[i] == CP_DIR_NEUTRAL) {
            int prev_dir = CP_DIR_LTR;
            for (int j = i - 1; j >= 0; --j) {
                if (dirs[j] != CP_DIR_NEUTRAL) {
                    prev_dir = dirs[j];
                    break;
                }
            }
            int next_dir = CP_DIR_LTR;
            for (int j = i + 1; j < run_count; ++j) {
                if (dirs[j] != CP_DIR_NEUTRAL) {
                    next_dir = dirs[j];
                    break;
                }
            }
            dirs[i] = (prev_dir == next_dir) ? prev_dir : CP_DIR_LTR;
        }
    }

    int start = 0;
    while (start < run_count) {
        if (dirs[start] == CP_DIR_RTL) {
            int end = start;
            while (end < run_count && dirs[end] == CP_DIR_RTL) {
                end++;
            }
            int left = start;
            int right = end - 1;
            while (left < right) {
                CP_Run tmp = runs[left];
                runs[left] = runs[right];
                runs[right] = tmp;
                left++;
                right--;
            }
            start = end;
        } else {
            start++;
        }
    }

    if (dirs != stack_dirs) {
        free(dirs);
    }
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

    CP_Color cur_color = default_color;
    char cur_face[32];
    cp_copy_str(cur_face, default_face ? default_face : "", 32);
    int cur_aa_toggle = 0;

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
                if (cur_run_len > 0 && run_count < max_runs) {
                    out_runs[run_count].start = cur_run_start;
                    out_runs[run_count].length = cur_run_len;
                    out_runs[run_count].script_group = cur_script;
                    out_runs[run_count].color = cur_color;
                    cp_copy_str(out_runs[run_count].face, cur_face, 32);
                    out_runs[run_count].aa_toggle = cur_aa_toggle;
                    run_count++;
                    cur_run_start = clean_count;
                    cur_run_len = 0;
                }
                if (is_reset) {
                    cur_color = default_color;
                } else {
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
            for (int k = i + 1; k < length && (k - i) < 30; ++k) {
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
                    out_runs[run_count].color = cur_color;
                    cp_copy_str(out_runs[run_count].face, cur_face, 32);
                    out_runs[run_count].aa_toggle = cur_aa_toggle;
                    run_count++;
                    cur_run_start = clean_count;
                    cur_run_len = 0;
                }

                int start_offset = (i + 1 < length && codepoints[i + 1] == '/') ? (i + 2) : (i + 1);
                int cmd_len = eq_idx - start_offset;
                char raw_cmd[32];
                int c_idx = 0;
                for (int k = start_offset; k < eq_idx && c_idx < 31; ++k) {
                    raw_cmd[c_idx++] = (char)codepoints[k];
                }
                raw_cmd[c_idx] = '\0';

                char parsed_face[32];
                int parsed_aa = 0;
                parse_face_cmd(raw_cmd, c_idx, parsed_face, &parsed_aa);

                if (parsed_face[0] != '\0') {
                    cp_copy_str(cur_face, parsed_face, 32);
                }
                cur_aa_toggle = parsed_aa;

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
                out_runs[run_count].color = cur_color;
                cp_copy_str(out_runs[run_count].face, cur_face, 32);
                out_runs[run_count].aa_toggle = cur_aa_toggle;
                run_count++;
                cur_run_start = clean_count;
                cur_run_len = 0;
            }
            cp_copy_str(cur_face, default_face ? default_face : "", 32);
            cur_aa_toggle = 0;
            i += 2;
            continue;
        }

        /* 4. Ignorable characters */
        if (cp_is_ignorable(ch)) {
            i++;
            continue;
        }

        /* 5. Script grouping & Combining mark inheritance */
        int script = cp_classify_script(ch);
        int inheritable = cp_is_inheritable(ch);

        if (inheritable && cur_script != -1 && cur_script != 0) {
            script = cur_script;
        }

        if (cur_run_len > 0 && script != cur_script) {
            if (run_count < max_runs) {
                out_runs[run_count].start = cur_run_start;
                out_runs[run_count].length = cur_run_len;
                out_runs[run_count].script_group = cur_script;
                out_runs[run_count].color = cur_color;
                cp_copy_str(out_runs[run_count].face, cur_face, 32);
                out_runs[run_count].aa_toggle = cur_aa_toggle;
                run_count++;
            }
            cur_run_start = clean_count;
            cur_run_len = 0;
        }

        if (cur_run_len == 0) {
            cur_script = script;
        }

        out_clean_chars[clean_count++] = ch;
        cur_run_len++;
        i++;
    }

    if (cur_run_len > 0 && run_count < max_runs) {
        out_runs[run_count].start = cur_run_start;
        out_runs[run_count].length = cur_run_len;
        out_runs[run_count].script_group = cur_script;
        out_runs[run_count].color = cur_color;
        cp_copy_str(out_runs[run_count].face, cur_face, 32);
        out_runs[run_count].aa_toggle = cur_aa_toggle;
        run_count++;
    }

    if (run_count > 1) {
        cp_reorder_bidi_runs(out_runs, run_count);
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
            for (int k = i + 1; k < length && (k - i) < 30; ++k) {
                if (codepoints[k] == '=' && (k + 1) < length && codepoints[k + 1] == '{') {
                    eq_idx = k;
                    break;
                }
            }

            if (eq_idx != -1) {
                int start_offset = (i + 1 < length && codepoints[i + 1] == '/') ? (i + 2) : (i + 1);
                int cmd_len = eq_idx - start_offset;
                char raw_cmd[32];
                int c_idx = 0;
                for (int k = start_offset; k < eq_idx && c_idx < 31; ++k) {
                    raw_cmd[c_idx++] = (char)codepoints[k];
                }
                raw_cmd[c_idx] = '\0';

                char parsed_face[32];
                int parsed_aa = 0;
                parse_face_cmd(raw_cmd, c_idx, parsed_face, &parsed_aa);

                if (parsed_face[0] != '\0') {
                    cp_copy_str(cur_face, parsed_face, 32);
                }

                out_tokens[token_count].codepoint = 0;
                out_tokens[token_count].is_tag = 1;
                out_tokens[token_count].script_group = -1;
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

            out_tokens[token_count].codepoint = 0;
            out_tokens[token_count].is_tag = 1;
            out_tokens[token_count].script_group = -1;
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
        cp_copy_str(out_tokens[token_count].active_face, cur_face, 32);
        cp_copy_str(out_tokens[token_count].tag_type, "-", 32);

        token_count++;
        i++;
    }

    return token_count;
}