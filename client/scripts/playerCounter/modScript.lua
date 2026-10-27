-- PlayerCounter client mod: loaded when a player downloads it from the server.
load("playerCounter_client")                           -- lua/ge/extensions/playerCounter/client.lua
setExtensionUnloadMode("playerCounter_client", "manual")  -- keep it across level loads
