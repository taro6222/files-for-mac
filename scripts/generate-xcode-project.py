#!/usr/bin/env python3
"""Generate a native app target using the local FilesCore Swift package product."""
from pathlib import Path
import hashlib
import plistlib
ROOT = Path(__file__).resolve().parents[1]
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return '"'+s+'"'
objects = []
def obj(key, body): objects.append(f'{uid(key)} = {{ {body} }};'); return uid(key)
files = sorted((ROOT/'Sources'/'FilesMac').rglob('*.swift'))
refs, builds = [], []
for f in files:
 p=str(f.relative_to(ROOT)); refs.append(obj('ref:'+p, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(p)}; sourceTree = SOURCE_ROOT;'))
 builds.append(obj('build:'+p, f'isa = PBXBuildFile; fileRef = {uid("ref:"+p)};'))
product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = "Files macOS.app"; sourceTree = BUILT_PRODUCTS_DIR;')
products=obj('products',f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group=obj('group',f'isa = PBXGroup; children = ({",".join(refs+[products])},); sourceTree = "<group>";')
sources=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
package=obj('local-package','isa = XCLocalSwiftPackageReference; relativePath = ".";')
core_product=obj('core-product',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = FilesCore;')
core_link=obj('core-link',f'isa = PBXBuildFile; productRef = {core_product};')
frameworks=obj('frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({core_link},); runOnlyForDeploymentPostprocessing = 0;')
configs=[]
for name in ['Debug','Release']:
 settings='''ALWAYS_SEARCH_USER_PATHS = NO; PRODUCT_NAME = "Files macOS"; PRODUCT_MODULE_NAME = FilesMac; PRODUCT_BUNDLE_IDENTIFIER = "org.taro6222.files-for-mac"; SWIFT_VERSION = 6.0; MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_INCLUDE_PATHS = ("$(SRCROOT)/Sources/CLibArchive", "$(SRCROOT)/Sources/CZlib"); GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = FilesMac.xcodeproj/Info.plist; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_APP_SANDBOX = NO; COMBINE_HIDPI_IMAGES = YES; MARKETING_VERSION = 0.1.0; CURRENT_PROJECT_VERSION = 1; '''
 settings += 'SWIFT_OPTIMIZATION_LEVEL = "'+ ('-Onone' if name=='Debug' else '-O')+'";'
 configs.append(obj('config:'+name,f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {settings} }};'))
configlist=obj('configlist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target',f'isa = PBXNativeTarget; name = "Files macOS"; productName = "Files macOS"; productType = "com.apple.product-type.application"; productReference = {product}; buildConfigurationList = {configlist}; buildPhases = ({sources},{frameworks},); buildRules = (); dependencies = (); packageProductDependencies = ({core_product},);')
project=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2660; }}; buildConfigurationList = {configlist}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,ko,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},); packageReferences = ({package},);')
out=ROOT/'FilesMac.xcodeproj';out.mkdir(exist_ok=True)
(out/'Info.plist').write_bytes(plistlib.dumps({
 "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
 "CFBundleExecutable": "$(EXECUTABLE_NAME)",
 "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
 "CFBundleInfoDictionaryVersion": "6.0",
 "CFBundleName": "$(PRODUCT_NAME)",
 "CFBundlePackageType": "APPL",
 "CFBundleShortVersionString": "$(MARKETING_VERSION)",
 "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
 "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
 "LSApplicationCategoryType": "public.app-category.utilities",
 "NSHighResolutionCapable": True,
 "FilesReleaseChannel": "preview",
}))
(out/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+project+'; }\n')
