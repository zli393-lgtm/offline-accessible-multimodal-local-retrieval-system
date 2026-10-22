import 'package:path/path.dart' as p;

class PureTextFileTypes {
  PureTextFileTypes._();

  static const Set<String> extensions = {
    // Plain text and line-oriented records.
    '.txt', '.text', '.log', '.csv', '.tsv', '.json', '.jsonl', '.ndjson',
    // Configuration and serialization formats whose stored content is text.
    '.xml', '.yaml', '.yml', '.toml', '.ini', '.cfg', '.conf', '.config',
    '.properties', '.env', '.editorconfig', '.gitignore', '.gitattributes',
    // Query and schema source.
    '.sql', '.graphql', '.gql', '.proto',
    // Programming and scripting languages.
    '.dart', '.py', '.pyw', '.js', '.mjs', '.cjs', '.ts', '.jsx', '.tsx',
    '.java', '.kt', '.kts', '.groovy', '.gradle', '.scala', '.sc',
    '.c', '.h', '.cc', '.cpp', '.cxx', '.hh', '.hpp', '.hxx', '.m', '.mm',
    '.cs', '.fs', '.fsx', '.vb', '.go', '.rs', '.swift',
    '.php', '.rb', '.r', '.lua', '.pl', '.pm', '.tcl',
    '.ex', '.exs', '.erl', '.hrl', '.clj', '.cljs', '.cljc', '.edn',
    // Shell, command and build source.
    '.sh', '.bash', '.zsh', '.fish', '.ps1', '.psm1', '.psd1', '.bat',
    '.cmd', '.vbs', '.cmake', '.mk',
    // Other text-only source formats.
    '.asm', '.s', '.vim', '.diff', '.patch',
  };

  static const Set<String> extensionlessFileNames = {
    'dockerfile',
    'makefile',
    'cmakelists.txt',
    'gemfile',
    'rakefile',
    'podfile',
    'procfile',
  };

  static bool supports(String filePath) {
    final name = p.basename(filePath).toLowerCase();
    return extensionlessFileNames.contains(name) ||
        extensions.contains(p.extension(name));
  }

  static String typeLabel(String filePath) {
    final name = p.basename(filePath).toLowerCase();
    if (extensionlessFileNames.contains(name)) {
      return name.toUpperCase();
    }
    final extension = p.extension(name);
    if (!extensions.contains(extension)) return 'UNSUPPORTED';
    return extension.substring(1).toUpperCase();
  }
}
