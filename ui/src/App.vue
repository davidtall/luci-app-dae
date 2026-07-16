<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import AppHeader from './components/AppHeader.vue'
import ConfigPanel from './components/ConfigPanel.vue'
import DnsConfigDialog from './components/DnsConfigDialog.vue'
import GlobalConfigDialog from './components/GlobalConfigDialog.vue'
import GroupDialog from './components/GroupDialog.vue'
import GroupPanel from './components/GroupPanel.vue'
import NodeDialog from './components/NodeDialog.vue'
import NodePanel from './components/NodePanel.vue'
import PickerDialog from './components/PickerDialog.vue'
import RoutingConfigDialog from './components/RoutingConfigDialog.vue'
import SourceEditorDialog from './components/SourceEditorDialog.vue'
import ServiceSettingsPanel from './components/ServiceSettingsPanel.vue'
import SubscriptionDialog from './components/SubscriptionDialog.vue'
import SubscriptionPanel from './components/SubscriptionPanel.vue'
import { updateDnsFromForm, updateGlobalFromForm, updateRoutingFromForm } from './config'
import type { DnsFormValues, GlobalFormValues, RoutingFormValues } from './config'
import { useDaeDashboard } from './composables/useDaeDashboard'
import type { DaeGroup, DaeNode, DaeSettings, DaeSubscription } from './types'

const dashboard = useDaeDashboard()
const {
  state,
  nodes,
  subscriptions,
  groups,
  loading,
  busy,
  dirty,
  toast,
  toastError,
  resolvingSubscriptions,
  showToast,
  loadState,
  pollServiceState,
  mutate,
  resolveSubscription,
  stageFile,
  stageSettings,
  validateConfig,
  saveConfig,
  applyConfig,
  reloadService,
  restartService,
} = dashboard

const nodeDialogOpen = ref(false)
const activeNode = ref<DaeNode | null>(null)
const subscriptionDialogOpen = ref(false)
const activeSubscription = ref<DaeSubscription | null>(null)
const groupDialogOpen = ref(false)
const activeGroup = ref<DaeGroup | null>(null)
const globalDialogOpen = ref(false)
const dnsDialogOpen = ref(false)
const routingDialogOpen = ref(false)
const sourceKey = ref<'global' | 'dns' | 'node' | 'routing' | null>(null)
let resizeObserver: ResizeObserver | null = null
let servicePollTimer: ReturnType<typeof window.setInterval> | null = null

const pickerOpen = ref(false)
const pickerType = ref<'node' | 'subscription'>('node')
const pickerGroup = ref<DaeGroup | null>(null)
const pickerInitialIds = ref<string[]>([])

const sourceTitle = computed(() => {
  if (sourceKey.value === 'global') return '全局配置源码'
  if (sourceKey.value === 'dns') return 'DNS 配置源码'
  if (sourceKey.value === 'node') return '节点配置源码'
  return '路由配置源码'
})

const sourceContent = computed(() => {
  if (!state.value || !sourceKey.value) return ''
  return state.value.files[sourceKey.value].content
})

const pickerItems = computed(() => (pickerType.value === 'node' ? nodes.value : subscriptions.value))
const pickerExcludedIds = computed(() => {
  const group = pickerGroup.value
  if (!group) return []
  return pickerType.value === 'node'
    ? group.nodeIds || []
    : (group.subscriptions || []).map((item) => item.subscriptionId)
})

function openNode(item: DaeNode | null = null) {
  activeNode.value = item
  nodeDialogOpen.value = true
}

function openSubscription(item: DaeSubscription | null = null) {
  activeSubscription.value = item
  subscriptionDialogOpen.value = true
}

function openGroup(item: DaeGroup | null = null) {
  activeGroup.value = item
  groupDialogOpen.value = true
}

function openPicker(type: 'node' | 'subscription', group: DaeGroup, initialIds: string[] = []) {
  pickerType.value = type
  pickerGroup.value = group
  pickerInitialIds.value = initialIds
  pickerOpen.value = true
}

function canonicalSubscriptionLink(link: string) {
  const value = link.trim()
  if (value.startsWith('https://')) return `https-file://${value.slice('https://'.length)}`
  if (value.startsWith('http://')) return `http-file://${value.slice('http://'.length)}`
  return value
}

async function saveNode(values: { previousId: string; id: string; link: string }) {
  if (await mutate('upsert_node', values, '节点修改已暂存')) nodeDialogOpen.value = false
}

async function deleteNode(id: string) {
  if (await mutate('delete_node', { id }, '节点删除操作已暂存')) nodeDialogOpen.value = false
}

async function saveSubscription(values: { previousId: string; id: string; link: string }) {
  const existing = subscriptions.value.find((item) => item.id === values.previousId)
  const linkChanged = !existing || canonicalSubscriptionLink(existing.link) !== canonicalSubscriptionLink(values.link)
  if (await mutate('upsert_subscription', values, '订阅修改已暂存')) {
    subscriptionDialogOpen.value = false
    if (!linkChanged) {
      showToast(`${values.id} 已保存，保留现有订阅缓存`)
      return
    }

    const resolved = await resolveSubscription(values.id, true, true, false)
    if (!resolved && existing) {
      await loadState()
      showToast(`${values.id} 的新地址拉取失败，已保留原订阅配置`, true)
    }
  }
}

async function deleteSubscription(id: string) {
  if (await mutate('delete_subscription', { id }, '订阅删除操作已暂存')) subscriptionDialogOpen.value = false
}

async function saveGroup(values: { previousId: string; id: string; policy: string }) {
  if (await mutate('upsert_group', values, '群组修改已暂存')) groupDialogOpen.value = false
}

async function deleteGroup(id: string) {
  if (await mutate('delete_group', { id }, '群组删除操作已暂存')) groupDialogOpen.value = false
}

async function addNode(groupId: string, nodeId: string, name: string) {
  await mutate('group_add_node', { groupId, nodeId }, `${name} 加入群组的操作已暂存`)
}

async function addSubscriptionNode(groupId: string, subscriptionId: string, nodeName: string) {
  await mutate(
    'group_add_subscription_node',
    { groupId, subscriptionId, nodeName },
    `${nodeName} 加入群组的操作已暂存`,
  )
}

function addSubscription(groupId: string, subscriptionId: string) {
  const group = groups.value.find((item) => item.id === groupId)
  if (group) openPicker('subscription', group, [subscriptionId])
}

async function confirmPicker(ids: string[], regex: string) {
  const group = pickerGroup.value
  if (!group) return
  for (const id of ids) {
    const ok = await mutate(
      pickerType.value === 'node' ? 'group_add_node' : 'group_add_subscription',
      pickerType.value === 'node'
        ? { groupId: group.id, nodeId: id }
        : { groupId: group.id, subscriptionId: id, regex },
    )
    if (!ok) return
  }
  pickerOpen.value = false
  showToast(`向 ${group.id} 添加 ${ids.length} 项的操作已暂存`)
}

async function saveSource(content: string) {
  if (!sourceKey.value) return
  const key = sourceKey.value
  if (await stageFile(key, content, `${sourceTitle.value}修改已暂存`)) sourceKey.value = null
}

async function saveGlobal(values: GlobalFormValues) {
  if (!state.value) return
  try {
    const content = updateGlobalFromForm(state.value.files.global.content, values)
    if (await stageFile('global', content, '全局配置修改已暂存')) globalDialogOpen.value = false
  } catch (error) {
    showToast((error as Error).message, true)
  }
}

function updateServiceSetting(key: keyof DaeSettings, value: boolean | string) {
  stageSettings({ [key]: value } as Partial<DaeSettings>)
}

async function saveDns(values: DnsFormValues) {
  if (!state.value) return
  try {
    const content = updateDnsFromForm(state.value.files.dns.content, values)
    if (await stageFile('dns', content, 'DNS 配置修改已暂存')) dnsDialogOpen.value = false
  } catch (error) {
    showToast((error as Error).message, true)
  }
}

async function saveRouting(values: RoutingFormValues) {
  if (!state.value) return
  try {
    const content = updateRoutingFromForm(state.value.files.routing.content, values)
    if (await stageFile('routing', content, '路由配置修改已暂存')) routingDialogOpen.value = false
  } catch (error) {
    showToast((error as Error).message, true)
  }
}

async function reloadDashboard() {
  if (dirty.value && !window.confirm('当前有未保存修改，重载会丢弃这些修改，是否继续？')) return
  try {
    await loadState()
    await reloadService()
    await postParentHeight()
    showToast('配置已重载')
  } catch {
    // loadState already displays the error toast.
  }
}

async function restartDae() {
  if (dirty.value && !window.confirm('当前有未保存修改，重启将使用已保存配置，是否继续？')) return
  await restartService()
}

function warnUnsavedChanges(event: BeforeUnloadEvent) {
  if (!dirty.value) return
  event.preventDefault()
  event.returnValue = ''
}

function postParentState() {
  window.parent.postMessage({
    source: 'luci-app-dae-dashboard',
    type: 'state',
    dirty: dirty.value,
    busy: busy.value,
  }, window.location.origin)
}

async function postParentHeight() {
  await nextTick()
  window.parent.postMessage({
    source: 'luci-app-dae-dashboard',
    type: 'resize',
    height: document.documentElement.scrollHeight,
  }, window.location.origin)
}

async function handleParentAction(event: MessageEvent) {
  if (event.source !== window.parent || event.origin !== window.location.origin) return
  const data = event.data as { source?: string; type?: string; action?: 'validate' | 'save' | 'apply' }
  if (data?.source !== 'luci-app-dae-page') return
  if (data.type === 'request-state') {
    postParentState()
    postParentHeight()
    return
  }
  if (data.type !== 'action' || !data.action) return

  let ok = false
  if (data.action === 'validate') ok = await validateConfig()
  else if (data.action === 'save') ok = await saveConfig()
  else if (data.action === 'apply') ok = await applyConfig()

  window.parent.postMessage({
    source: 'luci-app-dae-dashboard',
    type: 'result',
    action: data.action,
    ok,
  }, window.location.origin)
}

watch([dirty, busy], postParentState, { immediate: true })

onMounted(() => {
  window.addEventListener('beforeunload', warnUnsavedChanges)
  window.addEventListener('message', handleParentAction)
  resizeObserver = new ResizeObserver(() => postParentHeight())
  resizeObserver.observe(document.body)
  loadState().then(postParentHeight).catch(() => undefined)
  servicePollTimer = window.setInterval(() => {
    pollServiceState().catch(() => undefined)
  }, 5000)
})

onBeforeUnmount(() => {
  window.removeEventListener('beforeunload', warnUnsavedChanges)
  window.removeEventListener('message', handleParentAction)
  resizeObserver?.disconnect()
  if (servicePollTimer !== null) window.clearInterval(servicePollTimer)
})
</script>

<template>
  <div class="dashboard-shell">
    <AppHeader
      :version="state?.service.version"
      :running="state?.service.running || false"
      :enabled="state?.settings.enabled || false"
      :memory-kb="state?.service.memoryKb"
      :busy="busy || loading"
      @reload="reloadDashboard"
      @restart="restartDae"
    />

    <div v-if="loading && !state" class="loading-state">正在读取 dae 配置…</div>
    <main v-else-if="state" class="workspace">
      <ServiceSettingsPanel :settings="state.settings" :busy="busy" @update="updateServiceSetting" />
      <ConfigPanel
        :state="state"
        @edit-global="globalDialogOpen = true"
        @edit-dns="dnsDialogOpen = true"
        @edit-routing="routingDialogOpen = true"
        @edit-source="sourceKey = $event"
      />
      <GroupPanel
        :groups="groups"
        :nodes="nodes"
        :subscriptions="subscriptions"
        @create="openGroup()"
        @edit-node-source="sourceKey = 'node'"
        @edit="openGroup"
        @open-node-picker="openPicker('node', $event)"
        @open-subscription-picker="openPicker('subscription', $event)"
        @add-node="addNode"
        @add-subscription-node="addSubscriptionNode"
        @add-subscription="addSubscription"
        @remove-node="(groupId, nodeId) => mutate('group_remove_node', { groupId, nodeId }, '从群组移除节点的操作已暂存')"
        @remove-subscription-node="(groupId, subscriptionId, nodeName) => mutate('group_remove_subscription_node', { groupId, subscriptionId, nodeName }, '从群组移除订阅节点的操作已暂存')"
        @remove-subscription="(groupId, subscriptionId, filterId) => mutate('group_remove_subscription', { groupId, subscriptionId, filterId }, '从群组移除订阅的操作已暂存')"
      />
      <NodePanel :nodes="nodes" @create="openNode()" @edit="openNode" />
      <SubscriptionPanel
        :subscriptions="subscriptions"
        :resolving="resolvingSubscriptions"
        @create="openSubscription()"
        @edit="openSubscription"
        @refresh="resolveSubscription($event.id, true, true)"
      />
    </main>

    <div v-if="toast" class="toast" :class="{ error: toastError }">{{ toast }}</div>

    <template v-if="state">
      <NodeDialog :open="nodeDialogOpen" :item="activeNode" :busy="busy" @close="nodeDialogOpen = false" @save="saveNode" @remove="deleteNode" />
      <SubscriptionDialog :open="subscriptionDialogOpen" :item="activeSubscription" :busy="busy" @close="subscriptionDialogOpen = false" @save="saveSubscription" @remove="deleteSubscription" />
      <GroupDialog :open="groupDialogOpen" :item="activeGroup" :busy="busy" @close="groupDialogOpen = false" @save="saveGroup" @remove="deleteGroup" />
      <GlobalConfigDialog :open="globalDialogOpen" :global="state.resources.global" :busy="busy" @close="globalDialogOpen = false" @save="saveGlobal" />
      <DnsConfigDialog :open="dnsDialogOpen" :dns="state.resources.dns" :busy="busy" @close="dnsDialogOpen = false" @save="saveDns" />
      <RoutingConfigDialog :open="routingDialogOpen" :routing="state.resources.routing" :groups="groups" :busy="busy" @close="routingDialogOpen = false" @save="saveRouting" />
      <SourceEditorDialog :open="!!sourceKey" :title="sourceTitle" :content="sourceContent" :busy="busy" @close="sourceKey = null" @save="saveSource" />
      <PickerDialog
        :open="pickerOpen"
        :type="pickerType"
        :group-name="pickerGroup?.id || ''"
        :items="pickerItems"
        :excluded-ids="pickerExcludedIds"
        :initial-selected-ids="pickerInitialIds"
        :resolving-ids="resolvingSubscriptions"
        :busy="busy"
        @close="pickerOpen = false"
        @resolve="resolveSubscription($event)"
        @confirm="confirmPicker"
      />
    </template>
  </div>
</template>
