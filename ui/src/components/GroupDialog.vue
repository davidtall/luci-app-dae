<script setup lang="ts">
import { reactive, watch } from 'vue'
import type { DaeGroup } from '../types'
import BaseDialog from './BaseDialog.vue'

const props = defineProps<{ open: boolean; item: DaeGroup | null; busy: boolean }>()
const emit = defineEmits<{
  close: []
  save: [values: { previousId: string; id: string; policy: string }]
  remove: [id: string]
}>()

const form = reactive({ previousId: '', id: '', policy: 'min_moving_avg' })

watch(
  () => [props.open, props.item] as const,
  ([open, item]) => {
    if (!open) return
    form.previousId = item?.id || ''
    form.id = item?.id || ''
    form.policy = item?.policy || 'min_moving_avg'
  },
  { immediate: true },
)
</script>

<template>
  <BaseDialog :open="open" :title="item ? '编辑群组' : '新增群组'" @close="$emit('close')">
    <div class="form-grid form-grid-one">
      <label class="field">
        <span>群组名称</span>
        <input v-model.trim="form.id" placeholder="例如 proxy" autocomplete="off" />
      </label>
      <label class="field">
        <span>选择策略</span>
        <select v-model="form.policy">
          <option value="min_moving_avg">min_moving_avg</option>
          <option value="min_avg10">min_avg10</option>
          <option value="min">min</option>
          <option value="random">random</option>
          <option value="fixed">fixed</option>
        </select>
        <small v-if="form.policy === 'min_moving_avg'">选择移动平均延迟最小的节点。</small>
        <small v-else-if="form.policy === 'min_avg10'">选择最近 10 次延迟平均值最小的节点。</small>
        <small v-else-if="form.policy === 'min'">选择最后一次延迟最小的节点。</small>
        <small v-else-if="form.policy === 'random'">为每个连接随机选择节点。</small>
        <small v-else>选择索引为 0 的固定节点，群组中应只有一个节点。</small>
      </label>
    </div>
    <template #footer>
      <button v-if="item" type="button" class="btn btn-danger mr-auto" :disabled="busy" @click="$emit('remove', form.previousId)">删除</button>
      <button type="button" class="btn" :disabled="busy" @click="$emit('close')">取消</button>
      <button type="button" class="btn btn-primary" :disabled="busy || !form.id" @click="$emit('save', { ...form })">确认修改</button>
    </template>
  </BaseDialog>
</template>
