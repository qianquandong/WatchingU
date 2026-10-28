#!/usr/bin/env python3
"""Generate the four-target Xcode project deterministically on Windows or macOS."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--feature-set", choices=["full", "core-testing"], default="full",
                    help="Explicit release capabilities; full remains the default.")
FEATURE_SET = parser.parse_args().feature_set
CORE_TESTING = FEATURE_SET == "core-testing"
objects = {}


def key(name):
    return hashlib.sha1(name.encode("utf-8")).hexdigest()[:24].upper()


def add(tag, isa, **values):
    identity = key(tag)
    objects[identity] = dict(isa=isa, **values)
    return identity


def encode(value, depth=0):
    tab = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(tab + "\t" + json.dumps(str(k)) + " = " + encode(v, depth + 1) + ";\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(" + ", ".join(encode(item, depth) for item in value) + ("," if value else "") + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


base_info = dict(CFBundleDevelopmentRegion="en", CFBundleExecutable="$(EXECUTABLE_NAME)",
    CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleInfoDictionaryVersion="6.0",
    CFBundleName="$(PRODUCT_NAME)", CFBundleDisplayName="DayTape", CFBundlePackageType="APPL",
    CFBundleShortVersionString="$(MARKETING_VERSION)", CFBundleVersion="$(CURRENT_PROJECT_VERSION)",
    ITSAppUsesNonExemptEncryption=False, DayTapeAppGroup="" if CORE_TESTING else "$(DAYTAPE_APP_GROUP)",
    DayTapeFeatureSet=FEATURE_SET)
phone_info = dict(base_info, UILaunchScreen={}, UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait"],
    UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes": False},
    GIDClientID="$(GOOGLE_CLIENT_ID)", CFBundleURLTypes=[
        {"CFBundleURLSchemes": ["$(GOOGLE_REVERSED_CLIENT_ID)"]}, {"CFBundleURLSchemes": ["daytape"]}],
    NSHealthShareUsageDescription="在你开启健康关联后，读取同时间范围的心率、HRV、活动与睡眠样本。数据保存在本机，不用于医疗诊断。",
    NSSpeechRecognitionUsageDescription="在你开启转写后，将本机录音转换成文字。",
    NSMicrophoneUsageDescription="在你主动录音或登记本人声纹时使用麦克风。",
    NSLocalNetworkUsageDescription="在你配对电脑后，通过本地网络传输加密的录音与笔记。",
    NSBonjourServices=["_daytape._tcp"], UIBackgroundModes=["processing", "fetch"],
    BGTaskSchedulerPermittedIdentifiers=["$(PRODUCT_BUNDLE_IDENTIFIER).nightarchive"])
watch_info = dict(base_info, WKApplication=True, WKCompanionAppBundleIdentifier="$(DAYTAPE_BUNDLE_PREFIX)",
    WKRunsIndependentlyOfCompanionApp=True, UIBackgroundModes=["audio"],
    CFBundleURLTypes=[{"CFBundleURLSchemes": ["daytape"]}],
    NSMicrophoneUsageDescription="在你点击开始后录制声音，保存到手表并同步到配对 iPhone。",
    NSLocationWhenInUseUsageDescription="仅在你开启大致位置记录后，低频采样录音时所在的大致区域。")
widget_info = dict(base_info, CFBundlePackageType="XPC!", NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"})
if CORE_TESTING:
    phone_info.pop("NSHealthShareUsageDescription", None)
write_plist(ROOT / "Phone/Info.plist", phone_info)
write_plist(ROOT / "Watch/Info.plist", watch_info)
write_plist(ROOT / "Widgets/PhoneInfo.plist", widget_info)
write_plist(ROOT / "Widgets/WatchInfo.plist", widget_info)
group_entitlements = {"com.apple.security.application-groups": ["$(DAYTAPE_APP_GROUP)"]}
write_plist(ROOT / "Watch/DayTape.entitlements", group_entitlements)
write_plist(ROOT / "Widgets/DayTape.entitlements", group_entitlements)
write_plist(ROOT / "Phone/NoHealth.entitlements", group_entitlements)
write_plist(ROOT / "Phone/DayTape.entitlements", dict(group_entitlements,
    **{"com.apple.developer.healthkit": True, "com.apple.developer.healthkit.background-delivery": True}))
write_plist(ROOT / "Shared/CoreTesting.entitlements", {})

files, groups = {}, {}
kinds = {".swift": "sourcecode.swift", ".c": "sourcecode.c.c", ".h": "sourcecode.c.h",
    ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements", ".xcprivacy": "text.xml",
    ".xcassets": "folder.assetcatalog", ".py": "text.script.python", ".sh": "text.script.sh"}
for folder in ["Shared", "Watch", "Phone", "Widgets", "Licenses", "Tests", "Scripts"]:
    children = []
    for path in sorted((ROOT / folder).rglob("*"), key=lambda value: value.relative_to(ROOT).as_posix()):
        if any(part.endswith(".xcassets") or part == "__pycache__" for part in path.relative_to(ROOT / folder).parts[:-1]):
            continue
        if (not path.is_file() and path.suffix != ".xcassets") or path.suffix == ".pyc":
            continue
        relative = path.relative_to(ROOT).as_posix()
        reference = add("file:" + relative, "PBXFileReference", lastKnownFileType=kinds.get(path.suffix, "text"),
                        path=path.relative_to(ROOT / folder).as_posix(), sourceTree="<group>")
        files[relative] = reference
        children.append(reference)
    groups[folder] = add("group:" + folder, "PBXGroup", children=children, path=folder, sourceTree="<group>")
config = add("file:Local.xcconfig", "PBXFileReference", lastKnownFileType="text.xcconfig", path="Local.xcconfig", sourceTree="<group>")
target_specs = [
    ("DayTapeWidgets", "iphoneos", ".widgets", "Widgets/PhoneInfo.plist", "Widgets/DayTape.entitlements", True),
    ("DayTapeWatchWidgets", "watchos", ".watchkitapp.widgets", "Widgets/WatchInfo.plist", "Widgets/DayTape.entitlements", True),
    ("DayTapeWatch", "watchos", ".watchkitapp", "Watch/Info.plist", "Watch/DayTape.entitlements", False),
    ("DayTape", "iphoneos", "", "Phone/Info.plist", "$(DAYTAPE_ENTITLEMENTS)", False),
]
if CORE_TESTING:
    target_specs = [
        ("DayTapeWatch", "watchos", ".watchkitapp", "Watch/Info.plist", "Shared/CoreTesting.entitlements", False),
        ("DayTape", "iphoneos", "", "Phone/Info.plist", "Shared/CoreTesting.entitlements", False),
    ]
products = {}
for name, _, _, _, _, extension in target_specs:
    products[name] = add("product:" + name, "PBXFileReference", explicitFileType="wrapper.app-extension" if extension else "wrapper.application",
                         includeInIndex=0, path=name + (".appex" if extension else ".app"), sourceTree="BUILT_PRODUCTS_DIR")
product_group = add("products", "PBXGroup", children=list(products.values()), name="Products", sourceTree="<group>")
main_group = add("main", "PBXGroup", children=[*groups.values(), config, product_group], sourceTree="<group>")


def configuration_list(name, settings):
    entries = []
    for mode in ["Debug", "Release"]:
        values = dict(settings, SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O",
                      DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym")
        if mode == "Debug":
            values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) DEBUG " + settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")
        entries.append(add(name + mode, "XCBuildConfiguration", baseConfigurationReference=config, buildSettings=values, name=mode))
    return add(name + "configurations", "XCConfigurationList", buildConfigurations=entries, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


project_id = key("project")


def dependency(parent, child):
    proxy = add(parent + ":proxy:" + child, "PBXContainerItemProxy", containerPortal=project_id,
                proxyType=1, remoteGlobalIDString=key("target:" + child), remoteInfo=child)
    return add(parent + ":dependency:" + child, "PBXTargetDependency", target=key("target:" + child), targetProxy=proxy)


def embed(parent, child, watch=False):
    item = add(parent + ":embed:" + child, "PBXBuildFile", fileRef=products[child], settings={"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]})
    return add(parent + ":embed-phase:" + child, "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
               dstPath="$(CONTENTS_FOLDER_PATH)/Watch" if watch else "", dstSubfolderSpec=16 if watch else 13,
               files=[item], name="Embed " + child, runOnlyForDeploymentPostprocessing=0)


google_package = add("google-package", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/google/GoogleSignIn-iOS",
                     requirement={"kind": "exactVersion", "version": "10.0.0"})
fluid_package = add("fluid-package", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/FluidInference/FluidAudio",
                    requirement={"kind": "exactVersion", "version": "0.12.4"})
phone_products, phone_frameworks = [], []
for label, package, product in [("google", google_package, "GoogleSignIn"), ("google-swift", google_package, "GoogleSignInSwift"),
                                ("fluid", fluid_package, "FluidAudio")]:
    reference = add(label + "-product", "XCSwiftPackageProductDependency", package=package, productName=product)
    phone_products.append(reference)
    phone_frameworks.append(add(label + "-build", "PBXBuildFile", productRef=reference))

targets = []
shared = sorted(path for path in files if path.startswith("Shared/") and path.endswith(".swift")) + ["Shared/RecorderRules.c"]
for name, sdk, suffix, info, entitlements, extension in target_specs:
    folder = "Watch" if sdk == "watchos" else "Phone"
    sources = ["Widgets/DayTapeWidgets.swift", "Shared/WidgetSnapshot.swift"] if extension else shared + sorted(
        path for path in files if path.startswith(folder + "/") and path.endswith(".swift"))
    build_files = [add(name + ":source:" + path, "PBXBuildFile", fileRef=files[path]) for path in sources]
    phases = [add(name + ":sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=build_files, runOnlyForDeploymentPostprocessing=0),
              add(name + ":frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                  files=phone_frameworks if name == "DayTape" else [], runOnlyForDeploymentPostprocessing=0)]
    privacy = add(name + ":privacy", "PBXBuildFile", fileRef=files["Shared/PrivacyInfo.xcprivacy"])
    resources = [privacy]
    if not extension:
        resources.append(add(name + ":assets", "PBXBuildFile", fileRef=files[folder + "/Assets.xcassets"]))
    if name == "DayTape":
        resources += [add(name + ":license:" + path, "PBXBuildFile", fileRef=files[path])
                      for path in sorted(files) if path.startswith("Licenses/") and path.endswith(".txt")]
    phases.append(add(name + ":resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0))
    children = [] if extension else (["DayTapeWatchWidgets"] if sdk == "watchos" else ["DayTapeWidgets", "DayTapeWatch"])
    if CORE_TESTING:
        children = [] if sdk == "watchos" else ["DayTapeWatch"]
    phases += [embed(name, child, watch=child == "DayTapeWatch") for child in children]
    settings = dict(SDKROOT=sdk, CODE_SIGN_STYLE="Automatic", PRODUCT_NAME="$(TARGET_NAME)",
        PRODUCT_BUNDLE_IDENTIFIER="$(DAYTAPE_BUNDLE_PREFIX)" + suffix, INFOPLIST_FILE=info,
        GENERATE_INFOPLIST_FILE="NO", CODE_SIGN_ENTITLEMENTS=entitlements, SWIFT_VERSION="5.0",
        SWIFT_STRICT_CONCURRENCY="minimal", CLANG_ENABLE_MODULES="YES", GCC_C_LANGUAGE_STANDARD="c11",
        CURRENT_PROJECT_VERSION="1", MARKETING_VERSION="0.5.0", ENABLE_USER_SCRIPT_SANDBOXING="YES")
    # Target-specific profile selectors allow all four profiles to coexist in one signing xcconfig.
    profile_variable = {"DayTape": "DAYTAPE_PROFILE_IOS", "DayTapeWatch": "DAYTAPE_PROFILE_WATCH",
                        "DayTapeWidgets": "DAYTAPE_PROFILE_IOS_WIDGET", "DayTapeWatchWidgets": "DAYTAPE_PROFILE_WATCH_WIDGET"}[name]
    settings["PROVISIONING_PROFILE_SPECIFIER"] = "$(" + profile_variable + ")"
    if sdk == "watchos":
        settings.update(WATCHOS_DEPLOYMENT_TARGET="10.0", TARGETED_DEVICE_FAMILY="4", SUPPORTED_PLATFORMS="watchos watchsimulator", SKIP_INSTALL="YES")
    else:
        settings.update(IPHONEOS_DEPLOYMENT_TARGET="17.0", TARGETED_DEVICE_FAMILY="1", SUPPORTED_PLATFORMS="iphoneos iphonesimulator",
                        SUPPORTS_MACCATALYST="NO", SKIP_INSTALL="YES" if extension else "NO")
    if extension:
        settings.update(APPLICATION_EXTENSION_API_ONLY="YES", LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks")
    else:
        settings.update(ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", SWIFT_OBJC_BRIDGING_HEADER="$(SRCROOT)/Shared/RecorderRules.h")
    if name == "DayTape":
        settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "" if CORE_TESTING else "$(DAYTAPE_HEALTHKIT_FLAG)"
    target = add("target:" + name, "PBXNativeTarget", buildConfigurationList=configuration_list(name, settings), buildPhases=phases,
                 buildRules=[], dependencies=[dependency(name, child) for child in children], name=name, productName=name,
                 packageProductDependencies=phone_products if name == "DayTape" else [], productReference=products[name],
                 productType="com.apple.product-type.app-extension" if extension else "com.apple.product-type.application")
    targets.append(target)

attributes = {}
for name, *_ in target_specs:
    capabilities = {} if CORE_TESTING else {"com.apple.ApplicationGroups.iOS": {"enabled": 1}}
    if name == "DayTape" and not CORE_TESTING:
        capabilities["com.apple.HealthKit"] = {"enabled": 1}
    attributes[key("target:" + name)] = dict(CreatedOnToolsVersion="16.0", ProvisioningStyle="Automatic", SystemCapabilities=capabilities)
add("project", "PBXProject", attributes=dict(BuildIndependentTargetsInParallel="YES", LastUpgradeCheck="1600", TargetAttributes=attributes),
    buildConfigurationList=configuration_list("project", dict(ALWAYS_SEARCH_USER_PATHS="NO", CLANG_WARN_DOCUMENTATION_COMMENTS="YES",
        GCC_WARN_64_TO_32_BIT_CONVERSION="YES", GCC_WARN_UNUSED_VARIABLE="YES")), compatibilityVersion="Xcode 14.0", developmentRegion="en",
    hasScannedForEncodings=0, knownRegions=["en", "zh-Hans", "Base"], mainGroup=main_group, productRefGroup=product_group,
    projectDirPath="", projectRoot="", packageReferences=[google_package, fluid_package], targets=targets)
write_text(ROOT / "DayTape.xcodeproj/project.pbxproj", "// !$*UTF8*$!\n" + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project_id)) + "\n")

for name in ["DayTape", "DayTapeWatch"]:
    scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
    def reference(parent):
        ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=key("target:" + name),
                      BuildableName=name + ".app", BlueprintName=name, ReferencedContainer="container:DayTape.xcodeproj")
    reference(entry)
    ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                  selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
    launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
        selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO",
        ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", allowLocationSimulation="YES")
    reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"))
    ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    ET.indent(scheme)
    output = ROOT / "DayTape.xcodeproj/xcshareddata/xcschemes" / (name + ".xcscheme")
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(scheme).write(output, encoding="UTF-8", xml_declaration=True)

print("Generated " + FEATURE_SET + ": " + str(len(target_specs)) + " targets with explicit capability and embedding settings.")
