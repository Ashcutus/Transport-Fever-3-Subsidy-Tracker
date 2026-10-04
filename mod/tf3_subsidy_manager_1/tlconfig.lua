local installDir = os.getenv("TF3_INSTALL_DIR")

if not installDir then
	error("Set TF3_INSTALL_DIR to the Transport Fever 3 installation directory")
end

installDir = installDir:gsub("/$", "") .. "/"

return {
	include_dir = {
		installDir .. "api/tealdef",
		installDir .. "base/tealdef",
	},
	global_env_def = "all_def",
}