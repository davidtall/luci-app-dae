<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { DaeNode, DaeSubscription } from '../types'
import BaseDialog from './BaseDialog.vue'

const props = defineProps<{
  open: boolean
  type: 'node' | 'subscription'
  groupName: string
  items: Array<DaeNode | DaeSubscription>
  excludedIds: string[]
  busy: boolean
  resolvingIds?: Set<string>
  initialSelectedIds?: string[]
}>()

const emit = defineEmits<{
  close: []
  confirm: [ids: string[], regex: string]
  resolve: [id: string]
}>()

const search = ref('')
const regex = ref('')
const selected = ref(new Set<string>())

watch(
  () => props.open,
  (open) => {
    if (!open) return
    search.value = ''
    regex.value = ''
    selected.value = new Set(props.initialSelectedIds || [])
    if (props.type === 'subscription') {
      for (const id of selected.value) {
        const item = props.items.find((candidate) => candidate.id === id) as DaeSubscription | undefined
        if (item && !item.previewAvailable) emit('resolve', id)
      }
    }
  },
  { immediate: true },
)

const available = computed(() => {
  const excluded = new Set(props.excludedIds)
  const query = search.value.trim().toLowerCase()
  return props.items.filter((item) => {
    if (excluded.has(item.id)) return false
    const text = `${item.name || ''} ${item.id} ${item.address || ''}`.toLowerCase()
    return !query || text.includes(query)
  })
})

const regexError = computed(() => {
  const pattern = regex.value.trim()
  if (!pattern || props.type === 'node') return ''
  if (pattern.includes('(?=') || pattern.includes('(?!') || pattern.includes('(?<=') || pattern.includes('(?<!') || /\\[1-9]/.test(pattern)) {
    return 'RE2 不支持前后预查或反向引用'
  }
  try {
    new RegExp(pattern)
    return ''
  } catch {
    return '正则表达式无效'
  }
})

const selectedSubscriptions = computed(() => {
  if (props.type !== 'subscription') return []
  return (props.items as DaeSubscription[]).filter((item) => selected.value.has(item.id))
})

const subscriptionPreview = computed(() => {
  const pattern = regex.value.trim()
  const matcher = pattern && !regexError.value ? new RegExp(pattern) : null
  return selectedSubscriptions.value.map((subscription) => {
    const nodes = subscription.nodes || []
    return {
      subscription,
      nodes: matcher
        ? nodes.filter((node) => matcher.test(node.name || node.id))
        : nodes,
    }
  })
})

const totalMatchedNodes = computed(() => subscriptionPreview.value.reduce((total, item) => total + item.nodes.length, 0))

const submitDisabled = computed(() => {
  if (props.busy || !selected.value.size || !!regexError.value) return true
  return props.type === 'subscription' && !!regex.value.trim() && totalMatchedNodes.value === 0
})

function toggle(id: string, checked: boolean) {
  const next = new Set(selected.value)
  if (checked) next.add(id)
  else next.delete(id)
  selected.value = next
  if (checked && props.type === 'subscription') {
    const item = props.items.find((candidate) => candidate.id === id) as DaeSubscription | undefined
    if (item && !item.previewAvailable) emit('resolve', id)
  }
}
</script>

<template>
  <BaseDialog :open="open" :title="`${type === 'node' ? '添加节点到' : '增加订阅组到'} ${groupName}`" wide @close="$emit('close')">
    <label class="field picker-search"><span>搜索</span><input v-model="search" :placeholder="type === 'node' ? '按名称、标签或地址过滤' : '按名称或标签过滤'" /></label>
    <div class="picker-list">
      <label v-for="item in available" :key="item.id" class="picker-option" :class="{ selected: selected.has(item.id) }">
        <input type="checkbox" :checked="selected.has(item.id)" @change="toggle(item.id, ($event.target as HTMLInputElement).checked)" />
        <span class="picker-copy"><strong>{{ item.name || item.id }}</strong><small>{{ item.id }}<template v-if="item.address"> · {{ item.address }}</template></small></span>
        <span class="badge">{{ type === 'node' ? item.protocol || 'unknown' : '订阅' }}</span>
      </label>
      <div v-if="!available.length" class="empty-state">暂无可添加项目</div>
    </div>

    <div v-if="type === 'subscription'" class="picker-filter">
      <label class="field"><span>节点名称过滤正则（可选）</span><input v-model.trim="regex" placeholder="香港|日本|HK|JP" /></label>
      <p class="form-hint">独立 dae 会在加载订阅后应用该过滤规则。</p>
      <p v-if="regexError" class="form-error">{{ regexError }}</p>
    </div>

    <section v-if="type === 'subscription'" class="subscription-picker-preview">
      <div class="subscription-picker-preview-head">
        <div>
          <strong>节点预览</strong>
          <p>{{ regex.trim() ? `当前正则匹配 ${totalMatchedNodes} 个节点` : '显示已选订阅组的全部节点' }}</p>
        </div>
        <span v-if="selected.size" class="badge">{{ totalMatchedNodes }} 个节点</span>
      </div>

      <p v-if="!selected.size" class="form-hint">请先选择至少一个订阅组。</p>
      <div v-else class="subscription-preview-groups">
        <article v-for="item in subscriptionPreview" :key="item.subscription.id" class="subscription-preview-group">
          <div class="subscription-preview-group-head">
            <strong>{{ item.subscription.name || item.subscription.id }}</strong>
            <span class="badge">{{ item.nodes.length }} / {{ item.subscription.nodes?.length || 0 }}</span>
          </div>
          <p v-if="resolvingIds?.has(item.subscription.id)" class="form-hint">正在拉取并解析订阅…</p>
          <div v-else-if="item.nodes.length" class="subscription-preview-nodes">
            <span v-for="node in item.nodes" :key="node.id" class="subscription-preview-node">
              <small>{{ node.protocol || 'unknown' }}</small>
              <span>{{ node.name || node.id }}</span>
            </span>
          </div>
          <p v-else class="form-hint">{{ regex.trim() ? '该订阅没有匹配当前正则的节点。' : item.subscription.previewError || '该订阅尚未解析出节点。' }}</p>
        </article>
      </div>
    </section>

    <template #footer>
      <span class="selection-count">已选 {{ selected.size }} 项</span>
      <button type="button" class="btn" :disabled="busy" @click="$emit('close')">取消</button>
      <button type="button" class="btn btn-primary" :disabled="submitDisabled" @click="$emit('confirm', [...selected], regex.trim())">确认添加</button>
    </template>
  </BaseDialog>
</template>
