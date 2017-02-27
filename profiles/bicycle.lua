api_version = 1

-- Bicycle profile
local find_access_tag = require("lib/access").find_access_tag
local Set = require('lib/set')
local Sequence = require('lib/sequence')
local Handlers = require("lib/handlers")
local next = next       -- bind to local for speed
local limit = require("lib/maxspeed").limit
local pprint = require('lib/pprint')

-- load foot profile and change default mode to pushing bike
local foot_profile = require('foot')
foot_profile.default_mode = mode.pushing_bike

-- these need to be global because they are accesed externaly
properties.max_speed_for_map_matching    = 110/3.6 -- kmph -> m/s
properties.use_turn_restrictions         = false
properties.continue_straight_at_waypoint = false
properties.weight_name                   = 'duration'
--properties.weight_name                   = 'cyclability'


local default_speed = 15
local walking_speed = 6

local profile = {
  default_mode              = mode.cycling,
  default_speed             = 15,
  speed_reduction           = 1,
  oneway_handling           = true,
  traffic_light_penalty     = 2,
  u_turn_penalty            = 20,
  turn_penalty              = 6,
  turn_bias                 = 1.4,

  -- reduce the driving speed by 30% for unsafe roads
  -- local safety_penalty            = 0.7,
  safety_penalty            = 1.0,
  use_public_transport      = true,

  allowed_start_modes = Set {
    mode.cycling,
    mode.pushing_bike
  },

  barrier_whitelist = Set {
    'sump_buster',
    'bus_trap',
    'cycle_barrier',
    'bollard',
    'entrance',
    'cattle_grid',
    'border_control',
    'toll_booth',
    'sally_port',
    'gate',
    'no',
    'block'
  },

  access_tag_whitelist = Set {
  	'yes',
  	'permissive',
   	'designated'
  },

  access_tag_blacklist = Set {
  	'no',
   	'private',
   	'agricultural',
   	'forestry',
   	'delivery'
  },

  restricted_access_tag_list = Set { },

  restricted_highway_whitelist = Set { },

  access_tags_hierarchy = Sequence {
  	'bicycle',
  	'vehicle',
  	'access'
  },

  restrictions = Sequence {
  	'bicycle'
  },

  cycleway_tags = Set {
  	'track',
  	'lane',
  	'opposite',
  	'opposite_lane',
  	'opposite_track',
  	'share_busway',
  	'sharrow',
  	'shared'
  },

  unsafe_highway_list = Set {
  	'primary',
   	'secondary',
   	'tertiary',
   	'primary_link',
   	'secondary_link',
   	'tertiary_link'
  },
  
  speeds = Sequence {
    highway = {
      cycleway = default_speed,
      primary = default_speed,
      primary_link = default_speed,
      secondary = default_speed,
      secondary_link = default_speed,
      tertiary = default_speed,
      tertiary_link = default_speed,
      residential = default_speed,
      unclassified = default_speed,
      living_street = default_speed,
      road = default_speed,
      service = default_speed,
      track = 12,
      path = 12
    }
  },
  
  pedestrian_speeds = {
    footway = walking_speed,
    pedestrian = walking_speed,
    steps = 2
  },

  railway_speeds = {
    train = 10,
    railway = 10,
    subway = 10,
    light_rail = 10,
    monorail = 10,
    tram = 10
  },

  platform_speeds = {
    platform = walking_speed
  },

  amenity_speeds = {
    parking = 10,
    parking_entrance = 10
  },

  man_made_speeds = {
    pier = walking_speed
  },

  route_speeds = {
    ferry = 5
  },

  bridge_speeds = {
    movable = 5
  },

  surface_speeds = {
    asphalt = default_speed,
    ["cobblestone:flattened"] = 10,
    paving_stones = 10,
    compacted = 10,
    cobblestone = 6,
    unpaved = 6,
    fine_gravel = 6,
    gravel = 6,
    pebblestone = 6,
    ground = 6,
    dirt = 6,
    earth = 6,
    grass = 6,
    mud = 3,
    sand = 3,
    sett = 10
  },

  tracktype_speeds = {
  },

  smoothness_speeds = {
  },

  avoid = Set {
    'impassable',
    'construction'
  }
}


local function parse_maxspeed(source)
    if not source then
        return 0
    end
    local n = tonumber(source:match("%d*"))
    if not n then
        n = 0
    end
    if string.match(source, "mph") or string.match(source, "mp/h") then
        n = (n*1609)/1000
    end
    return n
end

function get_restrictions(vector)
  for i,v in ipairs(profile.restrictions) do
    vector:Add(v)
  end
end

function node_function (node, result)
  -- parse access and barrier tags
  local highway = node:get_value_by_key("highway")
  local is_crossing = highway and highway == "crossing"

  local access = find_access_tag(node, profile.access_tags_hierarchy)
  if access and access ~= "" then
    -- access restrictions on crossing nodes are not relevant for
    -- the traffic on the road
    if profile.access_tag_blacklist[access] and not is_crossing then
      result.barrier = true
    end
  else
    local barrier = node:get_value_by_key("barrier")
    if barrier and "" ~= barrier then
      if not profile.barrier_whitelist[barrier] then
        result.barrier = true
      end
    end
  end

  -- check if node is a traffic light
  local tag = node:get_value_by_key("highway")
  if tag and "traffic_signals" == tag then
    result.traffic_lights = true
  end
end

function way_function (way, result)
  -- the intial filtering of ways based on presence of tags
  -- affects processing times significantly, because all ways
  -- have to be checked.
  -- to increase performance, prefetching and intial tag check
  -- is done in directly instead of via a handler.

  -- in general we should  try to abort as soon as
  -- possible if the way is not routable, to avoid doing
  -- unnecessary work. this implies we should check things that
  -- commonly forbids access early, and handle edge cases later.

  -- data table for storing intermediate values during processing
  local data = {
    -- prefetch tags
    highway = way:get_value_by_key('highway'),
    bridge = way:get_value_by_key('bridge'),
    route = way:get_value_by_key('route'),
    leisure = way:get_value_by_key('leisure'),
    man_made = way:get_value_by_key('man_made'),
    railway = way:get_value_by_key('railway'),
    platform = way:get_value_by_key('platform'),
    amenity = way:get_value_by_key('amenity'),
    public_transport = way:get_value_by_key('public_transport'),
    bicycle = way:get_value_by_key("bicycle")
  }

  local bike_result = {}
  bicycle_way_function(data,way,bike_result)
  
  --pprint(bike_result)
  if not Handlers.both_directions_handled(data,bike_result,profile) then
    -- one or both directions are not routable by bike
    -- use foot profile to check if we can walk, if so
    -- assume we can push our bike.
    -- note that bicycle=no prevents pushing of bikes
    local foot_result = {}
    Handlers.handle_init(way,foot_result,data,foot_profile)
    foot_profile.way_function(way,foot_result)
    Handlers.merge(foot_result,bike_result)
  end
  
  Handlers.output(bike_result,result)
end

function handle_cycleways(way,result,data,profile)
  local cycleway = way:get_value_by_key("cycleway")
  local cycleway_left = way:get_value_by_key("cycleway:left")
  local cycleway_right = way:get_value_by_key("cycleway:right")
  
  local common = cycleway and profile.cycleway_tags[cycleway]
  local left = cycleway_left and profile.cycleway_tags[cycleway_left]
  local right = cycleway_right and profile.cycleway_tags[cycleway_right]
  local speed = profile.speeds.highway["cycleway"]
    
  if cycleway == 'opposite' or cycleway == 'opposite_track' or cycleway == 'opposite_lane' then
    if data.is_reverse_oneway then
      result.forward_mode = mode.cycling
      result.forward_speed = speed
    else
      result.backward_mode = mode.cycling
      result.backward_speed = speed
    end
  elseif common then
    if data.is_forward_oneway then
      result.forward_mode = mode.cycling
      result.forward_speed = speed
    elseif data.is_reverse_oneway then
      result.backward_mode = mode.cycling
      result.backward_speed = speed
    else
      result.backward_mode = mode.cycling
      result.backward_speed = speed
      result.forward_mode = mode.cycling
      result.forward_speed = speed    
    end
  elseif left and right then
    result.backward_mode = mode.cycling
    result.backward_speed = speed
    result.forward_mode = mode.cycling
    result.forward_speed = speed    
  elseif left then
    result.backward_mode = mode.cycling
    result.backward_speed = speed
  elseif right then
    result.forward_mode = mode.cycling
    result.forward_speed = speed    
  end
end

function bicycle_way_function (data,way,result)

  local handlers = Sequence {
    Handlers.handle_init,
    Handlers.handle_default_mode,
    Handlers.handle_blocked_ways,
    Handlers.handle_access,
    Handlers.handle_dismount,
    Handlers.handle_oneway,
    Handlers.handle_roundabouts,
    handle_cycleways,
    Handlers.handle_speed,
    --Handlers.handle_surface,
    Handlers.handle_maxspeed,
    Handlers.handle_weights
  }

  if Handlers.run(handlers,way,result,data,profile) == false then
    return
  end

  -- initial routability check, filters out buildings, boundaries, etc
  local route = way:get_value_by_key("route")
  local man_made = way:get_value_by_key("man_made")
  local railway = way:get_value_by_key("railway")
  local amenity = way:get_value_by_key("amenity")
  local public_transport = way:get_value_by_key("public_transport")
  local bridge = way:get_value_by_key("bridge")

  if (not data.highway or data.highway == '') and
  (not route or route == '') and
  (not profile.use_public_transport or not railway or railway=='') and
  (not amenity or amenity=='') and
  (not man_made or man_made=='') and
  (not public_transport or public_transport=='') and
  (not bridge or bridge=='')
  then
    return
  end


  -- other tags
  local barrier = way:get_value_by_key("barrier")
  local duration = way:get_value_by_key("duration")
  local service = way:get_value_by_key("service")


  -- speed
  local bridge_speed = profile.bridge_speeds[bridge]
  if (bridge_speed and bridge_speed > 0) then
    data.highway = bridge
    if duration and durationIsValid(duration) then
      result.duration = math.max( parseDuration(duration), 1 )
    end
    result.forward_speed = bridge_speed
    result.backward_speed = bridge_speed
  elseif profile.route_speeds[route] then
    -- ferries (doesn't cover routes tagged using relations)
    result.forward_mode = mode.ferry
    result.backward_mode = mode.ferry
    if duration and durationIsValid(duration) then
      result.duration = math.max( 1, parseDuration(duration) )
    else
       result.forward_speed = profile.route_speeds[route]
       result.backward_speed = profile.route_speeds[route]
    end
  -- railway platforms (old tagging scheme)
  elseif railway and profile.platform_speeds[railway] then
    result.forward_speed = profile.platform_speeds[railway]
    result.backward_speed = profile.platform_speeds[railway]
  -- public_transport platforms (new tagging platform)
  elseif public_transport and profile.platform_speeds[public_transport] then
    result.forward_speed = profile.platform_speeds[public_transport]
    result.backward_speed = profile.platform_speeds[public_transport]
  -- railways
  elseif profile.use_public_transport and railway and profile.railway_speeds[railway] and profile.access_tag_whitelist[access] then
    result.forward_mode = mode.train
    result.backward_mode = mode.train
    result.forward_speed = profile.railway_speeds[railway]
    result.backward_speed = profile.railway_speeds[railway]
  elseif amenity and profile.amenity_speeds[amenity] then
    -- parking areas
    result.forward_speed = profile.amenity_speeds[amenity]
    result.backward_speed = profile.amenity_speeds[amenity]
  elseif profile.speeds.highway[data.highway] then
    -- regular ways
    result.forward_speed = profile.speeds.highway[data.highway]
    result.backward_speed = profile.speeds.highway[data.highway]
  elseif access and profile.access_tag_whitelist[access]  then
    -- unknown way, but valid access tag
    result.forward_speed = default_speed
    result.backward_speed = default_speed
  else
  end




  -- convert duration into cyclability
  local is_unsafe = profile.safety_penalty < 1 and profile.unsafe_highway_list[data.highway]
  if result.forward_speed > 0 then
    -- convert from km/h to m/s
    result.forward_rate = result.forward_speed / 3.6;
    if is_unsafe then
      result.forward_rate = result.forward_rate * profile.safety_penalty
    end
  end
  if result.backward_speed > 0 then
    -- convert from km/h to m/s
    result.backward_rate = result.backward_speed / 3.6;
    if is_unsafe then
      result.backward_rate = result.backward_rate * profile.safety_penalty
    end
  end
  if result.duration > 0 then
    result.weight = result.duration;
    if is_unsafe then
      result.weight = result.weight * (1+profile.safety_penalty)
    end
  end



  local handlers = Sequence {
    -- compute speed taking into account way type, maxspeed tags, etc.
    Handlers.handle_surface,

    -- handle turn lanes and road classification, used for guidance
    Handlers.handle_classification,

    -- handle various other flags
    Handlers.handle_roundabouts,
    Handlers.handle_startpoint,

    -- set name, ref and pronunciation
    Handlers.handle_names
  }

  Handlers.run(handlers,way,result,data,profile)

end

function turn_function(turn)
  -- compute turn penalty as angle^2, with a left/right bias
  local normalized_angle = turn.angle / 90.0
  if normalized_angle >= 0.0 then
    turn.duration = normalized_angle * normalized_angle * profile.turn_penalty / profile.turn_bias
  else
    turn.duration = normalized_angle * normalized_angle * profile.turn_penalty * profile.turn_bias
  end

  if turn.direction_modifier == direction_modifier.uturn then
    turn.duration = turn.duration + profile.u_turn_penalty
  end

  if turn.has_traffic_light then
     turn.duration = turn.duration + profile.traffic_light_penalty
  end
  if properties.weight_name == 'cyclability' then
      -- penalize turns from non-local access only segments onto local access only tags
      if not turn.source_restricted and turn.target_restricted then
          turn.weight = turn.weight + 3000
      end
  end
end

profile.way_function = way_function
return profile