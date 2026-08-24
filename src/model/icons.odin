package model

import "core:path/filepath"
import "core:strings"


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
	Xml,
	Shell,
	PowerShell,
	CFamily,
	CPlusPlus,
	Header,
	Zig,
	Vim,
	Svg,
	CSharp,
	Go,
	Ruby,
	Php,
	Java,
	Kotlin,
	Swift,
	Lua,
	Sql,
	Data,
	Text,
	Log,
	Pdf,
	Image,
	Audio,
	Video,
	Archive,
	Lock,
	Binary,
	Font,
	Notebook,
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
	case ".toml", ".yaml", ".yml", ".ini", ".cfg", ".conf": return .Config
	case ".xml": return .Xml
	case ".sh", ".bash", ".zsh", ".fish": return .Shell
	case ".ps1", ".psm1", ".psd1", ".bat", ".cmd": return .PowerShell
	case ".c": return .CFamily
	case ".cpp", ".cc", ".cxx": return .CPlusPlus
	case ".h", ".hpp", ".hh": return .Header
	case ".zig": return .Zig
	case ".vim", ".nvim": return .Vim
	case ".cs": return .CSharp
	case ".go": return .Go
	case ".rb": return .Ruby
	case ".php": return .Php
	case ".java", ".jar": return .Java
	case ".kt", ".kts": return .Kotlin
	case ".swift": return .Swift
	case ".lua": return .Lua
	case ".sql", ".db", ".sqlite", ".sqlite3": return .Sql
	case ".csv", ".tsv": return .Data
	case ".txt": return .Text
	case ".log": return .Log
	case ".pdf": return .Pdf
	case ".svg": return .Svg
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".tiff": return .Image
	case ".mp3", ".wav", ".flac", ".ogg": return .Audio
	case ".mp4", ".mkv", ".avi", ".mov", ".webm": return .Video
	case ".zip", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".7z", ".rar": return .Archive
	case ".lock": return .Lock
	case ".exe", ".dll", ".so", ".dylib", ".a", ".o", ".bin", ".wasm": return .Binary
	case ".ttf", ".otf", ".woff", ".woff2": return .Font
	case ".ipynb": return .Notebook
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

material_icon :: proc(kind: Icon_Kind) -> Icon {
	#partial switch kind {
	case .Dir: return Icon{glyph = "\uf07b", r = 0x90, g = 0xa4, b = 0xae, colored = true}
	case .Dir_Open: return Icon{glyph = "\uf07c", r = 0x90, g = 0xa4, b = 0xae, colored = true}
	case .Rust: return Icon{glyph = "\ue7a8", r = 0xde, g = 0xa5, b = 0x84, colored = true}
	case .Odin: return Icon{glyph = "\uf0e3", r = 0x70, g = 0x9b, b = 0xe7, colored = true}
	case .Python: return Icon{glyph = "\ue73c", r = 0xff, g = 0xbc, b = 0x03, colored = true}
	case .JavaScript: return Icon{glyph = "\ue74e", r = 0xcb, g = 0xcb, b = 0x41, colored = true}
	case .TypeScript: return Icon{glyph = "\ue628", r = 0x51, g = 0x9a, b = 0xba, colored = true}
	case .React: return Icon{glyph = "\ue7ba", r = 0x20, g = 0xc2, b = 0xe3, colored = true}
	case .Json: return Icon{glyph = "\ue60b", r = 0xcb, g = 0xcb, b = 0x41, colored = true}
	case .Markdown: return Icon{glyph = "\uf48a", r = 0xdd, g = 0xdd, b = 0xdd, colored = true}
	case .Html: return Icon{glyph = "\ue736", r = 0xe4, g = 0x4d, b = 0x26, colored = true}
	case .Css: return Icon{glyph = "\ue749", r = 0x66, g = 0x33, b = 0x99, colored = true}
	case .Config: return Icon{glyph = "\ue615", r = 0x6d, g = 0x80, b = 0x86, colored = true}
	case .Xml: return Icon{glyph = "\uf121", r = 0xe3, g = 0x79, b = 0x33, colored = true}
	case .Shell: return Icon{glyph = "\uf489", r = 0x89, g = 0xe0, b = 0x51, colored = true}
	case .PowerShell: return Icon{glyph = "\U000f0a0a", r = 0x53, g = 0x91, b = 0xfe, colored = true}
	case .CFamily: return Icon{glyph = "\ue61e", r = 0x59, g = 0x9e, b = 0xff, colored = true}
	case .CPlusPlus: return Icon{glyph = "\ue61d", r = 0x51, g = 0x9a, b = 0xba, colored = true}
	case .Header: return Icon{glyph = "\uf0fd", r = 0xa0, g = 0x74, b = 0xc4, colored = true}
	case .Zig: return Icon{glyph = "\ue6a9", r = 0xf6, g = 0x9a, b = 0x1b, colored = true}
	case .Vim: return Icon{glyph = "\ue62b", r = 0x01, g = 0x98, b = 0x33, colored = true}
	case .Svg: return Icon{glyph = "\uf1c5", r = 0xff, g = 0xb1, b = 0x3b, colored = true}
	case .CSharp: return Icon{glyph = "\U000f031b", r = 0x17, g = 0x86, b = 0x00, colored = true}
	case .Go: return Icon{glyph = "\ue627", r = 0x00, g = 0xad, b = 0xd8, colored = true}
	case .Ruby: return Icon{glyph = "\ue791", r = 0x70, g = 0x15, b = 0x16, colored = true}
	case .Php: return Icon{glyph = "\ue73d", r = 0x4f, g = 0x5d, b = 0x95, colored = true}
	case .Java: return Icon{glyph = "\ue738", r = 0xb0, g = 0x72, b = 0x19, colored = true}
	case .Kotlin: return Icon{glyph = "\ue634", r = 0xa9, g = 0x7b, b = 0xff, colored = true}
	case .Swift: return Icon{glyph = "\ue755", r = 0xf0, g = 0x51, b = 0x38, colored = true}
	case .Lua: return Icon{glyph = "\ue620", r = 0x00, g = 0xa2, b = 0xff, colored = true}
	case .Sql: return Icon{glyph = "\ue706", r = 0xf2, g = 0x91, b = 0x11, colored = true}
	case .Data: return Icon{glyph = "\uf1c3", r = 0x33, g = 0xa8, b = 0x52, colored = true}
	case .Text: return Icon{glyph = "\uf15c", r = 0x89, g = 0xe0, b = 0x51, colored = true}
	case .Log: return Icon{glyph = "\uf15c", r = 0x75, g = 0x75, b = 0x75, colored = true}
	case .Pdf: return Icon{glyph = "\uf1c1", r = 0xb3, g = 0x0b, b = 0x00, colored = true}
	case .Image: return Icon{glyph = "\uf1c5", r = 0xa0, g = 0x74, b = 0xc4, colored = true}
	case .Audio: return Icon{glyph = "\uf1c7", r = 0xec, g = 0x40, b = 0x7a, colored = true}
	case .Video: return Icon{glyph = "\uf1c8", r = 0xff, g = 0x70, b = 0x43, colored = true}
	case .Archive: return Icon{glyph = "\uf1c6", r = 0xaf, g = 0xb4, b = 0x2b, colored = true}
	case .Git: return Icon{glyph = "\ue702", r = 0xf5, g = 0x4d, b = 0x27, colored = true}
	case .Docker: return Icon{glyph = "\uf308", r = 0x0d, g = 0xb7, b = 0xed, colored = true}
	case .Lock: return Icon{glyph = "\uf023", r = 0xff, g = 0xd5, b = 0x4f, colored = true}
	case .Binary: return Icon{glyph = "\uf471", r = 0xef, g = 0x53, b = 0x50, colored = true}
	case .Font: return Icon{glyph = "\uf031", r = 0xb0, g = 0xbe, b = 0xc5, colored = true}
	case .Notebook: return Icon{glyph = "\uf02d", r = 0xf5, g = 0x7c, b = 0x00, colored = true}
	case .Build: return Icon{glyph = "\uf0ad", r = 0x6d, g = 0x80, b = 0x86, colored = true}
	case .Package: return Icon{glyph = "\uf487", r = 0x8d, g = 0x6e, b = 0x63, colored = true}
	case .Readme: return Icon{glyph = "\uf02d", r = 0x42, g = 0xa5, b = 0xf5, colored = true}
	case .License: return Icon{glyph = "\uf24e", r = 0xff, g = 0xd5, b = 0x4f, colored = true}
	case .Env_Key: return Icon{glyph = "\uf084", r = 0xff, g = 0xd5, b = 0x4f, colored = true}
	case .File: return Icon{glyph = "\uf15b", r = 0x90, g = 0xa4, b = 0xae, colored = true}
	}
	return Icon{glyph = "\uf15b", r = 0x90, g = 0xa4, b = 0xae, colored = true}
}

// Icons are always the Nerd Font set; there is no second theme to choose from.
file_icon :: proc(name: string, is_dir, expanded: bool) -> Icon {
	return material_icon(icon_kind(name, is_dir, expanded))
}
