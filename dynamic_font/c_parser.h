#ifndef C_PARSER_H
#define C_PARSER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} CP_Color;

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t is_set;     /* 1 if the key exists in RICH_PALETTE, 0 otherwise */
} CP_PaletteEntry;

typedef struct {
    int start;
    int length;
    int script_group;
    CP_Color color;
    char face[32];
    int aa_toggle;
} CP_Run;

typedef struct {
    uint32_t codepoint;       /* 0 if this is a tag */
    int is_tag;               /* 1: is a tag, 0: is a character */
    char tag_type[32];        /* "COLOR:x", "FACE_OPEN:xxx", "FACE_CLOSE", "-" */
    char active_face[32];     /* Context face at that point in time */
    int script_group;         /* 0..7, or -1 if this is a tag */
} CP_DebugToken;

int cp_classify_script(uint32_t code);
int cp_is_ignorable(uint32_t code);
int cp_is_inheritable(uint32_t code);
void cp_reorder_bidi_runs(CP_Run* runs, int run_count);

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
);

int cp_parse_debug(
    const uint32_t* codepoints,
    int length,
    const char* default_face,
    const CP_PaletteEntry* palette,
    CP_DebugToken* out_tokens,
    int max_tokens
);

#ifdef __cplusplus
}
#endif

#endif /* C_PARSER_H */