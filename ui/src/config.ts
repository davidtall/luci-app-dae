import type { DaeDnsUpstream, DaeGlobalConfig } from './types'

interface BlockRange {
  open: number
  close: number
}

function namedBlock(content: string, name: string): BlockRange | null {
  const match = new RegExp(`(^|\\n)[ \\t]*${escapeRegExp(name)}\\s*\\{`, 'm').exec(content)
  if (!match) return null

  const open = content.indexOf('{', match.index)
  let depth = 0
  let quote = ''
  let escaped = false
  let comment = false

  for (let index = open; index < content.length; index += 1) {
    const char = content[index]
    if (comment) {
      if (char === '\n') comment = false
    } else if (quote) {
      if (escaped) escaped = false
      else if (char === '\\') escaped = true
      else if (char === quote) quote = ''
    } else if (char === '#') comment = true
    else if (char === "'" || char === '"') quote = char
    else if (char === '{') depth += 1
    else if (char === '}' && --depth === 0) return { open, close: index }
  }
  return null
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function blockBody(content: string, name: string): { block: BlockRange; body: string } {
  const block = namedBlock(content, name)
  if (!block) throw new Error(`找不到 ${name} 配置块`)
  return { block, body: content.slice(block.open + 1, block.close) }
}

function replaceBlockBody(content: string, block: BlockRange, body: string): string {
  return content.slice(0, block.open + 1) + body + content.slice(block.close)
}

function activeRule(line: string): boolean {
  const value = line.trim()
  return !!value && !value.startsWith('#') && (value.includes('->') || /^fallback\s*:/.test(value))
}

function activeEntry(line: string): boolean {
  const value = line.trim()
  return !!value && !value.startsWith('#') && /^[A-Za-z_][A-Za-z0-9_-]*\s*:/.test(value)
}

function replaceActiveLines(
  body: string,
  replacements: string[],
  predicate: (line: string) => boolean,
  defaultIndent: string,
): string {
  const newline = body.includes('\r\n') ? '\r\n' : '\n'
  const lines = body.split(/\r?\n/)
  const output: string[] = []
  let replacementIndex = 0
  let insertAt = -1
  let indent = defaultIndent

  for (const line of lines) {
    if (!predicate(line)) {
      output.push(line)
      continue
    }

    indent = line.match(/^\s*/)?.[0] || indent
    if (replacementIndex < replacements.length) {
      output.push(`${indent}${replacements[replacementIndex]}`)
      replacementIndex += 1
    }
    insertAt = output.length
  }

  if (replacementIndex < replacements.length) {
    if (insertAt < 0) {
      insertAt = output.length
      while (insertAt > 0 && !output[insertAt - 1].trim()) insertAt -= 1
    }
    output.splice(
      insertAt,
      0,
      ...replacements.slice(replacementIndex).map((line) => `${indent}${line}`),
    )
  }

  return output.join(newline)
}

function replaceBlockActiveLines(
  content: string,
  name: string,
  replacements: string[],
  predicate: (line: string) => boolean,
  defaultIndent: string,
): string {
  const { block, body } = blockBody(content, name)
  return replaceBlockBody(content, block, replaceActiveLines(body, replacements, predicate, defaultIndent))
}

export function quoteDae(value: string): string {
  return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

export function quoteDaeList(values: string[]): string {
  return quoteDae(values.map((value) => value.trim()).filter(Boolean).join(','))
}

function splitList(value: unknown, fallback: string[] = []): string[] {
  if (Array.isArray(value)) return value.map(String).map((item) => item.trim()).filter(Boolean)
  if (typeof value !== 'string' || !value.trim()) return [...fallback]
  return value.split(',').map((item) => item.trim()).filter(Boolean)
}

function numericPart(value: unknown, fallback: number): number {
  const parsed = Number.parseFloat(String(value ?? ''))
  return Number.isFinite(parsed) ? parsed : fallback
}

export function updateGlobalValues(
  content: string,
  values: Record<string, string | boolean>,
): string {
  const block = namedBlock(content, 'global')
  if (!block) throw new Error('找不到 global 配置块')

  const newline = content.includes('\r\n') ? '\r\n' : '\n'
  let body = content.slice(block.open + 1, block.close)
  if (!body.startsWith('\n') && !body.startsWith('\r\n')) body = `${newline}${body}`

  Object.entries(values).forEach(([key, value]) => {
    const line = `    ${key}: ${String(value)}`
    const pattern = new RegExp(`(^|\\n)[ \\t]*${escapeRegExp(key)}[ \\t]*:[^\\r\\n]*`)
    if (pattern.test(body)) body = body.replace(pattern, `$1${line}`)
    else body = `${body.replace(/\s*$/, '')}${newline}${line}${newline}`
  })

  if (!body.endsWith('\n')) body += newline

  return content.slice(0, block.open + 1) + body + content.slice(block.close)
}

export interface RuleFormRow {
  condition: string
  target: string
}

export interface DnsFormValues {
  upstreams: DaeDnsUpstream[]
  requestRules: RuleFormRow[]
  responseRules: RuleFormRow[]
}

export interface RoutingFormValues {
  rules: RuleFormRow[]
  fallback: string
}

export function ruleFormRows(rules: string[] = []): RuleFormRow[] {
  return rules.map((rule) => {
    const fallback = /^fallback\s*:\s*(.+)$/.exec(rule.trim())
    if (fallback) return { condition: 'fallback', target: fallback[1].trim() }
    const arrow = rule.lastIndexOf('->')
    if (arrow < 0) return { condition: rule.trim(), target: '' }
    return {
      condition: rule.slice(0, arrow).trim(),
      target: rule.slice(arrow + 2).trim(),
    }
  })
}

function ruleLines(rows: RuleFormRow[], includeFallback = true): string[] {
  return rows
    .map(({ condition, target }) => ({ condition: condition.trim(), target: target.trim() }))
    .filter(({ condition, target }) => condition && target)
    .map(({ condition, target }) =>
      includeFallback && condition.toLowerCase() === 'fallback'
        ? `fallback: ${target}`
        : `${condition} -> ${target}`,
    )
}

export function updateDnsFromForm(content: string, values: DnsFormValues): string {
  const dns = blockBody(content, 'dns')
  let body = dns.body
  body = replaceBlockActiveLines(
    body,
    'upstream',
    values.upstreams
      .map(({ id, link }) => ({ id: id.trim(), link: link.trim() }))
      .filter(({ id, link }) => id && link)
      .map(({ id, link }) => `${id}: ${quoteDae(link)}`),
    activeEntry,
    '        ',
  )

  const routing = blockBody(body, 'routing')
  let routingBody = routing.body
  routingBody = replaceBlockActiveLines(
    routingBody,
    'request',
    ruleLines(values.requestRules),
    activeRule,
    '            ',
  )
  routingBody = replaceBlockActiveLines(
    routingBody,
    'response',
    ruleLines(values.responseRules),
    activeRule,
    '            ',
  )
  body = replaceBlockBody(body, routing.block, routingBody)
  return replaceBlockBody(content, dns.block, body)
}

export function updateRoutingFromForm(content: string, values: RoutingFormValues): string {
  const lines = ruleLines(values.rules, false)
  if (values.fallback.trim()) lines.push(`fallback: ${values.fallback.trim()}`)
  return replaceBlockActiveLines(content, 'routing', lines, activeRule, '    ')
}

export function globalFormValues(global: DaeGlobalConfig) {
  return {
    logLevel: String(global.log_level ?? 'info'),
    tproxyPort: numericPart(global.tproxy_port, 12345),
    tproxyPortProtect: global.tproxy_port_protect !== false,
    soMarkFromDae: numericPart(global.so_mark_from_dae, 0),
    disableWaitingNetwork: global.disable_waiting_network === true,
    enableLocalTcpFastRedirect: global.enable_local_tcp_fast_redirect === true,
    mptcp: global.mptcp === true,
    lanInterfaces: splitList(global.lan_interface),
    wanInterfaces: splitList(global.wan_interface, ['auto']),
    tcpCheckUrls: splitList(global.tcp_check_url, [
      'http://cp.cloudflare.com',
      '1.1.1.1',
      '2606:4700:4700::1111',
    ]),
    tcpCheckHttpMethod: String(global.tcp_check_http_method ?? 'HEAD'),
    udpCheckDns: splitList(global.udp_check_dns, [
      'dns.google:53',
      '8.8.8.8',
      '2001:4860:4860::8888',
    ]),
    bootstrapResolver: String(global.bootstrap_resolver ?? ''),
    fallbackResolver: String(global.fallback_resolver ?? '8.8.8.8:53'),
    checkIntervalSeconds: numericPart(global.check_interval, 30),
    checkToleranceMs: numericPart(global.check_tolerance, 0),
    dialMode: String(global.dial_mode ?? 'domain'),
    sniffingTimeoutMs: numericPart(global.sniffing_timeout, 100),
    tlsImplementation: String(global.tls_implementation ?? 'tls'),
    utlsImitate: String(global.utls_imitate ?? 'chrome_auto'),
    bandwidthMaxTx: String(global.bandwidth_max_tx ?? '200 mbps'),
    bandwidthMaxRx: String(global.bandwidth_max_rx ?? '1 gbps'),
    autoKernel: global.auto_config_kernel_parameter !== false,
    allowInsecure: global.allow_insecure === true,
  }
}

export type GlobalFormValues = ReturnType<typeof globalFormValues>

export function updateGlobalFromForm(content: string, values: GlobalFormValues): string {
  const wanInterfaces = values.wanInterfaces.map((value) => value.trim()).filter(Boolean)
  return updateGlobalValues(content, {
    log_level: values.logLevel,
    tproxy_port: String(values.tproxyPort),
    tproxy_port_protect: values.tproxyPortProtect,
    so_mark_from_dae: String(values.soMarkFromDae),
    disable_waiting_network: values.disableWaitingNetwork,
    enable_local_tcp_fast_redirect: values.enableLocalTcpFastRedirect,
    mptcp: values.mptcp,
    lan_interface: quoteDaeList(values.lanInterfaces),
    wan_interface: wanInterfaces.length === 1 && wanInterfaces[0] === 'auto' ? 'auto' : quoteDaeList(wanInterfaces),
    auto_config_kernel_parameter: values.autoKernel,
    tcp_check_url: quoteDaeList(values.tcpCheckUrls),
    tcp_check_http_method: values.tcpCheckHttpMethod,
    udp_check_dns: quoteDaeList(values.udpCheckDns),
    bootstrap_resolver: quoteDae(values.bootstrapResolver),
    fallback_resolver: quoteDae(values.fallbackResolver),
    check_interval: `${values.checkIntervalSeconds}s`,
    check_tolerance: `${values.checkToleranceMs}ms`,
    dial_mode: values.dialMode,
    allow_insecure: values.allowInsecure,
    sniffing_timeout: `${values.sniffingTimeoutMs}ms`,
    tls_implementation: values.tlsImplementation,
    utls_imitate: values.utlsImitate,
    bandwidth_max_tx: quoteDae(values.bandwidthMaxTx),
    bandwidth_max_rx: quoteDae(values.bandwidthMaxRx),
  })
}
