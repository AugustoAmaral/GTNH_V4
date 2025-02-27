local shell = require('shell')
local args = {...}
local branch
local repo
local scripts = {'action.lua', 'database.lua', 'gps.lua', 'scanner.lua', 'config.lua', 'autoStat.lua', 'autoTier.lua',
                 'autoSpread.lua', 'autoMutate.lua', 'uninstall.lua'}

-- BRANCH
if #args >= 1 then
    branch = args[1]
else
    branch = 'main'
end

-- REPO
if #args >= 2 then
    repo = args[2]
else
    repo = 'https://raw.githubusercontent.com/AugustoAmaral/GTNH-CropAutomation/'
end

-- INSTALL
for i = 1, #scripts do
    shell.execute(string.format('wget -f %s%s/%s', repo, branch, scripts[i]))
end
