<template>
  <div class="screen-share-container">
    <!-- 加入房间表单 -->
    <div v-if="!isInRoom" class="join-form">
      <h2>屏幕共享</h2>
      <div class="form-group">
        <input v-model="roomId" type="text" placeholder="输入房间号" class="input-field">
        <input v-model="nickname" type="text" placeholder="输入昵称" class="input-field">
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
          <video ref="screenVideo" autoplay playsinline :class="{ 'hidden': !isSharing && !isViewing }"></video>
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
        <div class="meeting-controls">
          <button v-if="!isSharing" @click="startSharing" class="control-button share">
            <span class="icon">📤</span>
            分享屏幕
          </button>
          <button v-else @click="stopSharing" class="control-button stop">
            <span class="icon">⏹</span>
            停止共享
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
let localStream = null
let peerConnections = new Map()

// 初始化 Socket.IO 连接
const initializeSocket = () => {
  // 使用当前域名作为服务器地址
  //服务器
  socket = io("https://share-api.future-you.top")
  //备用服务器
  socket = io("https://share-api-bak.future-you.top")
  //本地
  //socket = io("http://localhost:3000")
  socket.on('connect', () => {
    console.log('Connected to server')
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
      const peerConnection = createPeerConnection(data.socketId)
      try {
        const offer = await peerConnection.createOffer()
        await peerConnection.setLocalDescription(offer)
        socket.emit('offer', {
          offer,
          to: data.socketId
        })
      } catch (error) {
        console.error('Error creating offer:', error)
      }
    }
  })

  socket.on('offer', async (data) => {
    if (!isSharing.value) {
      const peerConnection = createPeerConnection(data.from)
      try {
        await peerConnection.setRemoteDescription(data.offer)
        const answer = await peerConnection.createAnswer()
        await peerConnection.setLocalDescription(answer)
        socket.emit('answer', {
          answer,
          to: data.from
        })
      } catch (error) {
        console.error('Error handling offer:', error)
      }
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
    if (peerConnection) {
      try {
        await peerConnection.addIceCandidate(data.candidate)
      } catch (error) {
        console.error('Error adding ice candidate:', error)
      }
    }
  })

  socket.on('user-left', (data) => {
    const peerConnection = peerConnections.get(data.socketId)
    if (peerConnection) {
      peerConnection.close()
      peerConnections.delete(data.socketId)
    }

    // 检查离开的用户是否是共享者
    const leavingUser = users.value.find(user => user.socketId === data.socketId)
    if (leavingUser && isViewing.value) {
      // 如果正在观看离开用户的共享，重置观看状态
      isViewing.value = false
      if (screenVideo.value) {
        screenVideo.value.srcObject = null
      }
    }

    // 从用户列表中移除离开的用户
    users.value = users.value.filter(user => user.socketId !== data.socketId)
  })
}

// 创建 WebRTC 对等连接
const createPeerConnection = (socketId) => {
  const peerConnection = new RTCPeerConnection({
    iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
  })

  peerConnection.onicecandidate = (event) => {
    if (event.candidate) {
      socket.emit('ice-candidate', {
        candidate: event.candidate,
        to: socketId
      })
    }
  }

  if (localStream) {
    localStream.getTracks().forEach(track => {
      peerConnection.addTrack(track, localStream)
    })
  }

  peerConnection.ontrack = (event) => {
    if (screenVideo.value) {
      screenVideo.value.srcObject = event.streams[0]
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
    socket.emit('join-room', {
      roomId: roomId.value,
      nickname: nickname.value
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

// 开始屏幕共享
const startSharing = async () => {
  try {
    // 判断是否支持 getDisplayMedia
    if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
      alert('当前浏览器不支持屏幕共享功能，请使用支持的浏览器（如最新版Chrome、Edge、部分安卓浏览器）。')
      return
    }
    // 移动端兼容性提示
    const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
    if (isMobile) {
      // 部分安卓浏览器支持，iOS大部分不支持
      if (!navigator.mediaDevices.getDisplayMedia) {
        alert('移动端浏览器暂不支持屏幕共享，请在PC端或支持的安卓浏览器中使用。')
        return
      }
    }
    localStream = await navigator.mediaDevices.getDisplayMedia({
      video: true,
      audio: true
    })
    if (screenVideo.value) {
      screenVideo.value.srcObject = localStream
    }
    localStream.getVideoTracks()[0].onended = () => {
      stopSharing()
    }
    isSharing.value = true
    socket.emit('start-sharing')
  } catch (error) {
    alert('屏幕共享启动失败：' + error.message)
    console.error('Error starting screen share:', error)
  }
}

// 停止屏幕共享
const stopSharing = async () => {
  if (localStream) {
    localStream.getTracks().forEach(track => track.stop())
    localStream = null
  }

  if (screenVideo.value) {
    screenVideo.value.srcObject = null
  }

  peerConnections.forEach(connection => {
    connection.close()
  })
  peerConnections.clear()

  isSharing.value = false
  socket.emit('stop-sharing')
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
  if (localStream) {
    localStream.getTracks().forEach(track => track.stop())
  }
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
}
</style>