class PubVersion {
  final String name; // 1.2.3
  final int build; // +45
  const PubVersion(this.name, this.build);

  @override
  String toString() => '$name+$build';
}

final _versionRe =
    RegExp(r'^version:\s*([0-9A-Za-z.\-]+)(?:\+(\d+))?[ \t]*$', multiLine: true);

PubVersion? readVersion(String pubspec) {
  final m = _versionRe.firstMatch(pubspec);
  if (m == null) return null;
  return PubVersion(m.group(1)!, int.tryParse(m.group(2) ?? '') ?? 0);
}

String writeVersion(String pubspec, PubVersion v) =>
    pubspec.replaceFirst(_versionRe, 'version: ${v.name}+${v.build}');
