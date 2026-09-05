<template>
  <div class="screen-share-container">
    <!-- 加入房间表单 -->
    <div v-if="!isInRoom" class="join-form">
      <h2>屏幕共享</h2>
      <div class="form-group">
        <input v-model="roomId" type="text" placeholder="输入房间号" class="input-field">
        <input v-model="nickname" type="text" placeholder="输入昵称" class="input-field">
        <div class="audio-mode-group">
          <span class="audio-mode-label">分享声音:</span>
          <div class="audio-mode-options">
            <label v-for="mode in audioModes" :key="mode.value" class="audio-mode-option">
              <input type="radio" :value="mode.value" v-model="audioMode">
              <span>{{ mode.label }}</span>
            </label>
          </div>
        </div>
        <button @click="joinRoom" class="join-button" :disabled="!roomId || !nickname">
          加入会议
        </button>
      </div>
    </div>

    <!-- 会议室内容 -->
    <div v-else class="meeting-room">
      <!-- 视频显示区域 -->
      <div class="main-content">
        <div class="video-container" :class="{ 'is-sharing': isSharing || isViewing }">
          <video ref="screenVideo" autoplay playsinline
                 :class="{ 'hidden': !isSharing && !isViewing }"
                 :muted="isSharing"></video>
          <button v-if="isSharing || isViewing" class="fullscreen-btn" @click="enterFullscreen">
            <span class="icon">⛶</span> 全屏
          </button>
          <div class="video-overlay" v-if="!isSharing && !isViewing">
            <span class="no-video-text">等待屏幕共享...</span>
          </div>
        </div>

        <!-- 用户列表 -->
        <div class="users-list">
          <div v-for="user in users" :key="user.socketId" class="user-avatar">
            <span class="avatar">{{ user.nickname.charAt(0) }}</span>
            <span class="name">{{ user.nickname }}</span>
          </div>
        </div>
      </div>

      <!-- 底部工具栏 -->
      <div class="bottom-toolbar">
        <div class="room-info">
          <h3>会议室: {{ roomId }}</h3>
        </div>
        <div class="audio-mode-group" v-if="isSharing">
          <span class="audio-mode-label">声音:</span>
          <div class="audio-mode-options">
            <button v-for="mode in audioModes" :key="mode.value"
                    class="audio-mode-chip"
                    :class="{ active: audioMode === mode.value }"
                    @click="setAudioMode(mode.value)">
              {{ mode.label }}
            </button>
          </div>
        </div>
        <div class="meeting-controls">
          <button v-if="!isSharing" @click="startSharing" class="control-button share">
            <span class="icon">📤</span>
            分享屏幕
          </button>
          <button v-else @click="stopSharing" class="control-button stop">
            <span class="icon">⏹</span>
            停止共享
          </button>
          <button v-if="isSharing && hasMicTrack" @click="toggleMic" class="control-button mic"
                  :class="{ off: !isMicOn }">
            <span class="icon">{{ isMicOn ? '🎤' : '🔇' }}</span>
            {{ isMicOn ? '关闭麦克风' : '开启麦克风' }}
          </button>
          <button @click="leaveRoom" class="control-button leave">
            <span class="icon">🚪</span>
            离开会议
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { io } from 'socket.io-client'

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

// 声音分享模式: mixed=屏幕+麦克风, screen=仅屏幕内音, mic=仅麦克风, none=无声
const audioModes = [
  { value: 'mixed', label: '混合(屏幕+麦克风)' },
  { value: 'screen', label: '仅屏幕声音' },
  { value: 'mic', label: '仅麦克风' },
  { value: 'none', label: '无声' }
]
const audioMode = ref(localStorage.getItem('audioMode') || 'mixed')

// 全屏功能
const enterFullscreen = () => {
  const videoEl = screenVideo.value
  if (videoEl) {
    if (videoEl.requestFullscreen) {
      videoEl.requestFullscreen()
    } else if (videoEl.webkitRequestFullscreen) {
      videoEl.webkitRequestFullscreen()
    } else if (videoEl.mozRequestFullScreen) {
      videoEl.mozRequestFullScreen()
    } else if (videoEl.msRequestFullscreen) {
      videoEl.msRequestFullscreen()
    }
  }
}

// WebRTC 相关变量
let socket = null
let screenStream = null // 屏幕共享流(视频+屏幕内音)
let micStream = null    // 麦克风流(带回声抑制)
let peerConnections = new Map()
const remoteStreams = new Map() // socketId -> MediaStream(合成远端视频+音频)
const requestedStreams = new Set() // 已请求过流的共享者,防止重复请求

const serverUrl = new URLSearchParams(window.location.search).get('server')
  || `${window.location.protocol}//${window.location.hostname}:3000`

// 麦克风约束:开启回声抑制/噪声抑制/自动增益,避免扬声器声音被麦克风二次采集造成回音
const micConstraints = {
  audio: {
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
    channelCount: 1
  }
}

// 初始化 Socket.IO 连接
const initializeSocket = () => {
  socket = io(serverUrl, { transports: ['websocket', 'polling'] })
  socket.on('connect', () => {
    console.log('Connected to server')
  })
  // 调试钩子:便于自动化测试检查连接状态
  if (typeof window !== 'undefined') {
    window.__ss = { socket, peerConnections, remoteStreams }
  }

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
      const answer = await peerConnection.createAnswer()
      await peerConnection.setLocalDescription(answer)
      socket.emit('answer', {
        answer,
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

// 向指定用户创建对等连接并发送 Offer(共享者侧)
const createOfferTo = async (socketId) => {
  const peerConnection = createPeerConnection(socketId)
  // 已在协商中则跳过,避免重复 Offer 造成 answer 竞态
  if (peerConnection.signalingState === 'have-local-offer') {
    return
  }
  try {
    const offer = await peerConnection.createOffer()
    await peerConnection.setLocalDescription(offer)
    socket.emit('offer', {
      offer,
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

  // 发布本地轨道:屏幕视频/屏幕内音 + 麦克风
  if (screenStream) {
    screenStream.getTracks().forEach(track => {
      peerConnection.addTrack(track, screenStream)
    })
  }
  if (micStream) {
    micStream.getTracks().forEach(track => {
      peerConnection.addTrack(track, micStream)
    })
  }

  // 接收远端轨道:合成到同一 MediaStream,视频+多路音频一起播放
  peerConnection.ontrack = (event) => {
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
    if (screenVideo.value) {
      screenVideo.value.srcObject = remote
      isViewing.value = true
    }
  }

  peerConnections.set(socketId, peerConnection)
  return peerConnection
}

// 加入房间
const joinRoom = () => {
  if (roomId.value && nickname.value) {
    localStorage.setItem('roomId', roomId.value)
    localStorage.setItem('nickname', nickname.value)
    localStorage.setItem('audioMode', audioMode.value)
    socket.emit('join-room', {
      roomId: roomId.value,
      nickname: nickname.value,
      client: 'web'
    })
    isInRoom.value = true
  }
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
      video: true,
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

// 按模式应用轨道开关(共享中切换立即生效,无需重新协商)
const applyAudioMode = () => {
  const wantScreenAudio = audioMode.value === 'mixed' || audioMode.value === 'screen'
  const wantMic = audioMode.value === 'mixed' || audioMode.value === 'mic'

  if (screenStream) {
    screenStream.getAudioTracks().forEach(t => { t.enabled = wantScreenAudio && isMicOn.value !== false })
  }
  if (micStream) {
    micStream.getAudioTracks().forEach(t => { t.enabled = wantMic && isMicOn.value })
  }
}

// 共享中切换声音模式
const setAudioMode = (mode) => {
  audioMode.value = mode
  localStorage.setItem('audioMode', mode)
  if (isSharing.value) {
    applyAudioMode()
  }
}

const toggleMic = () => {
  if (micStream && micStream.getAudioTracks().length > 0) {
    isMicOn.value = !isMicOn.value
    applyAudioMode()
  }
}

const startSharing = async () => {
  try {
    isMicOn.value = true
    screenStream = await getScreenStream()
    // 麦克风按需采集(混合/仅麦克风模式)
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
    applyAudioMode()

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
  max-width: 1400px;
  margin: 0 auto;
  padding: 20px;
  min-height: 100vh;
  background-color: #f8f9fa;
}

.join-form {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-height: 80vh;
  gap: 24px;
}

.join-form h2 {
  font-size: 2.5rem;
  color: #2c3e50;
  margin-bottom: 1rem;
}

.form-group {
  display: flex;
  flex-direction: column;
  gap: 16px;
  width: 100%;
  max-width: 400px;
}

.input-field {
  padding: 12px 16px;
  border: 2px solid #e0e0e0;
  border-radius: 8px;
  font-size: 1rem;
  transition: border-color 0.3s;
}

.input-field:focus {
  border-color: #2196F3;
  outline: none;
}

.join-button {
  padding: 12px 24px;
  background-color: #2196F3;
  color: white;
  border: none;
  border-radius: 8px;
  cursor: pointer;
  font-size: 1rem;
  font-weight: 600;
  transition: background-color 0.3s;
}

.join-button:hover {
  background-color: #1976D2;
}

.join-button:disabled {
  background-color: #e0e0e0;
  cursor: not-allowed;
}

.meeting-room {
  display: flex;
  flex-direction: column;
  height: 100vh;
  position: relative;
}

.main-content {
  display: flex;
  flex: 1;
  position: relative;
}

.video-container {
  flex: 1;
  position: relative;
  background: #000;
}

.users-list {
  width: 200px;
  background: #f8f9fa;
  padding: 16px;
  border-left: 1px solid #e9ecef;
  overflow-y: auto;
}

.user-avatar {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 12px;
}

.avatar {
  width: 40px;
  height: 40px;
  background: #2196F3;
  color: white;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.2rem;
}

.name {
  font-size: 0.9rem;
  color: #495057;
}

.bottom-toolbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
  padding: 16px 24px;
  background: rgba(255, 255, 255, 0.9);
  backdrop-filter: blur(10px);
  border-top: 1px solid #e9ecef;
}

.room-info {
  display: flex;
  align-items: center;
}

.room-info h3 {
  font-size: 1.1rem;
  color: #2c3e50;
  margin: 0;
}

.meeting-controls {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
}

.control-button {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 16px;
  border: none;
  border-radius: 8px;
  cursor: pointer;
  font-weight: 500;
  transition: all 0.3s;
}

.control-button .icon {
  font-size: 1.2rem;
}

.control-button.share {
  background-color: #2196F3;
  color: white;
}

.control-button.share:hover {
  background-color: #1976D2;
}

.control-button.stop {
  background-color: #f44336;
  color: white;
}

.control-button.stop:hover {
  background-color: #d32f2f;
}

.control-button.leave {
  background-color: #666;
  color: white;
}

.control-button.leave:hover {
  background-color: #555;
}

.video-grid {
  flex: 1;
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
  gap: 24px;
  padding: 24px;
  background-color: white;
  border-radius: 12px;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
}

.video-container {
  position: relative;
  width: 100%;
  aspect-ratio: 16/9;
  background-color: #f8f9fa;
  border-radius: 8px;
  overflow: hidden;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
}

.video-container.is-sharing {
  border: 2px solid #2196F3;
}

video {
  width: 100%;
  height: 100%;
  object-fit: contain;
}

.video-overlay {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background-color: #f8f9fa;
}

.no-video-text {
  color: #666;
  font-size: 1.1rem;
}

.hidden {
  display: none;
}

.fullscreen-btn {
  position: absolute;
  top: 12px;
  right: 12px;
  z-index: 10;
  background: rgba(33, 150, 243, 0.85);
  color: #fff;
  border: none;
  border-radius: 6px;
  padding: 6px 14px;
  font-size: 1rem;
  cursor: pointer;
  transition: background 0.2s;
}
.fullscreen-btn:hover {
  background: #1976D2;
}

/* 声音模式选择 */
.audio-mode-group {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.audio-mode-label {
  font-size: 0.9rem;
  color: #495057;
  font-weight: 600;
}
.audio-mode-options {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.audio-mode-option {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 0.9rem;
  color: #2c3e50;
  cursor: pointer;
}
.audio-mode-chip {
  padding: 6px 12px;
  border: 1px solid #cfd8dc;
  border-radius: 16px;
  background: #fff;
  color: #455a64;
  font-size: 0.85rem;
  cursor: pointer;
  transition: all 0.2s;
}
.audio-mode-chip.active {
  background: #2196F3;
  border-color: #2196F3;
  color: #fff;
}
.audio-mode-chip:hover {
  border-color: #2196F3;
}

.control-button.mic {
  background-color: #ff9800;
  color: white;
}
.control-button.mic.off {
  background-color: #bdbdbd;
  color: #fff;
}
.control-button.mic:hover {
  background-color: #f57c00;
}

@media (max-width: 800px) {
  .main-content {
    flex-direction: column;
  }
  .video-container {
    width: 100% !important;
    max-width: 100vw;
    aspect-ratio: 16/9;
    margin-bottom: 16px;
  }
  .users-list {
    width: 100% !important;
    border-left: none;
    border-top: 1px solid #e9ecef;
    padding: 12px 8px;
    flex-direction: row;
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-start;
    gap: 8px;
  }
  .user-avatar {
    margin-bottom: 0;
    margin-right: 12px;
  }
  .bottom-toolbar {
    padding: 10px 12px;
  }
  .meeting-controls {
    gap: 8px;
  }
  .control-button {
    padding: 8px 10px;
    font-size: 0.9rem;
  }
}
</style>
