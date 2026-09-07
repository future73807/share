<template>
  <div class="screen-share-container">
    <!-- 加入房间 -->
    <div v-if="!isInRoom" class="join-wrap">
      <div class="join-layout">
        <div class="join-hero">
          <div class="hero-icon">
            <svg viewBox="0 0 24 24" width="40" height="40" aria-hidden="true">
              <rect x="5.8" y="4.8" width="12.4" height="9.6" rx="0.9"
                    fill="none" stroke="currentColor" stroke-width="1.2"/>
              <rect x="8.2" y="8.5" width="3.8" height="2.2" rx="0.5" fill="currentColor"/>
              <polygon points="11.8,7.2 11.8,12 15.3,9.6" fill="currentColor"/>
              <polygon points="7.2,14.9 16.8,14.9 18.3,17.3 5.7,17.3" fill="currentColor"/>
            </svg>
          </div>
          <h1 class="hero-title">屏幕共享</h1>
          <p class="hero-sub">把手机或电脑屏幕,连同声音,实时分享给房间里的每一个人</p>
          <ul class="hero-feats">
            <li>手机 / 电脑画面互通</li>
            <li>屏幕内音、麦克风、混合三种声音模式</li>
            <li>硬件级回声抑制</li>
          </ul>
        </div>
        <div class="join-card">
        <div class="brand-header">
          <div class="brand-icon">
            <svg viewBox="0 0 24 24" width="26" height="26" aria-hidden="true">
              <rect x="5.8" y="4.8" width="12.4" height="9.6" rx="0.9"
                    fill="none" stroke="currentColor" stroke-width="1.3"/>
              <rect x="8.2" y="8.5" width="3.8" height="2.2" rx="0.5" fill="currentColor"/>
              <polygon points="11.8,7.2 11.8,12 15.3,9.6" fill="currentColor"/>
              <polygon points="7.2,14.9 16.8,14.9 18.3,17.3 5.7,17.3" fill="currentColor"/>
            </svg>
          </div>
          <div>
            <h2 class="brand-title">屏幕共享</h2>
            <p class="brand-sub">实时画面 · 声音共享</p>
          </div>
        </div>

        <label class="field-label" for="room">房间号</label>
        <div class="input-wrap">
          <Hash :size="17" class="input-icon" />
          <input id="room" v-model="roomId" type="text" placeholder="输入房间号" class="input-field">
        </div>

        <label class="field-label" for="nick">昵称</label>
        <div class="input-wrap">
          <User :size="17" class="input-icon" />
          <input id="nick" v-model="nickname" type="text" placeholder="输入你的昵称" class="input-field">
        </div>

        <label class="field-label" for="server">服务器地址</label>
        <div class="input-wrap">
          <Server :size="17" class="input-icon" />
          <input id="server" v-model="serverInput" type="text"
                 placeholder="默认服务器连不上时手输" class="input-field">
        </div>

        <button class="join-button" :disabled="!roomId || !nickname || isJoining" @click="joinRoom">
          <Loader2 v-if="isJoining" :size="18" class="spin" />
          <Users v-else :size="18" />
          {{ isJoining ? '连接中…' : '加入房间' }}
        </button>

        <div v-if="joinError" class="error-pill">
          <AlertCircle :size="16" />
          <span>{{ joinError }}</span>
        </div>
        </div>
      </div>
    </div>

    <!-- 会议室 -->
    <div v-else class="meeting-room">
      <div class="main-content">
        <div class="video-container" :class="[{ live: isSharing || isViewing }, isFsPreview ? 'fs-preview' : '' ]">
          <video ref="screenVideo" autoplay playsinline :muted="isSharing"></video>
          <div class="video-overlay" v-if="!isSharing && !isViewing">
            <MonitorUp :size="44" />
            <p>等待屏幕共享…</p>
          </div>
          <div class="live-badge" v-if="isSharing">
            <span class="live-dot"></span>共享中
          </div>
          <button class="fullscreen-btn" @click="enterFullscreen" title="全屏">
            <Maximize :size="16" />
          </button>
        </div>

        <div class="users-panel">
          <p class="users-title">成员 · {{ users.length }}</p>
          <div class="users-scroll">
            <div v-for="user in users" :key="user.socketId" class="user-row">
              <span class="avatar">{{ user.nickname.charAt(0).toUpperCase() }}</span>
              <span class="name">{{ user.nickname }}</span>
            </div>
          </div>
        </div>
      </div>

      <div class="bottom-toolbar">
        <div class="toolbar-top">
          <span class="room-chip"><Tag :size="13" /> {{ roomId }}</span>
          <span class="status-pill" :class="{ live: isSharing }">
            <span class="dot"></span>{{ isSharing ? '共享中' : '未共享' }}
          </span>
        </div>
        <div class="mode-chips scroll" v-if="isSharing">
          <button v-for="mode in audioModes" :key="mode.value" type="button"
                  class="mode-chip" :class="{ active: audioMode === mode.value }"
                  @click="setAudioMode(mode.value)">
            <component :is="mode.icon" :size="14" />
            {{ shortMode(mode.label) }}
          </button>
        </div>
        <div class="fps-row" v-if="isSharing">
          <span class="fps-row-label">帧率</span>
          <button v-for="f in fpsTiers" :key="f" type="button"
                  class="mode-chip fps-chip" :class="{ active: shareFps === f }"
                  @click="setFpsTier(f)">{{ f }}</button>
        </div>
        <p v-if="shareHint" class="share-hint">{{ shareHint }}</p>
        <div class="controls">
          <button v-if="!isSharing" @click="showModePicker = true" class="control-button share">
            <MonitorUp :size="18" /> 分享屏幕
          </button>
          <button v-else @click="stopSharing" class="control-button stop">
            <Square :size="15" /> 停止共享
          </button>
          <button v-if="isSharing && hasMicTrack" @click="toggleMic" class="control-button mic"
                  :class="{ off: !isMicOn }">
            <MicOff v-if="!isMicOn" :size="18" />
            <Mic v-else :size="18" />
            {{ isMicOn ? '关闭麦克风' : '开启麦克风' }}
          </button>
          <button @click="leaveRoom" class="control-button leave">
            <LogOut :size="18" /> 离开会议
          </button>
        </div>
      </div>
    </div>

    <!-- 共享声音选择(点击分享屏幕时弹出) -->
    <div v-if="showModePicker" class="picker-mask" @click.self="showModePicker = false">
      <div class="picker-card">
        <p class="picker-title">选择共享声音模式</p>
        <div class="fps-row">
          <span class="fps-row-label">帧率</span>
          <button v-for="f in fpsTiers" :key="'p' + f" type="button"
                  class="mode-chip fps-chip" :class="{ active: shareFps === f }"
                  @click="setFpsTier(f)">{{ f }}</button>
        </div>
        <button v-for="mode in audioModes" :key="mode.value" type="button"
                class="picker-option" :class="{ active: audioMode === mode.value }"
                @click="pickAndShare(mode.value)">
          <component :is="mode.icon" :size="18" />
          <span>{{ mode.label }}</span>
          <Check v-if="audioMode === mode.value" :size="16" class="check" />
        </button>
        <button type="button" class="picker-cancel" @click="showModePicker = false">取消</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { io } from 'socket.io-client'
import {
  MonitorUp, Hash, User, Server, Tag, Maximize,
  Square, Mic, MicOff, LogOut, VolumeX, AudioLines,
  Users, Loader2, AlertCircle, Check
} from 'lucide-vue-next'

// 状态变量
const roomId = ref(localStorage.getItem('roomId') || '')
const nickname = ref(localStorage.getItem('nickname') || '')
const isInRoom = ref(false)
const isSharing = ref(false)
const isViewing = ref(false)
const screenVideo = ref(null)
const users = ref([])
const isMicOn = ref(true)
const hasMicTrack = ref(false)
const isJoining = ref(false)
const joinError = ref('')
const showModePicker = ref(false)

// 服务器地址:?server= 参数 > 本机记录 > 同域 3000
const initialServerUrl = new URLSearchParams(window.location.search).get('server')
  || localStorage.getItem('serverUrl')
  || `${window.location.protocol}//${window.location.hostname}:3000`
const serverInput = ref(initialServerUrl)

// 声音分享模式: mixed=屏幕+麦克风, screen=仅屏幕内音, mic=仅麦克风, none=无声
const audioModes = [
  { value: 'mixed', label: '混合(屏幕+麦克风)', icon: AudioLines },
  { value: 'screen', label: '仅屏幕声音(不采集麦克风)', icon: MonitorUp },
  { value: 'mic', label: '仅麦克风', icon: Mic },
  { value: 'none', label: '无声', icon: VolumeX }
]
const audioMode = ref(localStorage.getItem('audioMode') || 'mixed')

// 帧率档位:编码发送上限(实际帧率受设备刷新率限制,档位只是天花板)。
// 共享中可热切换:采集轨 applyConstraints + 所有 sender setParameters,免重协商。
const fpsTiers = [60, 90, 120, 144, 165]
const shareFps = ref(((v) => (fpsTiers.includes(v) ? v : 60))(parseInt(localStorage.getItem('shareFps'), 10)))
// 码率随帧率走(只是上限,实际由带宽估计自适应):
// 上限码率=fps*120k(60→7.2M,165→19.8M 封顶 20M);SDP 起步码率=fps*50k(60→3M,165→8M 封顶)
const fpsBitrate = (fps) => Math.min(20000000, Math.max(7200000, fps * 120000))
const fpsStartBitrate = (fps) => Math.min(8000000, Math.max(3000000, fps * 50000))
// 共享中切换档位:采集节流跟随 + 更新全部已建立连接的发送参数
const setFpsTier = (fps) => {
  shareFps.value = fps
  localStorage.setItem('shareFps', String(fps))
  if (!isSharing.value) return
  const vtrack = screenStream && screenStream.getVideoTracks()[0]
  if (vtrack && vtrack.applyConstraints) {
    vtrack.applyConstraints({ frameRate: { ideal: fps, max: fps } }).catch(() => {})
  }
  peerConnections.forEach((pc) => applyVideoSenderParams(pc))
}

const shortMode = (label) => ({
  '混合(屏幕+麦克风)': '混合',
  '仅屏幕声音(不采集麦克风)': '屏幕声音',
  '仅麦克风': '麦克风',
  '无声': '无声'
}[label] || label)

// 全屏功能。
// 共享自己的屏幕时,本地预览播放的正是当前屏幕内容——对它调
// requestFullscreen 会引发合成器递归自捕获,浏览器直接卡死;
// 因此本地预览走 CSS 覆盖层全屏,只有观看远端流才用 Fullscreen API。
const isFsPreview = ref(false)
const exitFsPreview = () => { isFsPreview.value = false }
// 容器级全屏:对视频容器(而非 video 元素)调 Fullscreen API——
// 浏览器窗口的标签栏/地址栏/书签全部收起,只剩页面内容,
// 画面铺满整个显示器。共享自己的屏幕时(本地预览=当前屏幕内容,
// API 全屏会引发合成器递归自捕获卡死)降级为 CSS 覆盖层全屏。
const enterFullscreen = () => {
  // 已在全屏:再点退出(Esc 同效)
  if (document.fullscreenElement) {
    if (document.exitFullscreen) document.exitFullscreen()
    isFsPreview.value = false
    return
  }
  if (isSharing.value) {
    // 共享自己的屏幕:本地预览=当前屏幕内容,API 全屏会合成器递归自捕获卡死,
    // 降级 CSS 覆盖层全屏
    isFsPreview.value = !isFsPreview.value
    return
  }
  const el = document.querySelector('.video-container')
  if (!el) return
  const req = el.requestFullscreen || el.webkitRequestFullscreen || el.mozRequestFullScreen || el.msRequestFullscreen
  if (req) {
    Promise.resolve(req.call(el)).catch(() => { isFsPreview.value = true })
  } else {
    isFsPreview.value = true
  }
}
const onFsKeydown = (e) => {
  if (e.key === 'Escape') isFsPreview.value = false
}
window.addEventListener('keydown', onFsKeydown)
onUnmounted(() => window.removeEventListener('keydown', onFsKeydown))

// WebRTC 相关变量
let socket = null
let activeServerUrl = initialServerUrl
let screenStream = null // 屏幕共享流(视频+屏幕内音)
let micStream = null    // 麦克风流(带回声抑制)
let peerConnections = new Map()
const audioSenders = new Map()   // socketId -> RTCRtpSender(音频,切模式时 replaceTrack)
const remoteStreams = new Map() // socketId -> MediaStream(合成远端视频+音频)
const requestedStreams = new Set() // 已请求过流的共享者,防止重复请求
let audioCtx = null             // WebAudio 上下文(混音/静音轨)
let mixedDest = null            // 混合模式混音目标
let mixedSources = []           // 混音源节点(切模式时先断开旧的)
let silentDest = null           // 静音占位轨道(保证音频 m-line 恒存在,免重新协商)
let activeAudioTrack = null     // 当前应发布的音频轨道(随模式重建)

// 屏幕内音是否真的被浏览器捕获到(用户在浏览器弹窗里勾选"分享音频"才有)
const hasScreenAudio = ref(false)
// 面板内的临时提示(如"未捕获到系统声音")
const shareHint = ref('')
let shareHintTimer = null
const showHint = (text) => {
  shareHint.value = text
  if (shareHintTimer) clearTimeout(shareHintTimer)
  shareHintTimer = setTimeout(() => { shareHint.value = '' }, 6000)
}

const ensureAudioCtx = () => {
  if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)()
  if (audioCtx.state === 'suspended') audioCtx.resume().catch(() => {})
  return audioCtx
}

// 静音占位轨:无声音模式也保留音频 m-line,切模式 replaceTrack 即可,无需重新协商
const ensureSilentTrack = () => {
  const ctx = ensureAudioCtx()
  if (!silentDest) {
    silentDest = ctx.createMediaStreamDestination()
    const src = ctx.createConstantSource()
    const gain = ctx.createGain()
    gain.gain.value = 0
    src.connect(gain)
    gain.connect(silentDest)
    src.start()
  }
  return silentDest.stream.getAudioTracks()[0]
}

// 按当前模式计算应发布的音频轨道(网上标准做法):
//  - 仅屏幕声音:仅 getDisplayMedia 捕获的系统音,绝不碰麦克风;
//  - 混合:系统音 + 麦克风经 WebAudio 混成单轨(部分观众端只播第一条音轨,
//    双轨分发会导致只有一路出声);
//  - 仅麦克风 / 无声:对应轨道或静音占位。
const buildAudioTrack = () => {
  const mode = audioMode.value
  const displayTrack = screenStream ? (screenStream.getAudioTracks()[0] || null) : null
  const micTrack = (micStream && isMicOn.value) ? (micStream.getAudioTracks()[0] || null) : null
  if (mode === 'none') return null
  if (mode === 'mic') return micTrack
  if (mode === 'screen') return displayTrack
  // mixed:统一经 mixedDest 输出(关闭麦克风后单源也重连,确保旧源一定被断开)
  const ctx = ensureAudioCtx()
  if (!mixedDest) mixedDest = ctx.createMediaStreamDestination()
  mixedSources.forEach(node => { try { node.disconnect() } catch (_) {} })
  mixedSources = []
  const sources = [displayTrack, micTrack].filter(Boolean)
  if (sources.length === 0) return null
  mixedSources = sources.map(t => {
    const node = ctx.createMediaStreamSource(new MediaStream([t]))
    node.connect(mixedDest)
    return node
  })
  return mixedDest.stream.getAudioTracks()[0]
}

// 重算当前音频轨并替换到所有已有连接(免重新协商)
const refreshPublishedAudio = () => {
  activeAudioTrack = buildAudioTrack()
  peerConnections.forEach((pc, socketId) => {
    const sender = audioSenders.get(socketId)
    if (sender) {
      sender.replaceTrack(activeAudioTrack || ensureSilentTrack()).catch(err => {
        console.warn('replaceTrack 失败:', err)
      })
    }
  })
}

// 麦克风约束:开启回声抑制/噪声抑制/自动增益,避免扬声器声音被麦克风二次采集造成回音
const micConstraints = {
  audio: {
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
    channelCount: 1
  }
}

// 初始化 Socket.IO 连接(地址变化时由 joinRoom 重建)
const initializeSocket = (url) => {
  activeServerUrl = url || activeServerUrl
  socket = io(activeServerUrl, { transports: ['websocket', 'polling'] })
  // 调试钩子:便于自动化测试检查连接状态
  if (typeof window !== 'undefined') {
    window.__ss = {
      socket, peerConnections, remoteStreams, setFps: setFpsTier,
      state: () => ({
        isInRoom: isInRoom.value, isJoining: isJoining.value,
        joinError: joinError.value, isSharing: isSharing.value
      })
    }
  }

  socket.on('connect', () => {
    console.log('Connected to server')
    joinError.value = ''
  })

  socket.on('connect_error', () => {
    joinError.value = `无法连接 ${activeServerUrl},请检查服务器地址和网络`
  })

  socket.on('room-users', (data) => {
    users.value = data.users
  })

  socket.on('user-joined', async (data) => {
    console.log(`${data.nickname} joined the room`)
    users.value.push({
      socketId: data.socketId,
      nickname: data.nickname
    })
    if (isSharing.value) {
      if (data.client === 'flutter') {
        // Flutter 观看者:请其发送 Offer(手机作为 ICE 控制端)
        socket.emit('accept-stream', { to: data.socketId })
      } else {
        await createOfferTo(data.socketId)
      }
    }
  })

  // 有人开始共享:非共享者主动请求流(覆盖"观看者先入房,共享者后开始共享"的场景)
  socket.on('share-started', async (data) => {
    if (!isSharing.value && data.from && data.from !== socket.id) {
      if (!requestedStreams.has(data.from)) {
        requestedStreams.add(data.from)
        socket.emit('request-stream', { to: data.from })
      }
    }
  })

  // 共享者收到拉流请求:
  //  - Flutter(手机)观看者:通知其发送 Offer(手机作为 ICE 控制端,提升 NAT 穿透成功率)
  //  - Web 观看者:直接发送 Offer
  socket.on('request-stream', async (data) => {
    if (!isSharing.value) return
    if (data.clientType === 'flutter') {
      socket.emit('accept-stream', { to: data.from })
    } else {
      await createOfferTo(data.from)
    }
  })

  // 观看者收到 accept-stream:创建接收型收发器并发送 Offer
  socket.on('accept-stream', async (data) => {
    if (isSharing.value) return
    const from = data.from
    const peerConnection = createPeerConnection(from)
    if (peerConnection.signalingState !== 'stable') return
    peerConnection.addTransceiver('video', { direction: 'recvonly' })
    peerConnection.addTransceiver('audio', { direction: 'recvonly' })
    try {
      const offer = await peerConnection.createOffer()
      await peerConnection.setLocalDescription(offer)
      socket.emit('offer', { offer, to: from })
    } catch (error) {
      console.error('Error creating viewer offer:', error)
    }
  })

  socket.on('offer', async (data) => {
    // 共享者也可能收到观看者的 recvonly Offer(Flutter 观看者主动 Offer 模式),需正常应答
    const from = data.from
    const peerConnection = createPeerConnection(from)
    try {
      await peerConnection.setRemoteDescription(data.offer)
      // 共享者应答:发送编码走 H264 硬编优先(与主动 Offer 一致)
      if (isSharing.value) preferHardwareVideoCodecs(peerConnection)
      const answer = await peerConnection.createAnswer()
      // 共享者的 Answer 含发送编码,同样提速起步码率
      const sdp = isSharing.value ? boostVideoStartBitrate(answer.sdp) : answer.sdp
      const boosted = { type: answer.type, sdp }
      await peerConnection.setLocalDescription(boosted)
      socket.emit('answer', {
        answer: boosted,
        to: from
      })
    } catch (error) {
      console.error('Error handling offer:', error)
    }
  })

  socket.on('answer', async (data) => {
    const peerConnection = peerConnections.get(data.from)
    if (peerConnection) {
      try {
        await peerConnection.setRemoteDescription(data.answer)
      } catch (error) {
        console.error('Error handling answer:', error)
      }
    }
  })

  socket.on('ice-candidate', async (data) => {
    const peerConnection = peerConnections.get(data.from)
    if (peerConnection && data.candidate) {
      try {
        await peerConnection.addIceCandidate(data.candidate)
      } catch (error) {
        console.error('Error adding ice candidate:', error)
      }
    }
  })

  // 有人停止共享:清理对应连接与远端画面,并允许其下次共享时再次请求
  socket.on('share-stopped', (data) => {
    const from = data.from
    if (from) requestedStreams.delete(from)
    const cleanPeer = (socketId) => {
      const pc = peerConnections.get(socketId)
      if (pc) {
        pc.close()
        peerConnections.delete(socketId)
      }
      remoteStreams.delete(socketId)
    }
    if (from && from !== socket.id) {
      cleanPeer(from)
    } else {
      peerConnections.forEach(pc => pc.close())
      peerConnections.clear()
      remoteStreams.clear()
    }
    if (remoteStreams.size === 0 && isViewing.value) {
      isViewing.value = false
      if (screenVideo.value) {
        screenVideo.value.srcObject = null
      }
    }
  })

  socket.on('user-left', (data) => {
    const peerConnection = peerConnections.get(data.socketId)
    if (peerConnection) {
      peerConnection.close()
      peerConnections.delete(data.socketId)
    }
    remoteStreams.delete(data.socketId)
    if (remoteStreams.size === 0 && isViewing.value) {
      isViewing.value = false
      if (screenVideo.value) {
        screenVideo.value.srcObject = null
      }
    }

    users.value = users.value.filter(user => user.socketId !== data.socketId)
  })
}

// 等待连接建立
const waitForConnected = (timeout) => new Promise(resolve => {
  const start = Date.now()
  const timer = setInterval(() => {
    if (socket && socket.connected) {
      clearInterval(timer)
      resolve(true)
    } else if (Date.now() - start > timeout) {
      clearInterval(timer)
      resolve(false)
    }
  }, 250)
})

// SDP 起步码率提速:给 m=video 段的编码格式追加 x-google-start/min-bitrate。
// 编码器默认 ~300kbps 起步、需数秒爬升,爬升期的模糊会被感知为"卡/糊";
// 起步值随帧率档位走(60fps→3M,120→6M,165→8M 封顶),消除爬升窗口。
const boostVideoStartBitrate = (sdp) => {
  const extra = `x-google-start-bitrate=${fpsStartBitrate(shareFps.value)};x-google-min-bitrate=1200`
  try {
    const newline = sdp.includes('\r\n') ? '\r\n' : '\n'
    const lines = sdp.split(/\r?\n/)
    const out = []
    let inVideo = false
    let fmtpDone = false
    for (const line of lines) {
      if (line.startsWith('m=')) inVideo = line.startsWith('m=video')
      if (inVideo) {
        const fmtp = line.match(/^a=fmtp:(\d+)(.*)$/)
        if (fmtp) {
          fmtpDone = true
          const rest = fmtp[2]
          if (!rest.includes('x-google-start-bitrate')) {
            out.push(rest.trim()
              ? `a=fmtp:${fmtp[1]}${rest};${extra}`
              : `a=fmtp:${fmtp[1]} ${extra}`)
            continue
          }
        } else if (!fmtpDone) {
          // 无 fmtp 行(如 VP8):在第一个视频 rtpmap 后补一行
          const pt = line.match(/^a=rtpmap:(\d+) [^ ]+\/90000/)
          if (pt) {
            out.push(line)
            out.push(`a=fmtp:${pt[1]} ${extra}`)
            fmtpDone = true
            continue
          }
        }
      }
      out.push(line)
    }
    return out.join(newline)
  } catch (_) {
    return sdp
  }
}

// 对一条连接的视频 sender 应用当前档位的发送参数(建连与切档共用)
const applyVideoSenderParams = (peerConnection) => {
  try {
    const vsender = peerConnection.getSenders().find(s => s.track && s.track.kind === 'video')
    if (!vsender) return
    const p = vsender.getParameters()
    p.encodings = p.encodings && p.encodings.length ? p.encodings : [{}]
    p.encodings[0].maxBitrate = fpsBitrate(shareFps.value)
    p.encodings[0].maxFramerate = shareFps.value
    p.degradationPreference = 'maintain-resolution'
    vsender.setParameters(p).catch(() => {})
  } catch (_) {}
}

// 编解码偏好:H264(硬件编码)优先。屏幕内容 VP8 软编(libvpx)吞吐
// 只有 20-30fps@2.5K,是高帧率的首要瓶颈;H264 走 GPU/MediaCodec 硬编。
// 仅重排序、不剔除,对端不支持 H264 时仍可回退 VP8。
const preferHardwareVideoCodecs = (peerConnection) => {
  try {
    const caps = RTCRtpSender.getCapabilities && RTCRtpSender.getCapabilities('video')
    if (!caps || !caps.codecs) return
    const score = (c) => {
      const m = (c.mimeType || '').toLowerCase()
      if (m === 'video/h264') return 0
      if (m === 'video/vp8') return 1
      return 2
    }
    const sorted = [...caps.codecs].sort((a, b) => score(a) - score(b))
    peerConnection.getTransceivers().forEach(t => {
      try {
        if (t.sender && t.sender.track && t.sender.track.kind === 'video' && t.setCodecPreferences) {
          t.setCodecPreferences(sorted)
        }
      } catch (_) {}
    })
  } catch (_) {}
}

// 向指定用户创建对等连接并发送 Offer(共享者侧)
const createOfferTo = async (socketId) => {
  const peerConnection = createPeerConnection(socketId)
  // 已在协商中则跳过,避免重复 Offer 造成 answer 竞态
  if (peerConnection.signalingState === 'have-local-offer') {
    return
  }
  try {
    preferHardwareVideoCodecs(peerConnection)
    const offer = await peerConnection.createOffer()
    const boosted = { type: offer.type, sdp: boostVideoStartBitrate(offer.sdp) }
    await peerConnection.setLocalDescription(boosted)
    socket.emit('offer', {
      offer: boosted,
      to: socketId
    })
  } catch (error) {
    console.error('Error creating offer:', error)
  }
}

// 创建 WebRTC 对等连接
const createPeerConnection = (socketId) => {
  // 已有连接则复用,避免重复协商
  const existing = peerConnections.get(socketId)
  if (existing) {
    return existing
  }

  const peerConnection = new RTCPeerConnection({
    iceServers: [
      { urls: 'stun:stun.l.google.com:19302' },
      { urls: 'stun:stun.miwifi.com:3478' } // 国内可达,提升 ICE 成功率
    ]
  })

  peerConnection.oniceconnectionstatechange = () => {
    console.log('ICE state:', socketId, peerConnection.iceConnectionState)
  }

  peerConnection.onicecandidate = (event) => {
    if (event.candidate) {
      socket.emit('ice-candidate', {
        candidate: event.candidate,
        to: socketId
      })
    }
  }

  // 发布本地轨道:屏幕视频 + 单一音频轨(混合模式=WebAudio 混音后的轨道;
  // 无声模式用静音轨占位,保证切模式时 replaceTrack 即可,无需重新协商)
  const videoTrack = screenStream ? screenStream.getVideoTracks()[0] : null
  if (videoTrack) {
    peerConnection.addTrack(videoTrack, screenStream)
  }
  const publishAudio = activeAudioTrack || ensureSilentTrack()
  audioSenders.set(
    socketId,
    peerConnection.addTrack(publishAudio, new MediaStream([publishAudio]))
  )

  // 屏幕共享发送参数:固定分辨率(maintain-resolution,只降帧不降分辨率)
  // + 足量码率 + 所选帧率档,消除分辨率泵动导致的闪烁、模糊与延迟
  applyVideoSenderParams(peerConnection)

  // 接收远端轨道:合成到同一 MediaStream,视频+多路音频一起播放
  peerConnection.ontrack = (event) => {
    // 低延迟:压缩接收端抖动缓冲目标(自适应默认可达数百毫秒)。
    // 视频尽快渲染(0 = 尽量低),音频留 40ms 防抖;单位为秒。
    // 屏幕内容偶发花屏/丢帧可接受(局域网重传一个 RTT 内恢复)。
    const recv = event.receiver
    if (recv) {
      const target = event.track.kind === 'video' ? 0 : 0.04
      try {
        if ('jitterBufferTarget' in recv) recv.jitterBufferTarget = target
        else if ('playoutDelayHint' in recv) recv.playoutDelayHint = target
      } catch (_) {}
    }
    let remote = remoteStreams.get(socketId)
    if (!remote) {
      remote = new MediaStream()
      remoteStreams.set(socketId, remote)
    }
    event.streams[0].getTracks().forEach(track => {
      if (!remote.getTracks().some(t => t.id === track.id)) {
        remote.addTrack(track)
      }
    })
    if (screenVideo.value && !isSharing.value) {
      // 共享者本地预览播放的是采集流,不能被观众回传的(可能仅音频的)
      // 远端流覆盖——只有观看者才把远端流接到 video 元素上
      screenVideo.value.srcObject = remote
      isViewing.value = true
  }
  }

  peerConnections.set(socketId, peerConnection)
  return peerConnection
}

// 加入房间
const joinRoom = async () => {
  if (!roomId.value || !nickname.value || isJoining.value) return
  isJoining.value = true
  joinError.value = ''
  let url = (serverInput.value || initialServerUrl).trim()
  if (!/^https?:\/\//.test(url)) url = `http://${url}`
  url = url.replace(/\/+$/, '')

  localStorage.setItem('roomId', roomId.value)
  localStorage.setItem('nickname', nickname.value)
  localStorage.setItem('audioMode', audioMode.value)
  localStorage.setItem('serverUrl', url)

  // 地址变化或未连接:按新地址重建 socket(失败可改地址重试)
  if (!socket || !socket.connected || url !== activeServerUrl) {
    initializeSocket(url)
  }
  const ok = await waitForConnected(8000)
  if (!ok) {
    isJoining.value = false
    joinError.value = `无法连接 ${url},请检查服务器地址和网络`
    return
  }
  socket.emit('join-room', {
    roomId: roomId.value,
    nickname: nickname.value,
    client: 'web'
  })
  isInRoom.value = true
  isJoining.value = false
}

// 离开房间
const leaveRoom = async () => {
  if (isSharing.value) {
    await stopSharing()
  }
  socket.disconnect()
  isInRoom.value = false
  isViewing.value = false
  roomId.value = ''
  nickname.value = ''
  // 清除localStorage
  localStorage.removeItem('roomId')
  localStorage.removeItem('nickname')
}

// 获取屏幕共享流(视频+可选屏幕内音)
const getScreenStream = async () => {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
    throw new Error('当前浏览器不支持屏幕共享功能')
  }
  const wantScreenAudio = audioMode.value === 'mixed' || audioMode.value === 'screen'
  try {
    return await navigator.mediaDevices.getDisplayMedia({
      // 采集节流跟随所选帧率档(高刷屏才能给到高于刷新率的值,取 min)
      video: { frameRate: { ideal: shareFps.value, max: shareFps.value } },
      audio: wantScreenAudio ? {
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false
      } : false
    })
  } catch (err) {
    if (wantScreenAudio && err && err.name === 'NotSupportedError') {
      // 部分浏览器/平台不支持屏幕内音采集,降级为无声共享
      return await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false })
    }
    throw err
  }
}

// 获取麦克风流(带回声抑制)
const getMicStream = async () => {
  try {
    return await navigator.mediaDevices.getUserMedia(micConstraints)
  } catch (err) {
    console.warn('麦克风获取失败,继续无声共享:', err)
    return null
  }
}

// 共享中切换声音模式:重算应发布的音频轨并 replaceTrack(即时生效,免重协商)
const setAudioMode = async (mode) => {
  audioMode.value = mode
  localStorage.setItem('audioMode', mode)
  if (!isSharing.value) return
  // 混合模式需要麦克风;从仅屏幕声音/无声切过来时补采(浏览器会弹授权)
  if (mode === 'mixed' && !micStream) {
    micStream = await getMicStream()
  }
  hasMicTrack.value = !!(micStream && micStream.getAudioTracks().length > 0)
  if ((mode === 'screen' || mode === 'mixed') && !hasScreenAudio.value) {
    showHint('未捕获到系统声音:发起共享时需在浏览器弹窗勾选“分享音频”,且共享整个屏幕才有系统音(共享单个标签页只有该标签页的声音)')
  }
  refreshPublishedAudio()
}

const toggleMic = () => {
  if (micStream && micStream.getAudioTracks().length > 0) {
    isMicOn.value = !isMicOn.value
    refreshPublishedAudio()
  }
}

const pickAndShare = (mode) => {
  showModePicker.value = false
  startSharing(mode)
}

const startSharing = async (mode) => {
  try {
    // 共享开始时确定声音模式(加入房间时无需预选)
    if (mode) {
      audioMode.value = mode
      localStorage.setItem('audioMode', mode)
    }
    isMicOn.value = true
    const wantScreenAudio = audioMode.value === 'mixed' || audioMode.value === 'screen'
    screenStream = await getScreenStream()
    // 帧率优先:告知编码器画面偏运动,掉帧前不牺牲流畅度
    const vtrack = screenStream.getVideoTracks()[0]
    if (vtrack && 'contentHint' in vtrack) vtrack.contentHint = 'motion'
    // 检测屏幕内音是否真的被捕获(浏览器弹窗勾选"分享音频"才有音轨)
    hasScreenAudio.value = screenStream.getAudioTracks().length > 0
    if (wantScreenAudio && !hasScreenAudio.value) {
      showHint('未捕获到系统声音:浏览器弹窗中需勾选“分享音频”,共享整个屏幕才有系统音')
    }
    // 麦克风按需采集(混合/仅麦克风模式);仅屏幕声音绝不碰麦克风
    if (audioMode.value === 'mixed' || audioMode.value === 'mic') {
      micStream = await getMicStream()
    }
    hasMicTrack.value = !!(micStream && micStream.getAudioTracks().length > 0)

    if (screenVideo.value) {
      screenVideo.value.srcObject = screenStream
    }
    // 本地预览静音:防止捕获的屏幕声音从扬声器回放后被麦克风二次采集产生回音
    if (screenVideo.value) {
      screenVideo.value.muted = true
    }
    activeAudioTrack = buildAudioTrack()

    // 用户点击浏览器"停止共享"条时自动结束
    screenStream.getVideoTracks()[0].onended = () => {
      stopSharing()
    }

    isSharing.value = true
    socket.emit('start-sharing')
  } catch (error) {
    releaseLocalStreams()
    alert('屏幕共享启动失败：' + error.message)
    console.error('Error starting screen share:', error)
  }
}

// 停止屏幕共享
const stopSharing = async () => {
  releaseLocalStreams()
  isFsPreview.value = false

  if (screenVideo.value) {
    screenVideo.value.srcObject = null
  }

  peerConnections.forEach(connection => {
    connection.close()
  })
  peerConnections.clear()

  isSharing.value = false
  hasMicTrack.value = false
  socket.emit('stop-sharing')
}

const releaseLocalStreams = () => {
  if (screenStream) {
    screenStream.getTracks().forEach(track => track.stop())
    screenStream = null
  }
  if (micStream) {
    micStream.getTracks().forEach(track => track.stop())
    micStream = null
  }
  // 清理 WebAudio 混音状态
  mixedSources.forEach(node => { try { node.disconnect() } catch (_) {} })
  mixedSources = []
  mixedDest = null
  activeAudioTrack = null
}

// 组件挂载时初始化 Socket 连接
onMounted(() => {
  initializeSocket()
  // 自动重连
  const savedRoomId = localStorage.getItem('roomId')
  const savedNickname = localStorage.getItem('nickname')
  if (savedRoomId && savedNickname) {
    roomId.value = savedRoomId
    nickname.value = savedNickname
    joinRoom()
    return
  }
  // 观看链接:?autoviewer=房间号 —— 打开即以随机昵称自动入房观看
  const autoViewer = new URLSearchParams(window.location.search).get('autoviewer')
  if (autoViewer) {
    roomId.value = autoViewer
    nickname.value = 'Viewer-' + Math.random().toString(36).slice(2, 6)
    joinRoom()
  }
})

// 组件卸载时清理资源
onUnmounted(() => {
  if (socket) {
    socket.disconnect()
  }
  releaseLocalStreams()
  peerConnections.forEach(connection => {
    connection.close()
  })
  peerConnections.clear()
})
</script>

<style scoped>
.screen-share-container {
  min-height: 100vh;
  background-color: #F1F5F9;
  color: #0F172A;
}

/* ── 加入页 ── */
.join-wrap {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px 16px;
}
.join-layout {
  width: 100%;
  max-width: 420px;
  display: flex;
  flex-direction: column;
}
/* 窄屏:与手机端一致——顶部品牌头(Logo+标题+副标题),无大 hero */
.join-hero {
  display: none;
}
.join-card {
  width: 100%;
  background: #fff;
  border-radius: 20px;
  padding: 28px 24px;
  box-shadow: 0 8px 30px rgba(15, 23, 42, 0.07);
}
/* 桌面:左右分栏,铺满利用宽度 */
@media (min-width: 960px) {
  .join-wrap {
    padding: 40px 64px;
  }
  .join-layout {
    max-width: none;
    flex-direction: row;
    align-items: center;
    gap: 72px;
  }
  .join-hero {
    display: block;
  }
  .join-hero {
    flex: 1.1;
    padding-right: 24px;
  }
  .hero-icon {
    width: 64px;
    height: 64px;
    border-radius: 18px;
  }
  .hero-title {
    font-size: 40px;
    font-weight: 800;
    color: #0F172A;
    margin: 18px 0 8px;
  }
  .hero-sub {
    font-size: 16px;
    color: #64748B;
    margin: 0 0 26px;
  }
  .hero-feats {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .hero-feats li {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 15px;
    color: #334155;
  }
  .hero-feats li svg {
    color: #2563EB;
    flex: none;
  }
  .join-card {
    flex: 1;
    max-width: 460px;
    padding: 34px 32px;
  }
}
.brand-header {
  display: flex;
  align-items: center;
  gap: 14px;
  margin-bottom: 22px;
}
.brand-icon, .hero-icon {
  background: #2563EB;
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  flex: none;
}
.brand-icon {
  width: 48px;
  height: 48px;
  border-radius: 14px;
  background: #2563EB;
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  flex: none;
}
.brand-title {
  font-size: 22px;
  font-weight: 800;
  color: #0F172A;
  margin: 0;
  line-height: 1.2;
}
.brand-sub {
  font-size: 13px;
  color: #64748B;
  margin: 2px 0 0;
}
.field-label {
  display: block;
  font-size: 13px;
  font-weight: 600;
  color: #64748B;
  margin: 14px 0 6px;
}
.input-wrap {
  position: relative;
}
.input-icon {
  position: absolute;
  left: 12px;
  top: 50%;
  transform: translateY(-50%);
  color: #94A3B8;
}
.input-field {
  width: 100%;
  box-sizing: border-box;
  padding: 12px 14px 12px 38px;
  border: 1px solid #E2E8F0;
  border-radius: 12px;
  background: #F8FAFC;
  font-size: 14px;
  color: #0F172A;
  outline: none;
  transition: border-color 0.15s, background 0.15s;
}
.input-field:focus {
  border-color: #2563EB;
  background: #fff;
}
.mode-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.mode-chips.scroll {
  overflow-x: auto;
  margin-top: 10px;
  flex-wrap: nowrap;
  padding-bottom: 2px;
}
.fps-row {
  display: flex;
  align-items: center;
  gap: 6px;
  overflow-x: auto;
  margin-top: 10px;
  padding-bottom: 2px;
}
.fps-row-label {
  flex: none;
  font-size: 12px;
  font-weight: 600;
  color: #64748B;
}
.fps-chip {
  flex: none;
  min-width: 44px;
  justify-content: center;
}
.share-hint {
  margin: 6px 0 0;
  font-size: 12px;
  line-height: 1.5;
  color: #D97706;
}
.mode-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 12px;
  border-radius: 10px;
  border: 1px solid #E2E8F0;
  background: #F8FAFC;
  color: #475569;
  font-size: 13px;
  cursor: pointer;
  white-space: nowrap;
  transition: border-color 0.15s, color 0.15s;
}
.mode-chip.active {
  background: #EFF6FF;
  border-color: #2563EB;
  color: #2563EB;
  font-weight: 600;
}
.join-button {
  width: 100%;
  height: 48px;
  margin-top: 22px;
  background: #2563EB;
  color: #fff;
  border: none;
  border-radius: 12px;
  font-size: 15px;
  font-weight: 700;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  transition: background 0.15s;
}
.join-button:hover {
  background: #1D4ED8;
}
.join-button:disabled {
  background: #CBD5E1;
  cursor: not-allowed;
}
.error-pill {
  margin-top: 14px;
  padding: 10px 14px;
  background: #FEF2F2;
  border: 1px solid #FECACA;
  border-radius: 10px;
  color: #B91C1C;
  font-size: 13px;
  display: flex;
  align-items: center;
  gap: 8px;
}
.spin {
  animation: spin 0.9s linear infinite;
}
.picker-mask {
  position: fixed;
  inset: 0;
  background: rgba(15, 23, 42, 0.45);
  z-index: 50;
  display: flex;
  align-items: flex-end;
  justify-content: center;
}
.picker-card {
  width: 100%;
  max-width: 420px;
  background: #fff;
  border-radius: 20px 20px 0 0;
  padding: 18px 14px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.picker-title {
  text-align: center;
  font-size: 16px;
  font-weight: 700;
  color: #0F172A;
  margin: 0 0 10px;
}
.picker-option {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 13px 14px;
  border: none;
  background: transparent;
  border-radius: 12px;
  font-size: 15px;
  color: #0F172A;
  cursor: pointer;
  text-align: left;
}
.picker-option:hover {
  background: #F1F5F9;
}
.picker-option.active {
  color: #2563EB;
  font-weight: 700;
}
.picker-option .check {
  margin-left: auto;
  color: #2563EB;
}
.picker-cancel {
  margin-top: 8px;
  height: 44px;
  border: none;
  border-radius: 12px;
  background: #F1F5F9;
  color: #475569;
  font-size: 14px;
  cursor: pointer;
}
@keyframes spin {
  to { transform: rotate(360deg); }
}

/* ── 会议室 ── */
.meeting-room {
  height: 100vh;
  display: flex;
  flex-direction: column;
}
.main-content {
  flex: 1;
  display: flex;
  /* 铺满全屏:视频区顶到屏幕边缘,无内边距 */
  padding: 0;
  gap: 0;
  min-height: 0;
}
.video-container {
  flex: 1;
  background: #0B1220;
  border-radius: 0;
  position: relative;
  overflow: hidden;
  border: none;
  min-height: 0;
  min-width: 0;
}
.video-container.live {
  border-color: transparent;
}
video {
  width: 100%;
  height: 100%;
  object-fit: contain;
}
.video-overlay {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  color: rgba(255, 255, 255, 0.35);
}
.video-overlay p {
  margin: 0;
  font-size: 14px;
}
.live-badge {
  position: absolute;
  top: 12px;
  left: 12px;
  display: flex;
  align-items: center;
  gap: 6px;
  background: rgba(0, 0, 0, 0.4);
  color: #fff;
  font-size: 12px;
  font-weight: 600;
  padding: 5px 10px;
  border-radius: 999px;
}
.live-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: #4ADE80;
}
.fullscreen-btn {
  position: absolute;
  top: 10px;
  right: 10px;
  width: 36px;
  height: 36px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.4);
  color: #fff;
  border: none;
  border-radius: 999px;
  cursor: pointer;
}
.fullscreen-btn:hover {
  background: rgba(0, 0, 0, 0.6);
}
.video-container.fs-preview {
  position: fixed;
  inset: 0;
  z-index: 2000;
  border-radius: 0;
}
.video-container:fullscreen {
  width: 100vw;
  height: 100vh;
}
.video-container:fullscreen video {
  width: 100%;
  height: 100%;
  object-fit: contain;
}
.users-panel {
  width: 220px;
  flex: none;
  background: #fff;
  border-radius: 0;
  border-left: 1px solid #E2E8F0;
  padding: 14px;
  display: flex;
  flex-direction: column;
  min-height: 0;
}
.users-title {
  font-size: 13px;
  font-weight: 700;
  color: #64748B;
  margin: 0 0 10px 4px;
}
.users-scroll {
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.user-row {
  display: flex;
  align-items: center;
  gap: 8px;
  background: #F8FAFC;
  border-radius: 10px;
  padding: 7px 9px;
}
.avatar {
  width: 30px;
  height: 30px;
  border-radius: 50%;
  background: #2563EB;
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  font-weight: 700;
  flex: none;
}
.name {
  font-size: 13px;
  font-weight: 600;
  color: #0F172A;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.bottom-toolbar {
  background: #fff;
  border-radius: 20px 20px 0 0;
  padding: 12px 18px 14px;
  box-shadow: 0 -6px 20px rgba(15, 23, 42, 0.06);
}
.toolbar-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.room-chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  background: #EFF6FF;
  color: #2563EB;
  font-size: 13px;
  font-weight: 700;
  padding: 5px 11px;
  border-radius: 999px;
}
.status-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  font-weight: 600;
  color: #94A3B8;
  background: #F1F5F9;
  padding: 5px 11px;
  border-radius: 999px;
}
.status-pill.live {
  color: #16A34A;
  background: #F0FDF4;
}
.status-pill .dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: currentColor;
}
.controls {
  display: flex;
  gap: 10px;
  margin-top: 12px;
}
.control-button {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 7px;
  height: 46px;
  padding: 0 18px;
  border: none;
  border-radius: 12px;
  color: #fff;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.15s;
}
.control-button.share {
  flex: 1;
  background: #2563EB;
}
.control-button.share:hover {
  background: #1D4ED8;
}
.control-button.stop {
  flex: 1;
  background: #EF4444;
}
.control-button.stop:hover {
  background: #DC2626;
}
.control-button.mic {
  flex: 1;
  background: #F59E0B;
}
.control-button.mic:hover {
  background: #D97706;
}
.control-button.mic.off {
  background: #94A3B8;
}
.control-button.leave {
  background: #64748B;
  flex: none;
  min-width: 118px;
}
.control-button.leave:hover {
  background: #475569;
}

/* ── 移动端 ── */
@media (max-width: 800px) {
  .main-content {
    flex-direction: column;
    padding: 0;
    gap: 0;
  }
  /* 参考手机端:视频占满剩余高度,成员列表收成横向紧凑条 */
  .video-container {
    flex: 1;
    min-height: 0;
  }
  .users-panel {
    width: 100%;
    flex: none;
    max-height: 118px;
    border-left: none;
    border-top: 1px solid #E2E8F0;
    padding: 8px 14px 10px;
  }
  .users-title {
    margin: 0 0 6px 2px;
  }
  .users-scroll {
    flex-direction: row;
    overflow-x: auto;
    overflow-y: hidden;
    gap: 8px;
    align-items: center;
  }
  .user-row {
    flex: none;
    width: auto;
  }
  .bottom-toolbar {
    padding: 10px 12px 12px;
  }
  .controls {
    flex-wrap: wrap;
  }
  .control-button {
    flex: 1 1 auto;
    padding: 0 12px;
    font-size: 13px;
  }
  .control-button.leave {
    min-width: 96px;
  }
}
</style>
