<script setup lang="ts">
import { ArrowDown, ArrowUp, Plus, Trash2 } from '@lucide/vue'
import { computed, useId } from 'vue'
import type { RuleFormRow } from '../config'

const props = withDefaults(
  defineProps<{
    modelValue: RuleFormRow[]
    title: string
    hint?: string
    conditionPlaceholder?: string
    targetPlaceholder?: string
    targetOptions?: string[]
    targetSelect?: boolean
  }>(),
  {
    hint: '',
    conditionPlaceholder: '例如 qname(geosite:gfw)',
    targetPlaceholder: '例如 proxy',
    targetOptions: () => [],
    targetSelect: false,
  },
)

const emit = defineEmits<{ 'update:modelValue': [value: RuleFormRow[]] }>()
const optionListId = `dae-rule-targets-${useId().replace(/:/g, '')}`
const selectOptions = computed(() => [
  ...new Set([
    ...props.targetOptions,
    ...props.modelValue.map((item) => item.target.trim()).filter(Boolean),
  ]),
])

function update(index: number, key: keyof RuleFormRow, value: string) {
  const next = props.modelValue.map((item) => ({ ...item }))
  next[index][key] = value
  emit('update:modelValue', next)
}

function add() {
  emit('update:modelValue', [...props.modelValue, { condition: '', target: '' }])
}

function insert(index: number) {
  const next = props.modelValue.map((item) => ({ ...item }))
  next.splice(index, 0, { condition: '', target: '' })
  emit('update:modelValue', next)
}

function remove(index: number) {
  emit('update:modelValue', props.modelValue.filter((_, itemIndex) => itemIndex !== index))
}

function move(index: number, offset: number) {
  const target = index + offset
  if (target < 0 || target >= props.modelValue.length) return
  const next = props.modelValue.map((item) => ({ ...item }))
  const [item] = next.splice(index, 1)
  next.splice(target, 0, item)
  emit('update:modelValue', next)
}
</script>

<template>
  <section class="visual-section">
    <div class="visual-section-head">
      <div class="visual-section-copy">
        <strong>{{ title }}</strong>
        <small v-if="hint">{{ hint }}</small>
      </div>
      <button type="button" class="btn btn-ghost btn-small" @click="add"><Plus :size="14" />添加规则</button>
    </div>

    <div v-if="modelValue.length" class="rule-editor-list">
      <div v-for="(rule, index) in modelValue" :key="index" class="visual-rule-row">
        <input
          :value="rule.condition"
          :placeholder="conditionPlaceholder"
          aria-label="匹配条件"
          @input="update(index, 'condition', ($event.target as HTMLInputElement).value)"
        />
        <span>→</span>
        <select
          v-if="targetSelect"
          :value="rule.target"
          aria-label="目标"
          @change="update(index, 'target', ($event.target as HTMLSelectElement).value)"
        >
          <option value="" disabled>{{ targetPlaceholder }}</option>
          <option v-for="option in selectOptions" :key="option" :value="option">{{ option }}</option>
        </select>
        <input
          v-else
          :value="rule.target"
          :list="optionListId"
          :placeholder="targetPlaceholder"
          aria-label="目标"
          @input="update(index, 'target', ($event.target as HTMLInputElement).value)"
        />
        <div class="row-actions">
          <button type="button" class="btn btn-ghost icon-btn" title="在此处插入规则" aria-label="在此处插入规则" @click="insert(index)"><Plus :size="14" /></button>
          <button type="button" class="btn btn-ghost icon-btn" :disabled="index === 0" aria-label="上移" @click="move(index, -1)"><ArrowUp :size="14" /></button>
          <button type="button" class="btn btn-ghost icon-btn" :disabled="index === modelValue.length - 1" aria-label="下移" @click="move(index, 1)"><ArrowDown :size="14" /></button>
          <button type="button" class="btn btn-ghost icon-btn" aria-label="删除规则" @click="remove(index)"><Trash2 :size="14" /></button>
        </div>
      </div>
    </div>
    <div v-else class="empty-editor">暂无规则</div>

    <datalist v-if="!targetSelect" :id="optionListId">
      <option v-for="option in targetOptions" :key="option" :value="option" />
    </datalist>
  </section>
</template>
