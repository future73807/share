import express from 'express';
import { createServer } from 'http';
import { Server } from 'socket.io';

const app = express();
const server = createServer(app);
const io = new Server(server, {
  cors: {
    origin: "http://localhost:5173",
    methods: ["GET", "POST"]
  }
});

// 存储房间信息和共享状态
const rooms = new Map();
const sharingUsers = new Map(); // 存储每个房间的共享用户列表

io.on('connection', (socket) => {
  console.log('用户已连接:', socket.id);

  // 加入房间
  socket.on('join-room', ({ roomId, nickname }) => {
    socket.join(roomId);
    
    // 存储用户信息
    if (!rooms.has(roomId)) {
      rooms.set(roomId, new Map());
    }
    rooms.get(roomId).set(socket.id, { nickname });

    // 通知房间内其他用户
    socket.to(roomId).emit('user-joined', {
      socketId: socket.id,
      nickname
    });
  });

  // 处理offer
  socket.on('offer', ({ offer, to }) => {
    socket.to(to).emit('offer', {
      offer,
      from: socket.id
    });
  });

  // 处理answer
  socket.on('answer', ({ answer, to }) => {
    socket.to(to).emit('answer', {
      answer,
      from: socket.id
    });
  });

  // 处理ICE候选
  socket.on('ice-candidate', ({ candidate, to }) => {
    socket.to(to).emit('ice-candidate', {
      candidate,
      from: socket.id
    });
  });

  // 开始共享
  socket.on('start-sharing', () => {
    const roomId = Array.from(socket.rooms)[1]; // 第一个room是socket.id
    if (roomId) {
      // 将用户添加到共享列表
      if (!sharingUsers.has(roomId)) {
        sharingUsers.set(roomId, new Set());
      }
      sharingUsers.get(roomId).add(socket.id);
      
      // 发送当前所有共享用户列表
      const currentSharingUsers = Array.from(sharingUsers.get(roomId));
      io.to(roomId).emit('share-started', { 
        from: socket.id,
        sharingUsers: currentSharingUsers
      });
    }
  });

  // 停止共享
  socket.on('stop-sharing', () => {
    const roomId = Array.from(socket.rooms)[1];
    if (roomId && sharingUsers.has(roomId)) {
      sharingUsers.get(roomId).delete(socket.id);
      if (sharingUsers.get(roomId).size === 0) {
        sharingUsers.delete(roomId);
      }
      socket.to(roomId).emit('share-stopped', { 
        from: socket.id,
        sharingUsers: Array.from(sharingUsers.get(roomId) || [])
      });
    }
  });

  // 断开连接
  socket.on('disconnect', () => {
    console.log('用户已断开连接:', socket.id);
    
    // 清理房间信息
    rooms.forEach((users, roomId) => {
      if (users.has(socket.id)) {
        users.delete(socket.id);
        
        // 清理共享状态
        if (sharingUsers.has(roomId)) {
          sharingUsers.get(roomId).delete(socket.id);
          if (sharingUsers.get(roomId).size === 0) {
            sharingUsers.delete(roomId);
          }
        }
        
        socket.to(roomId).emit('user-left', {
          socketId: socket.id,
          sharingUsers: Array.from(sharingUsers.get(roomId) || [])
        });
        
        // 如果房间为空，删除房间
        if (users.size === 0) {
          rooms.delete(roomId);
          sharingUsers.delete(roomId);
        }
      }
    });
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`服务器运行在端口 ${PORT}`);
});