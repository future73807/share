<template>
	<view class="content">
		<image class="logo" src="/static/logo.png"></image>
		<view class="text-area">
			<text class="title">{{title}}</text>
		</view>
		<button class="share-btn" @click="goToScreenShare">进入屏幕共享</button>
	</view>
</template>

<script>
	export default {
		data() {
			return {
				title: '屏幕共享应用'
			}
		},
		onLoad() {

		},
		methods: {
			goToScreenShare() {
				uni.navigateTo({
					url: '/pages/screenShare/screenShare'
				})
			}
		}
	}
</script>

<style>
	.content {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		padding: 40rpx;
	}

	.logo {
		height: 200rpx;
		width: 200rpx;
		margin-top: 200rpx;
		margin-left: auto;
		margin-right: auto;
		margin-bottom: 50rpx;
	}

	.text-area {
		display: flex;
		justify-content: center;
		margin-bottom: 80rpx;
	}

	.title {
		font-size: 40rpx;
		color: #2c3e50;
		font-weight: bold;
	}
	
	.share-btn {
		background-color: #2196F3;
		color: #ffffff;
		padding: 20rpx 40rpx;
		border-radius: 10rpx;
		font-size: 32rpx;
		margin-top: 60rpx;
		width: 80%;
	}
</style>
