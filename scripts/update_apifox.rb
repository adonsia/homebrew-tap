#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "uri"
require "zlib"

# Publish verified npm releases as Formula update PRs.
class ApifoxUpdater
  REGISTRY = "https://registry.npmjs.org"
  REPOSITORY = "adonsia/homebrew-tap"
  CI_WORKFLOW = "tests.yml"
  Result = Struct.new(:stdout, :stderr, :status)

  def initialize(formula = "Formula/apifox-cli.rb")
    @formula = formula
  end

  def command(*args, check: true, chdir: nil)
    options = chdir ? { chdir: chdir } : {}
    stdout, stderr, status = Open3.capture3(*args, **options)
    raise "#{args.first} failed: #{stderr.empty? ? stdout : stderr}" if check && !status.success?

    Result.new(stdout, stderr, status.exitstatus)
  end

  def download(url)
    attempts = 0
    begin
      uri = URI(url)
      6.times do
        raise "Expected HTTPS URL" unless uri.is_a?(URI::HTTPS)

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 60, read_timeout: 60) do |http|
          http.get(uri.request_uri, "User-Agent" => "homebrew-tap-updater")
        end
        return response.body if response.is_a?(Net::HTTPSuccess)
        raise "Download failed: #{response.code} #{uri.host}" unless response.is_a?(Net::HTTPRedirection)

        uri = URI.join(uri.to_s, response.fetch("location"))
      end
      raise "Too many redirects"
    rescue IOError, SystemCallError, Timeout::Error, SocketError
      attempts += 1
      raise if attempts >= 3

      sleep(2**(attempts - 1))
      retry
    end
  end

  def version_number(version)
    raise "Expected a stable version, got #{version.inspect}" unless version.match?(/\A\d+\.\d+\.\d+\z/)

    Gem::Version.new(version)
  end

  def formula_version(text)
    text.match(/apifox-cli-(\d+\.\d+\.\d+)\.tgz/)[1]
  end

  def lock_resource(text)
    block = text.match(/  resource "npm-shrinkwrap" do\n(.*?)\n  end/m)[1]
    url = block.match(/url "([^"]+)"/)[1]
    sha = block.match(/sha256 "([a-f0-9]{64})"/)[1]
    raise "Unexpected lock resource URL" unless url.start_with?("https://github.com/#{REPOSITORY}/releases/download/")

    content = download(url)
    raise "Existing dependency lock checksum mismatch" if Digest::SHA256.hexdigest(content) != sha

    content
  end

  def release_info(tag)
    result = command("gh", "api", "repos/#{REPOSITORY}/releases/tags/#{tag}", check: false)
    return JSON.parse(result.stdout) if result.status.zero?
    return if result.stderr.include?("HTTP 404")

    raise result.stderr
  end

  def prepare(text, metadata, directory, existing_lock = nil)
    version = metadata.fetch("version")
    version_number(version)
    url = "#{REGISTRY}/apifox-cli/-/apifox-cli-#{version}.tgz"
    raise "Unexpected npm tarball URL" if metadata.fetch("dist").fetch("tarball") != url

    archive = download(url)
    integrity = "sha512-#{[Digest::SHA512.digest(archive)].pack("m0")}"
    raise "npm tarball integrity mismatch" if metadata.fetch("dist").fetch("integrity") != integrity

    # Only package.json is needed to resolve the lock. Never extract archive paths or links.
    manifest_bytes = nil
    Zlib::GzipReader.wrap(StringIO.new(archive)) do |gzip|
      Gem::Package::TarReader.new(gzip) do |tar|
        tar.each do |entry|
          manifest_bytes = entry.read if entry.file? && entry.full_name == "package/package.json"
        end
      end
    end
    raise "Missing package/package.json" unless manifest_bytes

    manifest = JSON.parse(manifest_bytes)
    raise "Unexpected package identity" if manifest["name"] != "apifox-cli" || manifest["version"] != version

    package = File.join(directory, "package")
    FileUtils.mkdir_p(package)
    File.binwrite(File.join(package, "package.json"), manifest_bytes)
    lock_path = File.join(package, "npm-shrinkwrap.json")
    File.binwrite(lock_path, existing_lock || lock_resource(text))
    unless existing_lock
      command("npm", "install", "--package-lock-only", "--ignore-scripts", "--omit=dev", "--omit=optional",
              "--no-audit", "--no-fund", "--registry=#{REGISTRY}", chdir: package)
    end
    lock = JSON.parse(File.read(lock_path))
    root = lock.fetch("packages").fetch("")
    if lock["version"] != version || root["version"] != version
      raise "Dependency lock version does not match the release"
    end

    %w[dependencies optionalDependencies].each do |key|
      raise "Dependency lock #{key} do not match the package" if root.fetch(key, {}) != manifest.fetch(key, {})
    end
    sha = Digest::SHA256.hexdigest(archive)
    lock_sha = Digest::SHA256.file(lock_path).hexdigest
    text = text.sub(%r{  url "https://registry.npmjs.org/apifox-cli/-/[^\n]+\n  sha256 "[a-f0-9]+"},
                    "  url \"#{url}\"\n  sha256 \"#{sha}\"")
    text = text.sub(/^  revision \d+\n/, "")
    text = text.sub(/  resource "npm-shrinkwrap" do\n.*?\n  end/m) do
      <<~BLOCK.chomp.lines.map { |line| "  #{line}" }.join
        resource "npm-shrinkwrap" do
          url "https://github.com/#{REPOSITORY}/releases/download/apifox-cli-#{version}/npm-shrinkwrap.json"
          sha256 "#{lock_sha}"
        end
      BLOCK
    end
    [text, lock_path]
  end

  def dispatch_ci(branch, sha)
    runs = JSON.parse(command("gh", "run", "list", "--repo", REPOSITORY, "--workflow", CI_WORKFLOW,
                              "--branch", branch, "--event", "workflow_dispatch",
                              "--limit", "100", "--json", "headSha").stdout)
    return if runs.any? { |run| run["headSha"] == sha }

    command("gh", "workflow", "run", CI_WORKFLOW, "--repo", REPOSITORY, "--ref", branch)
    puts "Dispatched CI for #{branch} (#{sha})"
  end

  def run(dry_run: false)
    text = File.read(@formula)
    current = formula_version(text)
    metadata = JSON.parse(download("#{REGISTRY}/apifox-cli/latest"))
    version = metadata.fetch("version")
    if version_number(version) <= version_number(current)
      puts "No update: Formula #{current}, npm latest #{version}"
      return
    end
    branch = "auto/apifox-cli-#{version}"
    puts "Updating apifox-cli #{current} -> #{version}"
    unless dry_run
      prs = JSON.parse(command("gh", "pr", "list", "--repo", REPOSITORY, "--head", branch,
                               "--state", "all", "--json", "number,state,headRefOid").stdout)
      unless prs.empty?
        pr = prs.first
        dispatch_ci(branch, pr["headRefOid"]) if pr["state"] == "OPEN"
        puts "PR ##{pr["number"]} already exists (#{pr["state"]})"
        return
      end
      if command("git", "ls-remote", "--heads", "origin", branch).stdout.strip.empty?
        command("git", "switch", "-c", branch)
      else
        command("git", "fetch", "origin", branch)
        command("git", "switch", "-c", branch, "FETCH_HEAD")
        text = File.read(@formula)
      end
    end
    tag = "apifox-cli-#{version}"
    release = release_info(tag) unless dry_run
    asset = release&.fetch("assets")&.find { |item| item["name"] == "npm-shrinkwrap.json" }
    existing_lock = download(asset.fetch("browser_download_url")) if asset
    Dir.mktmpdir("apifox-update-") do |temporary|
      text, lock_path = prepare(text, metadata, temporary, existing_lock)
      File.write(@formula, text)
      command("git", "diff", "--check")
      if dry_run
        puts "Prepared Formula and verified dependency lock; no remote changes made"
        break
      end
      if release
        command("gh", "release", "upload", tag, lock_path, "--repo", REPOSITORY) unless existing_lock
      else
        command("gh", "release", "create", tag, lock_path, "--repo", REPOSITORY,
                "--target", command("git", "rev-parse", "HEAD").stdout.strip, "--latest=false",
                "--title", "apifox-cli #{version} dependency lock", "--notes", "Pinned npm dependencies for apifox-cli #{version}.")
      end
    end
    return if dry_run

    command("git", "add", @formula)
    command("git", "commit", "-m", "apifox-cli #{version}") if command("git", "diff", "--cached", "--quiet", check: false).status != 0
    command("git", "push", "--set-upstream", "origin", branch)
    body = "Update Apifox CLI from #{current} to #{version}. Verify the official npm tarball, refresh the dependency lock, " \
           "and reset the formula revision.\n\nCI checks installation, offline CLI validation, " \
           "dependency versions and " \
           "brew audit on macOS 26 and Ubuntu 26.04. Optional database addons remain excluded."
    command("gh", "pr", "create", "--repo", REPOSITORY, "--base", "main", "--head", branch,
            "--title", "apifox-cli #{version}", "--body", body)
    dispatch_ci(branch, command("git", "rev-parse", "HEAD").stdout.strip)
  end
end

if $PROGRAM_NAME == __FILE__
  options = { dry_run: false }
  OptionParser.new do |parser|
    parser.on("--dry-run", "Prepare the Formula without publishing or pushing") { options[:dry_run] = true }
  end.parse!
  ApifoxUpdater.new.run(**options)
end
