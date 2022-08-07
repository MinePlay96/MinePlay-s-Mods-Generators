dofile( "$SURVIVAL_DATA/Scripts/game/survival_items.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_shapes.lua" )
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/util/pipes.lua" )

dofile( "$CONTENT_DATA/Scripts/items.lua" )

DAYCYCLE_LIGHTING_TIMES = { 0, 3 / 24, 6 / 24, 18 / 24, 21 / 24, 1 }
DAYCYCLE_LIGHTING_VALUES = { 0, 0, 0.5, 0.5, 1, 1 }

BATTERY_POINTS_CREATION_COST = 20000
BATTERY_POINTS_GENERATION_PER_TICK = 500

INTERNAL_BATTERY_POINTS_STORAGE = 200000

SolarGenerator = class()

local GeneratorLevels = {
	[tostring(obj_solar_generator_01)] = {
		gears = Gears,
		effect = "SolarGenerator - Level 1",
		upgrade = tostring(obj_solar_generator_02),
		cost = 4,
		generation = 4,
		title = "#{LEVEL} 1",
		pointsPerBattery = INTERNAL_BATTERY_POINTS_STORAGE
	},
	[tostring(obj_solar_generator_02)] = {
		gears = Gears,
		effect = "SolarGenerator - Level 2",
		upgrade = tostring(obj_solar_generator_03),
		cost = 6,
		generation = 6,
		title = "#{LEVEL} 2",
		pointsPerBattery = INTERNAL_BATTERY_POINTS_STORAGE
	},
	[tostring(obj_solar_generator_03)] = {
		gears = Gears,
		effect = "SolarGenerator - Level 3",
		upgrade = tostring(obj_solar_generator_04),
		cost = 8,
		generation = 9,
		title = "#{LEVEL} 3",
		pointsPerBattery = INTERNAL_BATTERY_POINTS_STORAGE
	},
	[tostring(obj_solar_generator_04)] = {
		gears = Gears,
		effect = "SolarGenerator - Level 4",
		upgrade = tostring(obj_solar_generator_05),
		cost = 10,
		generation = 12,
		title = "#{LEVEL} 4",
		pointsPerBattery = INTERNAL_BATTERY_POINTS_STORAGE
	},
	[tostring(obj_solar_generator_05)] = {
		gears = Gears,
		effect = "SolarGenerator - Level 5",
		title = "#{LEVEL} 5",
		generation = 20,
		pointsPerBattery = INTERNAL_BATTERY_POINTS_STORAGE
	}
}

-- TODO: refactor client code

--[[ Server ]]

-- (Event) Called upon creation on server
function SolarGenerator.server_onCreate( self )
	-- TODO: add ui | internal container
	local container = self.shape.interactable:getContainer( 0 )
	if not container then
		container = self.shape:getInteractable():addContainer( 0, 1, 10 )
	end
	container:setFilters( { obj_consumable_battery } )

	local level = GeneratorLevels[tostring( self.shape:getShapeUuid() )]
	assert(level)
	self.level = level

	self:sv_init()
end

-- (Event) Called when script is refreshed (in [-dev])
function SolarGenerator.server_onRefresh( self )
	self:sv_init()
end

-- (Event) Called upon game tick. (40 times a second)
function SolarGenerator.server_onFixedUpdate( self, timeStep )

	if self:sv_pipeNetworkUpdateRequired() then
		self:sv_buildPipeNetwork()
	end

	if self:sv_canSeeSky() and not self:sv_isInternalBatteryPointsStorageFull() then
		self:sv_generateBatteryPoints()
	end

	if self:sv_canGenerateBattery() then
		self:sv_generateBattery()
	end

	self:sv_saveSorageData()
	self:sv_sendClientData()
end

function SolarGenerator.sv_init( self )
	self.sv = {}

	-- client table goes to client
	self.sv.client = {}
	self.sv.client.pipeNetwork = {}

	-- storage table goes to storage
	self.sv.storage = self.storage:load()

	if self.sv.storage == nil then
		self.sv.storage = {}
	end

	if self.sv.storage.internalBatteryPointsStorage == nil then
		self.sv.storage.internalBatteryPointsStorage = 0
	end

	self.sv.clientDataDirty = false
	self.sv.storageDataDirty = false	
	self.sv.connectedContainers = {}
	
	self:sv_buildPipeNetwork()
end

function SolarGenerator.sv_pipeNetworkUpdateRequired( self )
	-- Optimize this either through a simple has changed that only checks the body and not shapes
	-- Or let the body check and fire an event whenever it detects a change
	return self.shape:getBody():hasChanged( sm.game.getCurrentTick() - 1 )
end

function SolarGenerator.sv_canSeeSky( self )
	local raycastRadius = 1
	local raycastTarget = sm.vec3.new(0, 0, 100)
	local raycastStart = self.shape.worldPosition

	local hasBodyDetected = sm.physics.spherecast(self.shape.worldPosition, raycastTarget, raycastRadius)

	return not hasBodyDetected
end

function SolarGenerator.sv_isInternalBatteryPointsStorageFull( self )
	-- TODO: add upgrades and efficiency
	return self.sv.storage.internalBatteryPointsStorage >= INTERNAL_BATTERY_POINTS_STORAGE
end

function SolarGenerator.sv_getCurrentLightLevel( self ) 
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

function SolarGenerator.sv_generateBatteryPoints( self )

	local lightLevel = self.sv_getCurrentLightLevel()
	
	if lightLevel > 0 then
		local batteryPoints = self:getBatteryPointsGenerationByLightLevel( lightLevel )
		self:sv_addBatteryPoints( batteryPoints )
	end
end

function SolarGenerator.sv_canGenerateBattery( self )
	-- TODO: add upgrades and efficiency
	return self.sv.storage.internalBatteryPointsStorage >= BATTERY_POINTS_CREATION_COST
end

function SolarGenerator.sv_addBatteryPoints( self, batteryPoints )
	self.sv.storage.internalBatteryPointsStorage = self.sv.storage.internalBatteryPointsStorage + batteryPoints
	self:sv_markStorageDataAsDirty()
end

function SolarGenerator.sv_generateBattery( self )
	-- TODO: add ui | add check if no external container found use internal
	local containerSearchResult = FindContainerToCollectTo( self.sv.connectedContainers, obj_consumable_battery, 1 )

	if containerSearchResult then
		self:sv_sendBatteryToRemoteContainer(containerSearchResult)
	else
		self:sv_sendBatteryToLocalContainer()
	end

end

function SolarGenerator.sv_sendBatteryToLocalContainer( self )

	local container = self.shape.interactable:getContainer( 0 );

	if sm.container.totalQuantity(container, obj_consumable_battery) >= 10 then
		return
	end

	sm.container.beginTransaction()
	sm.container.collect( container, obj_consumable_battery, 1, true )

	if not sm.container.endTransaction() then
		print('Error: container Battery move Transaction faild')
	end

	-- TODO: add upgrades and efficiency
	self.sv.storage.internalBatteryPointsStorage = self.sv.storage.internalBatteryPointsStorage - BATTERY_POINTS_CREATION_COST
	self:sv_markStorageDataAsDirty()
end

function SolarGenerator.sv_sendBatteryToRemoteContainer( self, containerSearchResult )

	local container = containerSearchResult.shape:getInteractable():getContainer()

	sm.container.beginTransaction()
	sm.container.collect( container, obj_consumable_battery, 1, true )
	
	if not sm.container.endTransaction() then
		print('Error: container Battery move Transaction faild')
	end

	-- TODO: add upgrades and efficiency
	self.sv.storage.internalBatteryPointsStorage = self.sv.storage.internalBatteryPointsStorage - BATTERY_POINTS_CREATION_COST
	self:sv_markStorageDataAsDirty()
	
	self.network:sendToClients( "cl_n_onCollectToChest", { shapesOnContainerPath = containerSearchResult.shapesOnContainerPath, itemId = obj_consumable_battery } )

end

function SolarGenerator.sv_saveSorageData( self )
	if self.sv.storageDataDirty then
		self.storage:save( self.sv.storage )
		self.sv.storageDataDirty = false	
	end
end

function SolarGenerator.sv_sendClientData( self )
	if self.sv.clientDataDirty then
		self.network:setClientData( { pipeNetwork = self.sv.client.pipeNetwork } )
		self.sv.clientDataDirty = false
	end
end

function SolarGenerator.sv_markStorageDataAsDirty( self )
	self.sv.storageDataDirty = true
end

function SolarGenerator.sv_markClientDataAsDirty( self )
	self.sv.clientDataDirty = true
end

function SolarGenerator.sv_buildPipeNetwork( self )

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
	self:sv_markClientDataAsDirty()
end

function SolarGenerator.sv_n_tryUpgrade( self, _, player )

	if self.level and self.level.upgrade then
		local function fnUpgrade()
			local nextLevel = GeneratorLevels[self.level.upgrade]
			assert( nextLevel )
		
			self.network:sendToClients( "cl_n_onUpgrade", self.level.upgrade )

			self.shape:replaceShape( sm.uuid.new( self.level.upgrade ) )
			self.level = nextLevel
		end

		if sm.game.getEnableUpgrade() then
			local inventory = player:getInventory()

			if sm.container.totalQuantity( inventory, obj_consumable_component ) >= self.level.cost then

				if sm.container.beginTransaction() then
					sm.container.spend( inventory, obj_consumable_component, self.level.cost, true )

					if sm.container.endTransaction() then
						fnUpgrade()
					end
				end
			else
				print( "Cannot afford upgrade" )
			end
		end
	else
		print( "Can't be upgraded" )
	end

end

-- [[ Universal ]]

function SolarGenerator.getBatteryPointsGenerationByLightLevel( self, lightLevel )
	-- TODO: add normal distribution function
	-- TODO: add upgrades and efficiency
	return lightLevel * BATTERY_POINTS_GENERATION_PER_TICK
end

--[[ Client ]]

-- (Event) Called upon creation on client
function SolarGenerator.client_onCreate( self )
	local level = GeneratorLevels[tostring( self.shape:getShapeUuid() )]
	self.level = level

	self:cl_init()
	-- TODO: add background buzze
end

-- (Event) Called when script is refreshed (in [-dev])
function SolarGenerator.client_onRefresh( self )
	self:cl_init()
end

-- (Event) Called upon every frame. (Same as fps)
function SolarGenerator.client_onUpdate( self, deltaTime )
	LightUpPipes( self.cl.pipeNetwork )
	
	self.cl.pipeEffectPlayer:update( deltaTime )

	if self.gui then
		-- self.gui:setSliderData('BatteryProgress', BATTERY_POINTS_CREATION_COST, 500)
	end
end

-- (Event) Called when the server sends data to the client
function SolarGenerator.client_onClientDataUpdate( self, data )
	self.cl.pipeNetwork = data.pipeNetwork
end

function SolarGenerator.client_onDestroy( self )
	if self.gui then
		self.gui:close()
		self.gui:destroy()
		self.gui = nil
	end
end

function SolarGenerator.client_onInteract( self, character, state )
	if not state then
		return
	end

	self.gui = sm.gui.createGuiFromLayout( "$CONTENT_DATA/Gui/Layouts/Solar_Generator.layout" )

	self.gui:setText( "Name", "#{SOLAR_GENERATOR_TITLE}" )
	self.gui:setText( "Interaction", "#{SOLAR_GENERATOR_INSTRUCTION}" )
	self.gui:setText( "SubTitle", self.level.title )
	self.gui:setIconImage( "Icon", self.shape:getShapeUuid() )
	self.gui:setOnCloseCallback( "cl_onGuiClosed" )
	self.gui:setButtonCallback( "Upgrade", "cl_onUpgradeClicked" )

	self:cl_createFuelGrid()

	if self.level then
		if self.level.upgrade then
			local nextLevel = GeneratorLevels[ self.level.upgrade ]
			self.gui:setData( "UpgradeInfo", { Generation = nextLevel.generation } )
			self.gui:setIconImage( "UpgradeIcon", sm.uuid.new( self.level.upgrade ) )
		else
			self.gui:setVisible( "UpgradeIcon", false )
			self.gui:setData( "UpgradeInfo", nil )
		end

		if sm.game.getEnableUpgrade() and self.level.cost then
			local inventory = sm.localPlayer.getPlayer():getInventory()
			local availableKits = sm.container.totalQuantity( inventory, obj_consumable_component )
			local upgradeData = { cost = self.level.cost, available = availableKits }
			self.gui:setData( "Upgrade", upgradeData )
			self.gui:setText( "UpgradeCost", availableKits .. "/" .. self.level.cost)
		else
			self.gui:setVisible( "Upgrade", false )
		end

		self.gui:setVisible( "MainPanelFuelUpgrade", true)
		self.gui:setVisible( "MainPanelFuelNoUpgrade", false)
	else
		self.gui:setVisible( "MainPanelFuelUpgrade", false)
		self.gui:setVisible( "MainPanelFuelNoUpgrade", true)
	end

	self.gui:open()
end

function SolarGenerator.cl_createFuelGrid( self )
	local procGrid = {
		type = "itemGrid",
		layout = "$CONTENT_DATA/Gui/Layouts/Solar_Generator_FuelItemSlot.layout",
		itemWidth = 98,
		itemHeight = 116,
		itemCount = 1,
	}
	self.gui:createGridFromJson( "FuelGrid", procGrid )
	self.gui:setContainer( "Fuel", self.shape.interactable:getContainer( 0 ) )
	-- self.cl.guiInterface:setGridButtonCallback( "Collect", "cl_onCollect" )
end

function SolarGenerator.cl_onUpgradeClicked( self, buttonName )
	print( "upgrade clicked" )
	self.network:sendToServer("sv_n_tryUpgrade", sm.localPlayer.getPlayer() )
end

function SolarGenerator.cl_onGuiClosed( self )
	self.gui:destroy()
	self.gui = nil
end

function SolarGenerator.cl_init( self )
	self.cl = {}
	self.cl.pipeNetwork = {}

	self.cl.pipeEffectPlayer = PipeEffectPlayer()
	self.cl.pipeEffectPlayer:onCreate()

end

-- Called from server every time a battery is generated
function SolarGenerator.cl_n_onCollectToChest( self, params )

	local startNode = PipeEffectNode()
	startNode.shape = self.shape
	startNode.point = sm.vec3.new( -5.0, -2.5, 0.0 ) * sm.construction.constants.subdivideRatio
	table.insert( params.shapesOnContainerPath, 1, startNode)

	self.cl.pipeEffectPlayer:pushShapeEffectTask( params.shapesOnContainerPath, params.itemId )
end

function SolarGenerator.cl_n_onUpgrade( self, upgrade )
	local nextLevel = GeneratorLevels[upgrade]

	if self.gui and self.gui:isActive() then
		self.gui:setIconImage( "Icon", sm.uuid.new( upgrade ) )

		if sm.game.getEnableUpgrade() and nextLevel.cost then
			local inventory = sm.localPlayer.getPlayer():getInventory()
			local availableKits = sm.container.totalQuantity( inventory, obj_consumable_component )
			local upgradeData = { cost = nextLevel.cost, available = availableKits }
			self.gui:setData( "Upgrade", upgradeData )
		else
			self.gui:setVisible( "Upgrade", false )
		end

		self.gui:setText( "SubTitle", nextLevel.title )
		if self.level.upgrade then
			self.gui:setData( "UpgradeInfo", { Generation = nextLevel.generation } )
			self.gui:setIconImage( "UpgradeIcon", sm.uuid.new( self.level.upgrade ) )
		else
			self.gui:setVisible( "UpgradeIcon", false )
			self.gui:setData( "UpgradeInfo", nil )
		end
	end

	self.effect = sm.effect.createEffect( nextLevel.effect, self.interactable )
	sm.effect.playHostedEffect( "Part - Upgrade", self.interactable )

	self.level = nextLevel
end
