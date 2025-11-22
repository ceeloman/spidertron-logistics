if storage.beacons then goto updated end

storage.beacons = {}
for _, surface in pairs(game.surfaces) do
	for _, beacon in pairs(surface.find_entities_filtered{name = 'spidertron-logistic-beacon'}) do
		storage.beacons[beacon.unit_number] = beacon
		script.register_on_entity_died(beacon)
	end
end

::updated::
