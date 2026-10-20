from pathlib import Path
import json,subprocess,shutil,tempfile,os,zipfile,argparse
parser=argparse.ArgumentParser(description="Isolated fullscreen smoke test using cached Prism dependencies")
parser.add_argument("jar",type=Path)
parser.add_argument("--output",type=Path,required=True)
parser.add_argument("--java-home",type=Path,default=os.environ.get("JAVA_HOME"))
parser.add_argument("--toggle",action="store_true",help="Exercise one live ProMotion on/off cycle; can reproduce the system-level hang")
parser.add_argument("--mode",choices=["native","exclusive"],default="native",help="macOS native fullscreen (Spaces) matches the reported freeze")
parser.add_argument("--prepare-only",action="store_true",help="Compile the helper and prepare an isolated profile without launching Minecraft")
opts=parser.parse_args()
opts.jar=opts.jar.resolve()
root=opts.output.resolve();root.mkdir(parents=True,exist_ok=True)
prism=Path.home()/'Library/Application Support/PrismLauncher'
game=Path(tempfile.mkdtemp(prefix='mcopt-promotion-game-',dir='/private/tmp'))
root.joinpath('game-path').write_text(str(game))
java=(opts.java_home or Path(subprocess.check_output(["/usr/libexec/java_home","-v","25"],text=True).strip()))/"bin"
cp=[]
for uid,ver in [('org.lwjgl3','3.4.3'),('net.minecraft','26.3'),('net.fabricmc.fabric-loader','0.19.5')]:
 j=json.loads((prism/f'meta/{uid}/{ver}.json').read_text())
 for l in j.get('libraries',[])+([j['mainJar']] if 'mainJar'in j else []):
  allowed=not l.get('rules')
  for rule in l.get('rules',[]):
   osr=rule.get('os',{})
   if osr.get('name','osx-arm64') in ['osx-arm64'] and osr.get('arch','aarch64') in ['aarch64','arm64']:
    allowed=rule['action']=='allow'
  if not allowed:continue
  group,artifact,version,*classifier=l['name'].split(':')
  filename=artifact+'-'+version+('-'+classifier[0] if classifier else '')+'.jar'
  p=prism/'libraries'/group.replace('.','/')/artifact/version/filename
  if not p.exists():raise RuntimeError(str(p))
  cp.append(str(p))
(game/'mods').mkdir();(game/'config').mkdir()
shutil.copy2(opts.jar,game/'mods')
(game/'options.txt').write_text('pauseOnLostFocus:false\nenableVsync:true\nmaxFps:120\nfullscreen:false\nrenderDistance:4\nsimulationDistance:5\nlang:en_us\nonboardAccessibility:false\n')
(game/'config/mcopt.properties').write_text('mcopt.shade=true\nmcopt.shade.hdrMode=scene\nmcopt.shade.output=2160\n')
src=Path(__file__).with_name('FullscreenSmoke.java')
classes=root/'smoke-classes';classes.mkdir(exist_ok=True)
subprocess.run([str(java/'javac'),'-proc:none','-classpath',':'.join(cp+[str(opts.jar)]),'-d',str(classes),str(src)],check=True)
with zipfile.ZipFile(game/'mods/pacing-smoke.jar','w') as z:
 z.write(classes/'FullscreenSmoke.class','FullscreenSmoke.class')
 z.writestr('fabric.mod.json',json.dumps({'schemaVersion':1,'id':'pacing-smoke','version':'1','environment':'client','entrypoints':{'client':['FullscreenSmoke']}}))
args=[str(java/'java'),'-XstartOnFirstThread','-Xmx2G','--enable-native-access=ALL-UNNAMED','-Dmcopt.shade=true','-Dmcopt.shade.diag=false','-Dmixin.debug.export=true','-classpath',':'.join(cp),'net.fabricmc.loader.impl.launch.knot.KnotClient','--username','PacingTest','--uuid','00000000-0000-0000-0000-000000000001','--accessToken','0','--version','26.3','--gameDir',str(game),'--assetsDir',str(prism/'assets'),'--assetIndex','34','--width','640','--height','400']
if opts.toggle: args.insert(1, '-Dmcopt.smoke.toggle=true')
if opts.mode == 'exclusive': args.insert(1, '-Dmcopt.smoke.exclusive=true')
if opts.prepare_only:
 print('Prepared fullscreen helper without launching Minecraft:',game)
 raise SystemExit(0)
with (root/'fullscreen.log').open('w') as log:
 p=subprocess.Popen(args,cwd=game,stdout=log,stderr=subprocess.STDOUT,env={**os.environ,'MTL_DEBUG_LAYER':'1'})
 root.joinpath('game-pid').write_text(str(p.pid))
 try: code=p.wait(timeout=150)
 except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5);raise
print('Smoke process exit',code,'at',game)

for trace in (game/'logs').glob('mcopt-presentation-*.log'): shutil.copy2(trace,root/trace.name)
if code: raise RuntimeError('Fullscreen test failed; inspect fullscreen.log and game-path/logs/mcopt-presentation-*.log')
if 'FULLSCREEN_TEST PASS' not in (root/'fullscreen.log').read_text(): raise RuntimeError('Missing pass marker')
if opts.toggle and opts.mode == 'native':
 traces='\n'.join(p.read_text() for p in (game/'logs').glob('mcopt-presentation-*.log'))
 if 'fullscreenStyle=1' not in traces: raise RuntimeError('Missing AppKit native-fullscreen evidence in link context')
print('Fullscreen test PASS; mode:',opts.mode,'live toggle tested:',opts.toggle)
