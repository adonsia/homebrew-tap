#!/usr/bin/env python3
"""Check npm, publish a dependency lock, and open a tested version-update PR."""

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

REGISTRY = "https://registry.npmjs.org"
FORMULA = Path("Formula/apifox-cli.rb")
REPOSITORY = "adonsia/homebrew-tap"
CI_WORKFLOW = "tests.yml"


def command(*args, check=True, cwd=None):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=900)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr or result.stdout}")
    return result


def download(url):
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "homebrew-tap-updater"})
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except (OSError, urllib.error.URLError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def version_tuple(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(f"Expected a stable version, got {version!r}")
    return tuple(map(int, version.split(".")))


def formula_version(text):
    return re.search(r"apifox-cli-(\d+\.\d+\.\d+)\.tgz", text)[1]


def lock_resource(text):
    block = re.search(r'  resource "npm-shrinkwrap" do\n(.*?)\n  end', text, re.S)[1]
    url = re.search(r'url "([^"]+)"', block)[1]
    sha = re.search(r'sha256 "([a-f0-9]{64})"', block)[1]
    if not url.startswith(f"https://github.com/{REPOSITORY}/releases/download/"):
        raise ValueError("Unexpected lock resource URL")
    content = download(url)
    if hashlib.sha256(content).hexdigest() != sha:
        raise ValueError("Existing dependency lock checksum mismatch")
    return content


def release_info(tag):
    result = command("gh", "api", f"repos/{REPOSITORY}/releases/tags/{tag}", check=False)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "HTTP 404" in result.stderr:
        return None
    raise RuntimeError(result.stderr)


def prepare(text, metadata, package_dir, existing_lock=None):
    version = metadata["version"]
    version_tuple(version)
    url = f"{REGISTRY}/apifox-cli/-/apifox-cli-{version}.tgz"
    if metadata["dist"]["tarball"] != url:
        raise ValueError("Unexpected npm tarball URL")
    archive = download(url)
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(archive).digest()).decode()
    if metadata["dist"]["integrity"] != integrity:
        raise ValueError("npm tarball integrity mismatch")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        tar.extractall(package_dir, filter="data")
    package = package_dir / "package"
    manifest = json.loads((package / "package.json").read_text())
    if manifest["name"] != "apifox-cli" or manifest["version"] != version:
        raise ValueError("Unexpected package identity")
    lock_path = package / "npm-shrinkwrap.json"
    if existing_lock is not None:
        lock_path.write_bytes(existing_lock)
    else:
        lock_path.write_bytes(lock_resource(text))
        command("npm", "install", "--package-lock-only", "--ignore-scripts", "--omit=dev",
                "--omit=optional", "--no-audit", "--no-fund", f"--registry={REGISTRY}", cwd=package)
    lock = json.loads(lock_path.read_text())
    root = lock["packages"][""]
    if lock["version"] != version or root["version"] != version:
        raise ValueError("Dependency lock version does not match the release")
    for key in ("dependencies", "optionalDependencies"):
        if root.get(key, {}) != manifest.get(key, {}):
            raise ValueError(f"Dependency lock {key} do not match the package")
    sha = hashlib.sha256(archive).hexdigest()
    lock_sha = hashlib.sha256(lock_path.read_bytes()).hexdigest()
    text = re.sub(r'  url "https://registry.npmjs.org/apifox-cli/-/[^\n]+\n  sha256 "[a-f0-9]+"',
                  f'  url "{url}"\n  sha256 "{sha}"', text, count=1)
    text = re.sub(r"^  revision \d+\n", "", text, flags=re.M)
    text = re.sub(r'(  resource "npm-shrinkwrap" do\n).*?(\n  end)',
                  rf'\g<1>    url "https://github.com/{REPOSITORY}/releases/download/apifox-cli-{version}/npm-shrinkwrap.json"\n    sha256 "{lock_sha}"\g<2>',
                  text, count=1, flags=re.S)
    return text, lock_path


def dispatch_ci(branch, sha):
    runs = json.loads(command("gh", "run", "list", "--repo", REPOSITORY,
                              "--workflow", CI_WORKFLOW, "--branch", branch,
                              "--event", "workflow_dispatch", "--limit", "100",
                              "--json", "headSha").stdout)
    if not any(run["headSha"] == sha for run in runs):
        command("gh", "workflow", "run", CI_WORKFLOW, "--repo", REPOSITORY, "--ref", branch)
        print(f"Dispatched CI for {branch} ({sha})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Prepare the Formula without publishing or pushing")
    args = parser.parse_args()
    text = FORMULA.read_text()
    current = formula_version(text)
    metadata = json.loads(download(f"{REGISTRY}/apifox-cli/latest"))
    version = metadata["version"]
    if version_tuple(version) <= version_tuple(current):
        print(f"No update: Formula {current}, npm latest {version}")
        return
    branch = f"auto/apifox-cli-{version}"
    print(f"Updating apifox-cli {current} -> {version}")
    if not args.dry_run:
        prs = json.loads(command("gh", "pr", "list", "--repo", REPOSITORY, "--head", branch,
                                 "--state", "all", "--json", "number,state,headRefOid").stdout)
        if prs:
            pr = prs[0]
            if pr["state"] == "OPEN":
                dispatch_ci(branch, pr["headRefOid"])
            print(f"PR #{pr['number']} already exists ({pr['state']})")
            return
        remote = command("git", "ls-remote", "--heads", "origin", branch).stdout.strip()
        if remote:
            command("git", "fetch", "origin", branch)
            command("git", "switch", "-c", branch, "FETCH_HEAD")
            text = FORMULA.read_text()
        else:
            command("git", "switch", "-c", branch)
    tag = f"apifox-cli-{version}"
    release = None if args.dry_run else release_info(tag)
    existing_lock = None
    if release:
        for asset in release["assets"]:
            if asset["name"] == "npm-shrinkwrap.json":
                existing_lock = download(asset["browser_download_url"])
    with tempfile.TemporaryDirectory(prefix="apifox-update-") as temporary:
        text, lock_path = prepare(text, metadata, Path(temporary), existing_lock)
        FORMULA.write_text(text)
        command("git", "diff", "--check")
        if args.dry_run:
            print("Prepared Formula and verified dependency lock; no remote changes made")
            return
        if not release:
            command("gh", "release", "create", tag, str(lock_path), "--repo", REPOSITORY,
                    "--target", command("git", "rev-parse", "HEAD").stdout.strip(), "--latest=false",
                    "--title", f"apifox-cli {version} dependency lock",
                    "--notes", f"Pinned npm dependencies for apifox-cli {version}.")
        elif existing_lock is None:
            command("gh", "release", "upload", tag, str(lock_path), "--repo", REPOSITORY)
    command("git", "add", str(FORMULA))
    if command("git", "diff", "--cached", "--quiet", check=False).returncode:
        command("git", "commit", "-m", f"apifox-cli {version}")
    command("git", "push", "--set-upstream", "origin", branch)
    body = (f"Update Apifox CLI from {current} to {version}. Verify the official npm tarball, "
            "refresh the dependency lock, and reset the formula revision.\n\n"
            "CI checks installation, offline CLI validation, dependency versions and brew audit "
            "on macOS 26 and Ubuntu 26.04. Optional database addons remain excluded.")
    command("gh", "pr", "create", "--repo", REPOSITORY, "--base", "main", "--head", branch,
            "--title", f"apifox-cli {version}", "--body", body)
    dispatch_ci(branch, command("git", "rev-parse", "HEAD").stdout.strip())


if __name__ == "__main__":
    main()
