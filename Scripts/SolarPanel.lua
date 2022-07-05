dofile("$SURVIVAL_DATA/Scripts/game/survival_items.lua")
dofile( "$SURVIVAL_DATA/Scripts/game/survival_shapes.lua" )
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/util/pipes.lua" )

DAYCYCLE_LIGHTING_TIMES = { 0, 3 / 24, 6 / 24, 18 / 24, 21 / 24, 1 }
DAYCYCLE_LIGHTING_VALUES = { 0, 0, 0.5, 0.5, 1, 1 }

BATTERY_POINTS = 20000
BATTERY_POINTS_PER_TICK = 500


SolarPanel = class()

-- TODO: add ui
-- TODO: refactor

-- SolarPanel.connectionOutput = sm.interactable.connectionType.electricity
SolarPanel.connectionInput = sm.interactable.connectionType.electricity
SolarPanel.maxParentCount = 1
--[[ Server ]]

-- (Event) Called upon creation on server
function SolarPanel.server_onCreate( self )
	local container = self.shape.interactable:getContainer( 0 )
	if not container then
		container = self.shape:getInteractable():addContainer( 0, 1, 10 )
	end
	container:setFilters( { obj_consumable_battery } )


	self:sv_init()
end

-- (Event) Called when script is refreshed (in [-dev])
function SolarPanel.server_onRefresh( self )
	self:sv_init()
end


function SolarPanel.sv_init( self )
	self.sv = {}

	-- client table goes to client
	self.sv.client = {}
	self.sv.client.pipeNetwork = {}

	-- storage table goes to storage
	self.sv.storage = self.storage:load()

	if self.sv.storage == nil then
		self.sv.storage = {}
	end

	if self.sv.storage.batteryPoints == nil then
		self.sv.storage.batteryPoints = 0
	end

	self.sv.clientDataDirty = false
	self.sv.dirtyStorageTable = false	
	self.sv.connectedContainers = {}
	
	self:sv_buildPipeNetwork()
end

function SolarPanel.sv_sendClientData( self )
	if self.sv.clientDataDirty then
		self.network:setClientData( { pipeNetwork = self.sv.client.pipeNetwork } )
		self.sv.clientDataDirty = false
	end
end

function SolarPanel.getInputs( self )
	local parents = self.interactable:getParents()
	local batteryContainer = nil

	if parents[1] then
		if parents[1]:hasOutputType( sm.interactable.connectionType.electricity ) then
			batteryContainer = parents[1]:getContainer( 0 )
		end
	end

	return batteryContainer

end

function SolarPanel.sv_getCurrentLightLevel() 
	local timeOfDay = sm.game.getTimeOfDay();

	local index = 1
	while index < #DAYCYCLE_LIGHTING_TIMES and timeOfDay >= DAYCYCLE_LIGHTING_TIMES[index + 1] do
		index = index + 1
	end
	assert( index <= #DAYCYCLE_LIGHTING_TIMES )

	local light = 0.0
	if index < #DAYCYCLE_LIGHTING_TIMES then
		local p = ( timeOfDay - DAYCYCLE_LIGHTING_TIMES[index] ) / ( DAYCYCLE_LIGHTING_TIMES[index + 1] - DAYCYCLE_LIGHTING_TIMES[index] )
		light = sm.util.lerp( DAYCYCLE_LIGHTING_VALUES[index], DAYCYCLE_LIGHTING_VALUES[index + 1], p )
	else
		light = DAYCYCLE_LIGHTING_VALUES[index]
	end

	return light
end

function SolarPanel.sv_markClientTableAsDirty( self )
	self.sv.clientDataDirty = true
end

function SolarPanel.sv_buildPipeNetwork( self )

	self.sv.client.pipeNetwork = {}
	self.sv.connectedContainers = {}

	local function fnOnVertex( vertex )

		if isAnyOf( vertex.shape:getShapeUuid(), ContainerUuids ) then -- Is Container
			assert( vertex.shape:getInteractable():getContainer() )
			local container = {
				shape = vertex.shape,
				distance = vertex.distance,
				shapesOnContainerPath = vertex.shapesOnPath
			}

			table.insert( self.sv.connectedContainers, container )
		elseif isAnyOf( vertex.shape:getShapeUuid(), PipeUuids ) then -- Is Pipe
			assert( vertex.shape:getInteractable() )
			local pipe = {
				shape = vertex.shape,
				state = PipeState.off
			}

			table.insert( self.sv.client.pipeNetwork, pipe )
		end

		return true
	end

	ConstructPipedShapeGraph( self.shape, fnOnVertex )

	-- Sort container by closests
	table.sort( self.sv.connectedContainers, function(a, b) return a.distance < b.distance end )

	-- Synch the pipe network and initial state to clients
	local state = PipeState.off

	for _, container in ipairs( self.sv.connectedContainers ) do
		for _, shape in ipairs( container.shapesOnContainerPath ) do
			for _, pipe in ipairs( self.sv.client.pipeNetwork ) do
				if pipe.shape:getId() == shape:getId() then
					pipe.state = PipeState.connected
				end
			end
		end
	end

	self.sv.client.state = state
	self:sv_markClientTableAsDirty()
end

-- (Event) Called upon game tick. (40 times a second)
function SolarPanel.server_onFixedUpdate( self, timeStep )

	-- Optimize this either through a simple has changed that only checks the body and not shapes
	-- Or let the body check and fire an event whenever it detects a change
	if self.shape:getBody():hasChanged( sm.game.getCurrentTick() - 1 ) then
		self:sv_buildPipeNetwork()
	end

	local success = sm.physics.spherecast(self.shape.worldPosition, sm.vec3.new(0, 0, 100), 2)

	if not success then
		local light = self.sv_getCurrentLightLevel()
		local storageFull = false
	
		if self.sv.storage.batteryPoints >= BATTERY_POINTS then
			
			local containerSearchResult = FindContainerToCollectTo( self.sv.connectedContainers, obj_consumable_battery, 1 )
			
	
			if containerSearchResult then
				sm.container.beginTransaction()
				sm.container.collect( containerSearchResult.shape:getInteractable():getContainer(), obj_consumable_battery, 1, true )
				if sm.container.endTransaction() then
					self.sv.storage.batteryPoints = 0
					
					self.network:sendToClients( "cl_n_onCollectToChest", { shapesOnContainerPath = containerSearchResult.shapesOnContainerPath, itemId = obj_consumable_battery } )
				else
					storageFull = true
				end
			else 
				storageFull = true
			end
		end
	
		if not storageFull then
			self.sv.storage.batteryPoints = self.sv.storage.batteryPoints + light * BATTERY_POINTS_PER_TICK
		end
	end

	self.storage:save( self.sv.storage )
	self:sv_sendClientData()
end

--[[ Client ]]

-- (Event) Called upon creation on client
function SolarPanel.client_onCreate( self )
	self:cl_init()
	-- TODO: add background buzze
end

function SolarPanel.client_onRefresh( self )
	self:cl_init()
end

function SolarPanel.client_onClientDataUpdate( self, data )
	self.cl.pipeNetwork = data.pipeNetwork
end

function SolarPanel.cl_init( self )
	self.cl = {}
	self.cl.pipeNetwork = {}

	self.cl.pipeEffectPlayer = PipeEffectPlayer()
	self.cl.pipeEffectPlayer:onCreate()

end

-- (Event) Called upon every frame. (Same as fps)
function SolarPanel.client_onUpdate( self, deltaTime )
	LightUpPipes( self.cl.pipeNetwork )
	
	self.cl.pipeEffectPlayer:update( deltaTime )
end

function SolarPanel.cl_n_onCollectToChest( self, params )

	local startNode = PipeEffectNode()
	startNode.shape = self.shape
	startNode.point = sm.vec3.new( -5.0, -2.5, 0.0 ) * sm.construction.constants.subdivideRatio
	table.insert( params.shapesOnContainerPath, 1, startNode)

	self.cl.pipeEffectPlayer:pushShapeEffectTask( params.shapesOnContainerPath, params.itemId )
end
