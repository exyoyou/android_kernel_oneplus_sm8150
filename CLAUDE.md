本分支的项目说明、关键设计和操作流程见 KERNELSU.md，改动前先读：

@KERNELSU.md

- 回复用户用中文，git 提交说明也用中文（标题保留 `drivers:`、`fs:`、`ci:`、`docs:` 这类前缀）。
- 不要改变内核版本字符串的规则，也不要改变导出符号的 CRC（见 KERNELSU.md “关键设计”）。
- `.github/` 被 `.gitignore` 忽略，提交时用 `git add -f`。
- 推送由用户自己执行。
