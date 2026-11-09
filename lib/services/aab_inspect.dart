import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Satu entri di dalam file ZIP (AAB / IPA juga ZIP).
class ZipEntry {
  ZipEntry(this.name, this.method, this.compSize, this.size, this.localOffset);
  final String name;
  final int method; // 0 = stored, 8 = deflate
  final int compSize;
  final int size;
  final int localOffset;
}

/// Baca daftar entri dari central directory ZIP.
Future<List<ZipEntry>> readZipEntries(RandomAccessFile raf) async {
  final len = await raf.length();
  final tailLen = len < 66000 ? len : 66000;
  await raf.setPosition(len - tailLen);
  final tail = await raf.read(tailLen);
  var eocd = -1;
  for (var i = tail.length - 22; i >= 0; i--) {
    if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return [];
  final bd = ByteData.sublistView(tail);
  final count = bd.getUint16(eocd + 10, Endian.little);
  final cdSize = bd.getUint32(eocd + 12, Endian.little);
  final cdOffset = bd.getUint32(eocd + 16, Endian.little);
  await raf.setPosition(cdOffset);
  final cd = await raf.read(cdSize);
  final c = ByteData.sublistView(cd);
  final out = <ZipEntry>[];
  var o = 0;
  for (var n = 0; n < count && o + 46 <= cd.length; n++) {
    if (c.getUint32(o, Endian.little) != 0x02014b50) break;
    final method = c.getUint16(o + 10, Endian.little);
    final comp = c.getUint32(o + 20, Endian.little);
    final size = c.getUint32(o + 24, Endian.little);
    final nameLen = c.getUint16(o + 28, Endian.little);
    final extraLen = c.getUint16(o + 30, Endian.little);
    final commentLen = c.getUint16(o + 32, Endian.little);
    final local = c.getUint32(o + 42, Endian.little);
    final name = utf8.decode(cd.sublist(o + 46, o + 46 + nameLen), allowMalformed: true);
    out.add(ZipEntry(name, method, comp, size, local));
    o += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

/// Ambil isi satu entri ZIP (sudah didekompres).
Future<Uint8List?> readZipData(RandomAccessFile raf, ZipEntry e) async {
  await raf.setPosition(e.localOffset);
  final h = await raf.read(30);
  if (h.length < 30) return null;
  final bd = ByteData.sublistView(h);
  if (bd.getUint32(0, Endian.little) != 0x04034b50) return null;
  final nameLen = bd.getUint16(26, Endian.little);
  final extraLen = bd.getUint16(28, Endian.little);
  await raf.setPosition(e.localOffset + 30 + nameLen + extraLen);
  final data = await raf.read(e.compSize);
  if (e.method == 0) return data;
  if (e.method == 8) return Uint8List.fromList(ZLibDecoder(raw: true).convert(data));
  return null;
}

enum SignState { upload, debug, unsigned, unknown }

class BinaryInfo {
  String kind = ''; // aab | ipa
  int size = 0;
  String packageName = '';
  String versionCode = '';
  String versionName = '';
  SignState sign = SignState.unknown;
  String signer = ''; // nama file tanda tangan di META-INF
  String bundleId = ''; // IPA: CFBundleIdentifier
  String error = '';
}

/// Baca beberapa nilai string dari Info.plist (XML atau binary "bplist00").
Map<String, String> readPlistStrings(Uint8List b, Set<String> keys) {
  final out = <String, String>{};
  if (b.length > 8 && latin1.decode(b.sublist(0, 8)) == 'bplist00') {
    try {
      final bd = ByteData.sublistView(b);
      final t = b.length - 32;
      final offSize = b[t + 6], refSize = b[t + 7];
      final numObj = bd.getUint64(t + 8);
      final top = bd.getUint64(t + 16);
      final tableOff = bd.getUint64(t + 24);
      int readN(int pos, int n) {
        var v = 0;
        for (var i = 0; i < n; i++) {
          v = (v << 8) | b[pos + i];
        }
        return v;
      }

      int objOff(int ref) => readN(tableOff + ref * offSize, offSize);
      (int, int) lenAt(int pos) {
        final low = b[pos] & 0x0f;
        if (low != 0x0f) return (low, pos + 1);
        final intMarker = b[pos + 1];
        final n = 1 << (intMarker & 0x0f);
        return (readN(pos + 2, n), pos + 2 + n);
      }

      String? str(int ref) {
        final pos = objOff(ref);
        final type = b[pos] >> 4;
        final (len, start) = lenAt(pos);
        if (type == 0x5) return latin1.decode(b.sublist(start, start + len));
        if (type == 0x6) {
          final units = <int>[for (var i = 0; i < len; i++) (b[start + i * 2] << 8) | b[start + i * 2 + 1]];
          return String.fromCharCodes(units);
        }
        if (type == 0x1) return '${readN(pos + 1, 1 << (b[pos] & 0x0f))}';
        return null;
      }

      if (top >= numObj) return out;
      final dpos = objOff(top);
      if (b[dpos] >> 4 != 0xD) return out;
      final (count, start) = lenAt(dpos);
      for (var i = 0; i < count; i++) {
        final k = str(readN(start + i * refSize, refSize));
        if (k != null && keys.contains(k)) {
          final v = str(readN(start + (count + i) * refSize, refSize));
          if (v != null) out[k] = v;
        }
      }
    } catch (_) {}
    return out;
  }
  final xml = utf8.decode(b, allowMalformed: true);
  for (final k in keys) {
    final m = RegExp('<key>$k</key>\\s*<string>([^<]*)</string>').firstMatch(xml);
    if (m != null) out[k] = m.group(1)!;
  }
  return out;
}

/// Cari nilai atribut di AndroidManifest format proto (aapt2) di dalam AAB.
/// XmlAttribute: name = field 2 (0x12), value = field 3 (0x1a).
String _protoAttr(Uint8List b, String attr) {
  final key = [0x12, attr.length, ...latin1.encode(attr), 0x1a];
  outer:
  for (var i = 0; i + key.length + 1 < b.length; i++) {
    for (var k = 0; k < key.length; k++) {
      if (b[i + k] != key[k]) continue outer;
    }
    final lenPos = i + key.length;
    final len = b[lenPos];
    if (len == 0 || len > 120 || lenPos + 1 + len > b.length) continue;
    return latin1.decode(b.sublist(lenPos + 1, lenPos + 1 + len));
  }
  return '';
}

/// Periksa file AAB atau IPA tanpa tool tambahan.
Future<BinaryInfo> inspectBinary(File f) async {
  final info = BinaryInfo();
  final lower = f.path.toLowerCase();
  info.kind = lower.endsWith('.ipa') ? 'ipa' : 'aab';
  info.size = await f.length();
  final raf = await f.open();
  try {
    final entries = await readZipEntries(raf);
    if (entries.isEmpty) {
      info.error = 'not a valid ZIP/AAB/IPA file';
      return info;
    }
    if (info.kind == 'ipa') {
      final plist = entries.where((e) => RegExp(r'^Payload/[^/]+\.app/Info\.plist$').hasMatch(e.name)).firstOrNull;
      if (plist == null) {
        info.error = 'Payload/*.app/Info.plist not found — is this really an .ipa?';
        return info;
      }
      final data = await readZipData(raf, plist);
      if (data != null) {
        final v = readPlistStrings(data, {'CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion'});
        info.bundleId = v['CFBundleIdentifier'] ?? '';
        info.versionName = v['CFBundleShortVersionString'] ?? '';
        info.versionCode = v['CFBundleVersion'] ?? '';
      }
      return info;
    }

    final manifest = entries.where((e) => e.name == 'base/manifest/AndroidManifest.xml').firstOrNull;
    if (manifest == null) {
      info.error = 'base/manifest/AndroidManifest.xml not found — is this really an .aab?';
    } else {
      final data = await readZipData(raf, manifest);
      if (data != null) {
        info.packageName = _protoAttr(data, 'package');
        info.versionCode = _protoAttr(data, 'versionCode');
        info.versionName = _protoAttr(data, 'versionName');
      }
    }

    // Tanda tangan JAR: nama file = alias (huruf besar, maks 8 karakter).
    // Debug key Android memakai alias "androiddebugkey" → ANDROIDD.RSA
    final sigs = entries
        .map((e) => e.name)
        .where((n) => n.startsWith('META-INF/') && RegExp(r'\.(RSA|DSA|EC)$', caseSensitive: false).hasMatch(n))
        .toList();
    if (sigs.isEmpty) {
      info.sign = SignState.unsigned;
    } else if (sigs.any((n) => n.toUpperCase().contains('ANDROIDD'))) {
      info.sign = SignState.debug;
      info.signer = sigs.first;
    } else {
      info.sign = SignState.upload;
      info.signer = sigs.first;
    }
    return info;
  } catch (e) {
    info.error = '$e';
    return info;
  } finally {
    await raf.close();
  }
}
