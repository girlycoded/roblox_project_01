if game:GetService("RunService"):IsRunMode() then return end
plugin.Name = "KitSync"

--// Services
local ContentProvider = game:GetService("ContentProvider")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")
local StarterPlayerScripts = StarterPlayer.StarterPlayerScripts
local StarterCharacterScripts = StarterPlayer.StarterCharacterScripts
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local ScriptEditorService = game:GetService("ScriptEditorService")

--// CONSTS & Types
type ChangeItem = {
	instance: LuaSourceContainer,
	status: "addition" | "modification" | "deletion",
}

local NULL_PROXY = newproxy()

local STATUS_ICONS = {
	addition = {
		image = "rbxassetid://124035990493765",
		color = Color3.fromRGB(34, 134, 58),
	},
	modification = {
		image = "rbxassetid://103912415783053",
		color = Color3.fromRGB(170, 133, 7),
	},
	deletion = {
		image = "rbxassetid://75872286847980",
		color = Color3.fromRGB(203, 36, 49),
	}
}

local ASSETS_TO_PRELOAD = {"rbxassetid://124035990493765", "rbxassetid://103912415783053", "rbxassetid://75872286847980"}

--// Instances
local KitSync = script.Parent
local resources = KitSync.res
local src = KitSync.src

local github_interaction = require(src.github_interaction)
local utils = require(src.utils)

local encoded_cache = plugin:GetSetting(tostring(game.PlaceId) .. "cache")
local server_cache = {}

pcall(function()
	server_cache = HttpService:JSONDecode(encoded_cache) or server_cache
	print(server_cache)
end)

local widget = plugin:CreateDockWidgetPluginGuiAsync("KitSync", DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Left, false, false, 200, 200))
widget.Title = "Kit Sync"
widget.Name = "KitSync"

local toolbar = plugin:CreateToolbar("Kit Sync")
local plugin_button = toolbar:CreateButton("kitsync", "Sinks your cat", "rbxassetid://128458651639110", "Kit Sync")
plugin_button.ClickableWhenViewportHidden = true

plugin_button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	plugin_button:SetActive(widget.Enabled)
end)
plugin_button:SetActive(widget.Enabled)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	plugin_button:SetActive(widget.Enabled)
end)

function _parent_cache_if_widget_enabled()
	if not widget.Enabled then return end

	ContentProvider:PreloadAsync(ASSETS_TO_PRELOAD)
end

function save_cache(): boolean
	local success, result = pcall(function()
		local encoded_cache = HttpService:JSONEncode(server_cache)
		plugin:SetSetting(tostring(game.PlaceId) .. "cache", encoded_cache)
	end)
	if not success then warn("Failed to save server_cache!") end
	return success
end

widget:GetPropertyChangedSignal("Enabled"):Connect(_parent_cache_if_widget_enabled)
_parent_cache_if_widget_enabled()

--// Variables/
-- #TODO_readd_workspace_before_prod
local locations_to_index_names = {"Workspace", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer"}
local allowed_file_extensions = {"lua", "luau"}
local script_lookup = {
	server = "Script",
	client = "LocalScript",
	module = "ModuleScript",
}
local location_lookups = {
	client = "StarterPlayerScripts",
	server = "ServerScriptService",
	shared = "ReplicatedStorage",
	character = "StarterCharacterScripts"
}
local service_indexes = {
	ReplicatedStorage = "shared",
	ServerScriptService = "server",
	StarterPlayerScripts = "client",
	StarterCharacterScripts = "character",
}

local changes: {string: LuaSourceContainer} = {}

local user
local branch = "main"
local src_root = "src"

--// Gui

local gui = resources.View:Clone()
local Main = gui.Main

local Start = gui.Start

local StartPage = Start.StartPage
local Title = StartPage.Title
local TitleLabel = Title.TitleLabel
local SubtitleLabel = Title.SubtitleLabel

local User = Start.User
local UsernameLabel = User.UsernameLabel
local SignInStatusLabel = User.SignInStatusLabel
local LogOutButton = User.LogOutButton

local PATSignIn = StartPage.PATSignIn
local Login = PATSignIn.Login
local AccessTokenInput = Login.AccessTokenInput
local Hider = AccessTokenInput.Hider
local LoginButton = Login.LoginButton

local RepositoryList = StartPage.RepositoryList
local RepositoryScrollingFrame = RepositoryList.RepositoryScrollingFrame
local ErrorMessage = PATSignIn.ErrorMessage

--// Main GUI
local ChangesFrame = Main.ChangesFrame
local ChangesTitle = ChangesFrame.ChangesTitle
local ChangesCounterFrame = ChangesFrame.ChangesCounterFrame
local ChangesCounterLabel = ChangesCounterFrame.ChangesCounterLabel
local ChangesList = Main.ChangesList
local CurrentRepositoryFrame = Main.CurrentRepositoryFrame

local CommitFrame = Main.CommitFrame
local CommitButton = CommitFrame.CommitButton
local SummaryInput = CommitFrame.SummaryInput
local DescriptionInput = CommitFrame.DescriptionInput

local CurrentRepositoryLabel = CurrentRepositoryFrame.CurrentRepositoryLabel
local SettingsButton = CurrentRepositoryFrame.SettingsButton
local BackToRepositoryListButton = CurrentRepositoryFrame.BackToRepositoryListButton

--// Functions
function clear_ui_children(root_ui: Instance)
	for _, v in ipairs(root_ui:GetChildren()) do
		if not v:IsA("GuiObject") then continue end
		v:Destroy()
	end
end

function FindFirstChildWithNameOfClass(root_instance: Instance, name: string, class: string): Instance?
	for _, child in ipairs(root_instance:GetChildren()) do
		if child.Name == name and child:IsA(class) then return child end
	end
end

-- Will get directory and will make folders to directory specified if path doesn't yet exist
function get_directory(path: string)
	local directories = string.split(path, "/")
	local current_dir = game
	for i, directory in ipairs(directories) do
		if directory == src_root and i == 1 then continue end
		if i == #directories then continue end

		if current_dir == game then
			if directory == "client" then
				current_dir = StarterPlayer.StarterPlayerScripts
				continue
			end
			directory = location_lookups[directory] or directory
			if not table.find(locations_to_index_names, directory) then break end
		end

		local next_dir = current_dir:FindFirstChild(directory)
		if not next_dir then 
			local new_dir = Instance.new("Folder")
			new_dir.Name = directory
			new_dir.Parent = current_dir

			current_dir = new_dir
		else
			current_dir = next_dir
		end
	end
	return current_dir ~= game and current_dir
end

function get_directory_file(path: string)
	local extensions = string.split(path,".")
	local file_extension = extensions[#extensions]
	local sub_extension = #extensions > 2 and extensions[#extensions - 1] or nil

	local directories = string.split(extensions[1], "/")
	local file_name = directories[#directories]

	if not table.find(allowed_file_extensions, file_extension) then return end
	--print("•"..path)

	local directory = get_directory(path)
	if not directory then return end

	local script_class = script_lookup[sub_extension or "module"]
	local full_extension = sub_extension and sub_extension .. "." .. file_extension or file_extension
	return FindFirstChildWithNameOfClass(directory, file_name, script_class), file_name, script_class, directory, file_extension, full_extension
end

function pull_repo(fetched_repo: {}, force_clone: boolean)
	for _, tree_item in ipairs(fetched_repo.tree) do
		if tree_item.type ~= "blob" then continue end

		local path: string = tree_item.path
		local existing_script, file_name, script_class, directory, extension, full_extension = get_directory_file(path)
		if not script_class then continue end

		local remote_file_sha = tree_item.sha

		local script_sha = existing_script and existing_script:GetAttribute("sha")
		if script_sha ~= remote_file_sha or force_clone then
			print(`Updating {file_name}`)
			local success, file = github_interaction.github_request(tree_item.url)
			if not success then continue end

			local decoded_file_content = utils.from_base64(file.content)

			local new_script: LuaSourceContainer = existing_script or Instance.new(script_class)
			new_script.Name = file_name
			new_script.Parent = directory

			new_script:SetAttribute("file_extension", extension ~= "luau" and full_extension or nil)

			ScriptEditorService:UpdateSourceAsync(new_script, function()
				return decoded_file_content
			end)

			new_script:SetAttribute("sha", tree_item.sha)

			local new_cached_tree_item = {}
			new_cached_tree_item.source = decoded_file_content
			new_cached_tree_item.sha = tree_item.sha

			server_cache[path] = new_cached_tree_item

			new_script:GetPropertyChangedSignal("Parent"):Connect(function() -- might remove
				print(file_name, path)
				diff_check(new_script, path)
			end)
		end
	end
	save_cache()
end

function fetch_repo(repo)
	local repo_tree_path = string.gsub(repo.trees_url, "{/sha}", `/{branch}?recursive=1`)
	local success, result = github_interaction.github_request(repo_tree_path, "GET")
	if not result or not result.tree then return end
	return result
end

function open_repository(repo)
	CurrentRepositoryLabel.Text = repo.name

	Start.Visible = false
	Main.Visible = true
	
	plugin:SetSetting(tostring(game.PlaceId) .. "open_repo", HttpService:JSONEncode(repo))

	pull_repo(fetch_repo(repo), true) -- MAKE SURE FALSE
	index_all()
end

function logged_in()
	plugin:SetSetting("access_token", github_interaction.ACCESS_TOKEN)
	AccessTokenInput.Text = ""

	local success, user_repos = github_interaction.github_request(`user/repos`, "GET")
	if not success then return end

	clear_ui_children(RepositoryScrollingFrame)

	for _, repo in ipairs(user_repos) do
		local new_repo_frame = resources.RepositoryFrame:Clone()
		new_repo_frame.NameLabel.Text = repo.full_name

		local last_click = 0

		new_repo_frame.MouseButton1Click:Connect(function()
			if tick()-last_click < 0.4 then
				open_repository(repo)
			end
			last_click = tick()
		end)

		new_repo_frame.MouseEnter:Connect(function()
			new_repo_frame.BackgroundTransparency = 0
		end)

		new_repo_frame.MouseLeave:Connect(function()
			new_repo_frame.BackgroundTransparency = 11
		end)
		new_repo_frame.Parent = RepositoryScrollingFrame
	end
end

function login(): (boolean, string?)
	ErrorMessage.Text = ""
	--If there is an access token, attempt to get the user data as a means to show we are signed in

	local success, result
	if github_interaction.ACCESS_TOKEN ~= "" then
		success, result = github_interaction.github_request("user", "GET")
	elseif github_interaction.ACCESS_TOKEN == "" then
		result = "Empty Token"
	end
	user = success and result

	UsernameLabel.Text = success and result.login or ""
	SignInStatusLabel.Text = success and "Signed in as" or "Not signed in"
	SubtitleLabel.Text = success and "Open a repository" or "Log in with personal access token"
	LogOutButton.Visible = success
	SignInStatusLabel.Size = success and UDim2.new(1, -48,0, 25) or UDim2.new(1, -48,0, 33) --offsets label if user is signed out

	PATSignIn.Visible = not success
	RepositoryList.Visible = success

	if not success then return false, (result or "Auth failed") end

	if result then
		logged_in()
		return true
	end
end

function logout_current_user()
	github_interaction.set_access_token(nil, true)
	login()
end

function get_path(item: Instance): string?
	local item_path = item:GetFullName()
	local parts = string.split(item_path, ".")

	local item_root_name = parts[1]
	local item_root = game:FindFirstChild(item_root_name)
	if not item_root then return end

	if item_root:IsA("StarterPlayer") then
		table.remove(parts,1)
		item_root_name = parts[1]
	end

	parts[1] = service_indexes[item_root_name] or parts[1]

	local file_extension = item:GetAttribute("file_extension") or utils.get_file_extension(item)

	local final_location = src_root .. "/" .. table.concat(parts, "/") .. "." .. file_extension
	return final_location
end

function set_commit_button_enabled(new_state: boolean)
	CommitButton:SetAttribute("enabled", new_state)
	CommitButton.BackgroundTransparency = new_state and 0 or 0.4
end

function update_commit_button()
	local num_changes = utils.num_keys(changes)

	local can_commit = num_changes > 0 and SummaryInput.Text:gsub(" ", "") ~= ""
	CommitButton.Text = `Commit {num_changes} file{num_changes == 1 and "" or "s"} to <b>{branch}</b>`
	set_commit_button_enabled(can_commit)
end

function update_changes_ui()
	clear_ui_children(ChangesList)

	local num_changes = utils.num_keys(changes)
	ChangesCounterLabel.Text = num_changes

	update_commit_button()

	local changes_list = {}
	for change_location, changed_item: ChangeItem in pairs(changes) do
		table.insert(changes_list, change_location)
	end

	table.sort(changes_list, function(a: string, b: string)
		return a:lower() < b:lower()
	end)

	for _, path in ipairs(changes_list) do
		local changed_item = changes[path]
		local changed_script = changed_item.instance
		if not changed_script then continue end

		local change_frame_instance = resources.ChangeFrame:Clone()
		change_frame_instance.ChangeLocationTitle.Text = path
		change_frame_instance.ChangeLocationTitle.MouseButton1Click:Connect(function()
			ScriptEditorService:OpenScriptDocumentAsync(changed_script)
		end)

		local status_icon = STATUS_ICONS[changed_item.status] or STATUS_ICONS.modification

		change_frame_instance.ChangeStatusIcon.Image =  status_icon.image
		change_frame_instance.ChangeStatusIcon.ImageColor3 = status_icon.color

		change_frame_instance.Parent = ChangesList
	end
end

function diff_check(instance: Instance, force_path: string?)
	if not instance:IsA("LuaSourceContainer") and not force_path then return end
	local path = force_path or get_path(instance) 
	local cached_data = server_cache[path] 

	if force_path then
		print(path, instance)
		changes[path] = {
			instance = instance,
			status = "deletion",
		}
		--print(instance.Parent) -- Would remove here but we don't have access to path
	elseif cached_data then
		local did_data_change = cached_data.source ~= instance.Source
		--if did_data_change then print(cached_data.source, instance.Source) end
		changes[path] = did_data_change and {
			instance = instance,
			status = "modification",
		} or nil
	else
		changes[path] = {
			instance = instance,
			status = "addition",
		}
	end
	update_changes_ui()
end

function index(location: Instance, do_index_descendants: boolean)		
	--Query descendants
	local changes_hash = utils.hash_dict(changes)
	if do_index_descendants then
		local descendants = location:GetDescendants()
		for _, descendant in ipairs(descendants) do
			diff_check(descendant)
		end
	else
		diff_check(location)
	end
	--Only update ui there are actual changes
	if utils.hash_dict(changes) ~= changes_hash then
		update_changes_ui()
	end
end

function connect_indexed_service_events(service: Instance)
	service.DescendantAdded:Connect(function(instance)
		diff_check(instance)
	end)
end

function index_all()
	for _, service_name in ipairs(locations_to_index_names) do
		local service_to_index = game:GetService(service_name)
		if not service_to_index then continue end

		index(service_to_index, true)
	end
end

function commit_changes(): boolean
	print(changes)
	set_commit_button_enabled(false)

	local num_changes = utils.num_keys(changes)
	--if num_changes == 0 then return end

	local commit_summary = SummaryInput.Text
	local commit_description = DescriptionInput.Text

	local success, latest_commit = github_interaction.github_request(`{github_interaction.git_path()}/ref/heads/main`, "GET")
	if not success or not latest_commit then return end
	local latest_commit_sha = latest_commit.object.sha

	local success, base_tree = github_interaction.github_request(`{github_interaction.git_path()}/commits/{latest_commit_sha}`, "GET")
	if not success or not base_tree then return end
	local base_tree_sha = base_tree.tree.sha

	-- Write code that loops through changes and creates blobs based on changes
	-- Then push those changes to a new tree, commit the tree, and then push changes. (Update main brench ref to new sha)

	local new_change_blobs = {}
	local new_change_shas = {}

	for change_path: string, changed_item: ChangeItem in pairs(changes) do
		if not changed_item or not change_path or not changed_item.instance then continue end

		local success, new_blob
		if changed_item.status ~= "deletion" then
			success, new_blob = github_interaction.github_request(`{github_interaction.git_path()}/blobs`, "POST", {
				content = changed_item.instance.Source,
				encoding = "utf-8",
			})
			if not success then return end
		end
		local new_blob_sha = new_blob and new_blob.sha or NULL_PROXY
		table.insert(new_change_blobs, {
			path = change_path,
			mode = "100644",
			type = "blob",
			sha = new_blob_sha,
		})
		new_change_shas[change_path] = {
			sha = new_blob_sha,
			instance = changed_item.instance
		}
	end

	-- Create a new tree
	local success, new_tree = github_interaction.github_request(`{github_interaction.git_path()}/trees`, "POST", {
		base_tree = latest_commit_sha,
		tree = new_change_blobs
	})
	if not new_tree then return end
	local new_tree_sha = new_tree.sha

	-- Commit the tree
	local success, new_commit = github_interaction.github_request(`{github_interaction.git_path()}/commits`, "POST", {
		message = SummaryInput.Text .. (DescriptionInput.Text:gsub(" ", "") ~= "" and "\n\n" ..DescriptionInput.Text or ""),
		tree = new_tree_sha,
		parents = {latest_commit_sha},
	})
	if not new_commit then return end
	local new_commit_sha = new_commit.sha

	-- Push (update the branch ref)
	local success = github_interaction.github_request(`{github_interaction.git_path()}/refs/heads/main`, "PATCH", {
		sha = new_commit_sha,
	})
	if not success then return end
	
	-- Cache results
	for path, new_change_item in pairs(new_change_shas) do
		new_change_item.instance:SetAttribute("sha", new_change_item.sha)
		local new_cached_tree_item = {}
		new_cached_tree_item.source = new_change_item.instance.Source
		new_cached_tree_item.sha = new_change_item.sha

		server_cache[path] = new_cached_tree_item
	end
	
	-- Reset changes (hopefully works)
	changes = {}
	
	save_cache()
	index_all()
	update_changes_ui()

	SummaryInput.Text = ""
	DescriptionInput.Text = ""

	return success
end

ScriptEditorService.TextDocumentDidChange:Connect(function(document: ScriptDocument, changesArray: any)
	local document_script_instance = document:GetScript()
	if not document_script_instance then return end

	index(document_script_instance)
end)

local init do	
	github_interaction.init(plugin)

	PATSignIn.Visible = true
	RepositoryList.Visible = false

	index_all()

	SummaryInput:GetPropertyChangedSignal("Text"):Connect(update_commit_button)

	AccessTokenInput:GetPropertyChangedSignal("Text"):Connect(function()
		Hider.Text = string.rep("*", #AccessTokenInput.Text)
		Hider.Visible = #AccessTokenInput.Text ~= 0
	end)

	LoginButton.MouseButton1Click:Connect(function()
		github_interaction.set_access_token(AccessTokenInput.Text)
		local success, error_message = login()
		ErrorMessage.Text = success and "" or error_message
	end)

	LogOutButton.MouseButton1Click:Connect(logout_current_user)
	CommitButton.MouseButton1Click:Connect(function()
		if not CommitButton:GetAttribute("enabled") then return end

		local num_changes = utils.num_keys(changes)

		set_commit_button_enabled(false)
		CommitButton.Text = `Committing {num_changes} file{num_changes == 1 and "" or "s"} to <b>{branch}</b>`

		local was_commit_successful = commit_changes()
		set_commit_button_enabled(true)

		if not was_commit_successful then
			CommitButton.Text = "Commit unsuccessful."
			set_commit_button_enabled(false)
			warn("Commit unsuccessful") 
			return 
		end
	end)

	BackToRepositoryListButton.MouseButton1Click:Connect(function()
		Start.Visible = true
		Main.Visible = false
		changes = {}
		plugin:SetSetting("open_repo")
		plugin:SetSetting(tostring(game.PlaceId) .. "open_repo", HttpService:JSONEncode(nil))
	end)

	local success, error_message = login()
	ErrorMessage.Text = success and "" or (github_interaction.ACCESS_TOKEN ~= "" and "Invalid saved credentials" or error_message)

	Main.Visible, Start.Visible = false, true
	update_changes_ui()


	-- Open previously open repo
	open_repo = plugin:GetSetting(tostring(game.PlaceId) .. "open_repo")
	if success and open_repo then
		local success, decoded_repo = pcall(HttpService.JSONDecode, HttpService, open_repo)
		open_repository(decoded_repo)

		if not success then warn(decoded_repo) end
	end

	for _, service_name in ipairs(locations_to_index_names) do
		local service_to_index = game:GetService(service_name)
		if not service_to_index then continue end
		connect_indexed_service_events(service_to_index)
	end

	gui.Parent = widget
end