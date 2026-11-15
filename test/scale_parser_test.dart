import 'package:flutter_test/flutter_test.dart';
import 'package:wenxun/core/scale.dart';

void main() {
  group('ScaleParser.parseKg', () {
    test('常见连续输出报文', () {
      expect(ScaleParser.parseKg('ST,GS,+  1.235kg'), closeTo(1.235, 0.001));
      expect(ScaleParser.parseKg('US,GS,+  0.530kg'), closeTo(0.53, 0.001));
      expect(ScaleParser.parseKg('=  1.235 kg'), closeTo(1.235, 0.001));
      expect(ScaleParser.parseKg('0525 g'), closeTo(0.525, 0.001));
      expect(ScaleParser.parseKg('525g'), closeTo(0.525, 0.001));
      expect(ScaleParser.parseKg('12.5斤'), closeTo(6.25, 0.001));
    });

    test('空秤读数（自动检测必须能认到 0.000）', () {
      expect(ScaleParser.parseKg('0.000'), 0.0);
      expect(ScaleParser.parseKg('ST,GS,+  0.000kg'), 0.0);
    });

    test('拒绝仪表原始帧与乱码（含字母、无小数点、无单位）', () {
      expect(ScaleParser.parseKg('U11T1123452 03'), isNull);
      expect(ScaleParser.parseKg('abcdefgh'), isNull);
      expect(ScaleParser.parseKg('abc123def'), isNull);
    });
  });

  group('ScaleParser.stableOf', () {
    test('稳定位', () {
      expect(ScaleParser.stableOf('ST,GS,+  1.235kg'), isTrue);
      expect(ScaleParser.stableOf('US,GS,+  1.235kg'), isFalse);
      expect(ScaleParser.stableOf('=  1.235 kg'), isNull);
    });
  });

  group('ScaleBarcode', () {
    test('13 位条码秤标签', () {
      final b = ScaleBarcode.tryParse('2532410052573');
      expect(b, isNotNull);
      expect(b!.plu, '53241');
      expect(b.kg, closeTo(0.525, 0.0001));
    });
  });
}
