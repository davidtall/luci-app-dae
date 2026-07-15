import type { ApiErrorBody } from './types'

const API_BASE = '/cgi-bin/luci/admin/services/dae/api'

function errorMessage(data: ApiErrorBody, fallback: string): string {
  return data.error?.message || data.output || data.serviceOutput || fallback
}

export async function request<T>(path: string, payload?: unknown): Promise<T> {
  const options: RequestInit = {
    cache: 'no-store',
    credentials: 'same-origin',
    headers: { Accept: 'application/json' },
  }

  if (payload !== undefined) {
    options.method = 'POST'
    options.headers = {
      ...options.headers,
      'Content-Type': 'application/json',
    }
    options.body = JSON.stringify(payload)
  }

  const response = await fetch(`${API_BASE}/${path}`, options)
  const data = (await response.json().catch(() => ({}))) as T & ApiErrorBody
  if (!response.ok || data.ok === false) {
    throw new Error(errorMessage(data, `请求失败（HTTP ${response.status}）`))
  }
  return data
}

export async function requestServiceStatus(): Promise<{ running: boolean; memory?: string }> {
  const response = await fetch('/cgi-bin/luci/admin/services/dae/status', {
    cache: 'no-store',
    credentials: 'same-origin',
    headers: { Accept: 'application/json' },
  })
  const data = (await response.json().catch(() => ({}))) as { running?: boolean; memory?: string }
  if (!response.ok) throw new Error(`请求失败（HTTP ${response.status}）`)
  return { running: data.running === true, memory: data.memory }
}
