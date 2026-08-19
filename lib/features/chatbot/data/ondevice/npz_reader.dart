import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Just enough of NumPy's `.npz` to read the phrase index.
///
/// The index is written by `tools/embed_corpus_onnx.py` with
/// `np.savez_compressed`, which is a ZIP of `.npy` members. Reading it directly
/// is what lets the on-device engine consume **the very file the server's
/// pipeline produced**, with no conversion step in between — and a conversion
/// step is exactly where a silent dtype or row-order mistake would hide.
///
/// Deliberately narrow: it reads the members this feature needs and refuses
/// anything else clearly. A general NumPy reader would be more code and more
/// ways to be subtly wrong about a case that never occurs here.
class NpzArchive {
  NpzArchive._(this._bytes, this._entries);

  final Uint8List _bytes;
  final Map<String, _ZipEntry> _entries;

  /// Member names, without the `.npy` suffix — the keys `np.savez` was given.
  Iterable<String> get names => _entries.keys.map(_stripNpy);

  static String _stripNpy(String name) =>
      name.endsWith('.npy') ? name.substring(0, name.length - 4) : name;

  /// Parse the ZIP directory. The member data itself is decompressed lazily, so
  /// opening the archive does not inflate 8MB of vectors to count them.
  static NpzArchive open(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);

    // Find the end-of-central-directory record by scanning back from the end.
    // `np.savez` writes no ZIP comment, so it is at the very end, but the scan
    // costs nothing and tolerates one.
    var eocd = -1;
    final lowest = bytes.length - 22 - 0xFFFF;
    for (var i = bytes.length - 22; i >= (lowest < 0 ? 0 : lowest); i--) {
      if (view.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('not a zip archive');

    final count = view.getUint16(eocd + 10, Endian.little);
    var offset = view.getUint32(eocd + 16, Endian.little);
    if (offset == 0xFFFFFFFF) {
      // Zip64 only appears past 4GB. The index is 8MB and the model files are
      // downloaded, not zipped, so this cannot happen — saying so beats
      // half-supporting it.
      throw const FormatException('zip64 archives are not supported');
    }

    final entries = <String, _ZipEntry>{};
    for (var i = 0; i < count; i++) {
      if (view.getUint32(offset, Endian.little) != 0x02014b50) {
        throw const FormatException('corrupt zip central directory');
      }
      final method = view.getUint16(offset + 10, Endian.little);
      final compressedSize = view.getUint32(offset + 20, Endian.little);
      final uncompressedSize = view.getUint32(offset + 24, Endian.little);
      final nameLength = view.getUint16(offset + 28, Endian.little);
      final extraLength = view.getUint16(offset + 30, Endian.little);
      final commentLength = view.getUint16(offset + 32, Endian.little);
      final localHeader = view.getUint32(offset + 42, Endian.little);
      final name = utf8.decode(
          Uint8List.sublistView(bytes, offset + 46, offset + 46 + nameLength));

      entries[name] = _ZipEntry(
        method: method,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localHeader,
      );
      offset += 46 + nameLength + extraLength + commentLength;
    }

    return NpzArchive._(bytes, entries);
  }

  /// The raw bytes of one member, inflated if it was deflated.
  Uint8List _member(String name) {
    final entry = _entries['$name.npy'] ?? _entries[name];
    if (entry == null) {
      throw FormatException('the index has no member named "$name"');
    }

    final view = ByteData.sublistView(_bytes);
    final header = entry.localHeaderOffset;
    if (view.getUint32(header, Endian.little) != 0x04034b50) {
      throw const FormatException('corrupt zip local header');
    }
    // The local header repeats the name and extra fields at their own lengths —
    // trusting the central directory's would land mid-data on some writers.
    final nameLength = view.getUint16(header + 26, Endian.little);
    final extraLength = view.getUint16(header + 28, Endian.little);
    final start = header + 30 + nameLength + extraLength;
    final raw =
        Uint8List.sublistView(_bytes, start, start + entry.compressedSize);

    return switch (entry.method) {
      0 => raw,
      // ZIP stores a bare deflate stream with no zlib wrapper, which is what
      // `raw: true` means here.
      8 => Uint8List.fromList(ZLibCodec(raw: true).decode(raw)),
      _ => throw FormatException(
          'the index uses zip compression method ${entry.method}'),
    };
  }

  /// A 2-D `float32` member, returned flat in row-major order with its shape.
  ///
  /// Flat on purpose: 5,275 × 384 as a list-of-lists is two million boxed
  /// doubles and a garbage-collection event every time it is scanned. One
  /// [Float32List] is 8MB of contiguous memory that a dot product can walk.
  NpyMatrix matrix(String name) {
    final (header, data) = _npy(_member(name));

    if (header.descr != '<f4') {
      throw FormatException(
          'the index vectors are ${header.descr}, expected little-endian float32');
    }
    if (header.fortranOrder) {
      throw const FormatException('the index is column-major, expected row-major');
    }
    if (header.shape.length != 2) {
      throw FormatException('the index is ${header.shape.length}-D, expected 2-D');
    }

    final rows = header.shape[0];
    final columns = header.shape[1];
    if (data.length != rows * columns * 4) {
      throw const FormatException('the index vector block is the wrong length');
    }

    // A copy, not a view: the ZIP member is not guaranteed 4-byte aligned, and
    // `Float32List.view` throws on an unaligned offset on some platforms.
    final values = Float32List(rows * columns);
    final view = ByteData.sublistView(data);
    for (var i = 0; i < values.length; i++) {
      values[i] = view.getFloat32(i * 4, Endian.little);
    }

    return NpyMatrix(values: values, rows: rows, columns: columns);
  }

  /// A 0-D unicode member (`np.array("text")`), as a string.
  ///
  /// NumPy stores these as UCS-4: a fixed number of little-endian code points,
  /// NUL-padded to the declared width.
  String? scalarString(String name) {
    final Uint8List raw;
    try {
      raw = _member(name);
    } on FormatException {
      return null;
    }

    final (header, data) = _npy(raw);
    if (!header.descr.startsWith('<U')) return null;

    final view = ByteData.sublistView(data);
    final buffer = StringBuffer();
    for (var i = 0; i + 4 <= data.length; i += 4) {
      final code = view.getUint32(i, Endian.little);
      if (code == 0) break;
      buffer.writeCharCode(code);
    }
    return buffer.toString();
  }

  /// Split a `.npy` member into its parsed header and its data block.
  static (_NpyHeader, Uint8List) _npy(Uint8List bytes) {
    const magic = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]; // \x93NUMPY
    if (bytes.length < 10) throw const FormatException('truncated .npy member');
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw const FormatException('not a .npy member');
      }
    }

    final major = bytes[6];
    final view = ByteData.sublistView(bytes);
    // v1 writes a 2-byte header length, v2 and later a 4-byte one.
    final headerLength = major == 1
        ? view.getUint16(8, Endian.little)
        : view.getUint32(8, Endian.little);
    final headerStart = major == 1 ? 10 : 12;

    final header = utf8.decode(Uint8List.sublistView(
        bytes, headerStart, headerStart + headerLength));

    return (
      _NpyHeader.parse(header),
      Uint8List.sublistView(bytes, headerStart + headerLength),
    );
  }
}

/// A flat row-major float32 matrix.
class NpyMatrix {
  const NpyMatrix({
    required this.values,
    required this.rows,
    required this.columns,
  });

  final Float32List values;
  final int rows;
  final int columns;
}

class _ZipEntry {
  const _ZipEntry({
    required this.method,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
}

/// The `.npy` header, which is a Python dict literal rendered as text.
///
/// Parsed with three regular expressions rather than a Python-literal parser:
/// NumPy writes this field in one fixed shape, and the three values it holds
/// are the only ones that change how the bytes behind it must be read.
class _NpyHeader {
  const _NpyHeader({
    required this.descr,
    required this.fortranOrder,
    required this.shape,
  });

  final String descr;
  final bool fortranOrder;
  final List<int> shape;

  static _NpyHeader parse(String header) {
    final descr = RegExp(r"'descr'\s*:\s*'([^']*)'").firstMatch(header);
    final fortran = RegExp(r"'fortran_order'\s*:\s*(True|False)").firstMatch(header);
    final shape = RegExp(r"'shape'\s*:\s*\(([^)]*)\)").firstMatch(header);
    if (descr == null || fortran == null || shape == null) {
      throw const FormatException('unreadable .npy header');
    }

    final dimensions = shape
        .group(1)!
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .map(int.parse)
        .toList(growable: false);

    return _NpyHeader(
      descr: descr.group(1)!,
      fortranOrder: fortran.group(1) == 'True',
      shape: dimensions,
    );
  }
}
