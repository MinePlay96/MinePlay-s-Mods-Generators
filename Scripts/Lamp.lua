Lamp = class()

--[[ Server ]]

-- (Event) Called upon creation on server
function Lamp.server_onCreate( self )
	self:sv_init()
end

-- (Event) Called when script is refreshed (in [-dev])
function Lamp.server_onRefresh( self )
	self:sv_init()
end

function MountedPotatoGun.sv_init( self )
end

-- (Event) Called upon game tick. (40 times a second)
function Lamp.server_onFixedUpdate( self, timeStep )
end

--[[ Client ]]

-- (Event) Called upon creation on client
function Lamp.client_onCreate( self )
    self.lightEffect = sm.effect.createEffect( "pointLight" )
end

-- (Event) Called upon every frame. (Same as fps)
function Lamp.client_onUpdate( self, dt )
    if self.interactable.active and not self.lightEffect:isPlaying() then
		self.lightEffect:start()
	elseif not self.interactable.active and self.lightEffect:isPlaying() then
		self.lightEffect:stop()
	end
end

function Lamp.client_onGraphicsLoaded( self )

end