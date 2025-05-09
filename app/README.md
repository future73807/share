# 屏幕共享应用 - uni-app版本

## 项目介绍

这是一个基于uni-app框架的屏幕共享应用，支持在多平台运行，特别是在H5环境下可以实现完整的屏幕共享功能。该项目是从原Vue 3 + Vite项目迁移而来，保留了核心的屏幕共享功能。

## 技术架构

- 前端框架：uni-app
- 实时通信：Socket.IO
- 媒体传输：WebRTC (H5环境)
- 服务端：Express.js (与原项目共用)

## 功能特性

- 创建/加入会议室
- 屏幕共享（H5环境）
- 实时用户列表
- 麦克风控制
- 全屏显示

## 项目结构

```
app/
├── App.vue                 # 应用入口组件
├── main.js                 # 应用入口文件
├── manifest.json           # 应用配置文件
├── pages.json             # 页面路由配置
├── pages/                 # 页面目录
│   ├── index/             # 首页
│   └── screenShare/       # 屏幕共享页面
├── static/                # 静态资源
└── utils/                 # 工具类
    └── socket.js          # Socket.IO和WebRTC工具
```

## 平台兼容性说明

- **H5环境**：支持完整的屏幕共享功能，包括WebRTC视频传输
- **App环境**：基础UI功能可用，但屏幕共享功能受限
- **小程序环境**：基础UI功能可用，但屏幕共享功能不可用

## 使用说明

1. 安装依赖：
   ```
   npm install
   ```

2. 开发模式运行：
   ```
   npm run dev:h5      # H5平台
   npm run dev:app     # App平台
   ```

3. 构建发布：
   ```
   npm run build:h5    # H5平台
   npm run build:app   # App平台
   ```

## 迁移说明

本项目从原Vue 3 + Vite项目迁移而来，主要变更包括：

1. 调整目录结构以符合uni-app规范
2. 将Vue组件转换为uni-app页面
3. 替换DOM API为uni-app API
4. 增加平台条件编译以处理不同平台的兼容性
5. 封装Socket.IO和WebRTC相关功能为工具类

## 注意事项

- 屏幕共享功能仅在H5环境的桌面浏览器中完全可用
- 移动端浏览器可能不支持或限制屏幕共享功能
- 使用时需确保服务端正常运行