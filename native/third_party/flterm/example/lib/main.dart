import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'demo_page.dart';
import 'themes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    await initializeForWeb(
      Uri.parse('assets/assets/libghostty-wasm32-freestanding.wasm'),
    );
  }
  runApp(const _App());
}

class _App extends StatefulWidget {
  const _App();

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  var _themeIndex = 0;

  @override
  Widget build(BuildContext context) {
    final entry = TerminalThemes.all[_themeIndex];
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: entry.theme.background,
        body: SafeArea(child: DemoPage(theme: entry.theme)),
        floatingActionButton: Builder(
          builder: (innerContext) => FloatingActionButton(
            onPressed: () => _showThemePicker(innerContext),
            tooltip: 'Theme',
            backgroundColor: Colors.black54,
            foregroundColor: Colors.white,
            child: const Icon(Icons.palette),
          ),
        ),
      ),
    );
  }

  Future<void> _showThemePicker(BuildContext context) {
    final isLarge = MediaQuery.of(context).size.width >= 600;
    if (isLarge) {
      return showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360, maxHeight: 480),
            child: _ThemeList(
              currentIndex: _themeIndex,
              onSelect: (i) {
                setState(() => _themeIndex = i);
                Navigator.of(dialogContext).pop();
              },
            ),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: _ThemeList(
          currentIndex: _themeIndex,
          onSelect: (i) {
            setState(() => _themeIndex = i);
            Navigator.of(sheetContext).pop();
          },
        ),
      ),
    );
  }
}

class _ThemeList extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onSelect;

  const _ThemeList({required this.currentIndex, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      itemCount: TerminalThemes.all.length,
      itemBuilder: (_, i) {
        final entry = TerminalThemes.all[i];
        return ListTile(
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: entry.theme.background,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: entry.theme.foreground),
            ),
          ),
          title: Text(entry.name),
          selected: i == currentIndex,
          onTap: () => onSelect(i),
        );
      },
    );
  }
}
