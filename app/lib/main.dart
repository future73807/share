import 'package:flutter/material.dart';
import 'screen_share_page.dart';
import 'package:flutter/services.dart';

// 顶层定义 platform 变量
const platform = MethodChannel('screen_share_channel');

// 顶层定义权限请求方法
Future<void> _requestPermissions() async {
  await platform.invokeMethod('requestForegroundServicePermission');
  await platform.invokeMethod('requestCaptureVideoOutputPermission');
  await platform.invokeMethod('requestProjectMediaPermission');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _requestPermissions();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '屏幕共享',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ScreenSharePage(),
    );
  }
}
