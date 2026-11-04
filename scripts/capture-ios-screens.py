import json,subprocess,pathlib,plistlib,time,os

def run(*args, capture=False):
 r=subprocess.run(args,check=True,text=True,stdout=subprocess.PIPE if capture else None)
 return r.stdout.strip() if capture else None
root=pathlib.Path.cwd();out=root/'artifacts/screenshots';out.mkdir(exist_ok=True,parents=True)
run('xcodebuild','-project','ios/App/App.xcodeproj','-scheme','App','-configuration','Release','-sdk','iphonesimulator','-destination','generic/platform=iOS Simulator','-derivedDataPath','.build-ios-simulator','CODE_SIGNING_ALLOWED=NO','ONLY_ACTIVE_ARCH=YES','build')
app=root/'.build-ios-simulator/Build/Products/Release-iphonesimulator/App.app'
devices=json.loads(run('xcrun','simctl','list','devices','available','--json',capture=True))['devices']
choices=[('iphone',lambda n: 'iPhone' in n and ('Pro Max' in n or 'Plus' in n)),('ipad',lambda n:'iPad Pro' in n and ('13-inch' in n or '12.9-inch' in n))]
if os.environ.get('SCREENSHOT_SCOPE') == 'console': choices = choices[:1]
for label,matches in choices:
 options=[d for runtime,ds in devices.items() if 'iOS' in runtime for d in ds if matches(d['name'])]
 if not options:raise RuntimeError('No available '+label+' simulator')
 d=options[-1];uid=d['udid'];print('Capturing',d['name'],flush=True)
 if d['state']!='Booted':run('xcrun','simctl','boot',uid)
 run('xcrun','simctl','bootstatus',uid,'-b')
 run('xcrun','simctl','status_bar',uid,'override','--time','9:41','--batteryState','charged','--batteryLevel','100')
 run('xcrun','simctl','install',uid,str(app))
 container=pathlib.Path(run('xcrun','simctl','get_app_container',uid,'app.elementremote.mobile','data',capture=True))
 prefs=container/'Library/Preferences/app.elementremote.mobile.plist';prefs.parent.mkdir(parents=True,exist_ok=True)
 prefs.write_bytes(plistlib.dumps({'element.demoMode':True,'element.testMode':True}))
 names = ['console'] if os.environ.get('SCREENSHOT_SCOPE') == 'console' else ['console','faders','playback','more']
 for tab,name in enumerate(names):
  run('xcrun','simctl','launch',uid,'app.elementremote.mobile','--capture-tab='+str(tab))
  time.sleep(3)
  run('xcrun','simctl','io',uid,'screenshot',str(out/(label+'-'+name+'.png')))
  run('xcrun','simctl','terminate',uid,'app.elementremote.mobile')
 run('xcrun','simctl','shutdown',uid)
