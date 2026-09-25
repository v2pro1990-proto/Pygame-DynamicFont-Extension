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
    int aa_toggle;         /* style flags from tags: CP_STYLE_AA | CP_STYLE_TNUM */
    int color_is_default;  /* 1: run uses default_color (no ^X tag active) */
    int size;              /* inline font size from a size tag; 0 = render()'s size */
    int grad_id;           /* >0: a color tag referencing a gradient (gradient#N) */
    int tag_seq;           /* which opening tag this run belongs to (0 = none) */
    int level;             /* cp_itemize: UAX #9 embedding level (odd = right-to-left) */
    uint32_t script_tag;   /* cp_itemize: ISO 15924 script tag, e.g. 'Arab' (0 = unknown) */
} CP_Run;

/* CP_Run.aa_toggle flags */
#define CP_STYLE_AA    1   /* [aa] / alias: toggle anti-aliasing */
#define CP_STYLE_TNUM  2   /* [tnum] / tnum: tabular (equal-width) digits */

/* cp_itemize() base_dir values */
#define CP_DIR_AUTO       0   /* paragraph direction from the first strong character */
#define CP_DIR_FORCE_LTR  1
#define CP_DIR_FORCE_RTL  2

typedef struct {
    uint32_t codepoint;       /* 0 if this is a tag */
    int is_tag;               /* 1: is a tag, 0: is a character */
    char tag_type[32];        /* "COLOR:x", "FACE_OPEN:xxx", "FACE_CLOSE", "-" */
    char active_face[32];     /* Context face at that point in time */
    int script_group;         /* 0..7, or -1 if this is a tag */
    int size;                 /* active inline size (0 = render()'s size) */
    int has_color;            /* 0 none, 1 color tag (color below), 2 gradient tag (grad_id) */
    CP_Color color;
    int grad_id;
} CP_DebugToken;

int cp_classify_script(uint32_t code);
int cp_is_ignorable(uint32_t code);

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

/*
 * Splits the clean text (from cp_parse_text) into items that each have one
 * style run, one UAX #9 bidi level and one UAX #24 script — the pieces
 * HarfBuzz shapes — and returns them in VISUAL (left-to-right) order,
 * paragraph by paragraph (rule L2). Each item copies its style run's fields
 * plus start/length/level/script_tag. Returns the item count, or -1 when
 * out of memory. max_items >= length is always enough.
 */
int cp_itemize(const uint32_t* text, int length, const CP_Run* style_runs, int n_style,
               int base_dir, CP_Run* out_items, int max_items);

/*
 * Per-character analysis of the clean text (get_debug_info): the UAX #9
 * embedding level (odd = right-to-left) and the UAX #24 script (a SheenBidi
 * SBScript id, 0 = none) of every character. Returns length, or -1 when out
 * of memory.
 */
int cp_analyze_chars(const uint32_t* text, int length, int base_dir,
                     uint8_t* out_levels, uint8_t* out_scripts);
/* Unicode script name ("Latin", "Arabic", ...) of an SBScript id, or NULL. */
const char* cp_script_name(int sb_script);
/* ISO 15924 tag of an SBScript id (e.g. 'Latn'), 0 for none. */
uint32_t cp_script_tag(int sb_script);

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