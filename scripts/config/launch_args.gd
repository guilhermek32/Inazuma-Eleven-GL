class_name LaunchArgs
extends RefCounted

## Launch options, read the same way on every platform:
##   desktop   godot-4 --path . -- --name=value --flag
##   web       https://<host>/?name=value&flag
## value() returns "" when the option is absent; flag() is true when the option
## is present with any value other than "0"/"false". Values are read once per
## call (cheap: these are only consulted at start-up or on a menu action).

static func value(option: String) -> String:
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("new URLSearchParams(window.location.search).get(%s) || ''" % JSON.stringify(option), true))
	var prefix := "--%s=" % option
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""

static func flag(option: String) -> bool:
	if OS.has_feature("web"):
		var present := bool(JavaScriptBridge.eval("new URLSearchParams(window.location.search).has(%s)" % JSON.stringify(option), true))
		return present and not (value(option) in ["0", "false"])
	if OS.get_cmdline_user_args().has("--%s" % option):
		return true
	var v := value(option)
	return v != "" and not (v in ["0", "false"])
