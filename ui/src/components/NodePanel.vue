<script setup lang="ts">
import { Cloud, Pencil, Plus } from '@lucide/vue'
import type { DaeNode } from '../types'

defineProps<{ nodes: DaeNode[] }>()

defineEmits<{
  create: []
  edit: [node: DaeNode]
}>()

function dragStart(event: DragEvent, node: DaeNode) {
  event.dataTransfer?.setData(
    'application/json',
    JSON.stringify({ type: 'node', id: node.id, name: node.name || node.id }),
  )
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'copy'
}
</script>

<template>
  <section class="section">
    <div class="section-head">
      <div class="section-title"><Cloud :size="17" /><span>节点</span></div>
      <button type="button" class="btn btn-ghost icon-btn" aria-label="新增节点" @click="$emit('create')">
        <Plus :size="17" />
      </button>
    </div>
    <div class="stack">
      <article
        v-for="node in nodes"
        :key="node.id"
        class="card resource-card draggable-resource"
        draggable="true"
        @dragstart="dragStart($event, node)"
      >
        <div class="resource-head">
          <div class="resource-copy">
            <div class="resource-title">
              <span class="badge">{{ node.protocol || 'unknown' }}</span>
              <span class="truncate">{{ node.name || node.id }}</span>
            </div>
            <div class="meta-row"><span>{{ node.id }}</span><span>·</span><span>{{ node.address || '分享链接' }}</span></div>
          </div>
          <button type="button" class="btn btn-ghost icon-btn" :aria-label="`编辑 ${node.id}`" @click="$emit('edit', node)">
            <Pencil :size="15" />
          </button>
        </div>
      </article>
      <div v-if="!nodes.length" class="empty-state">暂无节点，点击右上角按钮添加分享链接。</div>
    </div>
  </section>
</template>
