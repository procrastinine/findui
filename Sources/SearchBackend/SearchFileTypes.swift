import Foundation

/// Shared by the native type menu and Python's typed-copy normalization.
/// Canonical SearchState always store the expanded extensions;
/// literal pasted CLI extensions never pass through natural-language aliases.
package enum SearchFileTypes {
    package struct Group: Decodable, Identifiable, Sendable {
        package let id: String
        package let title: String
        package let aliases: [String]
        package let extensions: [String]
        package let category: String?
        package init(id: String, title: String, aliases: [String], extensions: [String], category: String? = nil) {
            self.id = id
            self.title = title
            self.aliases = aliases
            self.extensions = extensions
            self.category = category
        }

    }

    /// A leading dot denotes a suffix. A trailing dot is part of the filename
    /// and must not silently change a search for `.py.` into one for `.py`.
    package static func literalSuffix<S: StringProtocol>(_ value: S) -> String {
        String(value.drop(while: { $0 == "." }))
    }

    package static func selectedExtensions(_ value: String) throws -> [String] {
        if let group = groups.first(where: { $0.aliases.contains(value.lowercased()) }) { return group.extensions }
        let literal = literalSuffix(value).lowercased()
        guard !literal.isEmpty, !literal.contains(where: { $0.isWhitespace || "*?[]{}/\\,;\0".contains($0) }) else {
            throw SearchServiceError.commandFailed("Use a file type or a literal extension.")
        }
        return [literal]
    }

    // Embedded JSON keeps the standalone Swift audits and packaged app aligned
    // without a second resource loader.
    package static let specification = #"""
    [
      {"id":"pdf","title":"PDF","category":"Formats","aliases":["pdf","pdfs"],"extensions":["pdf"]},
      {"id":"png","title":"PNG","category":"Formats","aliases":["png","pngs"],"extensions":["png"]},
      {"id":"jpeg","title":"JPEG","category":"Formats","aliases":["jpeg","jpegs"],"extensions":["jpeg","jpg"]},
      {"id":"jpg","title":"JPG","category":"Formats","aliases":["jpg","jpgs"],"extensions":["jpg"]},
      {"id":"gif","title":"GIF","category":"Formats","aliases":["gif","gifs"],"extensions":["gif"]},
      {"id":"svg","title":"SVG","category":"Formats","aliases":["svg","svgs"],"extensions":["svg"]},
      {"id":"zip","title":"ZIP","category":"Formats","aliases":["zip","zips"],"extensions":["zip"]},
      {"id":"csv","title":"CSV","category":"Formats","aliases":["csv","csvs"],"extensions":["csv"]},
      {"id":"markdown","title":"Markdown","category":"Formats","aliases":["markdown"],"extensions":["md","markdown"]},
      {"id":"mp3","title":"MP3","category":"Formats","aliases":["mp3","mp3s"],"extensions":["mp3"]},
      {"id":"mp4","title":"MP4","category":"Formats","aliases":["mp4","mp4s"],"extensions":["mp4"]},
      {
        "id": "powerpoint",
        "title": "PowerPoint",
        "aliases": [
          "powerpoint"
        ],
        "extensions": [
          "ppt",
          "pptx"
        ]
      },
      {
        "id": "word",
        "title": "Word",
        "aliases": [
          "word"
        ],
        "extensions": [
          "doc",
          "docx"
        ]
      },
      {
        "id": "excel",
        "title": "Excel",
        "aliases": [
          "excel"
        ],
        "extensions": [
          "xls",
          "xlsx"
        ]
      },
      {
        "id": "presentation",
        "title": "Presentations",
        "aliases": [
          "presentation",
          "presentations",
          "slide",
          "slides",
          "slideshow",
          "slideshows"
        ],
        "extensions": [
          "key",
          "odp",
          "ppt",
          "pptx"
        ]
      },
      {
        "id": "spreadsheet",
        "title": "Spreadsheets",
        "aliases": [
          "spreadsheet",
          "spreadsheets"
        ],
        "extensions": [
          "csv",
          "numbers",
          "ods",
          "tsv",
          "xls",
          "xlsx"
        ]
      },
      {
        "id": "document",
        "title": "Documents",
        "aliases": [
          "document",
          "documents"
        ],
        "extensions": [
          "doc",
          "docx",
          "odt",
          "pages",
          "pdf",
          "rtf",
          "txt"
        ]
      },
      {
        "id": "image",
        "title": "Images",
        "aliases": [
          "image",
          "images",
          "photo",
          "photos",
          "picture",
          "pictures"
        ],
        "extensions": [
          "apng",
          "arw",
          "avif",
          "bmp",
          "cr2",
          "cr3",
          "dng",
          "gif",
          "heic",
          "heif",
          "ico",
          "jfif",
          "jpeg",
          "jpg",
          "nef",
          "orf",
          "png",
          "raf",
          "rw2",
          "svg",
          "tif",
          "tiff",
          "webp"
        ]
      },
      {
        "id": "audio",
        "title": "Audio",
        "aliases": [
          "audio",
          "music"
        ],
        "extensions": [
          "aac",
          "aif",
          "aiff",
          "alac",
          "flac",
          "m4a",
          "mp3",
          "ogg",
          "opus",
          "wav"
        ]
      },
      {
        "id": "video",
        "title": "Video",
        "aliases": [
          "video",
          "videos",
          "movie",
          "movies"
        ],
        "extensions": [
          "avi",
          "m4v",
          "mkv",
          "mov",
          "mp4",
          "mpeg",
          "mpg",
          "webm"
        ]
      },
      {
        "id": "archive",
        "title": "Archives",
        "aliases": [
          "archive",
          "archives",
          "compressed"
        ],
        "extensions": [
          "7z",
          "bz2",
          "gz",
          "rar",
          "tar",
          "tbz2",
          "tgz",
          "txz",
          "xz",
          "zip",
          "zst"
        ]
      },
      {
        "id": "font",
        "title": "Fonts",
        "aliases": [
          "font",
          "fonts"
        ],
        "extensions": [
          "otf",
          "ttc",
          "ttf",
          "woff",
          "woff2"
        ]
      },
      {
        "id": "ebook",
        "title": "Ebooks",
        "aliases": [
          "ebook",
          "ebooks"
        ],
        "extensions": [
          "azw",
          "azw3",
          "epub",
          "mobi",
          "pdf"
        ]
      },
      {
        "id": "sourcecode",
        "title": "Source code",
        "aliases": [
          "code",
          "sourcecode"
        ],
        "extensions": [
          "c",
          "cc",
          "cpp",
          "cs",
          "cxx",
          "go",
          "h",
          "hpp",
          "java",
          "js",
          "jsx",
          "kt",
          "kts",
          "m",
          "mm",
          "php",
          "pl",
          "py",
          "r",
          "rb",
          "rs",
          "scala",
          "sh",
          "sql",
          "swift",
          "ts",
          "tsx",
          "vue"
        ]
      },
      {
        "id": "script",
        "title": "Scripts",
        "aliases": [
          "script",
          "scripts"
        ],
        "extensions": [
          "applescript",
          "bash",
          "fish",
          "js",
          "lua",
          "pl",
          "ps1",
          "py",
          "rb",
          "sh",
          "zsh"
        ]
      },
      {
        "id": "notebook",
        "title": "Jupyter notebooks",
        "aliases": [
          "notebook",
          "notebooks",
          "jupyter"
        ],
        "extensions": [
          "ipynb"
        ]
      },
      {
        "id": "database",
        "title": "Databases",
        "aliases": [
          "database",
          "databases"
        ],
        "extensions": [
          "accdb",
          "db",
          "duckdb",
          "mdb",
          "sqlite",
          "sqlite3"
        ]
      },
      {
        "id": "installer",
        "title": "Installers",
        "aliases": [
          "installer",
          "installers"
        ],
        "extensions": [
          "apk",
          "appx",
          "deb",
          "dmg",
          "mpkg",
          "msi",
          "msix",
          "pkg",
          "rpm"
        ]
      },
      {
        "id": "language-c",
        "title": "C",
        "category": "language",
        "aliases": [
          "c"
        ],
        "extensions": [
          "c"
        ]
      },
      {
        "id": "language-c-plus-plus",
        "title": "C++",
        "category": "language",
        "aliases": [
          "c++"
        ],
        "extensions": [
          "c++",
          "cc",
          "cpp",
          "cppm",
          "cxx",
          "hh",
          "hpp",
          "hxx"
        ]
      },
      {
        "id": "language-c-sharp",
        "title": "C#",
        "category": "language",
        "aliases": [
          "c#",
          "csharp"
        ],
        "extensions": [
          "cs",
          "csx"
        ]
      },
      {
        "id": "language-dart",
        "title": "Dart",
        "category": "language",
        "aliases": [
          "dart"
        ],
        "extensions": [
          "dart"
        ]
      },
      {
        "id": "language-go",
        "title": "Go",
        "category": "language",
        "aliases": [
          "go",
          "golang"
        ],
        "extensions": [
          "go"
        ]
      },
      {
        "id": "language-java",
        "title": "Java",
        "category": "language",
        "aliases": [
          "java"
        ],
        "extensions": [
          "java"
        ]
      },
      {
        "id": "language-javascript",
        "title": "JavaScript",
        "category": "language",
        "aliases": [
          "javascript"
        ],
        "extensions": [
          "cjs",
          "js",
          "jsx",
          "mjs"
        ]
      },
      {
        "id": "language-julia",
        "title": "Julia",
        "category": "language",
        "aliases": [
          "julia"
        ],
        "extensions": [
          "jl"
        ]
      },
      {
        "id": "language-kotlin",
        "title": "Kotlin",
        "category": "language",
        "aliases": [
          "kotlin"
        ],
        "extensions": [
          "kt",
          "kts"
        ]
      },
      {
        "id": "language-lua",
        "title": "Lua",
        "category": "language",
        "aliases": [
          "lua"
        ],
        "extensions": [
          "lua"
        ]
      },
      {
        "id": "language-objective-c",
        "title": "Objective-C",
        "category": "language",
        "aliases": [
          "objc",
          "objective-c",
          "objectivec"
        ],
        "extensions": [
          "m"
        ]
      },
      {
        "id": "language-perl",
        "title": "Perl",
        "category": "language",
        "aliases": [
          "perl"
        ],
        "extensions": [
          "perl",
          "pl",
          "pm"
        ]
      },
      {
        "id": "language-php",
        "title": "PHP",
        "category": "language",
        "aliases": [
          "php"
        ],
        "extensions": [
          "php"
        ]
      },
      {
        "id": "language-powershell",
        "title": "PowerShell",
        "category": "language",
        "aliases": [
          "powershell",
          "pwsh"
        ],
        "extensions": [
          "ps1",
          "psd1",
          "psm1"
        ]
      },
      {
        "id": "language-python",
        "title": "Python",
        "category": "language",
        "aliases": [
          "python",
          "python3"
        ],
        "extensions": [
          "py",
          "py3",
          "pyi",
          "pyw"
        ]
      },
      {
        "id": "language-r",
        "title": "R",
        "category": "language",
        "aliases": [
          "r"
        ],
        "extensions": [
          "r"
        ]
      },
      {
        "id": "language-ruby",
        "title": "Ruby",
        "category": "language",
        "aliases": [
          "ruby"
        ],
        "extensions": [
          "rb",
          "rbi",
          "rbw"
        ]
      },
      {
        "id": "language-rust",
        "title": "Rust",
        "category": "language",
        "aliases": [
          "rust"
        ],
        "extensions": [
          "rs",
          "rs.in"
        ]
      },
      {
        "id": "language-scala",
        "title": "Scala",
        "category": "language",
        "aliases": [
          "scala"
        ],
        "extensions": [
          "sbt",
          "sc",
          "scala"
        ]
      },
      {
        "id": "language-shell",
        "title": "Shell",
        "category": "language",
        "aliases": [
          "shell",
          "shell-script"
        ],
        "extensions": [
          "bash",
          "command",
          "ksh",
          "sh",
          "zsh"
        ]
      },
      {
        "id": "language-sql",
        "title": "SQL",
        "category": "language",
        "aliases": [
          "sql"
        ],
        "extensions": [
          "sql"
        ]
      },
      {
        "id": "language-swift",
        "title": "Swift",
        "category": "language",
        "aliases": [
          "swift"
        ],
        "extensions": [
          "swift"
        ]
      },
      {
        "id": "language-typescript",
        "title": "TypeScript",
        "category": "language",
        "aliases": [
          "typescript"
        ],
        "extensions": [
          "cts",
          "mts",
          "ts",
          "tsx"
        ]
      },
      {
        "id": "photoshop",
        "title": "Photoshop",
        "aliases": ["photoshop"],
        "extensions": ["psb", "psd"]
      },
      {
        "id": "vector",
        "title": "Vector graphics",
        "aliases": ["vector", "vectors", "vector graphic", "vector graphics"],
        "extensions": ["ai", "eps", "pdf", "ps", "svg"]
      },
      {
        "id": "illustrator",
        "title": "Illustrator",
        "aliases": [
          "illustrator"
        ],
        "extensions": [
          "ai"
        ]
      },
      {
        "id": "postscript",
        "title": "PostScript",
        "aliases": [
          "postscript"
        ],
        "extensions": [
          "ps"
        ]
      }
    ]
    """#

    package static let groups = try! JSONDecoder().decode([Group].self, from: Data(specification.utf8))

    package static func adding(_ group: Group, to existing: String) -> String {
        let current = existing.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { literalSuffix($0).lowercased() }
        return Set(current + group.extensions).sorted().joined(separator: ", ")
    }
}
