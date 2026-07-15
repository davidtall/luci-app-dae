<script setup lang="ts">
import { Power, RefreshCw } from '@lucide/vue'
import daeLogo from '../assets/dae-logo.webp'

const props = defineProps<{
  version?: string
  running: boolean
  enabled: boolean
  memoryKb?: number
  busy?: boolean
}>()

defineEmits<{
  reload: []
  restart: []
}>()

function formatMemory(memoryKb?: number) {
  if (!memoryKb || memoryKb <= 0) return ''
  return memoryKb >= 1024 ? `${(memoryKb / 1024).toFixed(1)} MB` : `${memoryKb} KB`
}

function formatVersion(version?: string) {
  return version?.replace(/^dae\s+/i, '') || '未知版本'
}
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
          <span class="version">{{ formatVersion(version) }}</span>
        </div>
        <div class="service-status" :class="{ danger: !running }">
          <span class="status-dot" />
          <span>{{ running ? '运行中' : enabled ? '未运行' : '未启用' }}</span>
          <span v-if="running && memoryKb" class="memory-usage">内存占用 {{ formatMemory(memoryKb) }}</span>
        </div>
      </div>
    </div>
    <div class="header-actions">
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
      <button
        type="button"
        class="btn btn-small dae-restart-button"
        :disabled="props.busy || !props.running"
        :title="props.running ? '重启 dae 服务' : 'dae 未运行，无法重启'"
        @click="$emit('restart')"
      >
        <Power :size="14" />
        <span>重启</span>
      </button>
    </div>
  </header>
</template>
