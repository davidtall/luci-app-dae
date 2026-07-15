<script setup lang="ts">
import { Power, RefreshCw } from '@lucide/vue'
import type { DaeSettings } from '../types'

defineProps<{
  settings: DaeSettings
  busy: boolean
}>()

const emit = defineEmits<{
  update: [key: 'enabled' | 'subscribeAutoUpdate' | 'subscribeUpdateWeekTime' | 'subscribeUpdateDayTime', value: boolean | string]
}>()

const weekOptions = [
  ['*', '每天'],
  ['1', '每周一'],
  ['2', '每周二'],
  ['3', '每周三'],
  ['4', '每周四'],
  ['5', '每周五'],
  ['6', '每周六'],
  ['7', '每周日'],
]

const timeOptions = Array.from({ length: 24 }, (_, hour) => [String(hour), `${hour}:00`])
</script>

<template>
  <section class="section service-settings-section">
    <div class="section-head">
      <div class="section-title"><Power :size="17" /><span>服务与订阅</span></div>
      <span class="section-caption">修改后使用页面底部按钮保存或应用</span>
    </div>

    <article class="card service-settings-card">
      <div class="service-settings-grid">
        <label class="settings-control">
          <span class="settings-control-copy">
            <strong>启用 dae 服务</strong>
            <small>控制系统是否在启动时加载 dae 服务。</small>
          </span>
          <input
            type="checkbox"
            :checked="settings.enabled"
            :disabled="busy"
            @change="emit('update', 'enabled', ($event.target as HTMLInputElement).checked)"
          />
        </label>

        <div class="settings-control settings-control-column">
          <label class="settings-control-toggle">
            <span class="settings-control-copy">
              <strong>启用订阅自动更新</strong>
              <small>按计划拉取并更新已配置的远程订阅。</small>
            </span>
            <input
              type="checkbox"
              :checked="settings.subscribeAutoUpdate"
              :disabled="busy"
              @change="emit('update', 'subscribeAutoUpdate', ($event.target as HTMLInputElement).checked)"
            />
          </label>

          <div v-if="settings.subscribeAutoUpdate" class="subscription-schedule">
            <label class="field">
              <span>更新周期</span>
              <select
                :value="settings.subscribeUpdateWeekTime"
                :disabled="busy"
                @change="emit('update', 'subscribeUpdateWeekTime', ($event.target as HTMLSelectElement).value)"
              >
                <option v-for="option in weekOptions" :key="option[0]" :value="option[0]">{{ option[1] }}</option>
              </select>
            </label>
            <label class="field">
              <span>更新时间</span>
              <select
                :value="settings.subscribeUpdateDayTime"
                :disabled="busy"
                @change="emit('update', 'subscribeUpdateDayTime', ($event.target as HTMLSelectElement).value)"
              >
                <option v-for="option in timeOptions" :key="option[0]" :value="option[0]">{{ option[1] }}</option>
              </select>
            </label>
          </div>
          <p v-else class="settings-hint"><RefreshCw :size="13" />打开后可设置自动更新计划。</p>
        </div>
      </div>
    </article>
  </section>
</template>
