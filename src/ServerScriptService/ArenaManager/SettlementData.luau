local SettlementData = {}
SettlementData.zones = nil
SettlementData.block_size = nil

function SettlementData.set_data(zones, block_size)
	SettlementData.zones = zones
	SettlementData.block_size = block_size
end

function SettlementData.get_zones()
	return SettlementData.zones or {}
end

function SettlementData.get_block_size()
	return SettlementData.block_size or 6
end

return SettlementData