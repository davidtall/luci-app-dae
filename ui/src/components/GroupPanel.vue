<script setup lang="ts">
import { Code2, LayoutGrid, Pencil, Plus, X } from '@lucide/vue'
import type { DaeGroup, DaeNode, DaeSubscription } from '../types'

const props = defineProps<{
  groups: DaeGroup[]
  nodes: DaeNode[]
  subscriptions: DaeSubscription[]
}>()

const emit = defineEmits<{
  create: []
  editNodeSource: []
  edit: [group: DaeGroup]
  openNodePicker: [group: DaeGroup]
  openSubscriptionPicker: [group: DaeGroup]
  addNode: [groupId: string, nodeId: string, name: string]
  addSubscriptionNode: [groupId: string, subscriptionId: string, nodeName: string]
  addSubscription: [groupId: string, subscriptionId: string, name: string]
  removeNode: [groupId: string, nodeId: string]
  removeSubscriptionNode: [groupId: string, subscriptionId: string, nodeName: string]
  removeSubscription: [groupId: string, subscriptionId: string, filterId: string]
}>()

function nodeName(id: string) {
  return props.nodes.find((node) => node.id === id)?.name || id
}

function subscriptionName(id: string) {
  return props.subscriptions.find((item) => item.id === id)?.name || id
}

function allowDrop(event: DragEvent, zone: HTMLElement) {
  event.preventDefault()
  zone.classList.add('is-over')
}

function drop(event: DragEvent, groupId: string, accept: 'node' | 'subscription') {
  event.preventDefault()
  ;(event.currentTarget as HTMLElement).classList.remove('is-over')
  try {
    const data = JSON.parse(event.dataTransfer?.getData('application/json') || '{}') as {
      type?: string
      id?: string
      name?: string
      subscriptionId?: string
    }
    if (accept === 'node' && data.type === 'subscription-node' && data.subscriptionId && data.name) {
      emit('addSubscriptionNode', groupId, data.subscriptionId, data.name)
      return
    }
    if (!data.id || data.type !== accept) return
    if (accept === 'node') emit('addNode', groupId, data.id, data.name || data.id)
    else emit('addSubscription', groupId, data.id, data.name || data.id)
  } catch {
    // Ignore unrelated drag payloads.
  }
}
</script>

<template>
  <section class="section group-section">
    <div class="section-head">
      <div class="section-title"><LayoutGrid :size="17" /><span>群组</span></div>
      <div class="resource-actions">
        <button type="button" class="btn btn-ghost icon-btn" aria-label="新增群组" @click="$emit('create')">
          <Plus :size="17" />
        </button>
        <button type="button" class="btn btn-ghost icon-btn" aria-label="编辑 node.dae 源码" @click="$emit('editNodeSource')">
          <Code2 :size="15" />
        </button>
      </div>
    </div>
    <div class="stack">
      <article v-for="group in groups" :key="group.id" class="card resource-card group-card">
        <div class="resource-head">
          <div class="resource-title">
            <span>{{ group.name || group.id }}</span>
            <span class="badge">{{ group.policy || 'min_moving_avg' }}</span>
          </div>
          <button type="button" class="btn btn-ghost icon-btn" :aria-label="`编辑 ${group.id}`" @click="$emit('edit', group)">
            <Pencil :size="15" />
          </button>
        </div>
        <div class="meta-row">
          <span>{{ (group.nodeIds?.length || 0) + (group.subscriptionNodes?.length || 0) }} 个节点</span><span>·</span><span>{{ group.subscriptions?.length || 0 }} 个订阅组</span>
        </div>

        <div class="group-zones">
          <div
            class="group-zone"
            @dragover="allowDrop($event, $event.currentTarget as HTMLElement)"
            @dragleave="($event.currentTarget as HTMLElement).classList.remove('is-over')"
            @drop="drop($event, group.id, 'node')"
          >
            <div class="group-zone-head">
              <div class="group-zone-title"><span>节点</span><span class="badge">{{ (group.nodeIds?.length || 0) + (group.subscriptionNodes?.length || 0) }}</span></div>
              <button type="button" class="btn btn-ghost btn-small" @click="$emit('openNodePicker', group)"><Plus :size="14" />添加节点</button>
            </div>
            <div class="group-items">
              <span v-for="id in group.nodeIds || []" :key="id" class="group-badge">
                <span>{{ nodeName(id) }}</span>
                <button type="button" :aria-label="`移除 ${id}`" @click="$emit('removeNode', group.id, id)"><X :size="13" /></button>
              </span>
              <span v-for="item in group.subscriptionNodes || []" :key="item.filterId || item.id" class="group-badge">
                <span>{{ item.nodeName }}</span>
                <small>{{ subscriptionName(item.subscriptionId) }}</small>
                <button type="button" :aria-label="`移除 ${item.nodeName}`" @click="$emit('removeSubscriptionNode', group.id, item.subscriptionId, item.nodeName)"><X :size="13" /></button>
              </span>
              <span v-if="!group.nodeIds?.length && !group.subscriptionNodes?.length" class="empty-drop">暂无内容，可拖入或点击添加</span>
            </div>
          </div>

          <div
            class="group-zone"
            @dragover="allowDrop($event, $event.currentTarget as HTMLElement)"
            @dragleave="($event.currentTarget as HTMLElement).classList.remove('is-over')"
            @drop="drop($event, group.id, 'subscription')"
          >
            <div class="group-zone-head">
              <div class="group-zone-title"><span>订阅组</span><span class="badge">{{ group.subscriptions?.length || 0 }}</span></div>
              <button type="button" class="btn btn-ghost btn-small" @click="$emit('openSubscriptionPicker', group)"><Plus :size="14" />增加订阅组</button>
            </div>
            <div class="group-items">
              <span v-for="membership in group.subscriptions || []" :key="membership.filterId || membership.id" class="group-badge">
                <span>{{ subscriptionName(membership.subscriptionId) }}</span>
                <small v-if="membership.nameFilterRegex">/{{ membership.nameFilterRegex }}/</small>
                <button type="button" :aria-label="`移除 ${membership.subscriptionId}`" @click="$emit('removeSubscription', group.id, membership.subscriptionId, membership.filterId || membership.id || '')"><X :size="13" /></button>
              </span>
              <span v-if="!group.subscriptions?.length" class="empty-drop">暂无内容，可拖入或点击添加</span>
            </div>
          </div>
        </div>
      </article>
      <div v-if="!groups.length" class="empty-state">暂无群组，点击右上角按钮创建。</div>
    </div>
  </section>
</template>
