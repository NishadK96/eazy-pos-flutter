import 'dart:io';

import 'package:flutter/foundation.dart';

bool get checkoutTimingEnabled => Platform.isWindows;

void writeCheckoutTiming(String entry) {
  try {
    File(
      '${Directory.systemTemp.path}/eazy-pos-print-timing.log',
    ).writeAsStringSync('$entry\n', mode: FileMode.append);
  } on FileSystemException {
    debugPrint(entry);
  }
}
