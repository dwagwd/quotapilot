import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class InstallTests(unittest.TestCase):
    def test_reinstall_can_quit_app_without_old_install_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts'; scripts.mkdir()
            shutil.copy2(Path(__file__).parents[1] / 'build-install.sh', scripts / 'build-install.sh')
            def executable(path, text):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('#!/bin/bash\nset -eu\n' + text + '\n'); path.chmod(0o755)
            executable(scripts / 'build.sh', 'exit 0')
            running = root / 'running'; running.touch()
            dist = root / 'dist'
            executable(dist / 'QuotaPilot.app/Contents/MacOS/QuotaPilot',
                       'test "$1" = "--quit"\nrm "$TEST_RUNNING"')
            executable(root / 'bin/pgrep', 'test -e "$TEST_RUNNING"')
            executable(root / 'bin/ditto', 'mkdir -p "$2"')
            env = dict(os.environ, HOME=str(root / 'home'), QUOTAPILOT_DIST_DIR=str(dist),
                       TEST_RUNNING=str(running), PATH=str(root / 'bin') + ':' + os.environ['PATH'])
            result = subprocess.run(['bash', str(scripts / 'build-install.sh')], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(running.exists())
            self.assertTrue((root / 'home/Applications/QuotaPilot.app').exists())

if __name__ == '__main__': unittest.main()
