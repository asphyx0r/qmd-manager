"""Protect consumer validation when updating the shared starter core."""

import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import venv


ROOT = Path(__file__).resolve().parents[1]


class StarterCoreMigrationTests(unittest.TestCase):
    def configuration(self):
        path = ROOT / ".starter-kit-project.json"
        self.assertTrue(path.is_file(), "Application validation must be declared")
        return json.loads(path.read_text(encoding="utf-8"))

    def test_existing_release_and_automation_behavior_is_preserved(self):
        config = self.configuration()
        self.assertEqual(config["repositoryRole"], "project")
        self.assertEqual(config["releaseKind"], "deployment")
        self.assertEqual(
            config["automations"],
            {"agentRulesSync": True, "guardedMerge": True, "releasePreflight": True},
        )

    def test_application_suite_runs_on_both_supported_platforms(self):
        checks = self.configuration()["checks"]
        expected = [
            "python",
            "-B",
            "-m",
            "unittest",
            "discover",
            "-s",
            "tests",
            "-p",
            "test_*.py",
        ]
        selected = [check for check in checks if check["argv"] == expected]
        self.assertEqual(len(selected), 1)
        self.assertEqual(set(selected[0]["platforms"]), {"linux", "windows"})

    def test_malformed_toml_is_rejected_without_hanging(self):
        module = ROOT / "tools/quality/node_modules/smol-toml"
        if not module.is_dir():
            command = shutil.which("markdownlint-cli2")
            self.assertIsNotNone(command, "Locked Markdownlint must be available")
            module = Path(command).resolve().parent.parent / "smol-toml"
        result = subprocess.run(
            ["node", "-e", f'require({json.dumps(str(module))}).parse("a=[1 #")'],
            cwd=ROOT / "tools" / "quality",
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TomlError", result.stderr)

    def test_project_check_uses_python_selected_by_path(self):
        config = self.configuration()
        config["checks"] = [
            {
                "name": "PATH-selected Python",
                "argv": ["python", "-c", "import sys; print(sys.executable)"],
                "workingDirectory": ".",
                "platforms": ["windows", "linux"],
            }
        ]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            runtime = fixture / "runtime"
            venv.EnvBuilder(with_pip=False).create(runtime)
            bin_dir = runtime / ("Scripts" if os.name == "nt" else "bin")
            expected = bin_dir / ("python.exe" if os.name == "nt" else "python")
            (fixture / ".starter-kit-project.json").write_text(
                json.dumps(config), encoding="utf-8"
            )
            environment = os.environ.copy()
            environment["PATH"] = str(bin_dir) + os.pathsep + environment["PATH"]
            result = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    str(ROOT / "tools/project_validation.py"),
                    "--repository-root",
                    directory,
                ],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
                timeout=40,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(os.path.normcase(str(expected)), os.path.normcase(result.stdout))

    def test_windows_audit_prefers_modern_powershell(self):
        command = (
            "source tools/repository-audit/common.sh; "
            "unset WSL_DISTRO_NAME WSL_INTEROP; "
            "uname() { echo MINGW64_NT; }; "
            'resolve_command() { echo "$1"; }; resolve_powershell_command'
        )
        result = subprocess.run(
            [shutil.which("bash"), "-c", command],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "pwsh.exe")

    def test_commit_message_hook_with_git_directory_environment(self):
        environment = os.environ.copy()
        environment["GIT_DIR"] = subprocess.check_output(
            ["git", "rev-parse", "--absolute-git-dir"], cwd=ROOT, text=True
        ).strip()
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "Git Bash must be available")
        with tempfile.TemporaryDirectory() as directory:
            message = Path(directory) / "message.txt"
            for content, expected in (
                ("chore(tools): verify hook root\n", 0),
                ("invalid message\n", 1),
            ):
                with self.subTest(message=content):
                    message.write_text(content, encoding="utf-8")
                    result = subprocess.run(
                        [bash, str(ROOT / ".githooks/commit-msg"), str(message)],
                        cwd=ROOT,
                        env=environment,
                        text=True,
                        capture_output=True,
                        check=False,
                        timeout=40,
                    )
                    self.assertEqual(
                        result.returncode, expected, result.stdout + result.stderr
                    )
                    self.assertIn("running commitlint", result.stdout)

    def test_failing_project_check_blocks_validation(self):
        runner = ROOT / "tools" / "project_validation.py"
        self.assertTrue(runner.is_file(), "The project check runner is required")
        config = self.configuration()
        config["checks"] = [
            {
                "name": "deliberate failure",
                "argv": [sys.executable, "-c", "raise SystemExit(7)"],
                "workingDirectory": ".",
                "platforms": ["windows", "linux"],
            }
        ]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            (fixture / ".starter-kit-project.json").write_text(
                json.dumps(config), encoding="utf-8"
            )
            result = subprocess.run(
                [sys.executable, "-B", str(runner), "--repository-root", directory],
                text=True,
                capture_output=True,
                check=False,
                timeout=30,
            )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("deliberate failure", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
