<script>
	export default {
		onLaunch: function() {
			console.log('App Launch')
			// 检查平台兼容性
			// #ifdef H5
			console.log('运行在H5环境，WebRTC功能可用')
			// #endif
			
			// #ifndef H5
			console.log('注意：完整的WebRTC功能在非H5环境可能受限')
			// #endif
		},
		onShow: function() {
			console.log('App Show')
		},
		onHide: function() {
			console.log('App Hide')
		}
	}
</script>

<style>
	/*每个页面公共css */
	/* 重置样式 */
	page {
		height: 100%;
		margin: 0;
		padding: 0;
		box-sizing: border-box;
		font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif;
	}
	
	/* 按钮通用样式 */
	button {
		outline: none;
		border: none;
		cursor: pointer;
		transition: all 0.3s ease;
	}
	
	/* 输入框通用样式 */
	input {
		outline: none;
		transition: border-color 0.3s ease;
	}
</style>
