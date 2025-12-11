-- Logging utility for spidertron logistics mod

local logging = {}

-- Enable/disable logging (set to false to disable all logs)
logging.enabled = true

-- Log levels
logging.levels = {
	DEBUG = 1,
	INFO = 2,
	WARN = 3,
	ERROR = 4
}

-- Current log level (only log messages at or above this level)
logging.current_level = logging.levels.DEBUG

function logging.log(level, category, message)
	if not logging.enabled then return end
	if level < logging.current_level then return end
	
	local prefix = "[Spidertron-Logistics"
	if category then
		prefix = prefix .. ":" .. category
	end
	prefix = prefix .. "] "
	
	-- Use log() to write to log file instead of game.print() which shows on screen
	log(prefix .. message)
end

function logging.debug(category, message)
	logging.log(logging.levels.DEBUG, category, message)
end

function logging.info(category, message)
	logging.log(logging.levels.INFO, category, message)
end

function logging.warn(category, message)
	logging.log(logging.levels.WARN, category, message)
end

function logging.error(category, message)
	logging.log(logging.levels.ERROR, category, message)
end

return logging

