import 'dart:convert';

import 'package:flutter/services.dart';

/// Embeds the app font for HTML-to-PDF engines with no local font access.
Future<String> embedArabicPrintFont(String html) async {
  final fonts = await Future.wait([
    rootBundle.load('assets/fonts/NotoKufiArabic-Regular.ttf'),
    rootBundle.load('assets/fonts/NotoKufiArabic-Bold.ttf'),
  ]);
  final css = [
    for (final (index, font) in fonts.indexed)
      "@font-face{font-family:'Noto Kufi Arabic';"
          'font-weight:${index == 0 ? 400 : 700};'
          'src:url(data:font/ttf;base64,'
          "${base64Encode(font.buffer.asUint8List(font.offsetInBytes, font.lengthInBytes))}) format('truetype');}",
  ].join();
  return html.replaceFirst('</head>', '<style>$css</style></head>');
}
