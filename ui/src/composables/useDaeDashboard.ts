import { computed, ref } from 'vue'
import { request, requestServiceStatus } from '../api'
import type { ApplyResult, DaeGroup, DaeNode, DaeState, DaeSubscription, DaeSettings, GroupSubscription, GroupSubscriptionNode } from '../types'

function asArray<T>(value: unknown): T[] {
  if (Array.isArray(value)) return value as T[]
  if (value && typeof value === 'object') return Object.values(value) as T[]
  return []
}

function normalizeState(value: DaeState): DaeState {
  value.resources.nodes = asArray<DaeNode>(value.resources.nodes)
  value.resources.subscriptions = asArray<DaeSubscription>(value.resources.subscriptions)
  value.resources.groups = asArray<DaeGroup>(value.resources.groups).map((group) => ({
    ...group,
    nodeIds: asArray<string>(group.nodeIds),
    subscriptions: asArray<GroupSubscription>(group.subscriptions),
    subscriptionNodes: asArray<GroupSubscriptionNode>(group.subscriptionNodes),
    filters: asArray<string>(group.filters),
  }))
  value.resources.dns.upstreams = asArray(value.resources.dns.upstreams)
  value.resources.dns.requestRules = asArray<string>(value.resources.dns.requestRules)
  value.resources.dns.responseRules = asArray<string>(value.resources.dns.responseRules)
  value.resources.routing.rules = asArray<string>(value.resources.routing.rules)
  return value
}

export function useDaeDashboard() {
  const state = ref<DaeState | null>(null)
  const loading = ref(true)
  const busy = ref(false)
  const dirty = ref(false)
  const toast = ref('')
  const toastError = ref(false)
  const resolvingSubscriptions = ref(new Set<string>())
  let toastTimer: ReturnType<typeof setTimeout> | undefined

  const nodes = computed(() => state.value?.resources.nodes ?? [])
  const subscriptions = computed(() => state.value?.resources.subscriptions ?? [])
  const groups = computed(() => state.value?.resources.groups ?? [])

  function setResolvingSubscription(id: string, resolving: boolean) {
    const next = new Set(resolvingSubscriptions.value)
    if (resolving) next.add(id)
    else next.delete(id)
    resolvingSubscriptions.value = next
  }

  function currentFiles(overrides: Partial<Record<'global' | 'dns' | 'node' | 'routing', string>> = {}) {
    if (!state.value) return {}
    return {
      global: { content: overrides.global ?? state.value.files.global.content },
      dns: { content: overrides.dns ?? state.value.files.dns.content },
      node: { content: overrides.node ?? state.value.files.node.content },
      routing: { content: overrides.routing ?? state.value.files.routing.content },
    }
  }

  function showToast(message: string, isError = false) {
    toast.value = message
    toastError.value = isError
    if (toastTimer) clearTimeout(toastTimer)
    toastTimer = setTimeout(() => {
      toast.value = ''
    }, 5000)
  }

  async function loadState(preserveDirty = false) {
    loading.value = true
    try {
      state.value = normalizeState(await request<DaeState>('state'))
      if (!preserveDirty) dirty.value = false
      void hydrateSubscriptions()
    } catch (error) {
      showToast(`读取独立 dae 状态失败：${(error as Error).message}`, true)
      throw error
    } finally {
      loading.value = false
    }
  }

  async function resolveSubscription(id: string, force = false, notify = false, allowPersistFallback = true) {
    if (!state.value || resolvingSubscriptions.value.has(id)) return false
    const current = state.value.resources.subscriptions.find((item) => item.id === id)
    if (!current) return false
    const requestedLink = current.link
    setResolvingSubscription(id, true)
    try {
      const result = await request<{ subscription: DaeSubscription }>('subscription/resolve', {
        id,
        link: requestedLink,
        force,
        allowPersistFallback,
      })
      const target = state.value?.resources.subscriptions.find((item) => item.id === id && item.link === requestedLink)
      if (target) {
        Object.assign(target, result.subscription, {
          nodes: asArray<DaeNode>(result.subscription.nodes),
        })
      }
      if (notify) showToast(`${id} 已解析 ${result.subscription.nodes?.length || 0} 个节点`)
      return true
    } catch (error) {
      const target = state.value?.resources.subscriptions.find((item) => item.id === id && item.link === requestedLink)
      if (target) {
        target.status = '拉取失败'
        target.previewError = (error as Error).message
      }
      if (notify) showToast((error as Error).message, true)
      return false
    } finally {
      setResolvingSubscription(id, false)
    }
  }

  async function pollServiceState() {
    if (!state.value) return false
    try {
      const result = await requestServiceStatus()
      const memoryMb = result.memory ? Number.parseFloat(result.memory) : Number.NaN
      if (state.value) {
        state.value.service = {
          ...state.value.service,
          running: result.running,
          pid: result.running ? state.value.service.pid : undefined,
          memoryKb: Number.isFinite(memoryMb) ? Math.round(memoryMb * 1024) : undefined,
        }
      }
      return true
    } catch {
      return false
    }
  }

  async function hydrateSubscriptions() {
    const queue = subscriptions.value.filter((item) => !item.previewAvailable).map((item) => item.id)
    const workers = Array.from({ length: Math.min(3, queue.length) }, async () => {
      while (queue.length) {
        const id = queue.shift()
        if (id) await resolveSubscription(id)
      }
    })
    await Promise.all(workers)
  }

  async function mutate(action: string, values: Record<string, unknown>, message = '') {
    if (!state.value) return false
    busy.value = true
    try {
      state.value = normalizeState(
        await request<DaeState>('mutate', {
          action,
          preview: true,
          revision: state.value.revision,
          files: currentFiles(),
          ...values,
        }),
      )
      dirty.value = true
      if (message) showToast(message)
      return true
    } catch (error) {
      showToast((error as Error).message, true)
      return false
    } finally {
      busy.value = false
    }
  }

  async function stageFile(key: 'global' | 'dns' | 'node' | 'routing', content: string, message: string) {
    if (!state.value) return false
    busy.value = true
    try {
      state.value = normalizeState(await request<DaeState>('preview', {
        revision: state.value.revision,
        validate: false,
        files: currentFiles({ [key]: content }),
      }))
      dirty.value = true
      showToast(message)
      return true
    } catch (error) {
      showToast((error as Error).message, true)
      return false
    } finally {
      busy.value = false
    }
  }

  function stageSettings(values: Partial<DaeSettings>, message = '服务设置修改已暂存') {
    if (!state.value) return false
    state.value.settings = { ...state.value.settings, ...values }
    dirty.value = true
    showToast(message)
    return true
  }

  async function validateConfig() {
    if (!state.value) return false
    busy.value = true
    try {
      const result = await request<{ output?: string }>('validate', { files: currentFiles() })
      showToast(result.output?.trim() || '配置验证通过：dae validate 返回成功')
      return true
    } catch (error) {
      showToast((error as Error).message, true)
      return false
    } finally {
      busy.value = false
    }
  }

  async function saveConfig() {
    if (!state.value) return false
    busy.value = true
    try {
      await request<ApplyResult>('save', {
        revision: state.value.revision,
        files: currentFiles(),
        settings: state.value.settings,
      })
      await loadState()
      showToast('配置已保存到文件，dae 尚未重载')
      return true
    } catch (error) {
      showToast((error as Error).message, true)
      return false
    } finally {
      busy.value = false
    }
  }

  async function applyConfig() {
    if (!state.value) return false
    busy.value = true
    try {
      const result = await request<ApplyResult>('apply', {
        revision: state.value.revision,
        files: currentFiles(),
        settings: state.value.settings,
      })
      await loadState()
      dirty.value = false
      const serviceAction = result.serviceAction?.replace(/_started$/, '')
      showToast(
        serviceAction === 'reload'
          ? '配置已保存，dae 热重载成功'
          : `配置已保存，dae 已执行 ${serviceAction || '应用'}`,
      )
      return true
    } catch (error) {
      showToast((error as Error).message, true)
      return false
    } finally {
      busy.value = false
    }
  }

  async function reloadService() {
    busy.value = true
    showToast('正在重载 dae 服务…')
    try {
      await request<ApplyResult>('reload', {})
      await loadState().catch(() => undefined)
      showToast('dae 服务已重载')
      return true
    } catch (error) {
      showToast((error as Error).message, true)
      return false
    } finally {
      busy.value = false
    }
  }

  async function restartService() {
    busy.value = true
    showToast('正在重启 dae 服务…')
    try {
      await request<ApplyResult>('restart', {})
      await loadState().catch(() => undefined)
      showToast('dae 服务已重启')
      return true
    } catch (error) {
      showToast((error as Error).message, true)
      return false
    } finally {
      busy.value = false
    }
  }

  return {
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
  }
}
