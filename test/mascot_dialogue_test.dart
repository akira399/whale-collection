import 'dart:math';

import 'package:ai_tool_collection/mascot_dialogue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each mascot conversation avoids immediately repeating the line', () {
    final random = Random(184);
    for (final lines in [mascotChatter, mascotFeeding, mascotJokes]) {
      var previous = lines.first;
      for (var i = 0; i < 30; i++) {
        final next = chooseMascotLine(lines, previous, random);
        expect(lines, contains(next));
        expect(next, isNot(previous));
        previous = next;
      }
    }
  });
}
