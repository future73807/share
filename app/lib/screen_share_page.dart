import 'package:flutter/material.dart';
import 'brand_logo.dart';
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
  {'value': audioModeScreen, 'label': '仅屏幕声音(不采集麦克风)'},
  {'value': audioModeMic, 'label': '仅麦克风'},
  {'value': audioModeNone, 'label': '无声'},
];

/// 帧率档位(默认 60)。编码发送上限;实际帧率受设备刷新率限制
/// (libwebrtc 屏幕采集帧率=屏幕内容更新率,闸门在编码器 maxFramerate)。
const List<int> kFpsTiers = [60, 90, 120, 144, 165];
const int kDefaultFps = 60;

/// 发送上限码率随帧率走(只是上限,实际由带宽估计自适应):
/// fps*120k,60→7.2M,165→19.8M 封顶 20M
int fpsBitrate(int fps) => (fps * 120000).clamp(7200000, 20000000);

/// SDP 起步码率随帧率走:fps*50k,60→3M,165→8M 封顶
int fpsStartBitrate(int fps) => (fps * 50000).clamp(3000000, 8000000);

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
  bool membersCollapsed = false; // 右侧成员列表收起状态
  int _videoRotation = 0; // 画面旋转,90° 步进(0-3 圈)
  final TransformationController _videoTransform = TransformationController();
  bool isJoining = false;
  String audioMode = audioModeMixed;
  int shareFps = kDefaultFps; // 帧率档位(60/90/120/144/165)
  // 设备屏幕刷新率(Hz)。屏幕采集帧率不可能超过屏幕刷新率,档位超过时
  // 采集/编码节奏失配会出现细线与拖影,闸门一律钳到 effectiveFps。
  double? _displayRefresh;
  double? _displayMaxRefresh;
  Timer? _refreshResyncTimer;
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
  Timer? _levelTimer;
  double _audioLevel = 0;
  int _lastCaptureWrites = 0;
  bool _screenCaptureAlive = false;

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
    _queryDisplayRefresh();
    // 浅色背景上状态栏图标用黑色
    _applyDarkStatusBarIcons();
  }

  void _applyDarkStatusBarIcons() {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark, // 安卓状态栏图标黑色
      statusBarBrightness: Brightness.light,    // iOS 同步
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
  }

  void _exitFullScreenUi() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _channel.invokeMethod('exitImmersive').catchError((_) => null);
    _applyDarkStatusBarIcons();
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
    _levelTimer?.cancel();
    _refreshResyncTimer?.cancel();
    _roomController.dispose();
    _nickController.dispose();
    _serverController.dispose();
    _videoTransform.dispose();
    peerConnections.forEach((_, pc) => pc.close());
    screenStream?.getTracks().forEach((t) => t.stop());
    micStream?.getTracks().forEach((t) => t.stop());
    localPublishStream?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    socket?.disconnect();
    if (isFullScreen) {
      _exitFullScreenUi();
    }
    super.dispose();
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRoom = prefs.getString('roomId') ?? '';
    final savedNickname = prefs.getString('nickname') ?? '';
    final savedServer = prefs.getString('serverUrl') ?? '';
    final savedFps = prefs.getInt('shareFps') ?? kDefaultFps;
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
        if (kFpsTiers.contains(savedFps)) {
          shareFps = savedFps;
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
        await _applyScreenSenderParams(pc);
        await _preferHardwareVideoCodec(pc);
      }
      final offer = await pc.createOffer();
      // 起步码率提速后作为本地描述;发给对端的 SDP 必须与实际
      // setLocalDescription 的一致,故 emit 也用提速后的
      final boosted = RTCSessionDescription(
          _boostVideoStartBitrate(offer.sdp ?? ''), offer.type);
      await pc.setLocalDescription(boosted);
      socket?.emit('offer', {
        'offer': {'type': boosted.type, 'sdp': boosted.sdp},
        'to': socketId,
      });
    } catch (e) {
      debugPrint('创建 offer 失败: $e');
    }
  }

  // ============ 屏幕共享 ============

  /// 实际生效的帧率上限 = min(所选档位, 当前屏幕刷新率)。
  /// 屏幕内容更新率以刷新率为天花板,编码闸门超过它不仅无收益,
  /// 还会因采集/编码节奏失配出现细线与拖影。
  int get effectiveFps {
    final r = _displayRefresh;
    if (r == null || r <= 0) return shareFps;
    final cap = r.round();
    return shareFps > cap ? cap : shareFps;
  }

  /// 查询当前屏幕刷新率与设备支持的最高档
  Future<void> _queryDisplayRefresh() async {
    try {
      final r = await _channel.invokeMethod('getDisplayInfo');
      if (r is Map) {
        final cur = (r['refreshRate'] as num?)?.toDouble();
        final max = (r['maxSupported'] as num?)?.toDouble();
        if (mounted) {
          setState(() {
            if (cur != null && cur > 0) _displayRefresh = cur;
            if (max != null && max > 0) _displayMaxRefresh = max;
          });
        }
      }
    } catch (_) {}
  }

  /// 档位高于当前刷新率但设备支持更高档时,请求系统切到匹配的
  /// 显示模式(与当前分辨率相同),让高帧率档位真正可用。
  Future<void> _syncDisplayRefreshForTier() async {
    await _queryDisplayRefresh();
    if (effectiveFps >= shareFps) return; // 当前刷新率已覆盖所选档位
    final maxSupported = _displayMaxRefresh ?? 0;
    if (maxSupported < shareFps) return; // 硬件不支持,保持钳制
    try {
      await _channel
          .invokeMethod('setPreferredRefreshRate', {'rate': shareFps.toDouble()});
    } catch (_) {}
    // 显示模式切换需要数百毫秒,稍后复查并校准闸门
    _refreshResyncTimer?.cancel();
    _refreshResyncTimer = Timer(const Duration(milliseconds: 1200), () async {
      await _queryDisplayRefresh();
      if (isSharing) await _applyFpsToAllSenders();
    });
  }

  /// 恢复系统默认刷新模式(停止共享/离开房间时调用)
  Future<void> _restoreDisplayRefresh() async {
    _refreshResyncTimer?.cancel();
    try {
      await _channel.invokeMethod('setPreferredRefreshRate', {'rate': 0.0});
    } catch (_) {}
  }

  /// 把当前 effectiveFps/码率应用到所有已建立连接的视频 sender
  Future<void> _applyFpsToAllSenders() async {
    final fps = effectiveFps;
    for (final pc in peerConnections.values) {
      try {
        final senders = await pc.getSenders();
        for (final sender in senders) {
          final track = sender.track;
          if (track == null || track.kind != 'video') continue;
          final params = sender.parameters;
          final encodings = params.encodings;
          if (encodings != null && encodings.isNotEmpty) {
            encodings.first.maxBitrate = fpsBitrate(fps);
            encodings.first.maxFramerate = fps;
            await sender.setParameters(params);
          }
        }
      } catch (e) {
        debugPrint('应用帧率参数失败: $e');
      }
    }
  }

  /// 屏幕共享视频发送参数。flutter_webrtc 默认发送码率用 WebRTC 低默认值:

  /// 屏幕共享视频发送参数。flutter_webrtc 默认发送码率用 WebRTC 低默认值:
  /// 带宽一波动编码器就不停降/升分辨率——表现为闪烁与忽清忽糊,帧队列
  /// 堆积则延迟越来越高。这里固定分辨率(maintain-resolution,只降帧不降
  /// 分辨率)+ 足量码率(随帧率档位,60fps≈7.2M)+ 帧率上限取所选档位
  /// (屏幕采集帧率=屏幕内容更新率,闸门在编码器),画质稳定、动画流畅。
  Future<void> _applyScreenSenderParams(RTCPeerConnection pc) async {
    try {
      final senders = await pc.getSenders();
      final fps = effectiveFps;
      for (final sender in senders) {
        final track = sender.track;
        if (track == null || track.kind != 'video') continue;
        final params = sender.parameters;
        params.degradationPreference =
            RTCDegradationPreference.MAINTAIN_RESOLUTION;
        final encodings = params.encodings;
        if (encodings != null && encodings.isNotEmpty) {
          encodings.first.maxBitrate = fpsBitrate(fps);
          encodings.first.maxFramerate = fps;
        }
        await sender.setParameters(params);
      }
    } catch (e) {
      debugPrint('设置视频发送参数失败: $e');
    }
  }

  /// 编解码偏好:H264(硬件编码)优先,高 Profile(640c…)再优先于
  /// 受限基线——同码率下质量更高、动态内容伪影更少。屏幕内容 VP8 软编
  /// 在手机上吞吐不足(1080p@30 即吃满 CPU,是"卡"的根源之一);H264
  /// 走 MediaCodec 硬编,高帧率无压力。仅重排序、不剔除,对端不支持
  /// 高 Profile 时仍可回退基线/VP8。
  Future<void> _preferHardwareVideoCodec(RTCPeerConnection pc) async {
    try {
      final caps = await getRtpSenderCapabilities('video');
      final codecs = caps.codecs;
      if (codecs == null || codecs.isEmpty) return;
      int score(RTCRtpCodecCapability c) {
        final m = c.mimeType.toLowerCase();
        if (m == 'video/h264') {
          final fmtp = (c.sdpFmtpLine ?? '').toLowerCase();
          return fmtp.contains('profile-id=640c') ? 0 : 1;
        }
        if (m == 'video/vp8') return 2;
        return 3;
      }

      final sorted = [...codecs]..sort((a, b) => score(a).compareTo(score(b)));
      for (final t in await pc.getTransceivers()) {
        try {
          final track = t.sender.track;
          if (track != null && track.kind == 'video') {
            await t.setCodecPreferences(sorted);
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('设置 H264 编解码偏好失败: $e');
    }
  }

  /// 切换帧率档位(共享前选择持久化;共享中热切换所有已建立连接的
  /// 发送参数,免重协商)。档位高于当前刷新率时,编码闸门钳到
  /// effectiveFps;设备支持更高刷新率则自动请求切换显示模式。
  Future<void> _setFpsTier(int fps) async {
    if (!kFpsTiers.contains(fps) || fps == shareFps) return;
    setState(() => shareFps = fps);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('shareFps', fps);
    if (isSharing) {
      await _syncDisplayRefreshForTier();
      await _applyFpsToAllSenders();
    } else {
      // 共享前选择:仅查询刷新率更新钳制与提示
      await _queryDisplayRefresh();
    }
  }

  /// SDP 起步码率提速:给 m=video 段的编码格式追加 x-google-start/min-bitrate。
  /// 编码器默认 ~300kbps 起步、需数秒爬升,爬升期的模糊会被感知为"卡/糊";
  /// 起步值随帧率档位走(60fps→3M,120→6M,165→8M 封顶)。失败回退原 SDP。
  String _boostVideoStartBitrate(String sdp) {
    final extra =
        'x-google-start-bitrate=${fpsStartBitrate(effectiveFps)};x-google-min-bitrate=1200';
    try {
      final newline = sdp.contains('\r\n') ? '\r\n' : '\n';
      final lines = sdp.split(RegExp(r'\r?\n'));
      final out = <String>[];
      var inVideo = false;
      var fmtpDone = false;
      final fmtpRe = RegExp(r'^a=fmtp:(\d+)(.*)$');
      final rtpmapRe = RegExp(r'^a=rtpmap:(\d+) [^ ]+/90000');
      for (final line in lines) {
        if (line.startsWith('m=')) {
          inVideo = line.startsWith('m=video');
        }
        if (inVideo) {
          final fmtp = fmtpRe.firstMatch(line);
          if (fmtp != null) {
            fmtpDone = true;
            final rest = fmtp.group(2) ?? '';
            if (!rest.contains('x-google-start-bitrate')) {
              out.add(rest.trim().isEmpty
                  ? 'a=fmtp:${fmtp.group(1)} $extra'
                  : 'a=fmtp:${fmtp.group(1)}$rest;$extra');
              continue;
            }
          } else if (!fmtpDone) {
            // 无 fmtp 行(如 VP8):在第一个视频 rtpmap 后补一行
            final pt = rtpmapRe.firstMatch(line);
            if (pt != null) {
              out.add(line);
              out.add('a=fmtp:${pt.group(1)} $extra');
              fmtpDone = true;
              continue;
            }
          }
        }
        out.add(line);
      }
      return out.join(newline);
    } catch (_) {
      return sdp;
    }
  }

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
      // 1. 麦克风权限(无声模式不需要)。其余模式必须:
      //    - 麦克风/混合模式:采集麦克风本身;
      //    - 仅屏幕声音:安卓系统规定声音内录(AudioPlaybackCapture)
      //      也必须持有"录制音频"权限,但本模式不会打开/采集物理麦克风
      //      (原生侧会把 WebRTC 采集源换成系统内录)。
      if (audioMode != audioModeNone) {
        final micGranted = await _ensureMicPermission();
        if (!micGranted) {
          _toast(audioMode == audioModeScreen
              ? '安卓系统要求内录也需"录制音频"权限(不会采集麦克风)'
              : '未授予麦克风权限,无法发送声音');
          return;
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

      // 4. 获取屏幕视频流(授权已缓存,不会再弹第二次)。
      //    帧率约束取 effectiveFps(档位钳到屏幕刷新率,超过会出现
      //    细线/拖影);真正的闸门仍是发送端 maxFramerate。
      screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'frameRate': effectiveFps,
        },
        'audio': false,
      });
      final videoTracks = screenStream!.getVideoTracks();

      // 5. 麦克风流(所有声音模式的音频载体;无声模式跳过)。
      //    仅屏幕声音模式下,原生侧会把 WebRTC 采集源换成系统内录并
      //    关闭物理麦克风——这里创建的轨道只作传输载体,不采麦克风内容。
      MediaStream? mic;
      if (audioMode != audioModeNone) {
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
          debugPrint('系统音频采集失败: ${e.code} ${e.message}');
          if (e.code == 'NEED_PROJECTION') {
            // 无法复用投影:走插件自建授权(第二次系统弹窗)
            final ok = ((await _channel
                .invokeMethod('startAudioProjectionFallback')) as bool?) ?? false;
            screenAudioActive = ok;
            if (!ok) _toast('屏幕内音授权失败,已切换为仅麦克风声音');
          } else if (e.code == 'UNSUPPORTED') {
            _toast('当前系统版本不支持采集屏幕内部声音');
            screenAudioActive = false;
          } else {
            _toast('屏幕内音采集失败(${e.code}),已切换为仅麦克风声音');
            screenAudioActive = false;
          }
        }
      }

      // 7. 计算生效模式并下发(麦克风轨道是所有声音模式的载体,缺失则无法发声)
      String nativeMode = effectiveNativeMode;
      if (mic == null && nativeMode != 'none') {
        nativeMode = 'none';
        _toast('麦克风不可用,本次共享无法发送声音');
      }
      if (!screenAudioActive &&
          (nativeMode == 'mixed' || nativeMode == 'screen')) {
        nativeMode = (mic != null) ? 'mic' : 'none';
        _toast('屏幕内音采集失败,本次将以麦克风声音共享');
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
      _levelTimer?.cancel();
      _lastCaptureWrites = 0;
      _levelTimer = Timer.periodic(
          const Duration(milliseconds: 400), (_) => _pollLevel());
      socket?.emit('start-sharing');

      // 所选档位高于当前刷新率且设备支持更高档时,请求切换显示模式
      await _syncDisplayRefreshForTier();

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
    _levelTimer?.cancel();
    await _restoreDisplayRefresh();
    if (mounted) setState(() => _audioLevel = 0);
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
    if (micStream == null && mode != audioModeNone) {
      _toast('麦克风不可用,无法切换到声音模式');
      return;
    }
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
            if (!ok) _toast('屏幕内音授权失败,已切换为仅麦克风声音');
          } else {
            _toast('屏幕内音采集失败(${e.code})');
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
    _applyDarkStatusBarIcons();
    // 重新连接 socket 以便下次加入
    socket?.connect();
  }

  /// 轮询原生混音电平(供 UI 电平条显示,便于现场判断声音是否在发)。
  /// 采集存活判定用 captureWrites(内录线程"产出"计数,与有无观众无关);
  /// 电平条取 发送峰值/采集原始峰值 的较大者,单人无观众时也能看到采集电平。
  Future<void> _pollLevel() async {
    if (!isSharing) return;
    try {
      final r = await _channel.invokeMethod('getAudioMixLevel');
      final outPeak = (r['outPeak'] as num?)?.toInt() ?? 0;
      final capturePeak = (r['capturePeak'] as num?)?.toInt() ?? 0;
      final cw = (r['captureWrites'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      final level = (outPeak >= capturePeak ? outPeak : capturePeak) / 32767;
      setState(() {
        _audioLevel = level.clamp(0.0, 1.0);
        _screenCaptureAlive = cw != _lastCaptureWrites;
        _lastCaptureWrites = cw;
      });
    } catch (_) {}
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: const Color(0xFF1E293B),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  String _shortModeLabel(String value) {
    switch (value) {
      case audioModeMixed:
        return '混合';
      case audioModeScreen:
        return '屏幕声音';
      case audioModeMic:
        return '麦克风';
      default:
        return '无声';
    }
  }

  IconData _modeIcon(String value) {
    switch (value) {
      case audioModeMixed:
        return Icons.surround_sound;
      case audioModeScreen:
        return Icons.desktop_windows_outlined;
      case audioModeMic:
        return Icons.mic_none;
      default:
        return Icons.volume_off_outlined;
    }
  }

  /// 帧率档位芯片。共享前在弹窗内选择、共享中在控制栏热切换。
  /// 超过当前屏幕刷新率的档位置灰显示(会钳到刷新率,或自动提档中)。
  Widget _fpsChip(int fps, {VoidCallback? afterTap}) {
    final selected = shareFps == fps;
    final refreshCap = (_displayRefresh ?? 0).round();
    final beyondDevice = refreshCap > 0 && fps > refreshCap;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        _setFpsTier(fps);
        afterTap?.call();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _brandLight : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? _brand : const Color(0xFFE2E8F0),
              width: selected ? 1.4 : 1),
        ),
        child: Text('$fps',
            style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? _brand
                    : (beyondDevice
                        ? const Color(0xFFB6C2D4)
                        : const Color(0xFF475569)))),
      ),
    );
  }

  /// 帧率行下方的设备刷新率提示(未检测到时不占位)
  Widget _fpsHint() {
    final cap = (_displayRefresh ?? 0).round();
    if (cap <= 0) return const SizedBox.shrink();
    final clamped = effectiveFps < shareFps;
    String text;
    if (clamped && isSharing && (_displayMaxRefresh ?? 0) >= shareFps) {
      text = '设备刷新率 ${cap}Hz,已请求提升屏幕刷新率以匹配 ${shareFps} 档';
    } else if (clamped) {
      text = '设备刷新率 ${cap}Hz,实际帧率将限制为 $effectiveFps';
    } else {
      text = '设备刷新率 ${cap}Hz,可流畅支撑当前档位';
    }
    return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text,
            style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))));
  }

  Future<String?> _pickAudioMode() async {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheetState) {
        final fpsSection = Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: kFpsTiers
                  .map((f) => _fpsChip(f, afterTap: () => setSheetState(() {})))
                  .toList()),
        );
        return Container(
        decoration:
            const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 12),
            Container(
                width: 40,
                height: 4,
                decoration:
                    BoxDecoration(color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(2))),
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('选择共享声音模式',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)))),
            ...kAudioModes.map((m) {
              final selected = m['value'] == audioMode;
              return InkWell(
                onTap: () => Navigator.pop(ctx, m['value']),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(children: [
                    Icon(_modeIcon(m['value']!),
                        size: 22, color: selected ? _brand : const Color(0xFF94A3B8)),
                    const SizedBox(width: 14),
                    Expanded(
                        child: Text(m['label']!,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                color: selected ? _ink : const Color(0xFF475569)))),
                    if (selected)
                      const Icon(Icons.check_circle, size: 20, color: _brand),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 8),
            const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('帧率(实际受屏幕刷新率限制)',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF64748B))))),
            const SizedBox(height: 8),
            fpsSection,
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                    alignment: Alignment.centerLeft, child: _fpsHint())),
            const SizedBox(height: 4),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                    '提示:混合模式含麦克风,观众端外放可能产生回音;不需要讲话可选"仅屏幕声音"',
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)))),
            const SizedBox(height: 12),
          ]),
        ),
        );
      }),
    );
  }

  // ============ UI ============
  static const _brand = Color(0xFF2563EB);
  static const _brandLight = Color(0xFFEFF6FF);
  static const _ink = Color(0xFF0F172A);
  static const _sub = Color(0xFF64748B);

  @override
  Widget build(BuildContext context) {
    // 不用顶层 SafeArea:去掉顶部安全区,内容延伸到透明状态栏底下。
    // 房间页自己用状态栏高度做顶部留白(全屏时为 0,视频真正铺满)。
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: !isInRoom ? _buildJoinForm() : _buildMeetingRoom(),
    );
  }

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child:
            Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _sub)),
      );

  Widget _textField(
      {required TextEditingController controller,
      required String hint,
      required IconData icon,
      ValueChanged<String>? onChanged,
      TextInputType? keyboardType}) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 15, color: _ink),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFFA6B2C4), fontSize: 14),
        prefixIcon: Icon(icon, size: 20, color: const Color(0xFF94A3B8)),
        isDense: true,
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _brand, width: 1.5)),
      ),
    );
  }

  Widget _modeChip(String value, String label, {VoidCallback? onTap}) {
    final selected = audioMode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap ?? () => setState(() => audioMode = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _brandLight : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? _brand : const Color(0xFFE2E8F0),
              width: selected ? 1.4 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_modeIcon(value),
              size: 15, color: selected ? _brand : const Color(0xFF94A3B8)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? _brand : const Color(0xFF475569))),
        ]),
      ),
    );
  }

  Widget _actionButton(String label, IconData icon, Color color, VoidCallback onPressed) {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 7),
              Flexible(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700))),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _statusPill() {
    final sharing = isSharing;
    final color = sharing ? const Color(0xFF16A34A) : const Color(0xFF94A3B8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: sharing ? const Color(0xFFF0FDF4) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(sharing ? '共享中' : '未共享',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  Widget _buildJoinForm() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                // logo 图标相对右侧文字整体略下移一点(视觉居中对齐标题)
                Padding(
                    padding: const EdgeInsets.only(top: 9),
                    child: const BrandLogo(size: 52)),
                const SizedBox(width: 14),
                const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('屏幕共享',
                          style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: _ink,
                              height: 1.2)),
                      SizedBox(height: 2),
                      Text('实时画面 · 声音共享',
                          style: TextStyle(fontSize: 13, color: _sub)),
                    ]),
              ]),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 24,
                        offset: const Offset(0, 8))
                  ],
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('房间号'),
                  _textField(
                      controller: _roomController,
                      hint: '输入房间号',
                      icon: Icons.tag,
                      onChanged: (v) => roomId = v),
                  const SizedBox(height: 14),
                  _fieldLabel('昵称'),
                  _textField(
                      controller: _nickController,
                      hint: '输入你的昵称',
                      icon: Icons.person_outline,
                      onChanged: (v) => nickname = v),
                  const SizedBox(height: 14),
                  _fieldLabel('服务器地址'),
                  _textField(
                      controller: _serverController,
                      hint: '默认服务器连不上时手输',
                      icon: Icons.dns_outlined,
                      keyboardType: TextInputType.url),
                  const SizedBox(height: 22),
                  Container(
                    height: 52,
                    decoration: BoxDecoration(
                      color: _brand,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: isJoining ? null : joinRoom,
                        child: Center(
                          child: isJoining
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2.4))
                              : const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.group_add, color: Colors.white),
                                    SizedBox(width: 8),
                                    Text('加入房间',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700)),
                                  ]),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
              if (statusText.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 14),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFECACA))),
                  child: Row(children: [
                    const Icon(Icons.error_outline,
                        size: 18, color: Color(0xFFDC2626)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(statusText,
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFFB91C1C)))),
                  ]),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMeetingRoom() {
    // 顶部留白 = 状态栏高度(全屏时为 0,视频延伸到屏幕最顶端,
    // 去掉顶部安全区白条);加入表单页内容居中,不受影响。
    final topInset = isFullScreen
        ? 0.0
        : (MediaQuery.of(context).padding.top + 6.0);
    return Column(children: [
      Expanded(
        child: isFullScreen
            ? _buildVideoArea()
            : Padding(
                padding: EdgeInsets.fromLTRB(12, topInset, 12, 12),
                // 收起时视频区占满整行,气泡条叠加在视频区右缘之上
                child: membersCollapsed
                    ? Stack(children: [
                        Positioned.fill(child: _buildVideoArea()),
                        Positioned(
                            right: 0,
                            top: 0,
                            bottom: 0,
                            child: Center(child: _buildMembersBubble())),
                      ])
                    : Row(children: [
                        Expanded(flex: 3, child: _buildVideoArea()),
                        const SizedBox(width: 12),
                        SizedBox(width: 150, child: _buildUserList()),
                      ]),
              ),
      ),
      if (!isFullScreen) _buildControlBar(),
    ]);
  }

  /// 成员面板收起后的半透明小气泡条:叠加在视频区右缘之上,
  /// 右侧直角贴合边缘、左侧圆角,含向左箭头+人形图标+成员数,点击展开面板
  Widget _buildMembersBubble() {
    return GestureDetector(
      onTap: () => setState(() => membersCollapsed = false),
      child: Container(
        height: 32,
        padding: const EdgeInsets.only(left: 6, right: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.6),
          borderRadius:
              const BorderRadius.horizontal(left: Radius.circular(12)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.chevron_left, size: 16, color: Color(0xFF334155)),
          const SizedBox(width: 3),
          // 人形图标与成员数上下两行,宽度更窄
          Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.people_outline,
                    size: 14, color: Color(0xFF334155)),
                Text('${users.length}',
                    style: const TextStyle(
                        fontSize: 10,
                        height: 1.1,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF334155))),
              ]),
        ]),
      ),
    );
  }

  Widget _buildVideoArea() {
    final live = isSharing || isViewing;
    final radius = isFullScreen ? 0.0 : 20.0;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: const Color(0xFF0B1220),
        // 全屏时不能有描边与光晕:品牌蓝的边框/阴影会在画面外圈
        // 形成一圈蓝边(普通模式保留,用于标识"直播中")
        border: isFullScreen
            ? null
            : Border.all(
                color: live
                    ? _brand.withOpacity(0.55)
                    : const Color(0xFF1E293B),
                width: live ? 1.5 : 1),
        boxShadow: (live && !isFullScreen)
            ? [
                BoxShadow(
                    color: _brand.withOpacity(0.22),
                    blurRadius: 18,
                    offset: const Offset(0, 6))
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(children: [
          if (_renderersInitialized && live)
            Positioned.fill(
                child: GestureDetector(
                    onDoubleTap: () => _videoTransform.value =
                        Matrix4.identity(), // 双击复位缩放
                    child: InteractiveViewer(
                        transformationController: _videoTransform,
                        panEnabled: true,
                        minScale: 1.0,
                        maxScale: 5.0,
                        child: RotatedBox(
                            quarterTurns: _videoRotation,
                            child: RTCVideoView(
                                isSharing ? _localRenderer : _remoteRenderer,
                                objectFit: RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitContain))))),
          if (!_renderersInitialized || !live)
            Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(isSharing ? Icons.cast_connected : Icons.connected_tv,
                  size: 52, color: Colors.white24),
              const SizedBox(height: 12),
              Text(isSharing ? '正在等待观众加入…' : '等待屏幕共享…',
                  style: const TextStyle(color: Colors.white38, fontSize: 14)),
            ])),
          if (isSharing)
            Positioned(
                top: 12,
                left: 12,
                child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                              color: Color(0xFF4ADE80), shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      const Text('共享中',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                    ]))),
          Positioned(
              // 全屏时离屏幕边缘稍远:避开挖孔/手势区,保证按钮可点击
              top: isFullScreen ? 18 : 8,
              right: isFullScreen ? 18 : 8,
              child: Row(children: [
                // 旋转画面:每按一次顺时针 90°(0/90/180/270 循环)
                if (live)
                  Material(
                      color: Colors.black38,
                      borderRadius: BorderRadius.circular(20),
                      child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => setState(
                              () => _videoRotation = (_videoRotation + 1) % 4),
                          child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(Icons.rotate_right,
                                  color: Colors.white, size: 20)))),
                if (live) const SizedBox(width: 8),
                Material(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () {
                          setState(() => isFullScreen = !isFullScreen);
                          if (isFullScreen) {
                            // 真全屏:隐藏状态栏与导航栏(下滑可临时唤出)。
                            // SystemChrome 在部分系统会被覆盖,原生
                            // WindowInsetsController 是权威路径。
                            SystemChrome.setEnabledSystemUIMode(
                                SystemUiMode.manual,
                                overlays: []);
                            _channel
                                .invokeMethod('enterImmersive')
                                .catchError((_) => null);
                          } else {
                            // 退出全屏:复位旋转与缩放,恢复状态栏(黑色图标)
                            setState(() {
                              _videoRotation = 0;
                              _videoTransform.value = Matrix4.identity();
                            });
                            _exitFullScreenUi();
                          }
                        },
                        child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(
                                isFullScreen
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                                color: Colors.white,
                                size: 20)))),
              ])),
        ]),
      ),
    );
  }

  Widget _buildUserList() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 16,
              offset: const Offset(0, 6))
        ],
      ),
      child: Stack(children: [
        // 内容区:左侧留出收起把手的宽度
        Padding(
          padding: const EdgeInsets.fromLTRB(27, 12, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text('成员 · ${users.length}',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _sub))),
            Expanded(
                child: users.isEmpty
                    ? Center(
                        child: Text('暂无成员',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFFA6B2C4))))
                    // 显式 padding=0:去掉 ListView 隐式继承的 MediaQuery
                    // 安全区内边距(首个成员上方曾出现一段空白)
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        itemCount: users.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final user = users[index];
                          final nick = (user['nickname'] ?? '') as String;
                          final isSelf = nick == nickname;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                                color: const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(12)),
                            child: Row(children: [
                              Container(
                                  width: 30,
                                  height: 30,
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(
                                      color: _brand, shape: BoxShape.circle),
                                  child: Text(
                                      nick.isNotEmpty
                                          ? nick[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700))),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Text(nick,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: _ink))),
                              if (isSelf)
                                const Text('我',
                                    style: TextStyle(
                                        fontSize: 11, color: _sub)),
                            ]),
                          );
                        })),
          ]),
        ),
        // 收起把手:面板内部、贴左边缘、垂直居中(箭头向右=收起)
        Align(
          alignment: Alignment.centerLeft,
          child: Material(
            color: const Color(0xFFF1F5F9),
            borderRadius:
                const BorderRadius.horizontal(right: Radius.circular(14)),
            child: InkWell(
              borderRadius:
                  const BorderRadius.horizontal(right: Radius.circular(14)),
              onTap: () => setState(() => membersCollapsed = true),
              child: const SizedBox(
                  width: 15,
                  height: 32,
                  child: Icon(Icons.chevron_right,
                      size: 15, color: Color(0xFF94A3B8))),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildControlBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Color(0x140F172A), blurRadius: 20, offset: Offset(0, -6))
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: _brandLight,
                    borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.tag, size: 14, color: _brand),
                  const SizedBox(width: 2),
                  Text(roomId,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _brand)),
                ])),
            const Spacer(),
            _statusPill(),
          ]),
          if (isSharing) ...[
            const SizedBox(height: 10),
            SizedBox(
                height: 34,
                child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: kAudioModes.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final m = kAudioModes[index];
                      return _modeChip(m['value']!, _shortModeLabel(m['value']!),
                          onTap: () => setAudioMode(m['value']!));
                    })),
            const SizedBox(height: 8),
            SizedBox(
                height: 34,
                child: Row(children: [
                  const SizedBox(
                      width: 40,
                      child: Text('帧率',
                          style: TextStyle(fontSize: 12, color: _sub))),
                  const SizedBox(width: 4),
                  Expanded(
                      child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: kFpsTiers.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, index) =>
                              _fpsChip(kFpsTiers[index]))),
                ])),
            Padding(
                padding: const EdgeInsets.only(left: 44),
                child: Align(
                    alignment: Alignment.centerLeft, child: _fpsHint())),
            const SizedBox(height: 10),
            Row(children: [
              const SizedBox(
                  width: 40,
                  child: Text('声音',
                      style: TextStyle(fontSize: 12, color: _sub))),
              const SizedBox(width: 4),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _audioLevel,
                    minHeight: 8,
                    backgroundColor: const Color(0xFFE2E8F0),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF2563EB)),
                  ),
                ),
              ),
            ]),
            if ((audioMode == audioModeMixed ||
                    audioMode == audioModeScreen) &&
                !_screenCaptureAlive)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 14, color: Color(0xFFD97706)),
                    const SizedBox(width: 6),
                    const Expanded(
                        child: Text(
                            '屏幕内音无数据:正在播放的应用可能禁止了声音采集,或当前没有播放任何声音',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFFD97706)))),
                  ])),
          ],
          const SizedBox(height: 12),
          Row(children: [
            if (!isSharing)
              Expanded(
                  flex: 2,
                  child: _actionButton(
                      '分享屏幕', Icons.screen_share, _brand, startSharingFlow))
            else
              Expanded(
                  flex: 2,
                  child: _actionButton(
                      '停止共享', Icons.stop, const Color(0xFFEF4444), stopSharing)),
            const SizedBox(width: 10),
            if (isSharing &&
                (audioMode == audioModeMixed || audioMode == audioModeMic))
              Expanded(
                  flex: 2,
                  child: _actionButton(
                      isMicOn ? '关闭麦克风' : '开启麦克风',
                      isMicOn ? Icons.mic_off : Icons.mic,
                      isMicOn ? const Color(0xFFF59E0B) : const Color(0xFF94A3B8),
                      toggleMic)),
            const SizedBox(width: 10),
            Expanded(
                flex: 1,
                child: _actionButton('离开', Icons.logout,
                    const Color(0xFF64748B), leaveRoom)),
          ]),
        ]),
      ),
    );
  }
}
