<script setup>
import ScreenShare from './components/ScreenShare.vue'
</script>

<template>
  <div class="app-container">
    <h1>屏幕共享应用</h1>
    <ScreenShare />
  </div>
</template>

<style scoped>
.app-container {
  max-width: 1200px;
  margin: 0 auto;
  padding: 20px;
  text-align: center;
}

h1 {
  color: #2c3e50;
  margin-bottom: 30px;
}
</style>
