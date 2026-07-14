<script setup lang="ts">
import { Code2, Map, Network, Settings, SlidersHorizontal } from '@lucide/vue'
import type { DaeState } from '../types'

defineProps<{ state: DaeState }>()

defineEmits<{
  editGlobal: []
  editDns: []
  editRouting: []
  editSource: [key: 'global' | 'dns' | 'routing']
}>()
</script>

<template>
  <section class="section config-section">
    <div class="section-head">
      <div class="section-title"><Settings :size="17" /><span>配置</span></div>
    </div>

    <div class="stack">
      <article class="card resource-card">
        <div class="resource-head">
          <div class="resource-title"><span>default</span></div>
          <div class="resource-actions">
            <button type="button" class="btn btn-ghost icon-btn" aria-label="可视化编辑配置" @click="$emit('editGlobal')">
              <SlidersHorizontal :size="16" />
            </button>
            <button type="button" class="btn btn-ghost icon-btn" aria-label="编辑配置源码" @click="$emit('editSource', 'global')">
              <Code2 :size="16" />
            </button>
          </div>
        </div>
        <div class="config-summary">
          <div class="summary-item"><span>日志</span><strong>{{ state.resources.global.log_level || '未设置' }}</strong></div>
          <div class="summary-item"><span>拨号模式</span><strong>{{ state.resources.global.dial_mode || '未设置' }}</strong></div>
          <div class="summary-item"><span>LAN</span><strong>{{ state.resources.global.lan_interface || '未设置' }}</strong></div>
          <div class="summary-item"><span>WAN</span><strong>{{ state.resources.global.wan_interface || '未设置' }}</strong></div>
          <div class="summary-item"><span>检查间隔</span><strong>{{ state.resources.global.check_interval || '未设置' }}</strong></div>
          <div class="summary-item"><span>不安全 TLS</span><strong>{{ state.resources.global.allow_insecure ? '允许' : '禁止' }}</strong></div>
        </div>
      </article>
    </div>
  </section>

  <section class="section dns-section">
    <div class="section-head">
      <div class="section-title"><Network :size="17" /><span>DNS</span></div>
    </div>
    <div class="stack">
      <article class="card resource-card">
        <div class="resource-head">
          <div class="resource-title"><span>default</span></div>
          <div class="resource-actions">
            <button type="button" class="btn btn-ghost icon-btn" aria-label="可视化编辑 DNS" @click="$emit('editDns')">
              <SlidersHorizontal :size="16" />
            </button>
            <button type="button" class="btn btn-ghost icon-btn" aria-label="编辑 DNS 源码" @click="$emit('editSource', 'dns')">
              <Code2 :size="16" />
            </button>
          </div>
        </div>
        <div class="meta-row">
          <span>{{ state.resources.dns.upstreams?.length || 0 }} 个上游</span>
          <span>·</span>
          <span>{{ (state.resources.dns.requestRules?.length || 0) + (state.resources.dns.responseRules?.length || 0) }} 条规则</span>
        </div>
      </article>
    </div>
  </section>

  <section class="section routing-section">
    <div class="section-head">
      <div class="section-title"><Map :size="17" /><span>路由</span></div>
    </div>
    <div class="stack">
      <article class="card resource-card">
        <div class="resource-head">
          <div class="resource-title"><span>default</span></div>
          <div class="resource-actions">
            <button type="button" class="btn btn-ghost icon-btn" aria-label="可视化编辑路由" @click="$emit('editRouting')">
              <SlidersHorizontal :size="16" />
            </button>
            <button type="button" class="btn btn-ghost icon-btn" aria-label="编辑路由源码" @click="$emit('editSource', 'routing')">
              <Code2 :size="16" />
            </button>
          </div>
        </div>
        <div class="meta-row">
          <span>{{ state.resources.routing.rules?.length || 0 }} 条规则</span>
          <span>·</span>
          <span>fallback: {{ state.resources.routing.fallback || '未设置' }}</span>
        </div>
      </article>
    </div>
  </section>
</template>
