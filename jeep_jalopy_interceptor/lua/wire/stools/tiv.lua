if not WireToolSetup then return end

WireToolSetup.setCategory("Vehicle Control")
WireToolSetup.open("tiv", "TIV Controller", "gmod_wire_tiv_controller", nil, "TIV Controllers")

if CLIENT then
    language.Add("Tool.wire_tiv.name", "TIV Controller Tool (Wire)")
    language.Add("Tool.wire_tiv.desc", "Spawn or link a Wire TIV Controller to a Tornado Intercept Vehicle.")
    WireToolSetup.setToolMenuIcon("icon16/weather_clouds.png")
end

WireToolSetup.BaseLang()
WireToolSetup.SetupMax(20)

TOOL.ClientConVar["model"] = "models/jaanus/wiretool/wiretool_siren.mdl"

WireToolSetup.SetupLinking(true, "vehicle")

function TOOL.BuildCPanel(panel)
    if WireDermaExts and WireDermaExts.ModelSelect then
        WireDermaExts.ModelSelect(panel, "wire_tiv_model", list.Get("Wire_Misc_Tools_Models"), 1)
    end
end
