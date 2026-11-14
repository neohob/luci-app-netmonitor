-- Home topology: Top N devices + 其他设备, Top N targets + 其他去向 (ADR-006),
-- one color per logical path shared by both gateway legs (ADR-007).
local M = {}

M.TOP = 4
M.PALETTE = {
	'#3b82f6', '#22c55e', '#f59e0b', '#ef4444', '#a855f7',
	'#06b6d4', '#ec4899', '#84cc16', '#f97316', '#6366f1',
}
M.OTHER_DEVICE = 'd:other'
M.OTHER_TARGET = 't:other'
M.GATEWAY = 'gw'

function M.hash(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	return h
end

-- Stable hash slot, probing forward so paths in one response stay distinct
-- while the palette has free hues.
function M.assign_colors(path_ids)
	local sorted = {}
	for i, p in ipairs(path_ids) do sorted[i] = p end
	table.sort(sorted)
	local n, used, out = #M.PALETTE, {}, {}
	for _, p in ipairs(sorted) do
		local slot = M.hash(p) % n
		local tries = 0
		while used[slot] and tries < n do
			slot = (slot + 1) % n
			tries = tries + 1
		end
		if tries >= n then slot = M.hash(p) % n end
		used[slot] = true
		out[p] = M.PALETTE[slot + 1]
	end
	return out
end

local function rank(totals)
	local list = {}
	for k, v in pairs(totals) do list[#list + 1] = { key = k, bytes = v } end
	table.sort(list, function(a, b)
		if a.bytes ~= b.bytes then return a.bytes > b.bytes end
		return a.key < b.key
	end)
	return list
end

-- rows: { {device=, target=, up=, down=} } aggregated over the range
-- info: { devices = {mac = {hostname=, ip=}}, targets = {key = {display=, unresolved=}} }
-- live: { devices = {mac = {live=, rate_up=, rate_down=}}, pairs = {"mac|target" = true} }
function M.build(rows, info, live)
	info = info or { devices = {}, targets = {} }
	live = live or { devices = {}, pairs = {} }
	local top = M.TOP
	local dev_tot, tgt_tot = {}, {}
	for _, r in ipairs(rows) do
		local b = (r.up or 0) + (r.down or 0)
		dev_tot[r.device] = (dev_tot[r.device] or 0) + b
		tgt_tot[r.target] = (tgt_tot[r.target] or 0) + b
	end
	local dev_rank, tgt_rank = rank(dev_tot), rank(tgt_tot)
	local dev_node, tgt_node = {}, {}
	for i, d in ipairs(dev_rank) do dev_node[d.key] = (i <= top) and ('d:' .. d.key) or M.OTHER_DEVICE end
	for i, t in ipairs(tgt_rank) do tgt_node[t.key] = (i <= top) and ('t:' .. t.key) or M.OTHER_TARGET end

	local nodes = { devices = {}, targets = {} }
	local node_by_id = {}
	local function node(list, id, base)
		local n = node_by_id[id]
		if not n then
			n = base
			n.id = id
			n.bytes_up, n.bytes_down, n.bytes_total, n.members = 0, 0, 0, 0
			n.live = false
			node_by_id[id] = n
			list[#list + 1] = n
		end
		return n
	end

	for i, d in ipairs(dev_rank) do
		local id = dev_node[d.key]
		local di = info.devices[d.key] or {}
		local base = (i <= top)
			and { kind = 'device', mac = d.key, label = di.hostname or di.ip or d.key, ip = di.ip }
			or { kind = 'other_devices', label = '其他设备' }
		local n = node(nodes.devices, id, base)
		n.members = n.members + 1
		local lv = live.devices[d.key]
		if lv and lv.live then n.live = true end
	end
	for i, t in ipairs(tgt_rank) do
		local id = tgt_node[t.key]
		local ti = info.targets[t.key] or {}
		local base = (i <= top)
			and { kind = 'target', key = t.key, label = ti.display or t.key,
				unresolved = ti.unresolved == 1,
				source = ti.source or (ti.unresolved == 1 and 'ip' or 'dns'),
				asn_org = ti.asn_org }
			or { kind = 'other_targets', label = '其他去向' }
		local n = node(nodes.targets, id, base)
		n.members = n.members + 1
	end

	local paths, path_ids, total = {}, {}, 0
	for _, r in ipairs(rows) do
		local dn, tn = dev_node[r.device], tgt_node[r.target]
		local pid = dn .. '>' .. tn
		local p = paths[pid]
		if not p then
			p = { id = pid, from = dn, to = tn, bytes_up = 0, bytes_down = 0, live = false }
			paths[pid] = p
			path_ids[#path_ids + 1] = pid
		end
		p.bytes_up = p.bytes_up + (r.up or 0)
		p.bytes_down = p.bytes_down + (r.down or 0)
		if live.pairs[r.device .. '|' .. r.target] then p.live = true end
		local dnode, tnode = node_by_id[dn], node_by_id[tn]
		for _, n in ipairs({ dnode, tnode }) do
			n.bytes_up = n.bytes_up + (r.up or 0)
			n.bytes_down = n.bytes_down + (r.down or 0)
			n.bytes_total = n.bytes_up + n.bytes_down
		end
		if p.live then tnode.live = true end
		total = total + (r.up or 0) + (r.down or 0)
	end

	local colors = M.assign_colors(path_ids)
	local max_b = 0
	for _, pid in ipairs(path_ids) do
		local p = paths[pid]
		p.bytes_total = p.bytes_up + p.bytes_down
		if p.bytes_total > max_b then max_b = p.bytes_total end
	end
	table.sort(path_ids, function(a, b)
		local pa, pb = paths[a], paths[b]
		if pa.bytes_total ~= pb.bytes_total then return pa.bytes_total > pb.bytes_total end
		return a < b
	end)
	local edges, out_paths = {}, {}
	for _, pid in ipairs(path_ids) do
		local p = paths[pid]
		p.color = colors[pid]
		p.weight = max_b > 0 and p.bytes_total / max_b or 0
		out_paths[#out_paths + 1] = p
		edges[#edges + 1] = { id = pid .. '#in', path = pid, from = p.from, to = M.GATEWAY,
			color = p.color, weight = p.weight, live = p.live,
			bytes_up = p.bytes_up, bytes_down = p.bytes_down, bytes_total = p.bytes_total, leg = 'up' }
		edges[#edges + 1] = { id = pid .. '#out', path = pid, from = M.GATEWAY, to = p.to,
			color = p.color, weight = p.weight, live = p.live,
			bytes_up = p.bytes_up, bytes_down = p.bytes_down, bytes_total = p.bytes_total, leg = 'down' }
	end

	return {
		nodes = nodes,
		gateway = { id = M.GATEWAY, label = 'OpenWrt' },
		paths = out_paths,
		edges = edges,
		bytes_total = total,
		device_count = #dev_rank,
		target_count = #tgt_rank,
	}
end

-- Dense grid: every device seen in the range, sorted by traffic.
-- rows: { {mac, ip, hostname, last_seen, bytes_up, bytes_down, top_target?} }
function M.devices(rows, live)
	live = live or { devices = {} }
	local out = {}
	for _, r in ipairs(rows) do
		local up, down = tonumber(r.bytes_up) or 0, tonumber(r.bytes_down) or 0
		local lv = live.devices[r.mac] or {}
		out[#out + 1] = {
			mac = r.mac, ip = r.ip, hostname = r.hostname,
			label = r.hostname or r.ip or r.mac,
			last_seen = tonumber(r.last_seen),
			bytes_up = up, bytes_down = down, bytes_total = up + down,
			top_target = r.top_target,
			live = lv.live == true,
			rate_up = lv.rate_up or 0, rate_down = lv.rate_down or 0,
		}
	end
	table.sort(out, function(a, b)
		if a.bytes_total ~= b.bytes_total then return a.bytes_total > b.bytes_total end
		return a.mac < b.mac
	end)
	return out
end

return M
