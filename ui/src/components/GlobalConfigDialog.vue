<script setup lang="ts">
import { reactive, watch } from 'vue'
import { globalFormValues } from '../config'
import type { DaeGlobalConfig } from '../types'
import BaseDialog from './BaseDialog.vue'
import ListInput from './ListInput.vue'

const props = defineProps<{ open: boolean; global: DaeGlobalConfig; busy: boolean }>()
const emit = defineEmits<{
  close: []
  save: [values: ReturnType<typeof globalFormValues>]
}>()

const httpMethods = ['CONNECT', 'HEAD', 'OPTIONS', 'TRACE', 'GET', 'POST', 'DELETE', 'PATCH', 'PUT']
const utlsOptions = [
  'chrome_auto', 'chrome_58', 'chrome_62', 'chrome_70', 'chrome_72', 'chrome_83', 'chrome_87', 'chrome_96',
  'chrome_100', 'chrome_102', 'firefox_auto', 'firefox_55', 'firefox_56', 'firefox_63', 'firefox_65',
  'firefox_99', 'firefox_102', 'firefox_105', 'safari_auto', 'safari_16_0', 'edge_auto', 'edge_85',
  'edge_106', 'ios_auto', 'ios_11_1', 'ios_12_1', 'ios_13', 'ios_14', 'android_11_okhttp', '360_auto',
  '360_7_5', '360_11_0', 'qq_auto', 'qq_11_1', 'randomized', 'randomizedalpn', 'randomizednoalpn',
]

const form = reactive(globalFormValues({}))
watch(
  () => [props.open, props.global] as const,
  ([open, global]) => {
    if (open) Object.assign(form, globalFormValues(global))
  },
  { immediate: true },
)
</script>

<template>
  <BaseDialog :open="open" title="全局配置" wide @close="$emit('close')">
    <details class="config-group" open>
      <summary>软件选项</summary>
      <div class="config-group-body software-options-layout">
        <div class="software-primary-grid">
          <label class="field">
            <span>透明代理端口</span>
            <input v-model.number="form.tproxyPort" type="number" min="0" max="65535" />
            <small>dae 内部透明代理监听端口，不是 HTTP 或 SOCKS 端口。</small>
          </label>
          <label class="field">
            <span>SO_MARK</span>
            <input v-model.number="form.soMarkFromDae" type="number" min="0" max="4294967295" />
            <small>dae 发出连接时使用的 socket mark。</small>
          </label>
          <label class="field">
            <span>日志级别</span>
            <select v-model="form.logLevel"><option>error</option><option>warn</option><option>info</option><option>debug</option><option>trace</option></select>
            <small>控制 dae 运行日志的详细程度。</small>
          </label>
        </div>
        <div class="software-switches">
          <label class="switch-row"><span><strong>保护透明代理端口</strong><small>阻止未经请求的流量访问透明代理端口。</small></span><input v-model="form.tproxyPortProtect" type="checkbox" /></label>
          <label class="switch-row"><span><strong>禁用等待网络</strong><small>启动时不等待网络联通。</small></span><input v-model="form.disableWaitingNetwork" type="checkbox" /></label>
          <label class="switch-row"><span><strong>本地 TCP 快速重定向</strong><small>启用本地 TCP fast redirect。</small></span><input v-model="form.enableLocalTcpFastRedirect" type="checkbox" /></label>
          <label class="switch-row"><span><strong>MPTCP</strong><small>允许支持的出站连接使用 MPTCP。</small></span><input v-model="form.mptcp" type="checkbox" /></label>
        </div>
      </div>
    </details>

    <details class="config-group" open>
      <summary>接口与内核选项</summary>
      <div class="config-group-body">
        <div class="form-grid">
          <ListInput v-model="form.lanInterfaces" label="LAN 接口" placeholder="br-lan" hint="可配置多个接口；留空表示不绑定 LAN。" />
          <ListInput v-model="form.wanInterfaces" label="WAN 接口" placeholder="auto" hint="使用 auto 自动检测默认 WAN，也可以配置多个接口。" required />
          <label class="switch-row form-span"><span><strong>自动配置内核参数</strong><small>启动时应用 dae 推荐的内核参数。</small></span><input v-model="form.autoKernel" type="checkbox" /></label>
        </div>
      </div>
    </details>

    <details class="config-group" open>
      <summary>节点连通性检测</summary>
      <div class="config-group-body connectivity-layout">
        <div class="connectivity-address-grid">
          <div class="connectivity-card">
            <ListInput v-model="form.tcpCheckUrls" label="TCP 检测地址" placeholder="http://cp.cloudflare.com" hint="第一项为 URL，后续可填写对应 IPv4/IPv6 地址。" required />
          </div>
          <div class="connectivity-card">
            <ListInput v-model="form.udpCheckDns" label="UDP 检测 DNS" placeholder="dns.google:53" hint="第一项为 DNS 地址，后续可填写对应 IPv4/IPv6 地址。" required />
          </div>
        </div>

        <div class="connectivity-options">
          <div class="connectivity-options-head">
            <strong>检测参数</strong>
            <small>用于所有节点的周期性 TCP 与 UDP 连通性检测。</small>
          </div>
          <label class="field">
            <span>TCP HTTP 方法</span>
            <select v-model="form.tcpCheckHttpMethod"><option v-for="method in httpMethods" :key="method">{{ method }}</option></select>
          </label>
          <label class="field"><span>检查间隔（秒）</span><input v-model.number="form.checkIntervalSeconds" type="number" min="0" /></label>
          <label class="field"><span>检查容差（毫秒）</span><input v-model.number="form.checkToleranceMs" type="number" min="0" /></label>
          <label class="field resolver-field"><span>Bootstrap Resolver</span><input v-model.trim="form.bootstrapResolver" placeholder="可选" /></label>
          <label class="field resolver-field"><span>Fallback Resolver</span><input v-model.trim="form.fallbackResolver" placeholder="8.8.8.8:53" /></label>
        </div>
      </div>
    </details>

    <details class="config-group" open>
      <summary>连接选项</summary>
      <div class="config-group-body form-grid form-grid-three">
        <label class="field">
          <span>拨号模式</span>
          <select v-model="form.dialMode"><option>ip</option><option>domain</option><option>domain+</option><option>domain++</option></select>
        </label>
        <label class="field"><span>嗅探超时（毫秒）</span><input v-model.number="form.sniffingTimeoutMs" type="number" min="0" /></label>
        <label class="field"><span>TLS 实现</span><select v-model="form.tlsImplementation"><option>tls</option><option>utls</option></select></label>
        <label v-if="form.tlsImplementation === 'utls'" class="field form-span"><span>uTLS 指纹</span><select v-model="form.utlsImitate"><option v-for="item in utlsOptions" :key="item">{{ item }}</option></select></label>
        <label class="field"><span>最大上行带宽</span><input v-model.trim="form.bandwidthMaxTx" placeholder="200 mbps" /></label>
        <label class="field"><span>最大下行带宽</span><input v-model.trim="form.bandwidthMaxRx" placeholder="1 gbps" /></label>
        <label class="switch-row form-span"><span><strong>允许不安全 TLS</strong><small>仅在明确了解风险时启用。</small></span><input v-model="form.allowInsecure" type="checkbox" /></label>
      </div>
    </details>

    <template #footer>
      <button type="button" class="btn" :disabled="busy" @click="$emit('close')">取消</button>
      <button type="button" class="btn btn-primary" :disabled="busy" @click="$emit('save', { ...form })">确认修改</button>
    </template>
  </BaseDialog>
</template>
