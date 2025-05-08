<template>
    <div class="screen-share-container">
      <!-- 加入房间表单 -->
      <div v-if="!isInRoom" class="join-form">
        <h2>视频会议</h2>
        <div class="form-group">
          <input 
            v-model="roomId" 
            type="text" 
            placeholder="输入房间号"
            class="input-field"
          >
          <input 
            v-model="nickname" 
            type="text" 
            placeholder="输入昵称"
            class="input-field"
          >
          <button 
            @click="joinRoom"
            class="join-button"
            :disabled="!roomId || !nickname"
          >
            加入会议
          </button>
        </div>
      </div>
  
      <!-- 会议室内容 -->
      <div v-else class="meeting-room">
        <div class="meeting-header">
          <div class="room-info">
            <h3>会议室: {{ roomId }}</h3>
            <p class="participant">{{ nickname }}</p>
          </div>
          <div class="meeting-controls">
            <button 
              v-if="!isSharing" 
              @click="startSharing"
              class="control-button share"
            >
              <span class="icon">📤</span>
              分享屏幕
            </button>
            <button 
              v-else 
              @click="stopSharing"
              class="control-button stop"
            >
              <span class="icon">⏹</span>
              停止共享
            </button>
            <button @click="leaveRoom" class="control-button leave">
              <span class="icon">🚪</span>
              离开会议
            </button>
          </div>
        </div>
  
        <!-- 视频显示区域 -->
        <div class="video-grid">
          <div class="video-container" :class="{ 'is-sharing': isSharing || isViewing }">
            <video
              ref="screenVideo"
              autoplay
              playsinline
              :class="{ 'hidden': !isSharing && !isViewing }"
            ></video>
            <div class="video-overlay" v-if="!isSharing && !isViewing">
              <span class="no-video-text">等待屏幕共享...</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  </template>
  
  <script setup>
  import { ref, onMounted, onUnmounted } from 'vue'
  import { io } from 'socket.io-client'
  
  // 状态变量
  const roomId = ref('')
  const nickname = ref('')
  const isInRoom = ref(false)
  const isSharing = ref(false)
  const isViewing = ref(false)
  const screenVideo = ref(null)
  
  // WebRTC 相关变量
  let socket = null
  let localStream = null
  let peerConnections = new Map()
  
  // 初始化 Socket.IO 连接
  const initializeSocket = () => {
    socket = io('http://localhost:3000')
  
    socket.on('connect', () => {
      console.log('Connected to server')
    })
  
    socket.on('user-joined', async (data) => {
      console.log(`${data.nickname} joined the room`)
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
  
    socket.on('user-left', (socketId) => {
      const peerConnection = peerConnections.get(socketId)
      if (peerConnection) {
        peerConnection.close()
        peerConnections.delete(socketId)
      }
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
  }
  
  // 开始屏幕共享
  const startSharing = async () => {
    try {
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
  
      // 为房间中的每个用户创建对等连接
      socket.emit('start-sharing')
    } catch (error) {
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
    gap: 24px;
    height: calc(100vh - 40px);
  }
  
  .meeting-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 16px 24px;
    background-color: white;
    border-radius: 12px;
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
  }
  
  .room-info {
    display: flex;
    align-items: center;
    gap: 16px;
  }
  
  .room-info h3 {
    font-size: 1.25rem;
    color: #2c3e50;
    margin: 0;
  }
  
  .participant {
    color: #666;
    margin: 0;
    padding: 4px 12px;
    background-color: #f1f1f1;
    border-radius: 16px;
    font-size: 0.9rem;
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
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
  }
  
  .video-container {
    position: relative;
    width: 100%;
    aspect-ratio: 16/9;
    background-color: #f8f9fa;
    border-radius: 8px;
    overflow: hidden;
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
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
  </style>