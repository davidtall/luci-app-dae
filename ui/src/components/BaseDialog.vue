<script setup lang="ts">
import { nextTick, ref, watch } from 'vue'
import { X } from '@lucide/vue'

const props = withDefaults(
  defineProps<{
    open: boolean
    title: string
    wide?: boolean
    bodyClass?: string
  }>(),
  { wide: false, bodyClass: '' },
)

const emit = defineEmits<{ close: [] }>()
const dialog = ref<HTMLDialogElement | null>(null)

watch(
  () => props.open,
  async (open) => {
    await nextTick()
    if (open && !dialog.value?.open) dialog.value?.showModal()
    if (!open && dialog.value?.open) dialog.value.close()
  },
  { immediate: true },
)

function handleClose() {
  emit('close')
}
</script>

<template>
  <dialog
    ref="dialog"
    class="modal"
    :class="{ 'modal-wide': wide }"
    @cancel.prevent="handleClose"
    @close="handleClose"
  >
    <div class="modal-head">
      <h2>{{ title }}</h2>
      <button type="button" class="btn btn-ghost icon-btn" aria-label="关闭" @click="handleClose">
        <X :size="17" />
      </button>
    </div>
    <div class="modal-body" :class="bodyClass">
      <slot />
    </div>
    <div v-if="$slots.footer" class="modal-actions">
      <slot name="footer" />
    </div>
  </dialog>
</template>
