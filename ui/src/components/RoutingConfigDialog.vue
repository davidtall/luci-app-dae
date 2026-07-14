<script setup lang="ts">
import { computed, reactive, watch } from 'vue'
import { ruleFormRows } from '../config'
import type { RoutingFormValues } from '../config'
import type { DaeGroup, DaeRoutingConfig } from '../types'
import BaseDialog from './BaseDialog.vue'
import RuleListEditor from './RuleListEditor.vue'

const props = defineProps<{ open: boolean; routing: DaeRoutingConfig; groups: DaeGroup[]; busy: boolean }>()
const emit = defineEmits<{
  close: []
  save: [values: RoutingFormValues]
}>()

const form = reactive<RoutingFormValues>({ rules: [], fallback: '' })

watch(
  () => [props.open, props.routing] as const,
  ([open, routing]) => {
    if (!open) return
    form.rules = ruleFormRows((routing.rules || []).filter((rule) => !/^fallback\s*:/.test(rule.trim())))
    form.fallback = routing.fallback || ''
  },
  { immediate: true },
)

const targetOptions = computed(() => [
  ...new Set([
    ...props.groups.map((group) => group.id).filter(Boolean),
    'direct',
    'must_direct',
    'block',
  ]),
])

const validationError = computed(() => {
  for (const rule of form.rules) {
    if (!rule.condition.trim() || !rule.target.trim()) return '规则的匹配条件和目标不能为空。'
    if (rule.condition.trim().toLowerCase() === 'fallback') return 'fallback 请使用下方的默认目标字段配置。'
  }
  if (!form.fallback.trim()) return '路由 fallback 不能为空。'
  return ''
})

function save() {
  if (validationError.value) return
  emit('save', {
    rules: form.rules.map((item) => ({ ...item })),
    fallback: form.fallback,
  })
}
</script>

<template>
  <BaseDialog :open="open" title="路由可视化配置" wide @close="$emit('close')">
    <p class="visual-note">规则按从上到下的顺序匹配。保存时只替换活动规则，原配置中的注释和空行会尽量保留；复杂表达式仍可通过源码编辑处理。</p>

    <RuleListEditor
      v-model="form.rules"
      title="路由规则"
      hint="左侧填写 dae 匹配表达式，右侧填写群组或 direct、must_direct、block。"
      condition-placeholder="例如 domain(geosite:gfw)"
      target-placeholder="例如 proxy"
      :target-options="targetOptions"
    />

    <section class="visual-section">
      <div class="visual-section-copy">
        <strong>默认目标（fallback）</strong>
        <small>所有规则都未匹配时使用的群组或动作。</small>
      </div>
      <label class="field routing-fallback-field">
        <span>fallback</span>
        <input v-model.trim="form.fallback" list="dae-routing-targets" placeholder="例如 proxy" />
      </label>
      <datalist id="dae-routing-targets">
        <option v-for="option in targetOptions" :key="option" :value="option" />
      </datalist>
    </section>

    <p v-if="validationError" class="form-error">{{ validationError }}</p>
    <template #footer>
      <button type="button" class="btn" :disabled="busy" @click="$emit('close')">取消</button>
      <button type="button" class="btn btn-primary" :disabled="busy || !!validationError" @click="save">确认修改</button>
    </template>
  </BaseDialog>
</template>
