#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib
import json
import plistlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def key(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(tag, isa, **values):
    identity = key(tag); objects[identity] = dict(isa=isa, **values); return identity
def encode(value, depth=0):
    tab = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(tab + "\t" + json.dumps(str(k)) + " = " + encode(v, depth+1) + ";\n" for k,v in value.items()) + tab + "}"
    if isinstance(value, list): return "(" + ", ".join(encode(x, depth) for x in value) + ("," if value else "") + ")"
    if isinstance(value, int): return str(value)
    return json.dumps(str(value), ensure_ascii=False)

files = {}
groups = {}
for folder in ["Shared", "Watch", "Phone", "Tests", "Scripts"]:
    children = []
    for path in sorted((ROOT/folder).iterdir()):
        if not path.is_file() and path.suffix != ".xcassets": continue
        suffix = path.suffix
        kind = {".swift":"sourcecode.swift", ".c":"sourcecode.c.c", ".h":"sourcecode.c.h", ".plist":"text.plist.xml", ".xcprivacy":"text.xml", ".xcassets":"folder.assetcatalog", ".py":"text.script.python", ".sh":"text.script.sh"}.get(suffix,"text")
        ref = add("file:"+str(path.relative_to(ROOT)), "PBXFileReference", lastKnownFileType=kind, path=path.name, sourceTree="<group>")
        files[str(path.relative_to(ROOT))] = ref; children.append(ref)
    groups[folder] = add("group:"+folder,"PBXGroup",children=children,path=folder,sourceTree="<group>")
config = add("file:Local.xcconfig","PBXFileReference",lastKnownFileType="text.xcconfig",path="Local.xcconfig",sourceTree="<group>")
products = {}
for name in ["DayTape", "DayTapeWatch"]:
    products[name]=add("product:"+name,"PBXFileReference",explicitFileType="wrapper.application",includeInIndex=0,path=name+".app",sourceTree="BUILT_PRODUCTS_DIR")
product_group=add("products","PBXGroup",children=list(products.values()),name="Products",sourceTree="<group>")
main_group=add("main","PBXGroup",children=[*groups.values(),config,product_group],sourceTree="<group>")

def configuration_list(name, settings):
    entries=[]
    for mode in ["Debug","Release"]:
        values=dict(settings)
        values.update({"SWIFT_OPTIMIZATION_LEVEL":"-Onone" if mode=="Debug" else "-O", "DEBUG_INFORMATION_FORMAT":"dwarf" if mode=="Debug" else "dwarf-with-dsym"})
        if mode=="Debug": values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]="$(inherited) DEBUG " + settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")
        entries.append(add(name+mode,"XCBuildConfiguration",baseConfigurationReference=config,buildSettings=values,name=mode))
    return add(name+"configurations","XCConfigurationList",buildConfigurations=entries,defaultConfigurationIsVisible=0,defaultConfigurationName="Release")

project_id=key("project")
watch_id=key("target:DayTapeWatch")
proxy=add("watch-proxy","PBXContainerItemProxy",containerPortal=project_id,proxyType=1,remoteGlobalIDString=watch_id,remoteInfo="DayTapeWatch")
dependency=add("watch-dependency","PBXTargetDependency",target=watch_id,targetProxy=proxy)
embed_file=add("embed-watch-file","PBXBuildFile",fileRef=products["DayTapeWatch"],settings={"ATTRIBUTES":["RemoveHeadersOnCopy"]})
embed=add("embed-watch-phase","PBXCopyFilesBuildPhase",buildActionMask=2147483647,dstPath="$(CONTENTS_FOLDER_PATH)/Watch",dstSubfolderSpec=16,files=[embed_file],name="Embed Watch Content",runOnlyForDeploymentPostprocessing=0)
google_package=add("google-package","XCRemoteSwiftPackageReference",repositoryURL="https://github.com/google/GoogleSignIn-iOS",requirement={"kind":"exactVersion","version":"10.0.0"})
google_product=add("google-product","XCSwiftPackageProductDependency",package=google_package,productName="GoogleSignIn")
google_build=add("google-build","PBXBuildFile",productRef=google_product)
google_swift=add("google-swift-product","XCSwiftPackageProductDependency",package=google_package,productName="GoogleSignInSwift")
google_swift_build=add("google-swift-build","PBXBuildFile",productRef=google_swift)
targets=[]
shared=["Shared/BackupClock.swift","Shared/DailySchedule.swift","Shared/DailyNotifications.swift","Shared/DayArchive.swift","Shared/ArchiveModels.swift","Shared/Models.swift","Shared/ClipStore.swift","Shared/Connectivity.swift","Shared/RecorderRules.c"]
for name,folder,sdk in [("DayTapeWatch","Watch","watchos"),("DayTape","Phone","iphoneos")]:
    sources=shared+[p for p in files if p.startswith(folder+"/") and p.endswith(".swift")]
    build_files=[add(name+":source:"+p,"PBXBuildFile",fileRef=files[p]) for p in sources]
    source_phase=add(name+":sources","PBXSourcesBuildPhase",buildActionMask=2147483647,files=build_files,runOnlyForDeploymentPostprocessing=0)
    frameworks=add(name+":frameworks","PBXFrameworksBuildPhase",buildActionMask=2147483647,files=[google_build,google_swift_build] if sdk=="iphoneos" else [],runOnlyForDeploymentPostprocessing=0)
    privacy=add(name+":privacy","PBXBuildFile",fileRef=files["Shared/PrivacyInfo.xcprivacy"])
    assets=add(name+":assets","PBXBuildFile",fileRef=files[folder+"/Assets.xcassets"])
    resources=add(name+":resources","PBXResourcesBuildPhase",buildActionMask=2147483647,files=[privacy,assets],runOnlyForDeploymentPostprocessing=0)
    settings={"SDKROOT":sdk,"CODE_SIGN_STYLE":"Automatic","PRODUCT_NAME":"$(TARGET_NAME)",
              "PRODUCT_BUNDLE_IDENTIFIER":"$(DAYTAPE_BUNDLE_PREFIX)"+(".watchkitapp" if sdk=="watchos" else ""),
              "INFOPLIST_FILE":folder+"/Info.plist","GENERATE_INFOPLIST_FILE":"NO",
              "ASSETCATALOG_COMPILER_APPICON_NAME":"AppIcon",
              "SWIFT_OBJC_BRIDGING_HEADER":"$(SRCROOT)/Shared/RecorderRules.h",
              "SWIFT_VERSION":"5.0","SWIFT_STRICT_CONCURRENCY":"minimal",
              "CLANG_ENABLE_MODULES":"YES","GCC_C_LANGUAGE_STANDARD":"c11",
              "CURRENT_PROJECT_VERSION":"1","MARKETING_VERSION":"0.4.1","ENABLE_USER_SCRIPT_SANDBOXING":"YES"}
    if sdk=="watchos":
        settings.update(WATCHOS_DEPLOYMENT_TARGET="10.0",TARGETED_DEVICE_FAMILY="4",SUPPORTED_PLATFORMS="watchos watchsimulator",SKIP_INSTALL="YES")
    else:
        settings.update(CODE_SIGN_ENTITLEMENTS="$(DAYTAPE_ENTITLEMENTS)",SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(DAYTAPE_HEALTHKIT_FLAG)",IPHONEOS_DEPLOYMENT_TARGET="17.0",TARGETED_DEVICE_FAMILY="1",SUPPORTED_PLATFORMS="iphoneos iphonesimulator",SUPPORTS_MACCATALYST="NO",SKIP_INSTALL="NO")
    config_list=configuration_list(name,settings)
    phases=[source_phase,frameworks,resources]+([embed] if sdk=="iphoneos" else [])
    target=add("target:"+name,"PBXNativeTarget",buildConfigurationList=config_list,buildPhases=phases,buildRules=[],dependencies=[dependency] if sdk=="iphoneos" else [],name=name,productName=name,packageProductDependencies=[google_product,google_swift] if sdk=="iphoneos" else [],productReference=products[name],productType="com.apple.product-type.application")
    targets.append(target)
project_configs=configuration_list("project",{"ALWAYS_SEARCH_USER_PATHS":"NO","CLANG_WARN_DOCUMENTATION_COMMENTS":"YES","GCC_WARN_64_TO_32_BIT_CONVERSION":"YES","GCC_WARN_UNUSED_VARIABLE":"YES"})
add("project","PBXProject",attributes={"BuildIndependentTargetsInParallel":"YES","LastUpgradeCheck":"1600","TargetAttributes":{t:{"CreatedOnToolsVersion":"16.0","ProvisioningStyle":"Automatic"} for t in targets}},buildConfigurationList=project_configs,compatibilityVersion="Xcode 14.0",developmentRegion="en",hasScannedForEncodings=0,knownRegions=["en","zh-Hans","Base"],mainGroup=main_group,productRefGroup=product_group,projectDirPath="",projectRoot="",packageReferences=[google_package],targets=targets)
project_dir=ROOT/"DayTape.xcodeproj"; project_dir.mkdir(exist_ok=True)
(project_dir/"project.pbxproj").write_text("// !$*UTF8*$!\n"+encode({"archiveVersion":1,"classes":{},"objectVersion":56,"objects":objects,"rootObject":project_id})+"\n")

base={"CFBundleDevelopmentRegion":"en","CFBundleExecutable":"$(EXECUTABLE_NAME)","CFBundleIdentifier":"$(PRODUCT_BUNDLE_IDENTIFIER)","CFBundleInfoDictionaryVersion":"6.0","CFBundleName":"$(PRODUCT_NAME)","CFBundleDisplayName":"DayTape","CFBundlePackageType":"APPL","CFBundleShortVersionString":"$(MARKETING_VERSION)","CFBundleVersion":"$(CURRENT_PROJECT_VERSION)","ITSAppUsesNonExemptEncryption":False}
phone=dict(base,UILaunchScreen={},UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait"],UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes":False})
phone.update(GIDClientID="$(GOOGLE_CLIENT_ID)",CFBundleURLTypes=[{"CFBundleURLSchemes":["$(GOOGLE_REVERSED_CLIENT_ID)"]}],NSHealthShareUsageDescription="读取睡眠记录，在检测到睡眠片段后自动归档之前的录音；睡眠数据不上传。",UIBackgroundModes=["processing","fetch"],BGTaskSchedulerPermittedIdentifiers=["$(PRODUCT_BUNDLE_IDENTIFIER).nightarchive"])
watch=dict(base,WKApplication=True,WKCompanionAppBundleIdentifier="$(DAYTAPE_BUNDLE_PREFIX)",WKRunsIndependentlyOfCompanionApp=True,UIBackgroundModes=["audio"],NSMicrophoneUsageDescription="在你点击开始后录制声音，保存到你的手表并传到配对 iPhone。")
for folder,info in [("Phone",phone),("Watch",watch)]:
    with (ROOT/folder/"Info.plist").open("wb") as f:plistlib.dump(info,f,sort_keys=False)

for name in ["DayTape","DayTapeWatch"]:
    scheme=ET.Element("Scheme",LastUpgradeVersion="1600",version="1.3")
    build=ET.SubElement(scheme,"BuildAction",parallelizeBuildables="YES",buildImplicitDependencies="YES")
    entries=ET.SubElement(build,"BuildActionEntries")
    entry=ET.SubElement(entries,"BuildActionEntry",buildForTesting="YES",buildForRunning="YES",buildForProfiling="YES",buildForArchiving="YES",buildForAnalyzing="YES")
    def reference(parent):
        ET.SubElement(parent,"BuildableReference",BuildableIdentifier="primary",BlueprintIdentifier=key("target:"+name),BuildableName=name+".app",BlueprintName=name,ReferencedContainer="container:DayTape.xcodeproj")
    reference(entry)
    ET.SubElement(scheme,"TestAction",buildConfiguration="Debug",selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",shouldUseLaunchSchemeArgsEnv="YES")
    launch=ET.SubElement(scheme,"LaunchAction",buildConfiguration="Debug",selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",launchStyle="0",useCustomWorkingDirectory="NO",ignoresPersistentStateOnLaunch="NO",debugDocumentVersioning="YES",allowLocationSimulation="YES")
    reference(ET.SubElement(launch,"BuildableProductRunnable",runnableDebuggingMode="0"))
    ET.SubElement(scheme,"ProfileAction",buildConfiguration="Release",shouldUseLaunchSchemeArgsEnv="YES",savedToolIdentifier="",useCustomWorkingDirectory="NO",debugDocumentVersioning="YES")
    ET.SubElement(scheme,"AnalyzeAction",buildConfiguration="Debug")
    ET.SubElement(scheme,"ArchiveAction",buildConfiguration="Release",revealArchiveInOrganizer="YES")
    output=project_dir/"xcshareddata"/"xcschemes"/(name+".xcscheme"); output.parent.mkdir(parents=True,exist_ok=True)
    ET.indent(scheme)
    ET.ElementTree(scheme).write(output,encoding="UTF-8",xml_declaration=True)
print("Generated DayTape.xcodeproj, iPhone and Watch schemes, and Info.plists.")
