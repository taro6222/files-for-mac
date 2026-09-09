#!/usr/bin/env python3
"""Generate a dependency-free native app target using the same Swift sources as SwiftPM."""
from pathlib import Path
import hashlib
ROOT = Path(__file__).resolve().parents[1]
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return '"'+s+'"'
objects = []
def obj(key, body): objects.append(f'{uid(key)} = {{ {body} }};'); return uid(key)
files = sorted((ROOT/'Sources').rglob('*.swift'))
refs, builds = [], []
for f in files:
 p=str(f.relative_to(ROOT)); refs.append(obj('ref:'+p, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(p)}; sourceTree = SOURCE_ROOT;'))
 builds.append(obj('build:'+p, f'isa = PBXBuildFile; fileRef = {uid("ref:"+p)};'))
product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = "Files macOS.app"; sourceTree = BUILT_PRODUCTS_DIR;')
products=obj('products',f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group=obj('group',f'isa = PBXGroup; children = ({",".join(refs+[products])},); sourceTree = "<group>";')
sources=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
frameworks=obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
configs=[]
for name in ['Debug','Release']:
 settings='''ALWAYS_SEARCH_USER_PATHS = NO; PRODUCT_NAME = "Files macOS"; PRODUCT_BUNDLE_IDENTIFIER = "org.taro6222.files-for-mac"; SWIFT_VERSION = 6.0; MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities"; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_APP_SANDBOX = NO; COMBINE_HIDPI_IMAGES = YES; MARKETING_VERSION = 0.1.0; CURRENT_PROJECT_VERSION = 1; '''
 settings += 'SWIFT_OPTIMIZATION_LEVEL = "'+ ('-Onone' if name=='Debug' else '-O')+'";'
 configs.append(obj('config:'+name,f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {settings} }};'))
configlist=obj('configlist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target',f'isa = PBXNativeTarget; name = "Files macOS"; productName = "Files macOS"; productType = "com.apple.product-type.application"; productReference = {product}; buildConfigurationList = {configlist}; buildPhases = ({sources},{frameworks},); buildRules = (); dependencies = ();')
project=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2660; }}; buildConfigurationList = {configlist}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,ko,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
out=ROOT/'FilesMac.xcodeproj';out.mkdir(exist_ok=True)
(out/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+project+'; }\n')
