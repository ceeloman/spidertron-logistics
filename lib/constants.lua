-- Constants for spidertron logistics mod

local constants = {}

constants.update_cooldown = 4 * 60

constants.idle = 1
constants.picking_up = 2
constants.dropping_off = 3
constants.dumping_items = 4

constants.spidertron_logistic_beacon = 'spidertron-logistic-beacon'
constants.spidertron_requester_chest = 'spidertron-requester-chest'
constants.spidertron_provider_chest = 'spidertron-provider-chest'

-- Job delay thresholds
constants.min_availability_ratio = 0.2  -- Delay if can_provide < 20% of real_amount
constants.distance_delay_base = 200     -- Base distance (tiles) to start applying delay scaling
constants.distance_delay_multiplier = 0.1  -- For every tile beyond base, increase min items by this ratio
constants.critical_fill_threshold = 0.2  -- If requester fill % < 20%, never delay (urgent)

return constants

