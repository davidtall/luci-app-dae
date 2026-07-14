<script setup lang="ts">
import { computed, reactive, watch } from 'vue'
import { Plus, Trash2 } from '@lucide/vue'
import { ruleFormRows } from '../config'
import type { DnsFormValues } from '../config'
import type { DaeDnsConfig } from '../types'
import BaseDialog from './BaseDialog.vue'
import RuleListEditor from './RuleListEditor.vue'

const props = defineProps<{ open: boolean; dns: DaeDnsConfig; busy: boolean }>()
const emit = defineEmits<{
  close: []
  save: [values: DnsFormValues]
}>()

const form = reactive<DnsFormValues>({ upstreams: [], requestRules: [], responseRules: [] })

watch(
  () => [props.open, props.dns] as const,
  ([open, dns]) => {
    if (!open) return
    form.upstreams = (dns.upstreams || []).map((item) => ({ ...item }))
    form.requestRules = ruleFormRows(dns.requestRules)
    form.responseRules = ruleFormRows(dns.responseRules)
  },
  { immediate: true },
)

const targetOptions = computed(() => [
  ...new Set([
    ...form.upstreams.map((item) => item.id.trim()).filter(Boolean),
    'accept',
    'reject',
  ]),
])

const validationError = computed(() => {
  const ids = new Set<string>()
  for (const upstream of form.upstreams) {
    const id = upstream.id.trim()
    if (!id || !upstream.link.trim()) return '上游名称和地址不能为空。'
    if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(id)) return `上游名称 ${id} 只能包含字母、数字、下划线和连字符，且不能以数字开头。`
    if (ids.has(id)) return `上游名称 ${id} 重复。`
    ids.add(id)
  }
  for (const rule of [...form.requestRules, ...form.responseRules]) {
    if (!rule.condition.trim() || !rule.target.trim()) return '规则的匹配条件和目标不能为空。'
  }
  return ''
})

function addUpstream() {
  form.upstreams.push({ id: '', link: '' })
}

function removeUpstream(index: number) {
  form.upstreams.splice(index, 1)
}

function save() {
  if (validationError.value) return
  emit('save', {
    upstreams: form.upstreams.map((item) => ({ ...item })),
    requestRules: form.requestRules.map((item) => ({ ...item })),
    responseRules: form.responseRules.map((item) => ({ ...item })),
  })
}
</script>

<template>
  <BaseDialog :open="open" title="DNS 可视化配置" wide @close="$emit('close')">
    <p class="visual-note">这里只更新上游 DNS、请求规则和响应规则；缓存参数等其它 DNS 字段会原样保留。源码编辑可处理更高级的配置。</p>

    <section class="visual-section">
      <div class="visual-section-head">
        <div class="visual-section-copy">
          <strong>上游 DNS</strong>
          <small>名称用于规则目标，地址支持 udp、tcp、tcp+udp、https 等 dae 支持的协议。</small>
        </div>
        <button type="button" class="btn btn-ghost btn-small" @click="addUpstream"><Plus :size="14" />添加上游</button>
      </div>
      <div v-if="form.upstreams.length" class="upstream-list">
        <div v-for="(upstream, index) in form.upstreams" :key="index" class="upstream-editor-row">
          <input v-model.trim="upstream.id" placeholder="名称，例如 localdns" aria-label="上游名称" />
          <input v-model.trim="upstream.link" placeholder="地址，例如 udp://127.0.0.1:53" aria-label="上游地址" />
          <button type="button" class="btn btn-ghost icon-btn" aria-label="删除上游" @click="removeUpstream(index)"><Trash2 :size="14" /></button>
        </div>
      </div>
      <div v-else class="empty-editor">暂无上游 DNS</div>
    </section>

    <RuleListEditor
      v-model="form.requestRules"
      title="请求路由"
      hint="匹配 DNS 请求并选择上游；fallback 可直接填写在匹配条件中。"
      condition-placeholder="例如 qname(geosite:gfw) 或 fallback"
      target-placeholder="例如 overseadns"
      :target-options="targetOptions"
    />
    <RuleListEditor
      v-model="form.responseRules"
      title="响应路由"
      hint="按上游、域名或 IP 等响应条件决定 accept、reject 或切换上游。"
      condition-placeholder="例如 upstream(overseadns) 或 fallback"
      target-placeholder="例如 accept"
      :target-options="targetOptions"
    />

    <p v-if="validationError" class="form-error">{{ validationError }}</p>
    <template #footer>
      <button type="button" class="btn" :disabled="busy" @click="$emit('close')">取消</button>
      <button type="button" class="btn btn-primary" :disabled="busy || !!validationError" @click="save">确认修改</button>
    </template>
  </BaseDialog>
</template>
