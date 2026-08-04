# 🚀 What's New in v1.2.2.5 ?

## Bug Fixes

**1. `ANTI_ALIAS` won't work correctly
Fixed a bug in the `ANTI ALIAS` configuration variable where text or characters were still aliased even when the variable was set to `False`.

**2. Add a mechanism for checking data safely.
Configuration variables in previous versions could be overwritten or assigned invalid values ​​for design purposes. In this version, we have integrated a data type checker for configuration variables such as `MODERN_FONT` (Boolean), `SMOOTH_FONT` (Boolean), `EMOJI_OFFSET_Y` (Float, Integer), etc., to ensure the program does not crash during runtime.