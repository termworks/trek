package model

import "core:path/filepath"
import "core:strings"

Icon_Theme :: enum {
	Emoji,
	Material,
}

Icon_Kind :: enum {
	Dir,
	Dir_Open,
	Rust,
	Odin,
	Python,
	JavaScript,
	TypeScript,
	React,
	Json,
	Markdown,
	Html,
	Css,
	Config,
	Shell,
	CFamily,
	Go,
	Lua,
	Sql,
	Text,
	Image,
	Audio,
	Video,
	Archive,
	Lock,
	Binary,
	Git,
	Docker,
	Package,
	Build,
	Readme,
	License,
	Env_Key,
	File,
}

Icon :: struct {
	glyph:   string,
	r:       u8,
	g:       u8,
	b:       u8,
	colored: bool,
}

icon_theme_name :: proc(theme: Icon_Theme) -> string {
	if theme == .Material do return "material"
	return "emoji"
}

icon_theme_parse :: proc(value: string) -> (Icon_Theme, bool) {
	lower := strings.to_lower(strings.trim_space(value))
	defer delete(lower)
	switch lower {
	case "emoji": return .Emoji, true
	case "material": return .Material, true
	}
	return .Emoji, false
}

icon_theme_toggle :: proc(theme: Icon_Theme) -> Icon_Theme {
	if theme == .Emoji do return .Material
	return .Emoji
}

icon_special_kind :: proc(lower: string) -> (Icon_Kind, bool) {
	switch lower {
	case "cargo.lock", "package-lock.json", "yarn.lock", "pnpm-lock.yaml": return .Lock, true
	case "cargo.toml", "package.json", "pyproject.toml", "go.mod", "gemfile": return .Package, true
	case "makefile", "justfile", "cmakelists.txt": return .Build, true
	case ".gitignore", ".gitattributes", ".gitmodules": return .Git, true
	case "copying": return .License, true
	}
	if strings.has_prefix(lower, "dockerfile") || strings.has_prefix(lower, "docker-compose") do return .Docker, true
	if strings.has_prefix(lower, "readme") do return .Readme, true
	if strings.has_prefix(lower, "license") do return .License, true
	if lower == ".env" || strings.has_prefix(lower, ".env.") do return .Env_Key, true
	return .File, false
}

icon_extension_kind :: proc(ext: string) -> Icon_Kind {
	switch ext {
	case ".rs": return .Rust
	case ".odin": return .Odin
	case ".py", ".pyi": return .Python
	case ".js", ".mjs", ".cjs": return .JavaScript
	case ".ts": return .TypeScript
	case ".jsx", ".tsx": return .React
	case ".json", ".jsonc": return .Json
	case ".md", ".markdown": return .Markdown
	case ".html", ".htm": return .Html
	case ".css", ".scss", ".sass", ".less": return .Css
	case ".toml", ".yaml", ".yml", ".ini", ".cfg", ".conf", ".xml": return .Config
	case ".sh", ".bash", ".zsh", ".fish": return .Shell
	case ".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".cs": return .CFamily
	case ".go": return .Go
	case ".lua": return .Lua
	case ".sql", ".db", ".sqlite", ".sqlite3": return .Sql
	case ".txt", ".log", ".pdf": return .Text
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".svg", ".tiff": return .Image
	case ".mp3", ".wav", ".flac", ".ogg": return .Audio
	case ".mp4", ".mkv", ".avi", ".mov", ".webm": return .Video
	case ".zip", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".7z", ".rar": return .Archive
	case ".lock": return .Lock
	case ".exe", ".dll", ".so", ".dylib", ".a", ".o", ".bin", ".wasm": return .Binary
	}
	return .File
}

icon_kind :: proc(name: string, is_dir, expanded: bool) -> Icon_Kind {
	if is_dir {
		if expanded do return .Dir_Open
		return .Dir
	}
	lower := strings.to_lower(name)
	defer delete(lower)
	if kind, ok := icon_special_kind(lower); ok do return kind
	return icon_extension_kind(filepath.ext(lower))
}

emoji_icon :: proc(kind: Icon_Kind) -> string {
	switch kind {
	case .Dir: return "📁"
	case .Dir_Open: return "📂"
	case .Rust: return "🦀"
	case .Odin: return "⚔"
	case .Python: return "🐍"
	case .JavaScript: return "🟨"
	case .TypeScript: return "🔷"
	case .React: return "🟦"
	case .Json: return "🧾"
	case .Markdown: return "📝"
	case .Html: return "🌐"
	case .Css: return "🎨"
	case .Config: return "🔧"
	case .Shell: return "🐚"
	case .CFamily: return "🔩"
	case .Go: return "🐹"
	case .Lua: return "🌙"
	case .Sql: return "💾"
	case .Text: return "📄"
	case .Image: return "📷"
	case .Audio: return "🎵"
	case .Video: return "🎬"
	case .Archive: return "🧳"
	case .Lock: return "🔒"
	case .Binary: return "⚡"
	case .Git: return "🙈"
	case .Docker: return "🐳"
	case .Package: return "📦"
	case .Build: return "🔨"
	case .Readme: return "📖"
	case .License: return "📜"
	case .Env_Key: return "🔑"
	case .File: return "📄"
	}
	return "📄"
}

material_icon :: proc(kind: Icon_Kind) -> Icon {
	#partial switch kind {
	case .Dir: return Icon{glyph = "\uf07b", r = 0x90, g = 0xa4, b = 0xae, colored = true}
	case .Dir_Open: return Icon{glyph = "\uf07c", r = 0x90, g = 0xa4, b = 0xae, colored = true}
	case .Rust: return Icon{glyph = "\ue7a8", r = 0xde, g = 0xa5, b = 0x84, colored = true}
	case .Odin: return Icon{glyph = "\uf0e3", r = 0x70, g = 0x9b, b = 0xe7, colored = true}
	case .Python: return Icon{glyph = "\ue73c", r = 0x35, g = 0x72, b = 0xa5, colored = true}
	case .JavaScript: return Icon{glyph = "\ue74e", r = 0xf1, g = 0xe0, b = 0x5a, colored = true}
	case .TypeScript: return Icon{glyph = "\ue628", r = 0x31, g = 0x78, b = 0xc6, colored = true}
	case .Git: return Icon{glyph = "\ue702", r = 0xf1, g = 0x4e, b = 0x32, colored = true}
	case .Docker: return Icon{glyph = "\uf308", r = 0x0d, g = 0xb7, b = 0xed, colored = true}
	case .Lock, .License, .Env_Key: return Icon{glyph = "\uf023", r = 0xff, g = 0xd5, b = 0x4f, colored = true}
	case .Image: return Icon{glyph = "\uf1c5", r = 0x26, g = 0xa6, b = 0x9a, colored = true}
	case .Build: return Icon{glyph = "\uf0ad", r = 0x6d, g = 0x80, b = 0x86, colored = true}
	case .Package: return Icon{glyph = "\uf487", r = 0x8d, g = 0x6e, b = 0x63, colored = true}
	}
	return Icon{glyph = "\uf15b", r = 0x90, g = 0xa4, b = 0xae, colored = true}
}

file_icon :: proc(theme: Icon_Theme, name: string, is_dir, expanded: bool) -> Icon {
	kind := icon_kind(name, is_dir, expanded)
	if theme == .Material do return material_icon(kind)
	return Icon{glyph = emoji_icon(kind)}
}
