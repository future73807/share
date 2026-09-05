import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';

/// 默认服务器地址:可用 --dart-define=SERVER_URL=... 覆盖;
/// 运行时可在加入页手输服务器地址(保存在本机,优先于该默认值)。
const String kServerUrl = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'https://share-api-bak.future-you.top',
);

/// 声音分享模式
const String audioModeMixed = 'mixed'; // 屏幕+麦克风(混合)
const String audioModeScreen = 'screen'; // 仅屏幕内部声音
const String audioModeMic = 'mic'; // 仅麦克风
const String audioModeNone = 'none'; // 无声

const List<Map<String, String>> kAudioModes = [
  {'value': audioModeMixed, 'label': '混合(屏幕+麦克风)'},
  {'value': audioModeScreen, 'label': '仅屏幕声音'},
  {'value': audioModeMic, 'label': '仅麦克风'},
  {'value': audioModeNone, 'label': '无声'},
];

class ScreenSharePage extends StatefulWidget {
  const ScreenSharePage({Key? key}) : super(key: key);

  @override
  _ScreenSharePageState createState() => _ScreenSharePageState();
}

class _ScreenSharePageState extends State<ScreenSharePage> {
  static const MethodChannel _channel = MethodChannel('screen_share_channel');

  // 状态
  String roomId = '';
  String nickname = '';
  bool isInRoom = false;
  bool isSharing = false;
  bool isViewing = false;
  bool isMicOn = true;
  bool isFullScreen = false;
  bool isJoining = false;
  String audioMode = audioModeMixed;
  String statusText = '';
  List<Map<String, dynamic>> users = [];

  // WebRTC
  IO.Socket? socket;
  late TextEditingController _roomController;
  late TextEditingController _nickController;
  late TextEditingController _serverController;
  String _activeServerUrl = kServerUrl; // 当前 socket 实际连接的地址
  MediaStream? screenStream; // 屏幕视频流
  MediaStream? micStream; // 麦克风流(硬件回声抑制)
  MediaStream? localPublishStream; // 发布流(视频+音频轨道)
  final Map<String, RTCPeerConnection> peerConnections = {};
  final Map<String, Future<RTCPeerConnection>> _pendingPeers = {};
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};
  final Set<String> _requestedStream = {};
  final Set<String> _recvOfferSent = {};
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _renderersInitialized = false;
  bool _startingShare = false;

  @override
  void initState() {
    super.initState();
    _roomController = TextEditingController(text: roomId);
    _nickController = TextEditingController(text: nickname);
    _serverController = TextEditingController();
    _initRenderers();
    initializeSocket();
    _loadSavedData();
    _setupNativeCallbacks();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (mounted) {
      setState(() => _renderersInitialized = true);
    }
  }

  /// 原生回调:投影被系统终止时同步 UI
  void _setupNativeCallbacks() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSystemAudioCaptureStopped') {
        debugPrint('系统音频采集被终止');
      }
    });
  }

  @override
  void dispose() {
    _roomController.dispose();
    _nickController.dispose();
    _serverController.dispose();
    peerConnections.forEach((_, pc) => pc.close());
    screenStream?.getTracks().forEach((t) => t.stop());
    micStream?.getTracks().forEach((t) => t.stop());
    localPublishStream?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    socket?.disconnect();
    if (isFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRoom = prefs.getString('roomId') ?? '';
    final savedNickname = prefs.getString('nickname') ?? '';
    final savedServer = prefs.getString('serverUrl') ?? '';
    if (mounted) {
      setState(() {
        if (savedRoom.isNotEmpty) {
          roomId = savedRoom;
          _roomController.text = savedRoom;
        }
        if (savedNickname.isNotEmpty) {
          nickname = savedNickname;
          _nickController.text = savedNickname;
        }
        if (savedServer.isNotEmpty) {
          _serverController.text = savedServer;
        }
      });
    }
  }

  /// 加入页输入的地址规范化:空则用默认值,无协议补 http://,去尾部斜杠
  String _normalizedServerUrl() {
    var u = _serverController.text.trim();
    if (u.isEmpty) u = kServerUrl;
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  void initializeSocket([String? url]) {
    _activeServerUrl = url ?? _activeServerUrl;
    debugPrint('初始化 socket: $_activeServerUrl');
    socket = IO.io(
      _activeServerUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .setReconnectionAttempts(5)
          .setReconnectionDelay(3000)
          .enableAutoConnect()
          .build(),
    );

    socket?.onConnect((_) {
      debugPrint('已连接到服务器: ${socket?.id}');
      if (isInRoom) {
        _emitJoinRoom();
      }
    });

    socket?.onConnectError((data) {
      debugPrint('连接错误: $data');
      if (mounted) setState(() => statusText = '无法连接服务器');
    });

    socket?.on('room-users', (data) {
      if (!mounted) return;
      setState(() {
        users = List<Map<String, dynamic>>.from((data['users'] as List).map(
            (u) => Map<String, dynamic>.from(u as Map)));
      });
      // 房间里已有人共享屏幕:主动向共享者请求流(每个共享者只请求一次)
      final sharingUsers = (data['sharingUsers'] as List?) ?? [];
      if (!isSharing && sharingUsers.isNotEmpty) {
        for (final sharer in sharingUsers) {
          final id = sharer.toString();
          if (_requestedStream.add(id)) {
            socket?.emit('request-stream', {'to': id});
          }
        }
      }
    });

    socket?.on('user-joined', (data) async {
      debugPrint('${data['nickname']} 加入了房间');
      if (!mounted) return;
      setState(() {
        users.add(Map<String, dynamic>.from(data as Map));
      });
      if (isSharing) {
        final socketId = data['socketId'] as String;
        if (data['client'] == 'flutter') {
          // Flutter 观看者:请其发送 Offer(手机作为 ICE 控制端)
          socket?.emit('accept-stream', {'to': socketId});
        } else {
          await createOfferTo(socketId);
        }
      }
    });

    // 有人开始共享:非共享者请求拉流(每个共享者只请求一次)
    socket?.on('share-started', (data) async {
      final from = data['from'] as String?;
      if (!isSharing && from != null && from != socket?.id) {
        if (_requestedStream.add(from)) {
          socket?.emit('request-stream', {'to': from});
        }
      }
    });

    // 共享者收到拉流请求:
    //  - Web 观看者:直接发送 Offer
    //  - Flutter 观看者:通知其发送 Offer(手机作为 ICE 控制端,提升 NAT 穿透成功率)
    socket?.on('request-stream', (data) async {
      if (!isSharing) return;
      final from = data['from'] as String;
      if (data['clientType'] == 'flutter') {
        socket?.emit('accept-stream', {'to': from});
      } else {
        await createOfferTo(from);
      }
    });

    // Flutter 观看者收到 accept-stream:创建接收型收发器并发送 Offer
    socket?.on('accept-stream', (data) async {
      if (isSharing) return;
      final from = data['from'] as String;
      if (_recvOfferSent.contains(from)) return;
      _recvOfferSent.add(from);
      final pc = await _getOrCreatePeer(from);
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      try {
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        socket?.emit('offer', {
          'offer': {'type': offer.type, 'sdp': offer.sdp},
          'to': from,
        });
      } catch (e) {
        debugPrint('观看者创建 offer 失败: $e');
      }
    });

    socket?.on('offer', (data) async {
      if (isSharing) return;
      final from = data['from'] as String;
      final pc = await _getOrCreatePeer(from);
      try {
        await pc.setRemoteDescription(
            RTCSessionDescription(data['offer']['sdp'], data['offer']['type']));
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        socket?.emit('answer', {
          'answer': {'type': answer.type, 'sdp': answer.sdp},
          'to': from,
        });
      } catch (e) {
        debugPrint('处理 offer 失败: $e');
      }
    });

    socket?.on('answer', (data) async {
      final pc = peerConnections[data['from']];
      if (pc != null) {
        try {
          await pc.setRemoteDescription(
              RTCSessionDescription(data['answer']['sdp'], data['answer']['type']));
        } catch (e) {
          debugPrint('处理 answer 失败: $e');
        }
      }
    });

    socket?.on('ice-candidate', (data) async {
      final from = data['from'] as String?;
      final pc = from != null ? peerConnections[from] : null;
      final candidate = data['candidate'];
      if (candidate == null) return;
      if (pc == null) {
        // 对端连接尚未建立(应答流程进行中),先缓存候选,建立后回放
        if (from != null) {
          _pendingCandidates.putIfAbsent(from, () => []).add(RTCIceCandidate(
                candidate['candidate'],
                candidate['sdpMid'],
                candidate['sdpMLineIndex'],
              ));
        }
        return;
      }
      try {
        await pc.addCandidate(RTCIceCandidate(
          candidate['candidate'],
          candidate['sdpMid'],
          candidate['sdpMLineIndex'],
        ));
        debugPrint('远端候选已添加($from): ${candidate['candidate']}');
      } catch (e) {
        debugPrint('添加 ICE 候选失败: $e');
      }
    });

    // 有人停止共享:清理对应连接与远端画面,并允许其下次共享时再次请求
    socket?.on('share-stopped', (data) {
      final from = data['from'] as String?;
      if (from != null) {
        _requestedStream.remove(from);
        _recvOfferSent.remove(from);
      }
      final ids = List<String>.from(peerConnections.keys);
      for (final id in ids) {
        if (from == null || from == id || from == socket?.id) {
          peerConnections[id]?.close();
          peerConnections.remove(id);
        }
      }
      if (peerConnections.isEmpty && isViewing && !isSharing) {
        _remoteRenderer.srcObject = null;
        if (mounted) setState(() => isViewing = false);
      }
    });

    socket?.on('user-left', (data) {
      final socketId = data['socketId'] as String?;
      if (socketId != null) {
        peerConnections[socketId]?.close();
        peerConnections.remove(socketId);
        if (peerConnections.isEmpty && isViewing) {
          _remoteRenderer.srcObject = null;
          if (mounted) setState(() => isViewing = false);
        }
        if (mounted) {
          setState(() {
            users.removeWhere((u) => u['socketId'] == socketId);
          });
        }
      }
    });
  }

  Future<void> _emitJoinRoom() async {
    socket?.emit('join-room', {
      'roomId': roomId,
      'nickname': nickname,
      'client': 'flutter',
    });
    if (mounted) setState(() => statusText = '');
  }

  /// 等待 socket 建立连接,超时返回 false
  Future<bool> _waitConnected(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (socket?.connected == true) return true;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return socket?.connected == true;
  }

  Future<void> joinRoom() async {
    if (roomId.isEmpty || nickname.isEmpty || isJoining) return;
    setState(() {
      isJoining = true;
      statusText = '连接中...';
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('roomId', roomId);
    await prefs.setString('nickname', nickname);
    final url = _normalizedServerUrl();
    await prefs.setString('serverUrl', url);

    // 地址变化或当前未连接:用输入的地址重建 socket(失败可改地址重试)
    if (socket == null || socket!.connected != true || url != _activeServerUrl) {
      initializeSocket(url);
    }
    final ok = await _waitConnected(const Duration(seconds: 8));
    if (!ok) {
      if (mounted) {
        setState(() {
          isJoining = false;
          statusText = '无法连接 $url,请检查服务器地址和网络后重试';
        });
      }
      return;
    }
    _emitJoinRoom();
    if (mounted) {
      setState(() {
        isInRoom = true;
        isJoining = false;
        statusText = '';
      });
    }
  }

  Future<RTCPeerConnection> _getOrCreatePeer(String socketId) {
    final existing = peerConnections[socketId];
    if (existing != null) return Future.value(existing);
    final pending = _pendingPeers[socketId];
    if (pending != null) return pending;
    // 串行化创建,避免并发事件导致同一对端生成两个连接
    final future = _createPeerInternal(socketId);
    _pendingPeers[socketId] = future;
    return future.whenComplete(() => _pendingPeers.remove(socketId));
  }

  Future<RTCPeerConnection> _createPeerInternal(String socketId) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun.miwifi.com:3478'}, // 国内可达,提升 ICE 成功率
      ],
      'sdpSemantics': 'unified-plan'
    });

    pc.onIceCandidate = (candidate) {
      debugPrint('本地候选($socketId): ${candidate.candidate}');
      socket?.emit('ice-candidate', {
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
        'to': socketId,
      });
    };

    pc.onTrack = (event) {
      debugPrint('收到远端轨道: ${event.track.kind} (来自 $socketId)');
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams[0];
        if (mounted) setState(() => isViewing = true);
      }
      // 音频轨道由 WebRTC 自动播放(远端声音)
    };

    pc.onConnectionState = (state) {
      debugPrint('P2P 状态($socketId): $state');
    };

    peerConnections[socketId] = pc;

    // 回放在连接建立前到达的远端候选
    final buffered = _pendingCandidates.remove(socketId);
    if (buffered != null && buffered.isNotEmpty) {
      debugPrint('回放缓存的远端候选 x${buffered.length} ($socketId)');
      for (final c in buffered) {
        try {
          await pc.addCandidate(c);
        } catch (e) {
          debugPrint('回放候选失败: $e');
        }
      }
    }
    return pc;
  }

  /// 共享者:向指定观众建立连接并发送 Offer
  Future<void> createOfferTo(String socketId) async {
    try {
      final pc = await _getOrCreatePeer(socketId);
      // 已在协商中则跳过,避免重复 Offer 造成 answer 竞态
      if (pc.signalingState ==
          RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        return;
      }
      // 发布本地轨道(幂等:同一轨道不会重复添加到已建立的连接)
      if (localPublishStream != null) {
        final senders = await pc.getSenders();
        for (final track in localPublishStream!.getTracks()) {
          final already = senders.any((s) => s.track?.id == track.id);
          if (!already) {
            await pc.addTrack(track, localPublishStream!);
          }
        }
      }
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      socket?.emit('offer', {
        'offer': {'type': offer.type, 'sdp': offer.sdp},
        'to': socketId,
      });
    } catch (e) {
      debugPrint('创建 offer 失败: $e');
    }
  }

  // ============ 屏幕共享 ============

  /// 生效的原生混音模式
  String get effectiveNativeMode {
    final wantScreen =
        (audioMode == audioModeMixed || audioMode == audioModeScreen);
    final wantMic = isMicOn &&
        (audioMode == audioModeMixed || audioMode == audioModeMic);
    if (wantScreen && wantMic) return 'mixed';
    if (wantScreen) return 'screen';
    if (wantMic) return 'mic';
    return 'none';
  }

  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> startSharingFlow() async {
    final selected = await _pickAudioMode();
    if (selected == null) return;
    setState(() => audioMode = selected);
    await startSharing();
  }

  Future<void> startSharing() async {
    // 防止重复触发(快速连点/弹窗竞态)
    if (isSharing || _startingShare) return;
    _startingShare = true;
    try {
      await _startSharingInternal();
    } finally {
      _startingShare = false;
    }
  }

  Future<void> _startSharingInternal() async {
    try {
      // 1. 麦克风权限(混音链路常驻麦克风,同时完成回声抑制)
      final needMic =
          audioMode == audioModeMixed || audioMode == audioModeMic;
      bool micGranted = false;
      if (needMic) {
        micGranted = await _ensureMicPermission();
        if (!micGranted) {
          _toast('未授予麦克风权限,将以无声模式共享');
        }
      }

      // 2. 系统授权弹窗(单个会话一次授权)
      final granted = await Helper.requestCapturePermission();
      if (granted != true) {
        _toast('屏幕共享授权被拒绝');
        return;
      }

      // 3. 启动 mediaProjection 前台服务(Android 14+ 必须先于采集启动,否则闪退)
      final serviceOk =
          await _channel.invokeMethod('startCaptureService') as bool?;
      debugPrint('前台服务就绪: ${serviceOk ?? false}');

      // 4. 获取屏幕视频流(授权已缓存,不会再弹第二次)
      screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
      final videoTracks = screenStream!.getVideoTracks();

      // 5. 麦克风流(带回声抑制/噪声抑制/自动增益)
      MediaStream? mic;
      try {
        mic = await navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          }
        });
      } catch (e) {
        debugPrint('麦克风获取失败: $e');
      }
      micStream = mic;

      // 6. 系统内部声音采集(AudioPlaybackCapture,注入 WebRTC 混音链路)
      bool screenAudioActive = false;
      final wantScreenAudio =
          audioMode == audioModeMixed || audioMode == audioModeScreen;
      if (wantScreenAudio && videoTracks.isNotEmpty) {
        try {
          final ok = await _channel.invokeMethod('startSystemAudioCapture',
              {'trackId': videoTracks.first.id});
          screenAudioActive = ok == true;
        } on PlatformException catch (e) {
          if (e.code == 'NEED_PROJECTION') {
            // 无法复用投影:走插件自建授权(第二次系统弹窗)
            final ok = ((await _channel
                .invokeMethod('startAudioProjectionFallback')) as bool?) ?? false;
            screenAudioActive = ok;
          } else if (e.code == 'UNSUPPORTED') {
            _toast('当前系统版本不支持采集屏幕内部声音');
          } else {
            debugPrint('系统音频采集失败: ${e.code} ${e.message}');
          }
        }
      }

      // 7. 计算生效模式并下发
      String nativeMode = effectiveNativeMode;
      if (mic == null && (nativeMode == 'mixed' || nativeMode == 'mic')) {
        nativeMode = screenAudioActive ? 'screen' : 'none';
      }
      if (!screenAudioActive &&
          (nativeMode == 'mixed' || nativeMode == 'screen')) {
        nativeMode = (mic != null) ? 'mic' : 'none';
      }
      await _channel.invokeMethod('setAudioShareMode', {'mode': nativeMode});

      // 8. 组装发布流
      final publish = await createLocalMediaStream('localShare');
      if (videoTracks.isNotEmpty) publish.addTrack(videoTracks.first);
      if (mic != null && mic.getAudioTracks().isNotEmpty) {
        publish.addTrack(mic.getAudioTracks().first);
      }
      localPublishStream = publish;

      _localRenderer.srcObject = publish;

      if (mounted) setState(() => isSharing = true);
      socket?.emit('start-sharing');

      // 向房间内已有观众推送(覆盖 room-users 时序)
      for (final u in users) {
        final sid = u['socketId'] as String?;
        if (sid != null && sid != socket?.id) {
          await createOfferTo(sid);
        }
      }
    } catch (e, s) {
      debugPrint('屏幕共享启动失败: $e\n$s');
      _toast('屏幕共享启动失败: $e');
      await _cleanupShare();
    }
  }

  Future<void> stopSharing() async {
    socket?.emit('stop-sharing');
    peerConnections.forEach((_, pc) => pc.close());
    peerConnections.clear();
    await _cleanupShare();
    if (mounted) {
      setState(() {
        isSharing = false;
        isMicOn = true;
      });
    }
  }

  Future<void> _cleanupShare() async {
    try {
      await _channel.invokeMethod('stopAllCapture');
    } catch (_) {}
    try {
      await _channel.invokeMethod('stopCaptureService');
    } catch (_) {}
    screenStream?.getTracks().forEach((t) => t.stop());
    micStream?.getTracks().forEach((t) => t.stop());
    screenStream = null;
    micStream = null;
    localPublishStream?.dispose();
    localPublishStream = null;
    _localRenderer.srcObject = null;
  }

  Future<void> toggleMic() async {
    if (!isSharing) return;
    final next = !isMicOn;
    setState(() => isMicOn = next);
    // 混音由原生处理器控制,轨道保持开启
    try {
      await _channel.invokeMethod('setAudioShareMode',
          {'mode': effectiveNativeModeIf(micOn: next)});
    } catch (_) {}
  }

  String effectiveNativeModeIf({required bool micOn}) {
    final wantScreen =
        (audioMode == audioModeMixed || audioMode == audioModeScreen);
    final wantMic = micOn &&
        (audioMode == audioModeMixed || audioMode == audioModeMic);
    if (wantScreen && wantMic) return 'mixed';
    if (wantScreen) return 'screen';
    if (wantMic) return 'mic';
    return 'none';
  }

  /// 共享中切换声音模式
  Future<void> setAudioMode(String mode) async {
    setState(() => audioMode = mode);
    if (!isSharing) return;

    final wantScreenAudio =
        mode == audioModeMixed || mode == audioModeScreen;
    bool screenAudioActive = false;
    if (wantScreenAudio) {
      final videoTracks = screenStream?.getVideoTracks() ?? [];
      if (videoTracks.isNotEmpty) {
        try {
          final ok = await _channel.invokeMethod('startSystemAudioCapture',
              {'trackId': videoTracks.first.id});
          screenAudioActive = ok == true;
        } on PlatformException catch (e) {
          if (e.code == 'NEED_PROJECTION') {
            final ok = ((await _channel
                .invokeMethod('startAudioProjectionFallback')) as bool?) ?? false;
            screenAudioActive = ok;
          } else {
            screenAudioActive = false;
          }
        }
      }
    } else {
      try {
        await _channel.invokeMethod('stopSystemAudioCapture');
      } catch (_) {}
    }

    String nativeMode = effectiveNativeModeIf(micOn: isMicOn);
    if (!screenAudioActive &&
        (nativeMode == 'mixed' || nativeMode == 'screen')) {
      nativeMode = (micStream != null) ? 'mic' : 'none';
    }
    await _channel.invokeMethod('setAudioShareMode', {'mode': nativeMode});
  }

  Future<void> leaveRoom() async {
    if (isSharing) await stopSharing();
    socket?.disconnect();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('roomId');
    await prefs.remove('nickname');

    if (mounted) {
      setState(() {
        isInRoom = false;
        isViewing = false;
        roomId = '';
        nickname = '';
        users = [];
        isFullScreen = false;
      });
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 重新连接 socket 以便下次加入
    socket?.connect();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<String?> _pickAudioMode() async {
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('选择共享声音模式',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            ...kAudioModes
                .map((m) => ListTile(
                      title: Text(m['label']!),
                      onTap: () => Navigator.pop(ctx, m['value']),
                    ))
                .toList(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ============ UI ============

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
      child: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.all(20),
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('屏幕共享',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              TextField(
                controller: _roomController,
                decoration: const InputDecoration(
                  hintText: '输入房间号',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => roomId = value,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nickController,
                decoration: const InputDecoration(
                  hintText: '输入昵称',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => nickname = value,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _serverController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: '服务器地址(连不上时手输,如 http://192.168.1.5:3000)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('共享声音',
                    style: TextStyle(fontSize: 14, color: Colors.grey[700])),
              ),
              Wrap(
                spacing: 8,
                children: kAudioModes
                    .map((m) => ChoiceChip(
                          label: Text(m['label']!),
                          selected: audioMode == m['value'],
                          onSelected: (_) =>
                              setState(() => audioMode = m['value']!),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: isJoining ? null : joinRoom,
                  icon: const Icon(Icons.group_add),
                  label: const Text('加入会议'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              if (statusText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(statusText,
                      style: const TextStyle(color: Colors.red)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMeetingRoom() {
    return Column(
      children: [
        Expanded(
          child: isFullScreen ? _buildVideoArea() : Row(
            children: [
              Expanded(flex: 3, child: _buildVideoArea()),
              SizedBox(width: 160, child: _buildUserList()),
            ],
          ),
        ),
        if (!isFullScreen) _buildControlBar(),
      ],
    );
  }

  Widget _buildVideoArea() {
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(
          color: (isSharing || isViewing) ? Colors.blue : Colors.grey,
        ),
        borderRadius: BorderRadius.circular(8),
        color: Colors.black,
      ),
      child: Stack(
        children: [
          if (_renderersInitialized)
            RTCVideoView(isSharing ? _localRenderer : _remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
          if (!_renderersInitialized || (!isSharing && !isViewing))
            const Center(
              child: Text('等待屏幕共享...',
                  style: TextStyle(color: Colors.white70)),
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
                setState(() => isFullScreen = !isFullScreen);
                if (isFullScreen) {
                  SystemChrome.setEnabledSystemUIMode(
                      SystemUiMode.immersiveSticky);
                } else {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserList() {
    return Container(
      margin: const EdgeInsets.only(top: 10, right: 10, bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      child: ListView.builder(
        itemCount: users.length,
        itemBuilder: (context, index) {
          final user = users[index];
          final nick = (user['nickname'] ?? '') as String;
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(child: Text(nick.isNotEmpty ? nick[0] : '?')),
            title: Text(nick, overflow: TextOverflow.ellipsis),
          );
        },
      ),
    );
  }

  Widget _buildControlBar() {
    final modeLabel =
        kAudioModes.firstWhere((m) => m['value'] == audioMode)['label']!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey[300]!)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('会议室: $roomId',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (isSharing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                alignment: WrapAlignment.center,
                children: kAudioModes
                    .map((m) => ChoiceChip(
                          label: Text(m['label']!,
                              style: const TextStyle(fontSize: 12)),
                          selected: audioMode == m['value'],
                          onSelected: (_) => setAudioMode(m['value']!),
                        ))
                    .toList(),
              ),
            ),
          if (isSharing)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text('当前声音: $modeLabel',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!isSharing)
                  ElevatedButton.icon(
                    onPressed: startSharingFlow,
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
                if (isSharing &&
                    (audioMode == audioModeMixed ||
                        audioMode == audioModeMic))
                  ElevatedButton.icon(
                    onPressed: toggleMic,
                    icon: Icon(isMicOn ? Icons.mic : Icons.mic_off),
                    label: Text(isMicOn ? '关闭麦克风' : '开启麦克风'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          isMicOn ? Colors.orange : Colors.grey,
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
          ),
        ],
      ),
    );
  }
}
