import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'screen_share_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 关键:禁用硬件语音处理旁路,强制采集音频走软件处理链。
  // 屏幕内音注入(flutter_webrtc 的 capturePostProcessing)挂在软件链上;
  // 若硬件 AEC 生效,采集音频会绕过软件链,屏幕内音注入将完全失效。
  try {
    await WebRTC.initialize(
        options: {'bypassVoiceProcessing': true});
  } catch (_) {}
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '屏幕共享',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
      ),
      home: const ScreenSharePage(),
    );
  }
}
