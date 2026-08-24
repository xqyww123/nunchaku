# W2 probe: headless Cygwin init for an extracted Isabelle Windows
# distribution.  Faithful replica of isabelle.setup.Environment.cygwin_init
# (src/Tools/Setup/src/Environment.java): the official Isabelle2025-2.exe
# "-init" path cannot be used on CI because the launch4j GUI wrapper detaches
# from the JVM and exits with code 259 (measured, round 2).
import ctypes
import os
import subprocess
import sys

isa = os.environ['ISA_HOME_W']
cyg = os.path.join(isa, 'contrib', 'cygwin')
marker = os.path.join(cyg, 'isabelle', 'uninitialized')

uninitialized = os.path.isfile(marker)
print('uninitialized marker present:', uninitialized)
if uninitialized:
    os.remove(marker)

    with open(os.path.join(cyg, 'isabelle', 'symlinks'), encoding='utf-8') as f:
        lines = f.read().split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    if len(lines) % 2 != 0:
        sys.exit('unbalanced symlinks list')
    for i in range(0, len(lines), 2):
        target, content = lines[i], lines[i + 1]
        path = os.path.join(isa, target)
        with open(path, 'wb') as f:
            f.write(b'!<symlink>' + content.encode('utf-8') + b'\x00')
        if not ctypes.windll.kernel32.SetFileAttributesW(path, 0x4):  # SYSTEM
            sys.exit('SetFileAttributes failed for ' + path)
    print('symlinks restored:', len(lines) // 2)

    env = dict(os.environ)
    env['CYGWIN'] = 'nodosfilewarning'
    for prog, script in [('dash.exe', '/isabelle/rebaseall'),
                         ('bash.exe', '/isabelle/postinstall')]:
        cmd = [os.path.join(cyg, 'bin', prog), script]
        r = subprocess.run(cmd, cwd=isa, env=env,
                           capture_output=True, text=True, timeout=1200)
        print('ran', script, '-> exit', r.returncode)
        if r.stdout:
            print(r.stdout[-2000:])
        if r.stderr:
            print(r.stderr[-2000:])
        if r.returncode != 0:
            sys.exit(1)

print('cygwin init done')
