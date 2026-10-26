import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:minireel/app/app_controller.dart';
import 'package:minireel/features/detail/detail_sheet.dart';
import 'package:minireel/features/library/library_screen.dart';
import 'package:minireel/features/player/player_screen.dart';
import 'package:minireel/features/shared/widgets.dart';
import 'package:minireel/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android app: library, player gestures, sheets, lock, lifecycle and history',
    (tester) async {
      await app.main();

      Future<void> until(bool Function() condition, String description) async {
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) fail('Timed out: $description');
          await tester.pump(const Duration(milliseconds: 200));
        }
      }

      await until(
        () => find.byType(DramaCard).evaluate().isNotEmpty,
        'catalog',
      );
      final controller = AppScope.read(
        tester.element(find.byType(LibraryScreen)),
      );
      final first = tester
          .widget<DramaCard>(find.byType(DramaCard).first)
          .drama;
      await tester.longPress(find.byType(DramaCard).first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('短剧详情'), findsOneWidget);
      await until(
        () => find.byType(EpisodeGrid).evaluate().isNotEmpty,
        'episode detail',
      );
      await tester.tap(find.byTooltip('关闭'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byType(DramaCard).first);
      await until(
        () => find.byType(PlayerScreen).evaluate().isNotEmpty,
        'player route',
      );
      await tester.pump(const Duration(milliseconds: 500));
      if (find
          .byKey(const ValueKey('dismiss-gesture-guide'))
          .evaluate()
          .isNotEmpty) {
        await tester.tap(find.byKey(const ValueKey('dismiss-gesture-guide')));
      }
      final player = tester.widget<Video>(find.byType(Video)).controller.player;
      await until(
        () => player.state.position > const Duration(seconds: 1),
        'video start',
      );

      final surface = find.byKey(const ValueKey('player-gesture-surface'));
      final bounds = tester.getRect(surface);
      final lower = Offset(bounds.center.dx, bounds.top + bounds.height * .73);
      final upper = Offset(bounds.center.dx, bounds.top + bounds.height * .24);

      final hold = await tester.startGesture(lower);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('2.0X 快进中'), findsOneWidget);
      expect(player.state.rate, 2);
      await hold.moveBy(const Offset(55, 0));
      await tester.pump(const Duration(milliseconds: 150));
      await hold.up();
      await tester.pump(const Duration(milliseconds: 600));
      expect(player.state.rate, controller.preferences.speed);

      // Opening a menu pauses without losing the viewer's intended play state.
      final menuHold = await tester.startGesture(upper);
      await tester.pump(const Duration(milliseconds: 450));
      await menuHold.up();
      await tester.pump(const Duration(milliseconds: 500));
      await until(() => !player.state.playing, 'menu pause');
      expect(find.text('选集'), findsOneWidget);
      if (!controller.isFavorite(first.id)) {
        await tester.tap(find.text('收藏'));
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(controller.isFavorite(first.id), true);
      await tester.tap(find.text('选集'));
      await tester.pump(const Duration(milliseconds: 500));
      final second = find.descendant(
        of: find.byType(EpisodeGrid),
        matching: find.text('2'),
      );
      await tester.tap(second);
      await tester.pump(const Duration(milliseconds: 500));
      await until(
        () =>
            player.state.playing &&
            player.state.position > const Duration(seconds: 1),
        'selected episode',
      );

      await tester.tap(find.byKey(const ValueKey('rail-handle')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byTooltip('锁定屏幕'));
      await tester.pump(const Duration(milliseconds: 200));
      final lockedHold = await tester.startGesture(lower);
      await tester.pump(const Duration(milliseconds: 500));
      await lockedHold.up();
      expect(find.text('2.0X 快进中'), findsNothing);
      expect(player.state.rate, controller.preferences.speed);
      expect(player.state.playing, true);
      await tester.tap(find.byKey(const ValueKey('player-unlock')));
      await tester.pump(const Duration(milliseconds: 200));

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await until(() => !player.state.playing, 'background pause');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await until(() => player.state.playing, 'foreground resume');

      // Returning to the library writes the progress before disposing the player.
      await binding.handlePopRoute();
      await until(
        () => find.byType(PlayerScreen).evaluate().isEmpty,
        'exit player',
      );
      await controller.flush();
      final history = await controller.store.readHistory();
      expect(
        history.any(
          (record) => record.drama.id == first.id && record.episodeIndex == 2,
        ),
        true,
      );

      // 菜单退出必须关闭播放路由，而不只是关闭底部菜单。
      await tester.tap(find.byType(DramaCard).first);
      await until(
        () => find.byType(PlayerScreen).evaluate().isNotEmpty,
        'reopen player',
      );
      await tester.tap(find.byKey(const ValueKey('player-menu')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('退出播放'));
      await until(
        () => find.byType(PlayerScreen).evaluate().isEmpty,
        'exit player from menu',
      );

      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('收藏'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
