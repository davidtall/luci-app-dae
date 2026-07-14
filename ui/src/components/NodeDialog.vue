<script setup lang="ts">
import { reactive, watch } from 'vue'
import type { DaeNode } from '../types'
import BaseDialog from './BaseDialog.vue'

const props = defineProps<{ open: boolean; item: DaeNode | null; busy: boolean }>()
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
  <BaseDialog :open="open" :title="item ? '编辑节点' : '新增节点'" @close="$emit('close')">
    <div class="form-grid">
      <label class="field">
        <span>节点标签</span>
        <input v-model.trim="form.id" placeholder="例如 hk" autocomplete="off" />
        <small>可使用字母、数字、点、短横线和下划线。</small>
      </label>
      <label class="field form-span">
        <span>分享链接</span>
        <textarea v-model.trim="form.link" rows="5" placeholder="ss://、vless://、hysteria2:// …" />
      </label>
    </div>
    <template #footer>
      <button v-if="item" type="button" class="btn btn-danger mr-auto" :disabled="busy" @click="$emit('remove', form.previousId)">删除</button>
      <button type="button" class="btn" :disabled="busy" @click="$emit('close')">取消</button>
      <button type="button" class="btn btn-primary" :disabled="busy || !form.id || !form.link" @click="$emit('save', { ...form })">确认修改</button>
    </template>
  </BaseDialog>
</template>
