#!/usr/bin/env python3
"""Generate a dependency-free, deterministic Xcode project using Python 3."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def q(text):
    return json.dumps(str(text))

def obj(name, body):
    key = uid(name)
    objects[key] = body
    return key

def arr(items):
    return '(' + ', '.join(items) + (',' if items else '') + ')'

def settings(values):
    return '{ ' + ' '.join(f'{k} = {q(v)};' for k, v in values.items()) + ' }'

products = []
targets = []
groups = []
for target in ['StayWeb', 'StayWebTests']:
    test = target.endswith('Tests')
    source_ids, resource_ids, file_ids = [], [], []
    for file in sorted((ROOT / target).rglob('*')):
        if any(parent.suffix == '.xcassets' for parent in file.parents):
            continue
        if not file.is_file() and file.suffix != '.xcassets':
            continue
        ext = file.suffix
        if ext not in ['.swift', '.json', '.xcprivacy', '.js', '.txt', '.xcassets']:
            continue
        key = f'file:{file.relative_to(ROOT)}'
        file_type = {'.xcassets': 'folder.assetcatalog', '.swift': 'sourcecode.swift', '.json': 'text.json', '.xcprivacy': 'text.xml', '.js': 'sourcecode.javascript', '.txt': 'text'}[ext]
        ref = obj(key, f'isa = PBXFileReference; lastKnownFileType = {file_type}; path = {q(file.relative_to(ROOT))}; sourceTree = SOURCE_ROOT;')
        file_ids.append(ref)
        build = obj('build:' + key, f'isa = PBXBuildFile; fileRef = {ref};')
        (source_ids if ext == '.swift' else resource_ids).append(build)
    groups.append(obj('group:' + target, f'isa = PBXGroup; children = {arr(file_ids)}; name = {q(target)}; sourceTree = "<group>";'))
    product = obj('product:' + target, f'isa = PBXFileReference; explicitFileType = {"wrapper.cfbundle" if test else "wrapper.application"}; includeInIndex = 0; path = {target}.{ "xctest" if test else "app"}; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    phases = []
    for name, kind, files in [('Sources', 'PBXSourcesBuildPhase', source_ids), ('Resources', 'PBXResourcesBuildPhase', resource_ids), ('Frameworks', 'PBXFrameworksBuildPhase', [])]:
        phases.append(obj(target + ':' + name, f'isa = {kind}; buildActionMask = 2147483647; files = {arr(files)}; runOnlyForDeploymentPostprocessing = 0;'))
    configs = []
    for config in ['Debug', 'Release']:
        vals = {
            'PRODUCT_NAME': '$(TARGET_NAME)',
            'PRODUCT_BUNDLE_IDENTIFIER': 'com.example.stayweb' + ('.tests' if test else ''),
            'GENERATE_INFOPLIST_FILE': 'YES',
            'IPHONEOS_DEPLOYMENT_TARGET': '16.0',
            'SWIFT_VERSION': '5.0',
            'TARGETED_DEVICE_FAMILY': '1,2',
            'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
            'SUPPORTS_MACCATALYST': 'NO',
            'CODE_SIGN_STYLE': 'Automatic',
            'CURRENT_PROJECT_VERSION': '5',
            'MARKETING_VERSION': '0.2.1',
            'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O',
            'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym',
            'ENABLE_TESTABILITY': 'YES' if config == 'Debug' else 'NO',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if config == 'Debug' else '',
        }
        if test:
            vals.update({'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/StayWeb.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/StayWeb', 'BUNDLE_LOADER': '$(TEST_HOST)'})
        else:
            vals.update({
                'INFOPLIST_KEY_CFBundleDisplayName': 'StayWeb',
                'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
                'INFOPLIST_KEY_LSApplicationCategoryType': 'public.app-category.utilities',
                'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES',
                'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES',
                'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone': 'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
                'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad': 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
                'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks',
            })
        configs.append(obj(target + ':config:' + config, f'isa = XCBuildConfiguration; buildSettings = {settings(vals)}; name = {config};'))
    config_list = obj(target + ':configs', f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    dependencies = []
    if test:
        proxy = obj('test:proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target:StayWeb")}; remoteInfo = StayWeb;')
        dependencies.append(obj('test:dependency', f'isa = PBXTargetDependency; target = {uid("target:StayWeb")}; targetProxy = {proxy};'))
    targets.append(obj('target:' + target, f'isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = {arr(phases)}; buildRules = (); dependencies = {arr(dependencies)}; name = {target}; productName = {target}; productReference = {product}; productType = {q("com.apple.product-type.bundle.unit-test" if test else "com.apple.product-type.application")};'))
product_group = obj('products', f'isa = PBXGroup; children = {arr(products)}; name = Products; sourceTree = "<group>";')
main_group = obj('main', f'isa = PBXGroup; children = {arr(groups + [product_group])}; sourceTree = "<group>";')
configs = []
for name in ['Debug', 'Release']:
    configs.append(obj('project:' + name, f'isa = XCBuildConfiguration; buildSettings = {{ SDKROOT = iphoneos; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; }}; name = {name};'))
config_list = obj('project:configs', f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1640; BuildIndependentTargetsInParallel = YES; }}; buildConfigurationList = {config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group}; productRefGroup = {product_group}; projectDirPath = ""; projectRoot = ""; targets = {arr(targets)};')
path = ROOT / 'StayWeb.xcodeproj'
path.mkdir(exist_ok=True)
(path / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n' + '\n'.join(f'{key} = {{ {value} }};' for key, value in sorted(objects.items())) + f'\n}};\nrootObject = {project};\n}}\n')
scheme_path = path / 'xcshareddata/xcschemes'
scheme_path.mkdir(parents=True, exist_ok=True)
def buildable(target):
    extension = 'xctest' if target.endswith('Tests') else 'app'
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target:" + target)}" BuildableName="{target}.{extension}" BlueprintName="{target}" ReferencedContainer="container:StayWeb.xcodeproj"/>'
(scheme_path / 'StayWeb.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable('StayWeb')}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable('StayWebTests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('StayWeb')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('StayWeb')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated StayWeb.xcodeproj')
