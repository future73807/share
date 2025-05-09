<template>
    <view class="screen-share-container">
        <!-- 加入房间表单 -->
        <view v-if="!isInRoom" class="join-form">
            <text class="title">屏幕共享</text>
            <view class="form-group">
                <input v-model="roomId" type="text" placeholder="输入房间号" class="input-field" />
                <input v-model="nickname" type="text" placeholder="输入昵称" class="input-field" />
                <button @click="joinRoom" class="join-button" :disabled="!roomId || !nickname">
                    加入会议
                </button>
            </view>
        </view>

        <!-- 会议室内容 -->
        <view v-else class="meeting-room">
            <!-- 视频显示区域 -->
            <view class="main-content">
                <view class="video-container" :class="{ 'is-sharing': isSharing || isViewing }">
                    <!-- 注意：uni-app中视频标签使用video组件 -->
                    <video :id="videoId" :class="{ 'hidden': !isSharing && !isViewing }" autoplay></video>
                    <button v-if="isSharing || isViewing" class="fullscreen-btn" @click="enterFullscreen">
                        <text class="icon">⛶</text> 全屏
                    </button>
                    <view class="video-overlay" v-if="!isSharing && !isViewing">
                        <text class="no-video-text">等待屏幕共享...</text>
                    </view>
                </view>

                <!-- 用户列表 -->
                <view class="users-list">
                    <view v-for="(user, index) in users" :key="index" class="user-avatar">
                        <view class="avatar">{{ user.nickname.charAt(0) }}</view>
                        <text class="name">{{ user.nickname }}</text>
                    </view>
                </view>
            </view>

            <!-- 底部工具栏 -->
            <view class="bottom-toolbar">
                <view class="room-info">
                    <text class="room-title">会议室: {{ roomId }}</text>
                </view>
                <view class="meeting-controls">
                    <button v-if="!isSharing" @click="startSharing" class="control-button share">
                        <text class="icon">📤</text>
                        分享屏幕
                    </button>
                    <button v-else @click="stopSharing" class="control-button stop">
                        <text class="icon">⏹</text>
                        停止共享
                    </button>
                    <button @click="toggleMic" class="control-button mic" :class="{ off: !isMicOn }">
                        <text class="icon">{{ isMicOn ? '🎤' : '🔇' }}</text>
                        {{ isMicOn ? '关闭麦克风' : '开启麦克风' }}
                    </button>
                    <button @click="leaveRoom" class="control-button leave">
                        <text class="icon">🚪</text>
                        离开会议
                    </button>
                </view>
            </view>
        </view>
    </view>
</template>

<script>
import io from '@hyoga/uni-socket.io'

export default {
    data() {
        return {
            // 状态变量
            roomId: uni.getStorageSync('roomId') || '',
            nickname: uni.getStorageSync('nickname') || '',
            isInRoom: false,
            isSharing: false,
            isViewing: false,
            videoId: 'screenVideo',
            users: [],
            isMicOn: true,
            // WebRTC 相关变量
            socket: null,
            localStream: null,
            peerConnections: new Map()
        }
    },
    onLoad() {
        // 初始化Socket连接
        this.initializeSocket();
        // 自动重连
        const savedRoomId = uni.getStorageSync('roomId');
        const savedNickname = uni.getStorageSync('nickname');
        if (savedRoomId && savedNickname) {
            this.roomId = savedRoomId;
            this.nickname = savedNickname;
            this.joinRoom();
        }
    },
    onUnload() {
        // 组件卸载时清理资源
        this.leaveRoom();
    },
    methods: {
        // 加入房间
        joinRoom() {
            if (this.roomId && this.nickname) {
                uni.setStorageSync('roomId', this.roomId);
                uni.setStorageSync('nickname', this.nickname);
                this.socket.emit('join-room', {
                    roomId: this.roomId,
                    nickname: this.nickname
                });
                this.isInRoom = true;
            }
        },

        // 初始化Socket连接
        initializeSocket() {
            // 配置选项
            const options = {
                transports: ['websocket', 'polling'],
                timeout: 5000,
                reconnection: true,
                reconnectionAttempts: 5
            }

            // 服务器
            this.socket = io("https://share-api.future-you.top", options);
            // 备用服务器
            // this.socket = io("https://share-api-bak.future-you.top", options);
            // 本地
            // this.socket = io("http://localhost:3000", options);

            this.socket.on('connect', () => {
                console.log('已连接到服务器:', this.socket.id);
            });

            this.socket.on('room-users', (data) => {
                this.users = data.users;
            });

            this.socket.on('user-joined', async (data) => {
                console.log(`${data.nickname} 加入了房间`);
                this.users.push({
                    socketId: data.socketId,
                    nickname: data.nickname
                });

                if (this.isSharing) {
                    const peerConnection = this.createPeerConnection(data.socketId);
                    try {
                        const offer = await peerConnection.createOffer();
                        await peerConnection.setLocalDescription(offer);
                        this.socket.emit('offer', {
                            offer,
                            to: data.socketId
                        });
                    } catch (error) {
                        console.error('创建offer失败:', error);
                    }
                }
            });

            this.socket.on('user-left', (data) => {
                const peerConnection = this.peerConnections.get(data.socketId);
                if (peerConnection) {
                    peerConnection.close();
                    this.peerConnections.delete(data.socketId);
                }

                // 检查离开的用户是否是共享者
                const leavingUser = this.users.find(user => user.socketId === data.socketId);
                if (leavingUser && this.isViewing) {
                    // 如果正在观看离开用户的共享，重置观看状态
                    this.isViewing = false;
                    const videoContext = uni.createVideoContext(this.videoId);
                    if (videoContext) {
                        videoContext.stop();
                    }
                }

                // 从用户列表中移除离开的用户
                this.users = this.users.filter(user => user.socketId !== data.socketId);
            });

            this.socket.on('offer', async (data) => {
                if (!this.isSharing) {
                    const peerConnection = this.createPeerConnection(data.from);
                    try {
                        await peerConnection.setRemoteDescription(data.offer);
                        const answer = await peerConnection.createAnswer();
                        await peerConnection.setLocalDescription(answer);
                        this.socket.emit('answer', {
                            answer,
                            to: data.from
                        });
                    } catch (error) {
                        console.error('处理offer失败:', error);
                    }
                }
            });

            this.socket.on('answer', async (data) => {
                const peerConnection = this.peerConnections.get(data.from);
                if (peerConnection) {
                    try {
                        await peerConnection.setRemoteDescription(data.answer);
                    } catch (error) {
                        console.error('处理answer失败:', error);
                    }
                }
            });

            this.socket.on('ice-candidate', async (data) => {
                const peerConnection = this.peerConnections.get(data.from);
                if (peerConnection) {
                    try {
                        await peerConnection.addIceCandidate(data.candidate);
                    } catch (error) {
                        console.error('添加ice candidate失败:', error);
                    }
                }
            });
        },

        // 离开房间
        leaveRoom() {
            if (this.isSharing) {
                this.stopSharing();
            }

            if (this.socket) {
                this.socket.disconnect();
            }

            this.isInRoom = false;
            this.isViewing = false;
            this.roomId = '';
            this.nickname = '';

            // 清除存储
            uni.removeStorageSync('roomId');
            uni.removeStorageSync('nickname');

            // 清理连接
            this.peerConnections.forEach(connection => {
                connection.close();
            });
            this.peerConnections.clear();
        },

        // 全屏功能
        enterFullscreen() {
            const videoContext = uni.createVideoContext(this.videoId);
            if (videoContext) {
                videoContext.requestFullScreen();
            }
        },

        // 切换麦克风
        toggleMic() {
            if (this.localStream) {
                const audioTracks = this.localStream.getAudioTracks();
                if (audioTracks.length > 0) {
                    this.isMicOn = !this.isMicOn;
                    audioTracks[0].enabled = this.isMicOn;
                }
            }
        },

        // 开始屏幕共享
        async startSharing() {
            try {
                this.localStream = await getScreenShareStream();

                // 在APP环境中，使用uni.openSharePanel已经在getScreenShareStream中处理
                // #ifdef H5
                const videoEl = uni.createVideoContext(this.videoId);
                if (videoEl && this.localStream) {
                    // 在H5环境中设置视频源
                    const videoElement = document.getElementById(this.videoId);
                    if (videoElement) {
                        videoElement.srcObject = this.localStream;
                    }
                }
                // #endif

                // 保证音频轨道状态与按钮同步
                const audioTracks = this.localStream.getAudioTracks();
                if (audioTracks.length > 0) {
                    audioTracks[0].enabled = this.isMicOn;
                }

                // 设置视频轨道结束事件
                const videoTracks = this.localStream.getVideoTracks();
                if (videoTracks.length > 0) {
                    videoTracks[0].onended = () => {
                        this.stopSharing();
                    };
                }

                this.isSharing = true;
                this.socket.emit('start-sharing');

                // 为房间中的每个用户创建对等连接
                for (const user of this.users) {
                    if (user.socketId !== this.socket.id) {
                        const peerConnection = createPeerConnection(user.socketId, this.socket, this.localStream);
                        try {
                            const offer = await peerConnection.createOffer();
                            await peerConnection.setLocalDescription(offer);
                            this.socket.emit('offer', {
                                offer,
                                to: user.socketId
                            });
                            this.peerConnections.set(user.socketId, peerConnection);
                        } catch (error) {
                            console.error('创建offer失败:', error);
                        }
                    }
                }
            } catch (error) {
                uni.showToast({
                    title: '屏幕共享启动失败：' + error.message,
                    icon: 'none',
                    duration: 3000
                });
                console.error('屏幕共享启动失败:', error);
            }
        },

        // 停止屏幕共享
        stopSharing() {
            if (this.localStream) {
                this.localStream.getTracks().forEach(track => track.stop());
                this.localStream = null;
            }

            const videoEl = uni.createVideoContext(this.videoId);
            if (videoEl) {
                videoEl.stop();
            }

            this.peerConnections.forEach(connection => {
                connection.close();
            });
            this.peerConnections.clear();

            this.isSharing = false;
            this.socket.emit('stop-sharing');
        }
    },
}
</script>

<style>
.screen-share-container {
    width: 100%;
    height: 100vh;
    background-color: #f8f9fa;
}

.join-form {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    height: 80vh;
}

.title {
    font-size: 48rpx;
    color: #2c3e50;
    margin-bottom: 40rpx;
}

.form-group {
    display: flex;
    flex-direction: column;
    width: 80%;
    max-width: 600rpx;
}

.input-field {
    padding: 24rpx 32rpx;
    border: 2rpx solid #e0e0e0;
    border-radius: 16rpx;
    font-size: 32rpx;
    margin-bottom: 30rpx;
}

.join-button {
    padding: 24rpx 48rpx;
    background-color: #2196F3;
    color: white;
    border: none;
    border-radius: 16rpx;
    font-size: 32rpx;
    font-weight: 600;
}

.join-button[disabled] {
    background-color: #e0e0e0;
    color: #999;
}

.meeting-room {
    display: flex;
    flex-direction: column;
    height: 100vh;
}

.main-content {
    display: flex;
    flex-direction: column;
    flex: 1;
}

.video-container {
    flex: 1;
    position: relative;
    background: #000;
}

.users-list {
    background: #f8f9fa;
    padding: 32rpx;
    border-top: 1rpx solid #e9ecef;
}

.user-avatar {
    display: flex;
    align-items: center;
    margin-bottom: 24rpx;
}

.avatar {
    width: 80rpx;
    height: 80rpx;
    background: #2196F3;
    color: white;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 40rpx;
    margin-right: 16rpx;
}

.name {
    font-size: 28rpx;
    color: #495057;
}

.bottom-toolbar {
    display: flex;
    flex-direction: column;
    padding: 32rpx;
    background: rgba(255, 255, 255, 0.9);
    border-top: 1rpx solid #e9ecef;
}

.room-info {
    margin-bottom: 20rpx;
}

.room-title {
    font-size: 32rpx;
    color: #2c3e50;
}

.meeting-controls {
    display: flex;
    flex-wrap: wrap;
    gap: 20rpx;
}

.control-button {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 12rpx 24rpx;
    border: none;
    border-radius: 12rpx;
    font-weight: 500;
    font-size: 24rpx;
}

.control-button .icon {
    font-size: 28rpx;
    margin-right: 8rpx;
}

.control-button.share {
    background-color: #2196F3;
    color: white;
}

.control-button.stop {
    background-color: #f44336;
    color: white;
}

.control-button.leave {
    background-color: #666;
    color: white;
}

.video-container {
    position: relative;
    width: 100%;
    aspect-ratio: 16/9;
    background-color: #f8f9fa;
    overflow: hidden;
}

.video-container.is-sharing {
    border: 2rpx solid #2196F3;
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
    font-size: 32rpx;
}

.hidden {
    display: none;
}

.fullscreen-btn {
    position: absolute;
    top: 24rpx;
    right: 24rpx;
    z-index: 10;
    background: rgba(33, 150, 243, 0.85);
    color: #fff;
    border: none;
    border-radius: 12rpx;
    padding: 12rpx 28rpx;
    font-size: 28rpx;
}

.control-button.mic {
    background-color: #ff9800;
    color: white;
}

.control-button.mic.off {
    background-color: #bdbdbd;
    color: #fff;
}
</style>
