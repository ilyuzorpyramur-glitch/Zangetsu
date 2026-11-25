import 'dart:io';

import 'package:hive/hive.dart';

/// Debug helper: dumps a Hive box copied off a device.
/// usage: flutter pub run tool/hive_dump.dart <dir> <boxName>
Future<void> main(List<String> args) async {
  Hive.init(args[0]);
  final box = await Hive.openBox(args[1]);
  var empty = 0;
  final empties = <String>[];
  for (final k in box.keys) {
    final v = box.get(k);
    if (v is String && v.isEmpty) {
      empty++;
      if (empties.length < 20) empties.add('$k');
    }
  }
  print('keys=${box.length} empty=$empty');
  for (final k in empties) {
    print('EMPTY: $k');
  }
  for (final k in box.keys.take(10)) {
    print('$k => ${box.get(k)}');
  }
  exit(0);
}
