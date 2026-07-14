export interface DaeFile {
  path: string
  content: string
}

export interface DaeNode {
  id: string
  tag?: string
  name?: string
  link: string
  protocol?: string
  address?: string
  source?: string
  subscriptionId?: string
}

export interface DaeSubscription extends DaeNode {
  previewAvailable?: boolean
  nodes?: DaeNode[]
  status?: string
  updatedAt?: string | number
  previewSource?: 'persist' | 'temporary' | 'remote' | 'missing'
  previewError?: string
}

export interface GroupSubscription {
  id?: string
  filterId?: string
  subscriptionId: string
  nameFilterRegex?: string
}

export interface GroupSubscriptionNode {
  id?: string
  filterId?: string
  subscriptionId: string
  nodeName: string
}

export interface DaeGroup {
  id: string
  name?: string
  policy?: string
  nodeIds?: string[]
  subscriptions?: GroupSubscription[]
  subscriptionNodes?: GroupSubscriptionNode[]
  filters?: string[]
}

export interface DaeGlobalConfig {
  log_level?: string
  sniffing_timeout?: string
  dial_mode?: string
  lan_interface?: string
  wan_interface?: string
  check_interval?: string
  check_tolerance?: string
  tcp_check_url?: string
  udp_check_dns?: string
  auto_config_kernel_parameter?: boolean
  allow_insecure?: boolean
  [key: string]: string | boolean | undefined
}

export interface DaeDnsUpstream {
  id: string
  link: string
}

export interface DaeDnsConfig {
  upstreams?: DaeDnsUpstream[]
  requestRules?: string[]
  responseRules?: string[]
}

export interface DaeRoutingConfig {
  rules?: string[]
  fallback?: string
}

export interface DaeState {
  ok: boolean
  revision: string
  dirty?: boolean
  service: {
    enabled: boolean
    running: boolean
    pid?: number
    memoryKb?: number
    version?: string
  }
  settings: Record<string, unknown>
  files: {
    global: DaeFile
    dns: DaeFile
    node: DaeFile
    routing: DaeFile
  }
  resources: {
    global: DaeGlobalConfig
    dns: DaeDnsConfig
    routing: DaeRoutingConfig
    nodes: DaeNode[]
    subscriptions: DaeSubscription[]
    groups: DaeGroup[]
  }
  warnings?: string[]
}

export interface ApiErrorBody {
  ok?: boolean
  output?: string
  serviceOutput?: string
  error?: {
    code?: string
    message?: string
  }
}

export interface ApplyResult extends ApiErrorBody {
  serviceAction?: string
  revision?: string
}
