import 'package:eazy_pos/features/printers/application/android_bluetooth_printer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('packs black dots into ESC/POS raster bytes', () {
    final image = img.Image(width: 8, height: 1);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    image.setPixelRgb(0, 0, 0, 0, 0);
    image.setPixelRgb(7, 0, 0, 0, 0);

    expect(AndroidBluetoothPrinter.rasterCommands(image), [
      0x1d,
      0x76,
      0x30,
      0x00,
      1,
      0,
      1,
      0,
      0x81,
    ]);
  });

  test('splits long receipts into bounded raster blocks', () {
    final image = img.Image(width: 8, height: 129);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    final bytes = AndroidBluetoothPrinter.rasterCommands(image);

    expect(bytes.length, 128 + 8 + 1 + 8);
    expect(bytes.sublist(0, 8), [0x1d, 0x76, 0x30, 0, 1, 0, 128, 0]);
    expect(bytes.sublist(136, 144), [0x1d, 0x76, 0x30, 0, 1, 0, 1, 0]);
  });

  test('removes trailing PDF whitespace and keeps a receipt margin', () {
    final image = img.Image(width: 80, height: 300);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    image.setPixelRgb(10, 99, 0, 0, 0);

    final cropped = AndroidBluetoothPrinter.trimTrailingWhitespace(image);

    expect(cropped.width, 80);
    expect(cropped.height, 132);
    expect(cropped.getPixel(10, 99).luminanceNormalized, 0);
  });

  test('does not crop an entirely blank or already full page', () {
    final blank = img.Image(width: 8, height: 20);
    img.fill(blank, color: img.ColorRgb8(255, 255, 255));
    expect(AndroidBluetoothPrinter.trimTrailingWhitespace(blank).height, 20);

    blank.setPixelRgb(0, 19, 0, 0, 0);
    expect(AndroidBluetoothPrinter.trimTrailingWhitespace(blank).height, 20);
  });

  test('strengthens anti-aliased receipt edges into solid thermal dots', () {
    final image = img.Image(width: 4, height: 1, numChannels: 4);
    image.setPixelRgba(0, 0, 0, 0, 0, 0);
    image.setPixelRgba(1, 0, 25, 25, 25, 255);
    image.setPixelRgba(2, 0, 180, 180, 180, 255);
    image.setPixelRgba(3, 0, 235, 235, 235, 255);

    final output = AndroidBluetoothPrinter.strengthenThermalBitmap(image);

    expect(output.getPixel(0, 0).r, 255);
    expect(output.getPixel(1, 0).r, 0);
    expect(output.getPixel(2, 0).r, 0);
    expect(output.getPixel(3, 0).r, 255);
    expect(output.getPixel(2, 0).a, 255);
  });

  test('removes blank side margins without shrinking receipt content', () {
    final image = img.Image(width: 640, height: 3);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    image.setPixelRgb(50, 1, 0, 0, 0);
    image.setPixelRgb(549, 1, 0, 0, 0);

    final output = AndroidBluetoothPrinter.fitToThermalCanvas(image, 576);
    final inkColumns = <int>[
      for (var x = 0; x < output.width; x++)
        if (output.getPixel(x, 1).luminanceNormalized < 0.5) x,
    ];

    expect(output.width, 576);
    expect(inkColumns, hasLength(2));
    expect(
      inkColumns.last - inkColumns.first,
      499,
      reason: 'native 203-DPI text spacing must not be rescaled',
    );
    expect(inkColumns.first + inkColumns.last, 575);
  });

  test('scales only genuinely over-wide receipt content', () {
    final image = img.Image(width: 640, height: 1);
    img.fill(image, color: img.ColorRgb8(0, 0, 0));

    final output = AndroidBluetoothPrinter.fitToThermalCanvas(image, 576);

    expect(output.width, 576);
    expect(output.height, 1);
    expect(output.getPixel(0, 0).luminanceNormalized, 0);
    expect(output.getPixel(575, 0).luminanceNormalized, 0);
  });
}
