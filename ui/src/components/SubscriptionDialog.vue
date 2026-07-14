<script setup lang="ts">
import { reactive, watch } from 'vue'
import type { DaeSubscription } from '../types'
import BaseDialog from './BaseDialog.vue'

const props = defineProps<{ open: boolean; item: DaeSubscription | null; busy: boolean }>()
const emit = defineEmits<{
  close: []
  save: [values: { previousId: string; id: string; link: string }]
  remove: [id: string]
}>()

const form = reactive({ previousId: '', id: '', link: '' })

watch(
  () => [props.open, props.item] as const,
  ([open, item]) => {
    if (!open) return
    form.previousId = item?.id || ''
    form.id = item?.id || ''
    form.link = item?.link || ''
  },
  { immediate: true },
)
</script>

<template>
  <BaseDialog :open="open" :title="item ? '编辑订阅' : '新增订阅'" @close="$emit('close')">
    <div class="form-grid">
      <label class="field">
        <span>订阅标签</span>
        <input v-model.trim="form.id" placeholder="例如 premium" autocomplete="off" />
      </label>
      <label class="field form-span">
        <span>订阅地址</span>
        <textarea v-model.trim="form.link" rows="4" placeholder="https://example.com/subscription" />
      </label>
      <p class="form-hint form-span">确认后会立即拉取并预览节点；正式保存时 HTTP/HTTPS 地址会转换为 http-file/https-file，由 dae 持久化订阅内容。</p>
    </div>
    <template #footer>
      <button v-if="item" type="button" class="btn btn-danger mr-auto" :disabled="busy" @click="$emit('remove', form.previousId)">删除</button>
      <button type="button" class="btn" :disabled="busy" @click="$emit('close')">取消</button>
      <button type="button" class="btn btn-primary" :disabled="busy || !form.id || !form.link" @click="$emit('save', { ...form })">确认修改</button>
    </template>
  </BaseDialog>
</template>
