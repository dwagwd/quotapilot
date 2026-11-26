import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "publish-site-data.sh"


def git(cwd, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e")
    for key in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
        env.pop(key, None)
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def write(root, rel, text):
    path = Path(root, rel)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class PublishSiteDataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bare = os.path.join(self.tmp, "origin.git")
        self.repo = os.path.join(self.tmp, "repo")
        git(self.tmp, "init", "--bare", "-b", "main", self.bare)
        git(self.tmp, "init", "-b", "main", self.repo)
        git(self.repo, "remote", "add", "origin", self.bare)
        write(self.repo, "site/data/a.json", "{}\n")
        write(self.repo, "README.md", "one\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "base")
        git(self.repo, "push", "origin", "main")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, *args):
        env = dict(os.environ, TMPDIR=self.tmp, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e")
        for key in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
            env.pop(key, None)
        return subprocess.run(["bash", str(SCRIPT), *args], cwd=self.repo, env=env, capture_output=True, text=True)

    def test_already_live(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already live", result.stdout)

    def test_unknown_option_is_rejected(self):
        write(self.repo, "site/data/a.json", '{"v": 3}\n')
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "data")
        result = self.run_script("--dryrun")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(git(self.bare, "rev-list", "--count", "main"), "1")

    def test_missing_validator_blocks_publish(self):
        write(self.repo, "site/data/a.json", '{"v": 4}\n')
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "data")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(git(self.bare, "rev-list", "--count", "main"), "1")

    def test_publishes_only_site_data(self):
        write(self.repo, "site/data/a.json", '{"v": 2}\n')
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "data")
        write(self.repo, "README.md", "two\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "unrelated local work")

        dry = self.run_script("--dry-run", "--skip-validate")
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("site/data/a.json", dry.stdout)
        self.assertEqual(git(self.bare, "rev-list", "--count", "main"), "1")

        result = self.run_script("--skip-validate", "Site data: test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(self.bare, "rev-list", "--count", "main"), "2")
        self.assertEqual(git(self.bare, "log", "-1", "--format=%s", "main"), "Site data: test")
        self.assertEqual(git(self.bare, "show", "main:site/data/a.json"), '{"v": 2}')
        self.assertEqual(git(self.bare, "show", "main:README.md"), "one")


if __name__ == "__main__":
    unittest.main()
