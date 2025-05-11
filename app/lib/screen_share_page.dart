import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:async';

class ScreenSharePage extends StatefulWidget {
  const ScreenSharePage({Key? key}) : super(key: key);

  @override
  _ScreenSharePageState createState() => _ScreenSharePageState();
}

class _ScreenSharePageState extends State<ScreenSharePage> {
  // 状态变量
  String roomId = '';
  String nickname = '';
  bool isInRoom = false;
  bool isSharing = false;
  bool isViewing = false;
  bool isMicOn = true;
  bool isFullScreen = false;
  List<Map<String, dynamic>> users = [];

  // WebRTC 相关变量
  IO.Socket? socket;
  MediaStream? localStream;
  Map<String, RTCPeerConnection> peerConnections = {};
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _isRendererInitialized = false;

  // 屏幕共享通道
  static const platform = MethodChannel('screen_share_channel');
  bool isScreenCapturePermissionGranted = false;

  Timer? _refreshTimer;

  Future<void> _requestPermissions() async {
    try {
      // 请求前台服务媒体投影权限
      await platform.invokeMethod('requestForegroundServicePermission');
      await platform.invokeMethod('requestCaptureVideoOutputPermission');
      await platform.invokeMethod('requestProjectMediaPermission');
      setState(() {
        isScreenCapturePermissionGranted = true;
      });
    } catch (e) {
      // 处理权限请求失败的情况
      print('权限请求失败: \$e');
      setState(() {
        isScreenCapturePermissionGranted = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    // 先请求必要权限
    _requestPermissions().then((_) {
      if (isScreenCapturePermissionGranted) {
        _initializeWebRTC().then((_) {
          initializeSocket();
          _loadSavedData();
          _setupScreenShareMethodChannel();
        });
      }
    });
    
    // 启动定时刷新
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (isInRoom && socket?.connected == true) {
        socket?.emit('get-room-users', {'roomId': roomId});
      }
    });
  }

  void _setupScreenShareMethodChannel() {
    platform.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onScreenCapturePermissionGranted':
          setState(() {
            isScreenCapturePermissionGranted = true;
          });
          // 在这里开始获取屏幕共享流
          final stream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
            'video': true,
            'audio': true
          });
          setState(() {
            localStream = stream;
            _localRenderer.srcObject = stream;
            isSharing = true;
          });
          break;
        case 'onScreenCapturePermissionDenied':
          setState(() {
            isScreenCapturePermissionGranted = false;
            isSharing = false;
          });
          break;
      }
    });
  }

  Future<void> _initializeWebRTC() async {
    try {
      await _localRenderer.initialize();
      setState(() => _isRendererInitialized = true);
    } catch (e) {
      debugPrint('RTCVideoRenderer初始化失败: $e');
    }
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      roomId = prefs.getString('roomId') ?? '';
      nickname = prefs.getString('nickname') ?? '';
    });
    if (roomId.isNotEmpty && nickname.isNotEmpty) {
      joinRoom();
    }
  }

  void initializeSocket() {
    // 构建请求头
    Map<String, dynamic> headers = {
      'origin': 'https://share-api-bak.future-you.top'
    };
    print("初始化socket");
    socket = IO.io(
      'https://share-api-bak.future-you.top',
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .setExtraHeaders(headers)
          .setQuery({
            'EIO': '4',
            'transport': 'polling'
          })
          .setReconnectionAttempts(5)
          .setReconnectionDelay(5000)
          .enableAutoConnect()
          .build(),
    );

    socket?.onConnect((_) {
      print('已连接到服务器: ${socket?.id}');
    });

    socket?.onConnectError((data) {
      print('连接错误: $data');
    });

    socket?.onError((data) {
      print('发生错误: $data');
    });

    socket?.onDisconnect((_) {
      print('已断开连接');
    });

    socket?.on('room-users', (data) {
      setState(() {
        users = List<Map<String, dynamic>>.from(data['users']);
      });
    });
  }

  Future<void> joinRoom() async {
    if (roomId.isNotEmpty && nickname.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('roomId', roomId);
      await prefs.setString('nickname', nickname);

      print('请求加入房间: roomId: $roomId, nickname: $nickname');
      socket?.emit('join-room', { 'roomId': roomId, 'nickname': nickname, });
      socket?.on('join-room-response', (response) { print('房间响应: $response'); });
      setState(() {
        isInRoom = true;
      });
    }
  }

  Future<void> startSharing() async {
    try {
      // 请求屏幕录制权限
      await platform.invokeMethod('requestScreenCapture');
      
      // 获取屏幕共享流
      final Map<String, dynamic> mediaConstraints = {
        'audio': true,
        'video': true
      };

      localStream =
          await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
      _localRenderer.srcObject = localStream;

      setState(() {
        isSharing = true;
      });

      socket?.emit('start-sharing');

      // 处理音频轨道状态
      final audioTracks = localStream?.getAudioTracks();
      if (audioTracks?.isNotEmpty ?? false) {
        audioTracks?.first.enabled = isMicOn;
      }
    } catch (e) {
      print('屏幕共享启动失败: $e');
    }
  }

  Future<void> stopSharing() async {
    localStream?.getTracks().forEach((track) => track.stop());
    localStream = null;
    _localRenderer.srcObject = null;

    // 停止原生端的屏幕录制
    await platform.invokeMethod('stopScreenCapture');

    setState(() {
      isSharing = false;
    });

    socket?.emit('stop-sharing');
  }

  void toggleMic() {
    if (localStream != null) {
      final audioTracks = localStream?.getAudioTracks();
      if (audioTracks?.isNotEmpty ?? false) {
        setState(() {
          isMicOn = !isMicOn;
          audioTracks?.first.enabled = isMicOn;
        });
      }
    }
  }

  Future<void> leaveRoom() async {
    if (isSharing) {
      await stopSharing();
    }

    if (localStream != null) {
      localStream!.getTracks().forEach((track) => track.stop());
      localStream!.dispose();
      localStream = null;
    }

    socket?.disconnect();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('roomId');
    await prefs.remove('nickname');

    setState(() {
      isInRoom = false;
      isViewing = false;
      roomId = '';
      nickname = '';
      users = [];
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    localStream?.dispose();
    _localRenderer.dispose();
    socket?.disconnect();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Container(
          width: double.infinity,
          height: double.infinity,
          color: Colors.grey[100],
          child: !isInRoom ? _buildJoinForm() : _buildMeetingRoom(),
        ),
      ),
    );
  }

  Widget _buildJoinForm() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '屏幕共享',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            TextField(
              decoration: const InputDecoration(
                hintText: '输入房间号',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => roomId = value),
            ),
            const SizedBox(height: 10),
            TextField(
              decoration: const InputDecoration(
                hintText: '输入昵称',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => nickname = value),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: roomId.isEmpty || nickname.isEmpty ? null : joinRoom,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
              child: const Text('加入会议'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMeetingRoom() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: isFullScreen ? 1 : 3,
                child: Container(
                  margin: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSharing || isViewing ? Colors.blue : Colors.grey,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Stack(
                    children: [
                      if (_isRendererInitialized)
                        RTCVideoView(_localRenderer),
                      if (!_isRendererInitialized || (!isSharing && !isViewing))
                        const Center(
                          child: Text('等待屏幕共享...'),
                        ),
                      Positioned(
                        top: 10,
                        right: 10,
                        child: IconButton(
                          icon: Icon(
                            isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              isFullScreen = !isFullScreen;
                            });
                            if (isFullScreen) {
                              SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                            } else {
                              SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 200,
                child: ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: users.length,
                  itemBuilder: (context, index) {
                    final user = users[index];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(user['nickname'][0]),
                      ),
                      title: Text(user['nickname']),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.grey[300]!)),
          ),
          child: Column(
            children: [
              Text('会议室: $roomId'),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!isSharing)
                    ElevatedButton.icon(
                      onPressed: startSharing,
                      icon: const Icon(Icons.screen_share),
                      label: const Text('分享'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: stopSharing,
                      icon: const Icon(Icons.stop),
                      label: const Text('停止共享'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: toggleMic,
                    icon: Icon(isMicOn ? Icons.mic : Icons.mic_off),
                    label: Text(isMicOn ? '关闭麦克风' : '开启麦克风'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isMicOn ? Colors.orange : Colors.grey,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: leaveRoom,
                    icon: const Icon(Icons.exit_to_app),
                    label: const Text('离开'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[600],
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
