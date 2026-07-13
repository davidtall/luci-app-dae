(() => {
  const root = document.getElementById('dae-ui-high-fidelity');
  if (!root) return;

  const API_BASE = '/cgi-bin/luci/admin/services/dae/api';
  const toast = root.querySelector('.toast');
  const unsaved = root.querySelector('.unsaved');
  const nodePickerDialog = root.querySelector('#group-node-picker-modal');
  const subscriptionPickerDialog = root.querySelector('#group-subscription-picker-modal');
  const regexDialog = root.querySelector('#regex-modal');
  let state = null;
  let dirty = false;
  let activeGroupId = '';
  let pendingSubscriptionDrop = null;
  const selectedNodeIds = new Set();
  const selectedSubscriptionIds = new Set();

  const asArray = (value) => Array.isArray(value) ? value : (value && typeof value === 'object' ? Object.values(value) : []);

  const escapeHtml = (value) => String(value ?? '').replace(/[&<>'"]/g, (char) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  })[char]);

  const refreshIcons = () => {
    if (window.lucide) window.lucide.createIcons({ attrs: { width: 16, height: 16 } });
  };

  const showToast = (message, isError = false) => {
    toast.textContent = message;
    toast.classList.toggle('text-destructive', isError);
    toast.classList.add('is-visible');
  };

  const setDirty = (value, message) => {
    dirty = value;
    unsaved.classList.toggle('is-visible', dirty);
    if (message) showToast(message);
  };

  const errorMessage = (data, fallback) => data?.error?.message || data?.output || data?.serviceOutput || fallback;

  async function request(path, payload) {
    const options = { credentials: 'same-origin', headers: { Accept: 'application/json' } };
    if (payload !== undefined) {
      options.method = 'POST';
      options.headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(payload);
    }
    const response = await fetch(`${API_BASE}/${path}`, options);
    const data = await response.json().catch(() => ({}));
    if (!response.ok || data.ok === false) throw new Error(errorMessage(data, `请求失败（HTTP ${response.status}）`));
    return data;
  }

  const nodeCatalog = () => asArray(state?.resources?.nodes).map((node) => ({
    ...node,
    description: node.address || '分享链接',
    source: '手动节点',
    latency: '未检测'
  }));

  const subscriptionCatalog = () => asArray(state?.resources?.subscriptions).map((subscription) => ({
    ...subscription,
    meta: subscription.previewAvailable ? `${subscription.nodes?.length || 0} 个节点` : '订阅节点由 dae 加载',
    previewNodes: subscription.nodes || []
  }));

  function renderStatus() {
    const service = state?.service || {};
    root.querySelector('.app-version').textContent = service.version || '未知版本';
    root.querySelector('.service-status-text').textContent = service.running ? '运行中' : (service.enabled ? '未运行' : '未启用');
    root.querySelector('.service-status').classList.toggle('text-destructive', !service.running);
  }

  function renderConfigSummary() {
    const global = state?.resources?.global || {};
    const values = [
      ['日志', global.log_level || '未设置'],
      ['拨号模式', global.dial_mode || '未设置'],
      ['LAN', global.lan_interface || '未设置'],
      ['WAN', global.wan_interface || '未设置'],
      ['检查间隔', global.check_interval || '未设置'],
      ['允许不安全 TLS', global.allow_insecure === true ? '是' : '否']
    ];
    const summary = root.querySelector('.config-section .config-summary');
    summary.innerHTML = values.map(([label, value]) => `<div class="summary-item"><span class="text-muted">${escapeHtml(label)}</span><span>${escapeHtml(value)}</span></div>`).join('');

    const dns = state?.resources?.dns || {};
    root.querySelector('.dns-section .meta-row').innerHTML = `<span>${dns.upstreams?.length || 0} 个上游</span><span>·</span><span>${(dns.requestRules?.length || 0) + (dns.responseRules?.length || 0)} 条路由规则</span>`;
    const routing = state?.resources?.routing || {};
    root.querySelector('.routing-section .meta-row').innerHTML = `<span>${routing.rules?.length || 0} 条规则</span><span>·</span><span>fallback: ${escapeHtml(routing.fallback || '未设置')}</span>`;
  }

  const emptyZone = () => '<span class="empty-drop text-small">暂无内容，可拖入或点击添加</span>';

  function renderGroups() {
    const nodes = new Map(nodeCatalog().map((item) => [item.id, item]));
    const subscriptions = new Map(subscriptionCatalog().map((item) => [item.id, item]));
    const groups = asArray(state?.resources?.groups);
    const stack = root.querySelector('.group-stack');
    if (!groups.length) {
      stack.innerHTML = '<div class="text-small text-muted">暂无群组，点击右上角“+”创建。</div>';
      return;
    }
    stack.innerHTML = groups.map((group) => {
      const groupNodeIds = asArray(group.nodeIds);
      const groupSubscriptions = asArray(group.subscriptions);
      const nodeBadges = groupNodeIds.map((id) => {
        const node = nodes.get(id) || { id, name: id };
        return `<span class="group-badge text-small" data-id="${escapeHtml(id)}"><i data-lucide="grip-vertical" aria-hidden="true"></i><span class="group-name">${escapeHtml(node.name || id)}</span><button type="button" class="group-remove" data-action="group-remove-node" data-group-id="${escapeHtml(group.id)}" data-resource-id="${escapeHtml(id)}" aria-label="从群组移除 ${escapeHtml(node.name || id)}"><i data-lucide="x" aria-hidden="true"></i></button></span>`;
      }).join('');
      const subscriptionBadges = groupSubscriptions.map((membership) => {
        const id = membership.subscriptionId || membership.id;
        const subscription = subscriptions.get(id) || { id, name: id };
        const regex = membership.nameFilterRegex ? ` · /${escapeHtml(membership.nameFilterRegex)}/` : '';
        return `<span class="group-badge text-small" data-id="${escapeHtml(id)}"><i data-lucide="grip-vertical" aria-hidden="true"></i><span class="group-name">${escapeHtml(subscription.name || id)}</span><span class="filter">订阅${regex}</span><button type="button" class="group-remove" data-action="group-remove-subscription" data-group-id="${escapeHtml(group.id)}" data-resource-id="${escapeHtml(id)}" aria-label="从群组移除 ${escapeHtml(subscription.name || id)}"><i data-lucide="x" aria-hidden="true"></i></button></span>`;
      }).join('');
      const policyParams = asArray(group.policyParams);
      const policyParam = policyParams[0]?.val ? `(${escapeHtml(policyParams[0].val)})` : '';
      return `<article class="card resource-card group-card" data-group-id="${escapeHtml(group.id)}">
        <div class="resource-head"><div class="resource-title"><span>${escapeHtml(group.name || group.id)}</span><span class="viz-badge">${escapeHtml(group.policy || 'min_moving_avg')}${policyParam}</span></div><button type="button" class="btn btn-ghost icon-btn" data-action="edit-group" data-id="${escapeHtml(group.id)}" aria-label="编辑 ${escapeHtml(group.name || group.id)} 群组"><i data-lucide="sliders-horizontal" aria-hidden="true"></i></button></div>
        <div class="meta-row text-small"><span>${groupNodeIds.length} 个节点</span><span>·</span><span>${groupSubscriptions.length} 个订阅组</span></div>
        <div class="group-zones">
          <div class="group-zone" data-group-id="${escapeHtml(group.id)}" data-accept="node"><div class="group-zone-head text-small"><div class="group-zone-title"><span>节点</span><span class="viz-badge zone-count">${groupNodeIds.length}</span></div><button type="button" class="btn btn-ghost" data-action="open-node-picker" data-group-id="${escapeHtml(group.id)}"><i data-lucide="plus" aria-hidden="true"></i>添加节点</button></div><div class="group-items">${nodeBadges || emptyZone()}</div></div>
          <div class="group-zone" data-group-id="${escapeHtml(group.id)}" data-accept="subscription"><div class="group-zone-head text-small"><div class="group-zone-title"><span>订阅组</span><span class="viz-badge zone-count">${groupSubscriptions.length}</span></div><button type="button" class="btn btn-ghost" data-action="open-subscription-picker" data-group-id="${escapeHtml(group.id)}"><i data-lucide="plus" aria-hidden="true"></i>增加订阅组</button></div><div class="group-items">${subscriptionBadges || emptyZone()}</div></div>
        </div>
      </article>`;
    }).join('');
  }

  function renderNodes() {
    const stack = root.querySelector('.node-stack');
    const nodes = nodeCatalog();
    stack.innerHTML = nodes.length ? nodes.map((node) => `<article class="card resource-card draggable-resource" draggable="true" data-type="node" data-id="${escapeHtml(node.id)}" data-name="${escapeHtml(node.name || node.id)}"><div class="resource-head"><div><div class="resource-title"><i class="drag-grip" data-lucide="grip-vertical" aria-hidden="true"></i><span class="viz-badge">${escapeHtml(node.protocol || 'unknown')}</span><span class="truncate">${escapeHtml(node.name || node.id)}</span></div><div class="meta-row text-small"><span>${escapeHtml(node.id)}</span><span>·</span><span>${escapeHtml(node.address || '拖到群组')}</span></div></div><button type="button" class="btn btn-ghost icon-btn" data-action="edit-node" data-id="${escapeHtml(node.id)}" aria-label="编辑 ${escapeHtml(node.name || node.id)}"><i data-lucide="pencil" aria-hidden="true"></i></button></div></article>`).join('') : '<div class="text-small text-muted">暂无节点，点击右上角按钮添加分享链接。</div>';
  }

  function renderSubscriptions() {
    const stack = root.querySelector('.subscription-stack');
    const subscriptions = subscriptionCatalog();
    stack.innerHTML = subscriptions.length ? subscriptions.map((subscription) => `<article class="card resource-card draggable-resource" draggable="true" data-type="subscription" data-id="${escapeHtml(subscription.id)}" data-name="${escapeHtml(subscription.name || subscription.id)}"><div class="resource-head"><div><div class="resource-title"><i class="drag-grip" data-lucide="grip-vertical" aria-hidden="true"></i><span class="viz-badge">订阅</span><span class="truncate">${escapeHtml(subscription.name || subscription.id)}</span></div><div class="meta-row text-small"><span>${escapeHtml(subscription.id)}</span><span>·</span><span>由 dae 加载并按全局计划更新</span></div></div><button type="button" class="btn btn-ghost icon-btn" data-action="edit-subscription" data-id="${escapeHtml(subscription.id)}" aria-label="编辑 ${escapeHtml(subscription.name || subscription.id)}"><i data-lucide="pencil" aria-hidden="true"></i></button></div></article>`).join('') : '<div class="text-small text-muted">暂无订阅，点击右上角按钮添加订阅地址。</div>';
  }

  function bindDrags() {
    root.querySelectorAll('.draggable-resource').forEach((resource) => {
      resource.addEventListener('dragstart', (event) => {
        event.dataTransfer.effectAllowed = 'copy';
        event.dataTransfer.setData('application/json', JSON.stringify({ type: resource.dataset.type, id: resource.dataset.id, name: resource.dataset.name }));
      });
    });
    root.querySelectorAll('.group-zone').forEach((zone) => {
      zone.addEventListener('dragover', (event) => { event.preventDefault(); zone.classList.add('is-over'); });
      zone.addEventListener('dragleave', () => zone.classList.remove('is-over'));
      zone.addEventListener('drop', async (event) => {
        event.preventDefault();
        zone.classList.remove('is-over');
        let resource;
        try { resource = JSON.parse(event.dataTransfer.getData('application/json')); } catch { return; }
        if (!resource || resource.type !== zone.dataset.accept) return;
        if (resource.type === 'node') {
          await mutate('group_add_node', { groupId: zone.dataset.groupId, nodeId: resource.id }, `${resource.name} 已加入群组`);
        } else {
          pendingSubscriptionDrop = { groupId: zone.dataset.groupId, subscriptionId: resource.id, name: resource.name };
          root.querySelector('.regex-subscription').value = resource.name;
          root.querySelector('.regex-group').value = zone.dataset.groupId;
          root.querySelector('.regex-input').value = '';
          root.querySelector('.all-nodes-toggle').checked = true;
          updateRegexPreview();
          regexDialog.showModal();
        }
      });
    });
  }

  function render() {
    renderStatus();
    renderConfigSummary();
    renderGroups();
    renderNodes();
    renderSubscriptions();
    bindDrags();
    refreshIcons();
  }

  async function loadState(preserveDirty = false) {
    state = await request('state');
    if (!preserveDirty) setDirty(false);
    render();
  }

  async function mutate(action, values, message) {
    try {
      state = await request('mutate', { action, revision: state?.revision, ...values });
      setDirty(true, message || '配置已保存，等待重载 dae');
      render();
      return true;
    } catch (error) {
      showToast(error.message, true);
      return false;
    }
  }

  async function saveFile(key, content, message) {
    try {
      await request('save', { revision: state?.revision, files: { [key]: { content } } });
      await loadState(true);
      setDirty(true, message || '配置文件已保存，等待重载 dae');
      return true;
    } catch (error) {
      showToast(error.message, true);
      return false;
    }
  }

  function openNode(id = '') {
    const item = asArray(state?.resources?.nodes).find((node) => node.id === id);
    root.querySelector('.node-previous-id').value = item?.id || '';
    root.querySelector('.node-id').value = item?.id || '';
    root.querySelector('.node-link').value = item?.link || '';
    root.querySelector('.node-delete').hidden = !item;
    root.querySelector('#node-modal').showModal();
  }

  function openSubscription(id = '') {
    const item = asArray(state?.resources?.subscriptions).find((subscription) => subscription.id === id);
    root.querySelector('.subscription-previous-id').value = item?.id || '';
    root.querySelector('.subscription-id').value = item?.id || '';
    root.querySelector('.subscription-link').value = item?.link || '';
    root.querySelector('.subscription-delete').hidden = !item;
    root.querySelector('#subscription-modal').showModal();
  }

  function openGroup(id = '') {
    const item = asArray(state?.resources?.groups).find((group) => group.id === id);
    root.querySelector('.group-previous-id').value = item?.id || '';
    root.querySelector('.group-id').value = item?.id || '';
    root.querySelector('.group-policy').value = item?.policy || 'min_moving_avg';
    root.querySelector('.group-policy-param').value = asArray(item?.policyParams)[0]?.val || '';
    root.querySelector('.group-delete').hidden = !item;
    root.querySelector('#group-modal').showModal();
  }

  function openSourceModal(id) {
    const dialog = root.querySelector(`#${id}`);
    if (id === 'config-source-modal') dialog.querySelector('textarea').value = state.files.global.content;
    if (id === 'dns-modal') dialog.querySelector('#dns-source textarea').value = state.files.dns.content;
    if (id === 'routing-modal') dialog.querySelector('#routing-source textarea').value = state.files.routing.content;
    dialog.showModal();
  }

  function groupById(id) { return asArray(state?.resources?.groups).find((group) => group.id === id); }

  function renderNodePicker() {
    const group = groupById(activeGroupId);
    const existing = new Set(asArray(group?.nodeIds));
    const query = root.querySelector('.node-picker-search').value.trim().toLowerCase();
    const items = nodeCatalog().filter((item) => !existing.has(item.id) && (!query || `${item.name} ${item.id} ${item.protocol} ${item.address}`.toLowerCase().includes(query)));
    root.querySelector('.node-picker-selected').textContent = `已选 ${selectedNodeIds.size} 项`;
    root.querySelector('.node-picker-confirm').disabled = !selectedNodeIds.size;
    root.querySelector('.node-picker-list').innerHTML = items.length ? items.map((item) => `<label class="picker-option${selectedNodeIds.has(item.id) ? ' is-selected' : ''}"><input type="checkbox" class="form-check-input picker-node-check" value="${escapeHtml(item.id)}" ${selectedNodeIds.has(item.id) ? 'checked' : ''}><span class="picker-option-copy"><span class="picker-option-title">${escapeHtml(item.name || item.id)}</span><span class="text-small picker-option-meta">${escapeHtml(item.id)} · ${escapeHtml(item.address || '分享链接')}</span></span><span class="viz-badge">${escapeHtml(item.protocol || 'unknown')}</span></label>`).join('') : '<p class="picker-empty text-small">暂无可添加的节点</p>';
  }

  function renderSubscriptionPicker() {
    const group = groupById(activeGroupId);
    const existing = new Set(asArray(group?.subscriptions).map((item) => item.subscriptionId || item.id));
    const query = root.querySelector('.subscription-picker-search').value.trim().toLowerCase();
    const items = subscriptionCatalog().filter((item) => !existing.has(item.id) && (!query || `${item.name} ${item.id}`.toLowerCase().includes(query)));
    root.querySelector('.subscription-picker-selected').textContent = `已选 ${selectedSubscriptionIds.size} 项`;
    root.querySelector('.subscription-picker-list').innerHTML = items.length ? items.map((item) => `<label class="picker-option${selectedSubscriptionIds.has(item.id) ? ' is-selected' : ''}"><input type="checkbox" class="form-check-input picker-subscription-check" value="${escapeHtml(item.id)}" ${selectedSubscriptionIds.has(item.id) ? 'checked' : ''}><span class="picker-option-copy"><span class="picker-option-title">${escapeHtml(item.name || item.id)}</span><span class="text-small picker-option-meta">${escapeHtml(item.id)}</span></span><span class="viz-badge">订阅</span></label>`).join('') : '<p class="picker-empty text-small">暂无可添加的订阅组</p>';
    const pattern = root.querySelector('.subscription-picker-regex').value.trim();
    let error = '';
    if (pattern) {
      try { new RegExp(pattern); } catch { error = '正则表达式无效'; }
      if (pattern.includes('(?=') || pattern.includes('(?!') || pattern.includes('(?<=') || pattern.includes('(?<!') || /\\[1-9]/.test(pattern)) error = 'RE2 不支持前后预查或反向引用';
    }
    root.querySelector('.subscription-picker-error').textContent = error;
    root.querySelector('.subscription-preview-summary').textContent = '独立 dae 会在加载订阅后应用此名称过滤规则；配置文件模式下不预取订阅节点。';
    root.querySelector('.subscription-preview-groups').innerHTML = selectedSubscriptionIds.size ? `<div class="picker-preview-group"><div class="picker-preview-title"><span>将添加 ${selectedSubscriptionIds.size} 个订阅组</span><span class="viz-badge">${pattern ? `/${escapeHtml(pattern)}/` : '全部节点'}</span></div></div>` : '';
    root.querySelector('.subscription-picker-confirm').disabled = !selectedSubscriptionIds.size || !!error;
  }

  async function applyConfig() {
    try {
      const result = await request('apply', { revision: state?.revision });
      await loadState();
      setDirty(false, result.serviceAction === 'reload' ? '配置已保存，dae 热重载成功' : `配置已保存，dae 已执行 ${result.serviceAction || '应用'}`);
    } catch (error) { showToast(error.message, true); }
  }

  async function validateConfig() {
    try {
      const result = await request('validate', {});
      showToast(result.output?.trim() || '配置验证通过：dae validate 返回成功');
    } catch (error) { showToast(error.message, true); }
  }

  function globalBlock(content) {
    const match = /global\s*\{/.exec(content);
    if (!match) return null;
    const open = content.indexOf('{', match.index);
    let depth = 0;
    let quote = '';
    let escaped = false;
    for (let index = open; index < content.length; index += 1) {
      const char = content[index];
      if (quote) {
        if (escaped) escaped = false;
        else if (char === '\\') escaped = true;
        else if (char === quote) quote = '';
      } else if (char === "'" || char === '"') quote = char;
      else if (char === '{') depth += 1;
      else if (char === '}' && --depth === 0) return { open, close: index };
    }
    return null;
  }

  function updateGlobalValues(content, values) {
    const block = globalBlock(content);
    if (!block) throw new Error('找不到 global 配置块');
    let body = content.slice(block.open + 1, block.close);
    Object.entries(values).forEach(([key, value]) => {
      const line = `    ${key}:${value}`;
      const pattern = new RegExp(`(^|\\n)\\s*${key.replace(/[.*+?^${}()|[\\]\\]/g, '\\$&')}\\s*:[^\\r\\n]*`);
      if (pattern.test(body)) body = body.replace(pattern, `$1${line}`);
      else body = `${body.replace(/\\s*$/, '')}\n${line}\n`;
    });
    return content.slice(0, block.open + 1) + body + content.slice(block.close);
  }

  const labelControl = (dialog, text) => [...dialog.querySelectorAll('label.form-label')].find((label) => label.textContent.trim().startsWith(text))?.querySelector('input,select');

  function fillGlobalVisual() {
    const dialog = root.querySelector('#config-modal');
    const global = state.resources.global || {};
    const mapping = { '日志级别': 'log_level', '嗅探超时': 'sniffing_timeout', '拨号模式': 'dial_mode', 'LAN 接口': 'lan_interface', 'WAN 接口': 'wan_interface', '检查间隔': 'check_interval', '检查容差': 'check_tolerance', 'TCP 检测地址': 'tcp_check_url', 'UDP 检测 DNS': 'udp_check_dns' };
    Object.entries(mapping).forEach(([label, key]) => { const control = labelControl(dialog, label); if (control && global[key] !== undefined) control.value = global[key]; });
    const sections = dialog.querySelectorAll('.form-section');
    const kernelToggle = sections[1]?.querySelectorAll('input[type="checkbox"]')[1];
    const insecureToggle = sections[3]?.querySelectorAll('input[type="checkbox"]')[0];
    if (kernelToggle) kernelToggle.checked = global.auto_config_kernel_parameter !== false;
    if (insecureToggle) insecureToggle.checked = global.allow_insecure === true;
  }

  async function saveGlobalVisual() {
    const dialog = root.querySelector('#config-modal');
    const raw = (label) => labelControl(dialog, label)?.value.trim() || '';
    const quoted = (value) => `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
    const sections = dialog.querySelectorAll('.form-section');
    const values = {
      log_level: raw('日志级别'), sniffing_timeout: raw('嗅探超时'), dial_mode: raw('拨号模式'),
      lan_interface: quoted(raw('LAN 接口')), wan_interface: raw('WAN 接口'), check_interval: raw('检查间隔'),
      check_tolerance: raw('检查容差'), tcp_check_url: quoted(raw('TCP 检测地址')), udp_check_dns: quoted(raw('UDP 检测 DNS')),
      auto_config_kernel_parameter: String(!!sections[1]?.querySelectorAll('input[type="checkbox"]')[1]?.checked),
      allow_insecure: String(!!sections[3]?.querySelectorAll('input[type="checkbox"]')[0]?.checked)
    };
    const content = updateGlobalValues(state.files.global.content, values);
    if (await saveFile('global', content, '全局配置已保存，等待重载 dae')) dialog.close();
  }

  root.querySelectorAll('dialog button').forEach((button) => { if (!button.hasAttribute('type')) button.type = 'button'; });
  root.querySelectorAll('dialog button[value="cancel"]').forEach((button) => button.addEventListener('click', () => button.closest('dialog').close()));
  root.querySelectorAll('.tab-button').forEach((button) => button.addEventListener('click', () => {
    const dialog = button.closest('dialog');
    dialog.querySelectorAll('.tab-button').forEach((tab) => tab.setAttribute('aria-selected', String(tab === button)));
    dialog.querySelectorAll('.tab-panel').forEach((panel) => panel.classList.toggle('is-active', panel.id === button.dataset.tab));
  }));

  root.addEventListener('click', async (event) => {
    const button = event.target.closest('button');
    if (!button) return;
    const action = button.dataset.action;
    if (button.classList.contains('validate-action')) return validateConfig();
    if (button.classList.contains('save-reload-action')) return applyConfig();
    if (button.classList.contains('open-modal')) {
      const id = button.dataset.modal;
      if (id === 'node-modal') return openNode();
      if (id === 'subscription-modal') return openSubscription();
      if (id === 'group-modal') return openGroup();
      if (id === 'config-modal') { fillGlobalVisual(); return root.querySelector('#config-modal').showModal(); }
      return openSourceModal(id);
    }
    if (action === 'edit-node') return openNode(button.dataset.id);
    if (action === 'edit-subscription') return openSubscription(button.dataset.id);
    if (action === 'edit-group') return openGroup(button.dataset.id);
    if (action === 'group-remove-node') return mutate('group_remove_node', { groupId: button.dataset.groupId, nodeId: button.dataset.resourceId }, '节点已从群组删除');
    if (action === 'group-remove-subscription') return mutate('group_remove_subscription', { groupId: button.dataset.groupId, subscriptionId: button.dataset.resourceId }, '订阅组已从群组删除');
    if (action === 'open-node-picker') {
      activeGroupId = button.dataset.groupId; selectedNodeIds.clear(); root.querySelector('.node-picker-search').value = '';
      root.querySelector('.node-picker-title').textContent = `添加节点到 ${activeGroupId}`; renderNodePicker(); return nodePickerDialog.showModal();
    }
    if (action === 'open-subscription-picker') {
      activeGroupId = button.dataset.groupId; selectedSubscriptionIds.clear(); root.querySelector('.subscription-picker-search').value = ''; root.querySelector('.subscription-picker-regex').value = '';
      root.querySelector('.subscription-picker-title').textContent = `增加订阅组到 ${activeGroupId}`; renderSubscriptionPicker(); return subscriptionPickerDialog.showModal();
    }
  });

  root.querySelector('.node-save').addEventListener('click', async () => {
    const ok = await mutate('upsert_node', { previousId: root.querySelector('.node-previous-id').value, id: root.querySelector('.node-id').value.trim(), link: root.querySelector('.node-link').value.trim() }, '节点已保存，等待重载 dae');
    if (ok) root.querySelector('#node-modal').close();
  });
  root.querySelector('.node-delete').addEventListener('click', async () => {
    const ok = await mutate('delete_node', { id: root.querySelector('.node-previous-id').value }, '节点已删除');
    if (ok) root.querySelector('#node-modal').close();
  });
  root.querySelector('.subscription-save').addEventListener('click', async () => {
    const ok = await mutate('upsert_subscription', { previousId: root.querySelector('.subscription-previous-id').value, id: root.querySelector('.subscription-id').value.trim(), link: root.querySelector('.subscription-link').value.trim() }, '订阅已保存，等待重载 dae');
    if (ok) root.querySelector('#subscription-modal').close();
  });
  root.querySelector('.subscription-delete').addEventListener('click', async () => {
    const ok = await mutate('delete_subscription', { id: root.querySelector('.subscription-previous-id').value }, '订阅已删除');
    if (ok) root.querySelector('#subscription-modal').close();
  });
  root.querySelector('.group-save').addEventListener('click', async () => {
    const ok = await mutate('upsert_group', { previousId: root.querySelector('.group-previous-id').value, id: root.querySelector('.group-id').value.trim(), policy: root.querySelector('.group-policy').value, policyParam: root.querySelector('.group-policy-param').value.trim() }, '群组已保存，等待重载 dae');
    if (ok) root.querySelector('#group-modal').close();
  });
  root.querySelector('.group-delete').addEventListener('click', async () => {
    const ok = await mutate('delete_group', { id: root.querySelector('.group-previous-id').value }, '群组已删除');
    if (ok) root.querySelector('#group-modal').close();
  });

  root.querySelectorAll('.modal-save').forEach((button) => button.addEventListener('click', async () => {
    const dialog = button.closest('dialog');
    let ok = false;
    if (dialog.id === 'config-modal') return saveGlobalVisual();
    if (dialog.id === 'config-source-modal') ok = await saveFile('global', dialog.querySelector('textarea').value, '全局配置源码已保存');
    if (dialog.id === 'dns-modal') ok = await saveFile('dns', dialog.querySelector('#dns-source textarea').value, 'DNS 配置已保存');
    if (dialog.id === 'routing-modal') ok = await saveFile('routing', dialog.querySelector('#routing-source textarea').value, '路由配置已保存');
    if (ok) dialog.close();
  }));

  root.querySelector('.node-picker-search').addEventListener('input', renderNodePicker);
  root.querySelector('.node-picker-list').addEventListener('change', (event) => {
    if (!event.target.classList.contains('picker-node-check')) return;
    event.target.checked ? selectedNodeIds.add(event.target.value) : selectedNodeIds.delete(event.target.value); renderNodePicker();
  });
  root.querySelector('.node-picker-confirm').addEventListener('click', async () => {
    for (const nodeId of selectedNodeIds) {
      if (!await mutate('group_add_node', { groupId: activeGroupId, nodeId }, '')) return;
    }
    nodePickerDialog.close(); setDirty(true, `已向 ${activeGroupId} 添加 ${selectedNodeIds.size} 个节点`);
  });

  root.querySelector('.subscription-picker-search').addEventListener('input', renderSubscriptionPicker);
  root.querySelector('.subscription-picker-regex').addEventListener('input', renderSubscriptionPicker);
  root.querySelector('.subscription-picker-list').addEventListener('change', (event) => {
    if (!event.target.classList.contains('picker-subscription-check')) return;
    event.target.checked ? selectedSubscriptionIds.add(event.target.value) : selectedSubscriptionIds.delete(event.target.value); renderSubscriptionPicker();
  });
  root.querySelector('.subscription-picker-confirm').addEventListener('click', async () => {
    const regex = root.querySelector('.subscription-picker-regex').value.trim();
    for (const subscriptionId of selectedSubscriptionIds) {
      if (!await mutate('group_add_subscription', { groupId: activeGroupId, subscriptionId, regex }, '')) return;
    }
    subscriptionPickerDialog.close(); setDirty(true, `已向 ${activeGroupId} 增加 ${selectedSubscriptionIds.size} 个订阅组`);
  });

  function updateRegexPreview() {
    const useAll = root.querySelector('.all-nodes-toggle').checked;
    root.querySelector('.regex-input').disabled = useAll;
    root.querySelector('.regex-match-count').textContent = useAll ? '使用订阅中的全部节点' : 'dae 加载订阅后按此正则筛选';
    root.querySelector('.regex-results').replaceChildren();
  }
  root.querySelector('.all-nodes-toggle').addEventListener('change', updateRegexPreview);
  root.querySelector('.regex-input').addEventListener('input', updateRegexPreview);
  root.querySelector('.regex-confirm').addEventListener('click', async () => {
    if (!pendingSubscriptionDrop) return;
    const regex = root.querySelector('.all-nodes-toggle').checked ? '' : root.querySelector('.regex-input').value.trim();
    const ok = await mutate('group_add_subscription', { ...pendingSubscriptionDrop, regex }, `${pendingSubscriptionDrop.name} 已加入群组`);
    if (ok) { pendingSubscriptionDrop = null; regexDialog.close(); }
  });
  root.querySelectorAll('.regex-cancel').forEach((button) => button.addEventListener('click', () => { pendingSubscriptionDrop = null; regexDialog.close(); }));
  root.querySelector('.import-action').addEventListener('click', () => openNode());

  loadState().catch((error) => showToast(`读取独立 dae 状态失败：${error.message}`, true));
})();
