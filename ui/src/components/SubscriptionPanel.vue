<script setup lang="ts">
import { ChevronDown, ChevronUp, Pencil, Plus, Radio, RefreshCw } from '@lucide/vue'
import { ref } from 'vue'
import type { DaeNode, DaeSubscription } from '../types'

defineProps<{ subscriptions: DaeSubscription[]; resolving: Set<string> }>()

defineEmits<{
  create: []
  edit: [subscription: DaeSubscription]
  refresh: [subscription: DaeSubscription]
}>()

const expanded = ref(new Set<string>())

function toggle(id: string) {
  const next = new Set(expanded.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expanded.value = next
}

function dragSubscription(event: DragEvent, subscription: DaeSubscription) {
  event.dataTransfer?.setData(
    'application/json',
    JSON.stringify({ type: 'subscription', id: subscription.id, name: subscription.name || subscription.id }),
  )
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'copy'
}

function dragNode(event: DragEvent, subscription: DaeSubscription, node: DaeNode) {
  event.stopPropagation()
  event.dataTransfer?.setData(
    'application/json',
    JSON.stringify({
      type: 'subscription-node',
      id: node.id,
      name: node.name || node.id,
      subscriptionId: subscription.id,
    }),
  )
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'copy'
}

function sourceLabel(subscription: DaeSubscription) {
  if (subscription.previewSource === 'persist') return '持久缓存'
  if (subscription.previewSource === 'remote') return '远程拉取'
  if (subscription.previewSource === 'temporary') return '临时缓存'
  return subscription.status || '尚未解析'
}
</script>

<template>
  <section class="section subscription-section">
    <div class="section-head">
      <div class="section-title"><Radio :size="17" /><span>订阅</span></div>
      <button type="button" class="btn btn-ghost icon-btn" aria-label="新增订阅" @click="$emit('create')">
        <Plus :size="17" />
      </button>
    </div>
    <div class="stack">
      <article
        v-for="subscription in subscriptions"
        :key="subscription.id"
        class="card resource-card draggable-resource subscription-card"
        draggable="true"
        @dragstart="dragSubscription($event, subscription)"
      >
        <div class="resource-head">
          <div class="resource-copy">
            <div class="resource-title">
              <span class="badge">订阅</span>
              <span class="truncate">{{ subscription.name || subscription.id }}</span>
            </div>
            <div class="meta-row">
              <span>{{ subscription.nodes?.length || 0 }} 个节点</span><span>·</span><span>{{ sourceLabel(subscription) }}</span>
            </div>
          </div>
          <div class="resource-actions">
            <button type="button" class="btn btn-ghost icon-btn" :disabled="resolving.has(subscription.id)" :aria-label="`刷新 ${subscription.id}`" @click.stop="$emit('refresh', subscription)">
              <RefreshCw :size="15" :class="{ spinning: resolving.has(subscription.id) }" />
            </button>
            <button type="button" class="btn btn-ghost icon-btn" :aria-label="`编辑 ${subscription.id}`" @click.stop="$emit('edit', subscription)">
              <Pencil :size="15" />
            </button>
            <button type="button" class="btn btn-ghost icon-btn" :aria-label="expanded.has(subscription.id) ? '收起节点' : '展开节点'" @click.stop="toggle(subscription.id)">
              <ChevronUp v-if="expanded.has(subscription.id)" :size="15" />
              <ChevronDown v-else :size="15" />
            </button>
          </div>
        </div>

        <div v-if="subscription.previewError" class="subscription-warning">{{ subscription.previewError }}</div>
        <div v-if="expanded.has(subscription.id)" class="subscription-nodes" @dragstart.stop>
          <div
            v-for="node in subscription.nodes || []"
            :key="node.id"
            class="subscription-node draggable-resource"
            draggable="true"
            @dragstart="dragNode($event, subscription, node)"
          >
            <div class="subscription-node-copy">
              <strong class="truncate">{{ node.name || node.id }}</strong>
              <small class="truncate">{{ node.address || '地址未知' }}</small>
            </div>
            <span class="badge">{{ node.protocol || 'unknown' }}</span>
          </div>
          <div v-if="resolving.has(subscription.id)" class="empty-editor">正在拉取并解析订阅…</div>
          <div v-else-if="!subscription.nodes?.length" class="empty-editor">暂无可显示节点，请点击刷新重试。</div>
        </div>
      </article>
      <div v-if="!subscriptions.length" class="empty-state">暂无订阅，点击右上角按钮添加订阅地址。</div>
    </div>
  </section>
</template>
