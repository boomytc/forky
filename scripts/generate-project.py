#!/usr/bin/env python3
"""Generate Forky's dependency-free native Xcode project. Stable identifiers; no external generators."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def obj(object_name, isa, **fields):
    key = ident(object_name)
    if key in objects:
        raise ValueError(f"Duplicate project object: {object_name}")
    objects[key] = dict(isa=isa, **fields)
    return key

class Ref(str):
    pass

def ref(name):
    return Ref(ident(name))

def encode(value, level=0):
    if isinstance(value, Ref):
        return str(value)
    if isinstance(value, dict):
        indent = "\t" * (level + 1)
        return "{\n" + "".join(indent + str(k) + " = " + encode(v, level+1) + ";\n" for k,v in value.items()) + "\t"*level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(encode(v, level+1) for v in value) + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)

for name, path in [("appSources", "Sources/Forky"), ("coreTestsSources", "Tests/ForkyCoreTests"), ("uiTestsSources", "Tests/ForkyUITests")]:
    obj(name, "PBXFileSystemSynchronizedRootGroup", path=path, sourceTree="<group>")
obj("package", "XCLocalSwiftPackageReference", relativePath=".")
for name, path, type_ in [("appProduct", "Forky.app", "wrapper.application"),
                         ("coreTestsProduct", "ForkyCoreTests.xctest", "wrapper.cfbundle"),
                         ("uiTestsProduct", "ForkyUITests.xctest", "wrapper.cfbundle")]:
    obj(name, "PBXFileReference", explicitFileType=type_, includeInIndex=0, path=path, sourceTree="BUILT_PRODUCTS_DIR")
for name, path in [("readme", "README.md"), ("packageManifest", "Package.swift")]:
    obj(name, "PBXFileReference", lastKnownFileType="text", path=path, sourceTree="<group>")
obj("products", "PBXGroup", children=[ref("appProduct"), ref("coreTestsProduct"), ref("uiTestsProduct")], name="Products", sourceTree="<group>")
obj("mainGroup", "PBXGroup", children=[ref("appSources"), ref("coreTestsSources"), ref("uiTestsSources"), ref("packageManifest"), ref("readme"), ref("products")], sourceTree="<group>")
obj("proxy", "PBXContainerItemProxy", containerPortal=ref("project"), proxyType=1, remoteGlobalIDString=ref("app"), remoteInfo="Forky")
obj("appDependency", "PBXTargetDependency", target=ref("app"), targetProxy=ref("proxy"))

common = dict(MACOSX_DEPLOYMENT_TARGET="14.0", SDKROOT="macosx", SWIFT_VERSION="6.0",
              SWIFT_STRICT_CONCURRENCY="complete", CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES")
for mode in ["Debug", "Release"]:
    settings = dict(common)
    settings.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode=="Debug" else "-O",
                    DEBUG_INFORMATION_FORMAT="dwarf" if mode=="Debug" else "dwarf-with-dsym")
    if mode == "Debug":
        settings.update(ENABLE_TESTABILITY="YES", ONLY_ACTIVE_ARCH="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG $(inherited)")
    obj("project"+mode, "XCBuildConfiguration", buildSettings=settings, name=mode)
obj("projectConfig", "XCConfigurationList", buildConfigurations=[ref("projectDebug"), ref("projectRelease")], defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

for key, name, product, group, kind in [
    ("app", "Forky", "appProduct", "appSources", "com.apple.product-type.application"),
    ("coreTests", "ForkyCoreTests", "coreTestsProduct", "coreTestsSources", "com.apple.product-type.bundle.unit-test"),
    ("uiTests", "ForkyUITests", "uiTestsProduct", "uiTestsSources", "com.apple.product-type.bundle.ui-testing"),
]:
    linked = []
    package_deps = []
    if key != "uiTests":
        obj(key+"Core", "XCSwiftPackageProductDependency", package=ref("package"), productName="ForkyCore")
        obj(key+"LinkCore", "PBXBuildFile", productRef=ref(key+"Core"))
        linked.append(ref(key+"LinkCore"))
        package_deps.append(ref(key+"Core"))
    obj(key+"SourcesPhase", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    obj(key+"Frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=linked, runOnlyForDeploymentPostprocessing=0)
    obj(key+"Resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    for mode in ["Debug", "Release"]:
        settings = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="dev.forky."+name,
                        GENERATE_INFOPLIST_FILE="YES", CODE_SIGN_STYLE="Automatic",
                        SWIFT_VERSION="6.0", ENABLE_APP_SANDBOX="NO",
                        LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"])
        if key == "app":
            settings.update(INFOPLIST_KEY_LSApplicationCategoryType="public.app-category.developer-tools",
                            INFOPLIST_KEY_CFBundleDisplayName="Forky",
                            INFOPLIST_KEY_NSHumanReadableCopyright="Forky contributors",
                            ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon",
                            ENABLE_HARDENED_RUNTIME="YES", MARKETING_VERSION="0.1.0", CURRENT_PROJECT_VERSION="1")
        elif key == "uiTests":
            settings.update(TEST_TARGET_NAME="Forky")
        obj(key+mode, "XCBuildConfiguration", buildSettings=settings, name=mode)
    obj(key+"Config", "XCConfigurationList", buildConfigurations=[ref(key+"Debug"), ref(key+"Release")],
        defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    obj(key, "PBXNativeTarget", buildConfigurationList=ref(key+"Config"),
        buildPhases=[ref(key+"SourcesPhase"), ref(key+"Frameworks"), ref(key+"Resources")],
        buildRules=[], dependencies=[ref("appDependency")] if key=="uiTests" else [],
        fileSystemSynchronizedGroups=[ref(group)], name=name,
        packageProductDependencies=package_deps, productName=name, productReference=ref(product), productType=kind)

obj("project", "PBXProject", attributes=dict(BuildIndependentTargetsInParallel="YES", LastUpgradeCheck="2700",
    TargetAttributes={ident("uiTests"): dict(CreatedOnToolsVersion="27.0", TestTargetID=ref("app"))}),
    buildConfigurationList=ref("projectConfig"), developmentRegion="en", knownRegions=["en","Base"],
    mainGroup=ref("mainGroup"), minimizedProjectReferenceProxies=1,
    packageReferences=[ref("package")], preferredProjectObjectVersion=77,
    productRefGroup=ref("products"), projectDirPath="", projectRoot="",
    targets=[ref("app"),ref("coreTests"),ref("uiTests")])
project = dict(archiveVersion=1, classes={}, objectVersion=77, objects=objects, rootObject=ref("project"))
path = ROOT/"Forky.xcodeproj"
path.mkdir(exist_ok=True)
(path/"project.pbxproj").write_text("// !$*UTF8*$!\n"+encode(project)+"\n")
scheme_dir=path/"xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True,exist_ok=True)
def buildable(key,name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(key)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:Forky.xcodeproj"/>'
entries=[]
for key, name in [("app","Forky.app"),("coreTests","ForkyCoreTests.xctest"),("uiTests","ForkyUITests.xctest")]:
    run = "YES" if key=="app" else "NO"
    entries.append(f'<BuildActionEntry buildForTesting="YES" buildForRunning="{run}" buildForProfiling="{run}" buildForArchiving="{run}" buildForAnalyzing="YES">{buildable(key,name)}</BuildActionEntry>')
tests="".join(f'<TestableReference skipped="NO" parallelizable="NO">{buildable(key,name)}</TestableReference>' for key,name in [("coreTests","ForkyCoreTests.xctest"),("uiTests","ForkyUITests.xctest")])
(scheme_dir/"Forky.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>{"".join(entries)}</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><MacroExpansion>{buildable("app","Forky.app")}</MacroExpansion><Testables>{tests}</Testables><EnvironmentVariables><EnvironmentVariable key="FORKY_TEST_GIT_EXECUTABLE" value="$(DEVELOPER_DIR)/usr/bin/git" isEnabled="YES"/></EnvironmentVariables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="YES" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("app","Forky.app")}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("app","Forky.app")}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(path)
