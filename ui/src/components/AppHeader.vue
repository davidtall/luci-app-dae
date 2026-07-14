<script setup lang="ts">
import { RefreshCw } from '@lucide/vue'
import daeLogo from '../assets/dae-logo.webp'

const props = defineProps<{
  version?: string
  running: boolean
  enabled: boolean
  busy?: boolean
}>()

defineEmits<{
  reload: []
}>()
</script>

<template>
  <header class="appbar">
    <div class="brand">
      <span class="brand-mark">
        <img class="brand-logo" :src="daeLogo" alt="dae" />
      </span>
      <div class="brand-copy">
        <div class="brand-line">
          <span>dae</span>
          <span class="version">{{ version || '未知版本' }}</span>
        </div>
        <div class="service-status" :class="{ danger: !running }">
          <span class="status-dot" />
          <span>{{ running ? '运行中' : enabled ? '未运行' : '未启用' }}</span>
        </div>
      </div>
    </div>
    <button
      type="button"
      class="btn btn-primary btn-small dae-reload-button"
      :disabled="props.busy || !props.running"
      :title="props.running ? '重载 dae 服务' : 'dae 未运行，无法重载'"
      @click="$emit('reload')"
    >
      <RefreshCw :size="14" />
      <span>重载</span>
    </button>
  </header>
</template>
