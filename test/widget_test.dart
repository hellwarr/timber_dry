import 'package:flutter_test/flutter_test.dart';
import 'package:timber_dry/main.dart';

void main() {
  testWidgets('TimberDryApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const TimberDryApp());
    expect(find.text('TimberDry Pro'), findsWidgets);
  });
}
