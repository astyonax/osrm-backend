require("lib/access")
require("lib/maxspeed")

-- connect to postgis
lua_sql = require "luasql.postgres"
sql_env = assert( lua_sql.postgres() )
sql_con = assert( sql_env:connect("osm", "osm", "") )

-- Begin of globals
barrier_whitelist = { [""] = true, ["cycle_barrier"] = true, ["bollard"] = true, ["entrance"] = true, ["cattle_grid"] = true, ["border_control"] = true, ["toll_booth"] = true, ["sally_port"] = true, ["gate"] = true, ["no"] = true }
access_tag_whitelist = { ["yes"] = true, ["permissive"] = true, ["designated"] = true }
access_tag_blacklist = { ["no"] = true, ["private"] = true, ["agricultural"] = true, ["forestery"] = true }
access_tag_restricted = { ["destination"] = true, ["delivery"] = true }
access_tags_hierachy = { "bicycle", "vehicle", "access" }
cycleway_tags = {["track"]=true,["lane"]=true,["opposite"]=true,["opposite_lane"]=true,["opposite_track"]=true,["share_busway"]=true,["sharrow"]=true,["shared"]=true }
service_tag_restricted = { ["parking_aisle"] = true }
restriction_exception_tags = { "bicycle", "vehicle", "access" }

default_speed = 15
walking_speed = 6

bicycle_speeds = {
  ["cycleway"] = default_speed,
  ["primary"] = default_speed * 0.5,
  ["primary_link"] = default_speed * 0.5,
  ["secondary"] = default_speed * 0.6,
  ["secondary_link"] = default_speed * 0.6,
  ["tertiary"] = default_speed * 0.7,
  ["tertiary_link"] = default_speed * 0.7,
  ["residential"] = default_speed,
  ["unclassified"] = default_speed,
  ["living_street"] = default_speed,
  ["road"] = default_speed,
  ["service"] = default_speed,
  ["track"] = default_speed,
  ["path"] = default_speed
}

pedestrian_speeds = {
  ["footway"] = walking_speed,
  ["pedestrian"] = walking_speed,
  ["steps"] = 2
}

railway_speeds = {
  ["train"] = 10,
  ["railway"] = 10,
  ["subway"] = 10,
  ["light_rail"] = 10,
  ["monorail"] = 10,
  ["tram"] = 10
}

platform_speeds = {
  ["platform"] = walking_speed
}

amenity_speeds = {
  ["parking"] = 10,
  ["parking_entrance"] = 10
}

man_made_speeds = {
  ["pier"] = walking_speed
}

route_speeds = {
  ["ferry"] = 1
}

surface_speeds = {
  ["asphalt"] = default_speed,
  ["cobblestone:flattened"] = default_speed,
  ["paving_stones"] = default_speed,
  ["compacted"] = default_speed,
  ["cobblestone"] = default_speed * 0.8,
  ["unpaved"] = default_speed,
  ["gravel"] = default_speed * 0.8,
  ["fine_gravel"] = default_speed * 0.8,
  ["pebbelstone"] = default_speed * 0.8,
  ["ground"] = default_speed * 0.8,
  ["dirt"] = default_speed * 0.8 ,
  ["earth"] = default_speed  * 0.5,
  ["grass"] = default_speed * 0.3,
  ["mud"] = default_speed * 0.1,
  ["sand"] =  default_speed * 0.1
}

take_minimum_of_speeds  = true
obey_oneway       = true
obey_bollards       = false
use_restrictions    = true
ignore_areas      = true    -- future feature
traffic_signal_penalty  = 10
u_turn_penalty      = 20
use_turn_restrictions   = false
turn_penalty      = 120
turn_bias         = 1.4


--modes
mode_normal = 1
mode_pushing = 2
mode_ferry = 3
mode_train = 4


local function parse_maxspeed(source)
    if not source then
        return 0
    end
    local n = tonumber(source:match("%d*"))
    if not n then
        n = 0
    end
    if string.match(source, "mph") or string.match(source, "mp/h") then
        n = (n*1609)/1000;
    end
    return n
end


function get_exceptions(vector)
  for i,v in ipairs(restriction_exception_tags) do
    vector:Add(v)
  end
end

function node_function (node)
  local barrier = node.tags:Find ("barrier")
  local access = Access.find_access_tag(node, access_tags_hierachy)
  local traffic_signal = node.tags:Find("highway")

	-- flag node if it carries a traffic light
	if traffic_signal == "traffic_signals" then
		node.traffic_light = true
	end

	-- parse access and barrier tags
	if access and access ~= "" then
		if access_tag_blacklist[access] then
			node.bollard = true
		else
			node.bollard = false
		end
	elseif barrier and barrier ~= "" then
		if barrier_whitelist[barrier] then
			node.bollard = false
		else
			node.bollard = true
		end
	end

	-- return 1
end

function way_function (way)
  -- initial routability check, filters out buildings, boundaries, etc
  local highway = way.tags:Find("highway")
  local route = way.tags:Find("route")
  local man_made = way.tags:Find("man_made")
  local railway = way.tags:Find("railway")
  local amenity = way.tags:Find("amenity")
  local public_transport = way.tags:Find("public_transport")
  if (not highway or highway == '') and
  (not route or route == '') and
  (not railway or railway=='') and
  (not amenity or amenity=='') and
  (not man_made or man_made=='') and
  (not public_transport or public_transport=='')
  then
    return
  end

  -- don't route on ways or railways that are still under construction
  if highway=='construction' or railway=='construction' then
    return
  end

  -- access
  local access = Access.find_access_tag(way, access_tags_hierachy)
  if access_tag_blacklist[access] then
    return
  end

  -- other tags
  local name = way.tags:Find("name")
  local ref = way.tags:Find("ref")
  local junction = way.tags:Find("junction")
  local maxspeed = parse_maxspeed(way.tags:Find ( "maxspeed") )
  local maxspeed_forward = parse_maxspeed(way.tags:Find( "maxspeed:forward"))
  local maxspeed_backward = parse_maxspeed(way.tags:Find( "maxspeed:backward"))
  local barrier = way.tags:Find("barrier")
  local oneway = way.tags:Find("oneway")
  local onewayClass = way.tags:Find("oneway:bicycle")
  local cycleway = way.tags:Find("cycleway")
  local cycleway_left = way.tags:Find("cycleway:left")
  local cycleway_right = way.tags:Find("cycleway:right")
  local duration = way.tags:Find("duration")
  local service = way.tags:Find("service")
  local area = way.tags:Find("area")
  local foot = way.tags:Find("foot")
  local surface = way.tags:Find("surface")
  local bicycle = way.tags:Find("bicycle")

  -- name
  if "" ~= ref and "" ~= name then
    way.name = name .. ' / ' .. ref
  elseif "" ~= ref then
    way.name = ref
  elseif "" ~= name then
    way.name = name
  else
    -- if no name exists, use way type
    -- this encoding scheme is excepted to be a temporary solution
    way.name = "{highway:"..highway.."}"
  end

  -- roundabout handling
  if "roundabout" == junction then
    way.roundabout = true;
  end

  -- speed
  if route_speeds[route] then
    -- ferries (doesn't cover routes tagged using relations)
    way.forward_mode = mode_ferry
    way.backward_mode = mode_ferry
    way.ignore_in_grid = true
    if durationIsValid(duration) then
      way.duration = math.max( 1, parseDuration(duration) )
    else
       way.forward_speed = route_speeds[route]
       way.backward_speed = route_speeds[route]
    end
  elseif railway and platform_speeds[railway] then
    -- railway platforms (old tagging scheme)
    way.forward_speed = platform_speeds[railway]
    way.backward_speed = platform_speeds[railway]
  elseif platform_speeds[public_transport] then
    -- public_transport platforms (new tagging platform)
    way.forward_speed = platform_speeds[public_transport]
    way.backward_speed = platform_speeds[public_transport]
    elseif railway and railway_speeds[railway] then
      way.forward_mode = mode_train
      way.backward_mode = mode_train
     -- railways
    if access and access_tag_whitelist[access] then
      way.forward_speed = railway_speeds[railway]
      way.backward_speed = railway_speeds[railway]
    end
  elseif amenity and amenity_speeds[amenity] then
    -- parking areas
    way.forward_speed = amenity_speeds[amenity]
    way.backward_speed = amenity_speeds[amenity]
  elseif bicycle_speeds[highway] then
    -- regular ways
    way.forward_speed = bicycle_speeds[highway]
    way.backward_speed = bicycle_speeds[highway]
  elseif access and access_tag_whitelist[access] then
    -- unknown way, but valid access tag
    way.forward_speed = default_speed
    way.backward_speed = default_speed
  else
    -- biking not allowed, maybe we can push our bike?
    -- essentially requires pedestrian profiling, for example foot=no mean we can't push a bike
    if foot ~= 'no' and junction ~= "roundabout" then
      if pedestrian_speeds[highway] then
        -- pedestrian-only ways and areas
        way.forward_speed = pedestrian_speeds[highway]
        way.backward_speed = pedestrian_speeds[highway]
        way.forward_mode = mode_pushing
        way.backward_mode = mode_pushing
      elseif man_made and man_made_speeds[man_made] then
        -- man made structures
        way.forward_speed = man_made_speeds[man_made]
        way.backward_speed = man_made_speeds[man_made]
        way.forward_mode = mode_pushing
        way.backward_mode = mode_pushing
      elseif foot == 'yes' then
        way.forward_speed = walking_speed
        way.backward_speed = walking_speed
        way.forward_mode = mode_pushing
        way.backward_mode = mode_pushing
      elseif foot_forward == 'yes' then
        way.forward_speed = walking_speed
        way.forward_mode = mode_pushing
        way.backward_mode = 0
      elseif foot_backward == 'yes' then
        way.forward_speed = walking_speed
        way.forward_mode = 0
        way.backward_mode = mode_pushing
      end
    end
  end

  -- direction
  local impliedOneway = false
  if junction == "roundabout" or highway == "motorway_link" or highway == "motorway" then
    impliedOneway = true
  end

  if onewayClass == "yes" or onewayClass == "1" or onewayClass == "true" then
    way.backward_mode = 0
  elseif onewayClass == "no" or onewayClass == "0" or onewayClass == "false" then
    -- prevent implied oneway
  elseif onewayClass == "-1" then
    way.forward_mode = 0
  elseif oneway == "no" or oneway == "0" or oneway == "false" then
    -- prevent implied oneway
  elseif cycleway and string.find(cycleway, "opposite") == 1 then
    if impliedOneway then
      way.forward_mode = 0
      way.backward_mode = mode_normal
      --way.backward_speed = bicycle_speeds["cycleway"]
    end
  elseif cycleway_left and cycleway_tags[cycleway_left] and cycleway_right and cycleway_tags[cycleway_right] then
    -- prevent implied
  elseif cycleway_left and cycleway_tags[cycleway_left] then
    if impliedOneway then
      way.forward_mode = 0
      way.backward_mode = mode_normal
      --way.backward_speed = bicycle_speeds["cycleway"]
    end
  elseif cycleway_right and cycleway_tags[cycleway_right] then
    if impliedOneway then
      way.forward_mode = mode_normal
      --way.backward_speed = bicycle_speeds["cycleway"]
      way.backward_mode = 0
    end
  elseif oneway == "-1" then
    way.forward_mode = 0
  elseif oneway == "yes" or oneway == "1" or oneway == "true" or impliedOneway then
    way.backward_mode = 0
  end
  
  -- pushing bikes
  if bicycle_speeds[highway] or pedestrian_speeds[highway] then
    if foot ~= "no" and junction ~= "roundabout" then
      if way.backward_mode == 0 then
        way.backward_speed = walking_speed
        way.backward_mode = mode_pushing
      elseif way.forward_mode == 0 then
        way.forward_speed = walking_speed
        way.forward_mode = mode_pushing
      end
    end
  end

  -- cycleways
  --if cycleway and cycleway_tags[cycleway] then
  --  way.forward_speed = bicycle_speeds["cycleway"]
  --  way.backward_speed = bicycle_speeds["cycleway"]
  --elseif cycleway_left and cycleway_tags[cycleway_left] then
  --  way.backward_speed = bicycle_speeds["cycleway"]
  --elseif cycleway_right and cycleway_tags[cycleway_right] then
  --  way.forward_speed = bicycle_speeds["cycleway"]
  --end

  -- dismount
  if bicycle == "dismount" then
    way.forward_mode = mode_pushing
    way.backward_mode = mode_pushing
    way.forward_speed = walking_speed
    way.backward_speed = walking_speed
  end

  -- surfaces
  if surface then
    surface_speed = surface_speeds[surface]
    if surface_speed then
      way.forward_speed = math.min( surface_speed, way.forward_speed )
      way.backward_speed = math.min( surface_speed, way.backward_speed )
    end
  end

  -- maxspeed
  --MaxSpeed.limit( way, maxspeed, maxspeed_forward, maxspeed_backward )

  -- compute score
  local score = 1

  if way.forward_speed > 0 or way.backward_speed > 0 then
    local bridge = way.tags:Find("bridge")
    if bridge=="yes" and highway=="cycleway" then
    -- bonus for bike bridges
      score = score * 1.5
    end

    local tunnel = way.tags:Find("tunnel")
    local layer = tonumber(way.tags:Find("layer"))
    if tunnel=="yes" or tunnel=="1" or (layer~=nil and layer<0) then
      -- if in a tunnel or underground, we don't have to consider
      -- nearby ways or areas
      score = score * 0.8
    else
      -- query PostGIS for information about surroundings
      -- expects data to be imported using oms2pgsql, with the ibikecph configuration
      -- specifically ways and areas are expected to have a 'green_score' attribute,
      -- which we use when computing how green the current way is

      local sql_query = nil
      local cursor = nil
      local row = nil
      local area_score_outside = 0
      local area_score_inside = 0
      local area_score = 0
      local line_score = 0

      -- proximity to areas (parks, landuse, etc)
      -- expand areas and sum up distance travelled through them
      sql_query = "" ..
        "SELECT " ..
        "  way.osm_id AS osm_id, " ..
        "  SUM( " ..
        "    ST_Length( " ..
        "      ST_Intersection( way.way, ST_Buffer(b.way, 20) ) " ..
        "    ) * b.green_score " ..
        "  ) / ST_Length( way.way ) AS score " ..
        "FROM planet_osm_line AS way " ..
        "INNER JOIN planet_osm_polygon b " ..
        "ON b.green_score <> 0 " ..
        "AND ST_DWithin( way.way, b.way, 20 )  " ..
        "WHERE way.osm_id = " .. way.id ..  " "..
        "GROUP BY way.osm_id, way.way; "

      cursor = assert( sql_con:execute(sql_query) )
      row = cursor:fetch( {}, "a" )
    	if row then
        area_score_outside = tonumber(row.score) * 0.3
      end

      -- inside areas (parks, landuse, etc)
      -- contract areas and sum up distance travelled through them
      sql_query = "" ..
        "SELECT " ..
        "  way.osm_id AS osm_id, " ..
        "  SUM( " ..
        "    ST_Length( " ..
        "      ST_Intersection( way.way, ST_Buffer(b.way, -10) ) " ..
        "    ) * b.green_score " ..
        "  ) / ST_Length( way.way ) AS score " ..
        "FROM planet_osm_line AS way " ..
        "INNER JOIN planet_osm_polygon b " ..
        "ON b.green_score <> 0 " ..
        "AND ST_Intersects( way.way, b.way )  " ..
        "WHERE way.osm_id = " .. way.id ..  " "..
        "GROUP BY way.osm_id, way.way; "

      cursor = assert( sql_con:execute(sql_query) )
      row = cursor:fetch( {}, "a" )
      if row then
        area_score_inside = tonumber(row.score)
      end
      area_score = area_score_outside + area_score_inside

      -- proximity to lines (ways, barriers, waterways, etc)
      sql_query = "" ..
        "SELECT " ..
        "  way.osm_id AS osm_id, " ..
        "  SUM( " ..
        "    ST_Length( " ..
        "      ST_Intersection( way.way, ST_Buffer(b.way, 20) ) " ..
        "    ) * b.green_score " ..
        "  ) / ST_Length( way.way ) AS score " ..
        "FROM planet_osm_line AS way " ..
        "INNER JOIN planet_osm_line b " ..
        "ON b.green_score <> 0 " ..                    -- only ways with a green score
        "AND b.osm_id <> " .. way.id ..  " " ..        -- don't join on self
        "AND (b.layer IS NULL OR b.layer>=0) " ..      -- ignore underground ways
        "AND b.tunnel <> 1" ..                         -- ignore tunnels
        "AND ST_DWithin( way.way, b.way, 20 )  " ..    -- within 20 meters
        "WHERE way.osm_id = " .. way.id ..  " "..
        "GROUP BY way.osm_id, way.way; "

      cursor = assert( sql_con:execute(sql_query) )
      row = cursor:fetch( {}, "a" )
      if row then
        line_score = tonumber(row.score) * 1.0
      end

      -- use sigmoid function to ensure a factor in the range [0..2]
      -- http://en.wikipedia.org/wiki/Sigmoid_function
      -- input of will produce 1 as output
      local sum = area_score + line_score   -- might be negative
      local steepness = 4.0                 -- steepness
      score = 2/(1.0+math.pow(steepness,-sum))
    end
  end


  if score == nil then
    score = 'NULL'
  else
    local min_speed = 1
    way.forward_speed = math.max(way.forward_speed * score, min_speed )
    way.backward_speed = math.max(way.backward_speed * score, min_speed )
  end

  -- for debugging, write the score back to postgis
  local update_query = 
    "UPDATE planet_osm_line " ..
    "SET osrm_speed = " .. way.forward_speed .. ", green_computed = " .. score .. " " ..
    "WHERE osm_id = " .. way.id .. ";"
  sql_con:execute(update_query)
  
end

function turn_function (angle)
  -- compute turn penalty as angle^2, with a left/right bias
  k = turn_penalty/(90.0*90.0)
  if angle>=0 then
    return angle*angle*k/turn_bias
  else
    return angle*angle*k*turn_bias
  end
end
