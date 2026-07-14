<script setup lang="ts">
import { ref, watch } from 'vue'
import BaseDialog from './BaseDialog.vue'

const props = defineProps<{
  open: boolean
  title: string
  content: string
  busy: boolean
}>()

defineEmits<{
  close: []
  save: [content: string]
}>()

const draft = ref('')
watch(
  () => [props.open, props.content] as const,
  ([open, content]) => {
    if (open) draft.value = content
  },
  { immediate: true },
)
</script>

<template>
  <BaseDialog :open="open" :title="title" wide body-class="source-editor-body" @close="$emit('close')">
    <textarea v-model="draft" class="code-editor" spellcheck="false" />
    <template #footer>
      <button type="button" class="btn" :disabled="busy" @click="$emit('close')">取消</button>
      <button type="button" class="btn btn-primary" :disabled="busy" @click="$emit('save', draft)">确认修改</button>
    </template>
  </BaseDialog>
</template>
