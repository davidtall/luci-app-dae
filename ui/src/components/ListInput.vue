<script setup lang="ts">
import { Plus, Trash2 } from '@lucide/vue'

const props = withDefaults(
  defineProps<{
    modelValue: string[]
    label: string
    hint?: string
    placeholder?: string
    required?: boolean
  }>(),
  { hint: '', placeholder: '', required: false },
)

const emit = defineEmits<{ 'update:modelValue': [value: string[]] }>()

function update(index: number, value: string) {
  const next = [...props.modelValue]
  next[index] = value
  emit('update:modelValue', next)
}

function add() {
  emit('update:modelValue', [...props.modelValue, ''])
}

function remove(index: number) {
  const next = props.modelValue.filter((_, itemIndex) => itemIndex !== index)
  emit('update:modelValue', props.required && !next.length ? [''] : next)
}
</script>

<template>
  <div class="list-field">
    <div class="list-field-head">
      <strong>{{ label }}</strong>
      <button type="button" class="btn btn-ghost btn-small" @click="add"><Plus :size="14" />添加</button>
    </div>
    <div class="list-items">
      <div v-for="(item, index) in modelValue" :key="index" class="list-row">
        <input :value="item" :placeholder="placeholder" @input="update(index, ($event.target as HTMLInputElement).value)" />
        <button type="button" class="btn btn-ghost icon-btn" aria-label="删除" @click="remove(index)"><Trash2 :size="14" /></button>
      </div>
    </div>
    <small v-if="hint">{{ hint }}</small>
  </div>
</template>
